#!/usr/bin/env python3
"""Summary and coverage checks for script/test.sh (reads forge's --junit reports and --list --json output).

  test-summary.py run <logs> <mode> <inv-shard> <inv-runs> <wall-secs> <shard>...
  test-summary.py list-check <logs> <shard>...

`run` prints one row per shard (compile s, test s, pass / fail / skip) and one row per invariant campaign (runs and
calls summed over the seed processes), then checks that the tests that ran are exactly the tests the shards list
(by name, once each) and, in full mode, that every campaign that ran did the configured number of runs. Exit 1 on
any failure, missing result or mismatch.

`list-check` checks that the union of the shards' `forge test --list --json` equals the single-process reference
list (FOUNDRY_PROFILE=full forge test --list --json), with no test in two shards.
"""
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET


def load_json(path):
    """forge prints the JSON object on stdout; tolerate stray lines before it."""
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return None
    start = text.find("{")
    if start < 0:
        return None
    try:
        return json.loads(text[start:])
    except json.JSONDecodeError:
        return None


def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None


def listed(logs, shard):
    """{(file:Contract, test)} from a shard's `forge test --list --json`."""
    data = load_json(os.path.join(logs, f"{shard}.list.json"))
    if data is None:
        return None
    out = set()
    for path, contracts in data.items():
        for contract, tests in contracts.items():
            for t in tests:
                out.add((f"{path}:{contract}", t.split("(")[0]))
    return out


INVARIANT_STATS = re.compile(r"\(runs: (\d+), calls: (\d+), reverts: (\d+)\)")


def results(path):
    """{(file:Contract, test): {status, reason, secs, runs, calls}} from a `forge test --junit` report.

    JUnit rather than --json: forge's JSON carries every campaign's setUp traces (~150 MB per invariant process)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    start = text.find("<testsuites")
    if start < 0:
        return None
    try:
        root = ET.fromstring(text[start:])
    except ET.ParseError:
        return None
    out = {}
    for suite in root.iter("testsuite"):
        for case in suite.iter("testcase"):
            failure = case.find("failure")
            if failure is None:
                failure = case.find("error")
            if failure is not None:
                status, reason = "Failure", failure.get("message") or (failure.text or "")
            elif case.find("skipped") is not None:
                status, reason = "Skipped", ""
            else:
                status, reason = "Success", ""
            m = INVARIANT_STATS.search(case.findtext("system-out") or "")
            out[(suite.get("name"), case.get("name", "").split("(")[0])] = {
                "status": status,
                "reason": reason,
                "secs": float(case.get("time") or 0),
                "runs": int(m.group(1)) if m else 0,
                "calls": int(m.group(2)) if m else 0,
            }
    return out


def is_invariant(name):
    """forge runs functions named invariant* / statefulFuzz* as invariant campaigns (test.sh INV_RE)."""
    return name.startswith("invariant") or name.startswith("statefulFuzz")


def expand_setup(res, expected):
    """A suite whose setUp skips (e.g. LegacyStakingInvariants without INVARIANT_LEGACY) or fails reports a single
    "setUp" result instead of one per test: apply it to each expected test of that suite."""
    out = {k: r for k, r in res.items() if k[1] != "setUp"}
    for (suite, name), r in res.items():
        if name == "setUp":
            for k in expected:
                if k[0] == suite and k not in out:
                    out[k] = r
    return out


def run(logs, mode, inv_shard, inv_runs, wall, shards):
    ok = True
    problems = []
    listed_all = {}
    ran = {}  # key -> list of results (one per process for invariant campaigns)
    rows = []
    for s in shards:
        lst = listed(logs, s)
        failed_step = open(os.path.join(logs, f"{s}.failed")).read().strip() if os.path.exists(
            os.path.join(logs, f"{s}.failed")) else None
        if lst is None:
            problems.append(f"shard {s}: no test list ({failed_step or 'compile failed or timed out'}), "
                            f"see {logs}/{s}.build.log")
            rows.append((s, read_int(os.path.join(logs, f"{s}.compile.secs")), None, "-", "-", "-"))
            continue
        for k in lst:
            if k in listed_all:
                problems.append(f"{k[0]}::{k[1]} is listed by shards {listed_all[k]} and {s}")
            listed_all[k] = s
        res = results(os.path.join(logs, f"{s}.xml"))
        if res is None:
            problems.append(f"shard {s}: no test results, see {logs}/{s}.log")
            res = {}
        # The invariant shard's own run leaves its campaigns to the seed processes; other shards run everything.
        res = expand_setup(res, {k for k in lst if s != inv_shard or not is_invariant(k[1])})
        counts = {"Success": 0, "Failure": 0, "Skipped": 0}
        for k, r in res.items():
            ran.setdefault(k, []).append(r)
            counts[r["status"]] += 1
            if r["status"] == "Failure":
                problems.append(f"{k[0]}::{k[1]} FAILED (shard {s}): {r['reason'].strip()[:300]}")
        rows.append((s, read_int(os.path.join(logs, f"{s}.compile.secs")),
                     read_int(os.path.join(logs, f"{s}.test.secs")),
                     counts["Success"], counts["Failure"], counts["Skipped"]))

    # Invariant processes: every campaign appears once per process.
    chunk_files = sorted(glob.glob(os.path.join(logs, "inv-chunk-*.xml")),
                         key=lambda p: int(p.rsplit("-", 1)[1].split(".")[0]))
    chunks = []
    try:
        with open(os.path.join(logs, "inv-chunks.txt")) as f:
            chunks = [line.split() for line in f if line.strip()]
    except FileNotFoundError:
        pass
    inv = {}
    inv_expected = {k for k in listed_all if listed_all[k] == inv_shard and is_invariant(k[1])}
    for i, path in enumerate(chunk_files):
        res = results(path)
        if res is None:
            problems.append(f"invariant process {i}: no results, see {path[:-4]}.log")
            continue
        res = expand_setup(res, inv_expected)
        for k, r in res.items():
            inv.setdefault(k, []).append((i, r))
    if chunks and len(chunk_files) != len(chunks):
        problems.append(f"{len(chunks)} invariant processes started, {len(chunk_files)} wrote results")

    inv_rows = []
    counts = {"Success": 0, "Failure": 0, "Skipped": 0}
    for k in sorted(inv):
        parts = inv[k]
        statuses = [r.get("status", "Failure") for _, r in parts]
        runs = sum(r["runs"] for _, r in parts)
        calls = sum(r["calls"] for _, r in parts)
        secs = round(max(r["secs"] for _, r in parts))
        if "Failure" in statuses:
            status = "Failure"
            for i, r in parts:
                if r.get("status") == "Failure":
                    seed = chunks[i][2] if i < len(chunks) else "?"
                    nruns = chunks[i][1] if i < len(chunks) else "?"
                    problems.append(f"{k[0]}::{k[1]} FAILED in invariant process {i} (seed {seed}, {nruns} runs): "
                                    f"{(r.get('reason') or '').strip()[:300]}")
        elif all(st == "Skipped" for st in statuses):
            status = "Skipped"
        else:
            status = "Success"
            if len(parts) != len(chunk_files):
                problems.append(f"{k[0]}::{k[1]} ran in {len(parts)} of {len(chunk_files)} invariant processes")
            if runs != inv_runs:
                problems.append(f"{k[0]}::{k[1]}: {runs} runs in total, expected {inv_runs}")
        counts[status] += 1
        ran.setdefault(k, []).append(parts[0][1])
        inv_rows.append((k[1], len(parts), runs, calls, secs, status))
    if inv or chunks:
        rows.append((f"{inv_shard}:campaigns", None, read_int(os.path.join(logs, "inv-chunks.secs")),
                     counts["Success"], counts["Failure"], counts["Skipped"]))

    # Every listed test ran exactly once (invariant campaigns: once per process, merged above), nothing else ran.
    missing = sorted(set(listed_all) - set(ran))
    extra = sorted(set(ran) - set(listed_all))
    for k in missing[:20]:
        problems.append(f"listed but not run: {k[0]}::{k[1]}")
    for k in extra[:20]:
        problems.append(f"ran but not listed: {k[0]}::{k[1]}")
    for k, rs in ran.items():
        if len(rs) > 1:
            problems.append(f"ran more than once: {k[0]}::{k[1]}")

    # Table.
    print()
    print(f"{'shard':<16} {'compile s':>9} {'test s':>7} {'pass':>6} {'fail':>5} {'skip':>5}")
    tp = tf = ts = 0
    for s, c, t, p, f, k in rows:
        fmt = lambda v: "-" if v is None else str(v)
        print(f"{s:<16} {fmt(c):>9} {fmt(t):>7} {fmt(p):>6} {fmt(f):>5} {fmt(k):>5}")
        tp += p if isinstance(p, int) else 0
        tf += f if isinstance(f, int) else 0
        ts += k if isinstance(k, int) else 0
    print(f"{'TOTAL':<16} {'':>9} {wall:>7} {tp:>6} {tf:>5} {ts:>5}   (listed: {len(listed_all)})")
    if inv_rows:
        print()
        print(f"invariant campaigns ({len(chunk_files)} processes, runs summed; configured/requested: {inv_runs})")
        print(f"  {'campaign':<56} {'procs':>5} {'runs':>5} {'calls':>8} {'max s':>6} status")
        for name, n, runs, calls, secs, status in inv_rows:
            print(f"  {name:<56} {n:>5} {runs:>5} {calls:>8} {secs:>6} {status}")
    if mode == "quick":
        print(f"\nQUICK MODE: invariant campaigns ran {inv_runs} runs each -- not full coverage.")
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print(f"  - {p}")
        ok = False
    print()
    return 0 if ok and tf == 0 else 1


def list_check(logs, shards):
    ref = load_json(os.path.join(logs, "reference.list.json"))
    if ref is None:
        print("list-check: no reference list")
        return 1
    ref_set = set()
    for path, contracts in ref.items():
        for contract, tests in contracts.items():
            for t in tests:
                ref_set.add((f"{path}:{contract}", t))
    union = {}
    dup = []
    for s in shards:
        lst = listed(logs, s)
        if lst is None:
            print(f"list-check: shard {s} has no list")
            return 1
        for k in lst:
            if k in union:
                dup.append((k, union[k], s))
            union[k] = s
    missing = sorted(ref_set - set(union))
    extra = sorted(set(union) - ref_set)
    print(f"reference: {len(ref_set)} tests in {len(ref)} files; shards: {len(union)} tests "
          f"({', '.join(f'{s}={sum(1 for v in union.values() if v == s)}' for s in shards)})")
    for k in missing:
        print(f"  MISSING from shards: {k[0]}::{k[1]}")
    for k in extra:
        print(f"  NOT in reference: {k[0]}::{k[1]}")
    for k, a, b in dup:
        print(f"  IN TWO SHARDS ({a}, {b}): {k[0]}::{k[1]}")
    if missing or extra or dup:
        print("list-check: FAILED")
        return 1
    print("list-check: OK (identical sets, no duplicates)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "list-check":
        sys.exit(list_check(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) >= 8 and sys.argv[1] == "run":
        _, _, logs, mode, inv_shard, inv_runs, wall, *shards = sys.argv
        sys.exit(run(logs, mode, inv_shard, int(inv_runs), int(wall), shards))
    print(__doc__)
    sys.exit(2)
