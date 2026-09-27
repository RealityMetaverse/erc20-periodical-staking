#!/usr/bin/env bash
# Build and run the test suite on every core.
#
#   ./script/test.sh full         the gate: every test CI's `FOUNDRY_PROFILE=full forge test` runs, at the same
#                                 depth (fuzz and invariant settings from the full profile, untouched)
#   ./script/test.sh quick        inner dev loop: every unit and fuzz test, invariant campaigns at a REDUCED run
#                                 count (QUICK_INVARIANT_RUNS, default 32). Not full coverage; `full` is the gate.
#   ./script/test.sh list-check   prove the shards cover exactly what `FOUNDRY_PROFILE=full forge test --list`
#                                 lists: same test names, none missing, none in two shards (see below)
#
# Why it is fast:
#   - One forge process = one single-threaded solc job (via_ir). The test files are split into shards (SHARDS
#     below), each compiled by its own forge process into its own out/cache under out-shards/<shard>/, so the
#     shards compile in parallel. sparse_mode + --match-path make each process compile only its files and their
#     imports. The shipped bytecode does not depend on this: dynamic_test_linking deploys src from the src
#     artifacts, and src compilation is unchanged (see foundry.toml).
#   - The invariant wall time was set by the slowest campaign on one core. Here every campaign's runs are split
#     over INVARIANT_PROCS processes (-j 1 each) with different seeds: process i runs EVERY campaign with
#     runs_i runs, sum(runs_i) = the configured runs, depth unchanged. Each process has the same mix of work, so
#     they finish together. Runs are independent (each starts from the setUp state), so the number of runs and
#     calls per campaign is the same as a single process; what differs is the random sequences (one seed per
#     process instead of one per campaign) and that the fuzz dictionary is built per process.
#   - Each shard starts its tests as soon as it has compiled; the invariant processes start as soon as the
#     invariant shard has compiled.
#
# Measured on 8 cores / 16 threads / 15 GB (WSL): full from nothing ~13.5 min; full with nothing changed, after a
# test edit or after a src edit INSIDE a function body ~8 min -- the invariant campaigns (32 x 256 runs x depth
# 500, ~70 CPU-minutes) are that floor; quick after a src body edit ~1.5-2 min. A src edit OUTSIDE a function body
# (signature, storage, events, NatSpec, even a comment at contract/file level) changes what every test compiles
# against, so all shards rebuild: ~13 min full, ~7 min quick. Even a body edit recompiles test files that forge
# treats as mocks (a contract inheriting a src contract or interface, e.g. RewardMathHarness); those sit in their
# own small `mocks` shard (see SHARDS) so the other shards recompile only src (~20 s).
#
# Settings (environment):
#   QUICK_INVARIANT_RUNS  quick mode: runs per invariant campaign (default 32)
#   INVARIANT_SEED        base seed (decimal); process i uses INVARIANT_SEED+i. Default: random, printed.
#   INVARIANT_PROCS       invariant processes (default: chosen by memory, see pick_inv_procs; capped at the runs).
#                         1 = no split by seed: one forge process runs every campaign at full runs on all threads,
#                         the same search as a plain `forge test` (CI uses this; only the compile is sharded)
#   UNIT_THREADS          threads per shard for the unit/fuzz tests (default 4; they take seconds per shard)
#   STEP_TIMEOUT          seconds before any single forge process is killed (default 3600)
#   FORGE                 forge binary (default: forge on PATH, else ~/.foundry/bin/forge)
#
# Output: a summary table (shard, compile s, test s, pass / fail / skip), one invariant row per campaign with the
# summed runs, and logs under out-shards/logs/. Exit code 1 if any test fails, any process fails or times out, or
# the tests run differ from the tests listed.
set -euo pipefail

die() { echo "test.sh: error: $*" >&2; exit 1; }
note() { echo "test.sh: $*" >&2; }

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ $# -eq 1 ] || usage
MODE="$1"
case "$MODE" in
  full | quick | list-check) ;;
  -h | --help) usage ;;
  *) die "unknown mode '$MODE' (expected full, quick or list-check)" ;;
esac

FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
[ -x "$FORGE" ] || die "forge not found (put it on PATH or set FORGE)"
command -v python3 >/dev/null || die "python3 is required (it reads forge's JUnit / JSON output)"
command -v timeout >/dev/null || die "timeout (coreutils) is required"

STEP_TIMEOUT="${STEP_TIMEOUT:-3600}"
WORK="$ROOT/out-shards" # gitignored (/out-*)
LOGS="$WORK/logs"

# Every shard runs under the full profile (no no_match_path, same compiler settings as CI) with sparse_mode on, so
# --match-path limits what each process compiles.
export FOUNDRY_PROFILE=full
export FOUNDRY_SPARSE_MODE=true

# ---------------------------------------------------------------------------------------------------------------
# Shards. A test file goes to the FIRST shard whose pattern matches; anything unmatched (new directories, new
# files) lands in `misc`, so no file can be left out. Balanced on measured cold via_ir compile times (each shard
# ~4-6 min cold, all in parallel). `inv` holds only the invariant campaign suites: the campaigns are the longest
# work, so that shard must compile first. The other files that import the invariant Handler (HarnessSmoke,
# RewardMathFuzz, SolvencyPoC) go to the light `misc` shard.
#
# `mocks` holds the test files forge treats as mocks (a contract that inherits a src contract, see foundry.toml):
# they recompile on every src edit, even inside a function body, while every other shard then recompiles only src.
# Alone in a small shard they do not hold a big one back. Only SaturatingRewardMath.t.sol (RewardMathHarness needs the
# internal reward function) is one; an interface mock goes in its own file under test/shared/mocks/ instead, so the
# test files that use it stay ordinary. List a new unavoidable mock here.
INV_DIR=test/erc20-periodical-staking/security/invariants
SHARDS=(inv v050a v050b attacks v030 auditA auditB misc mocks)
shard_of() {
  case "$1" in
    test/erc20-periodical-staking/v030/SaturatingRewardMath.t.sol) echo mocks ;;
    "$INV_DIR"/*Invariants.t.sol) echo inv ;;
    test/v050/HarnessSmoke.t.sol | "$INV_DIR"/*) echo misc ;;
    test/v050/Voucher* | test/v050/ApyBps.t.sol) echo v050a ;;
    test/v050/*) echo v050b ;;
    test/erc20-periodical-staking/security/attacks/*) echo attacks ;;
    test/erc20-periodical-staking/v030/* | test/erc20-periodical-staking/scenarios/*) echo v030 ;;
    test/audit-poc/staking/* | test/audit-poc/verify-staking/* | test/audit-poc/verify2/*) echo auditA ;;
    test/audit-poc/* | test/requirement-checker-v2/*) echo auditB ;;
    *) echo misc ;;
  esac
}
# The shard whose files hold the invariant campaigns (they are split by seed, see above).
INV_SHARD=inv
# forge treats functions named invariant* / statefulFuzz* as invariant campaigns.
INV_RE='^(invariant|statefulFuzz)'

# forge runs test functions in every compiled file, but the shards select *.t.sol files only. Refuse test
# functions anywhere else under test/ rather than silently skip them.
stray="$(grep -rlE --include='*.sol' 'function (test|invariant|statefulFuzz)[A-Za-z0-9_]*[[:space:]]*\(' test |
  grep -v '\.t\.sol$' || true)"
[ -z "$stray" ] || die "test functions outside *.t.sol files (rename them to .t.sol): $stray"

declare -A GLOB
while IFS= read -r f; do
  s="$(shard_of "$f")"
  GLOB[$s]+="${GLOB[$s]:+,}$f"
done < <(find test -name '*.t.sol' | LC_ALL=C sort)
ACTIVE=()
for s in "${SHARDS[@]}"; do
  [ -n "${GLOB[$s]:-}" ] && ACTIVE+=("$s")
done

rm -rf "$LOGS"
mkdir -p "$LOGS"

# On Ctrl-C / SIGTERM, stop every child (forge, solc): ignore the signal here, send it to the process group.
trap 'trap "" INT TERM; kill -TERM 0 2>/dev/null; exit 130' INT TERM

# `forge test` on one shard's files, out and cache, with a hard time limit. Usage: fg <shard> <extra forge args...>
# FG_CACHE overrides the cache dir (the invariant processes each use a private copy, see run_invariants).
fg() {
  local s="$1"
  shift
  timeout --kill-after=30 "$STEP_TIMEOUT" "$FORGE" test --match-path "{${GLOB[$s]}}" \
    --out "$WORK/$s/out" --cache-path "${FG_CACHE:-$WORK/$s/cache}" "$@"
}

# ---------------------------------------------------------------------------------------------------------------
if [ "$MODE" = list-check ]; then
  # Reference: ONE forge process over everything (sparse off), as CI's `FOUNDRY_PROFILE=full forge test` sees it.
  # Which tests exist does not depend on how hard solc optimizes, so by default the reference is compiled with the
  # Yul optimizer steps emptied (via_ir kept: without it the code is stack-too-deep) into its own out dir: ~3.5 min
  # instead of ~20+. LIST_CHECK_EXACT=1 uses the real full profile and ./out instead.
  if [ "${LIST_CHECK_EXACT:-0}" = 1 ]; then
    note "reference list: FOUNDRY_PROFILE=full forge test --list (single process; ~20+ min when ./out is cold)"
    ref_args=()
  else
    note "reference list: single process, everything, Yul optimizer steps emptied (~3.5 min cold)"
    export FOUNDRY_OPTIMIZER_DETAILS='{yul=true,yulDetails={stackAllocation=true,optimizerSteps=":"}}'
    ref_args=(--out "$WORK/reference/out" --cache-path "$WORK/reference/cache")
  fi
  FOUNDRY_SPARSE_MODE=false timeout "$STEP_TIMEOUT" "$FORGE" test --list --json "${ref_args[@]}" \
    >"$LOGS/reference.list.json" 2>"$LOGS/reference.list.log" &
  ref_pid=$!
  unset FOUNDRY_OPTIMIZER_DETAILS # the shards below compile with the real settings
  pids=()
  for s in "${ACTIVE[@]}"; do
    fg "$s" --list --json >"$LOGS/$s.list.json" 2>"$LOGS/$s.build.log" &
    pids+=($!)
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || die "shard ${ACTIVE[$i]}: list failed, see $LOGS/${ACTIVE[$i]}.build.log"
  done
  wait "$ref_pid" || die "reference list failed, see $LOGS/reference.list.log"
  python3 "$ROOT/script/test-summary.py" list-check "$LOGS" "${ACTIVE[@]}"
  exit $?
fi

# ---------------------------------------------------------------------------------------------------------------
# Invariant settings.
cfg="$("$FORGE" config --json)"
cfg_get() { python3 -c 'import json,sys; c=json.loads(sys.argv[1]); print(c[sys.argv[2]][sys.argv[3]])' "$cfg" "$@"; }
CFG_INV_RUNS="$(cfg_get invariant runs)"
CFG_INV_DEPTH="$(cfg_get invariant depth)"
CFG_FUZZ_RUNS="$(cfg_get fuzz runs)"
if [ "$MODE" = full ]; then
  # The gate must run the configured depth: refuse overrides that would weaken it.
  for v in $(env | grep -oE '^FOUNDRY_(FUZZ|INVARIANT)_[A-Z_]+' || true); do
    die "$v is set; full mode runs the configured fuzz/invariant settings (unset it, or use quick)"
  done
  INV_RUNS="$CFG_INV_RUNS"
else
  INV_RUNS="${QUICK_INVARIANT_RUNS:-32}"
fi
[[ "$INV_RUNS" =~ ^[1-9][0-9]*$ ]] || die "invariant runs must be a positive integer (got '$INV_RUNS')"
NPROC="$(nproc)"
[[ "${INVARIANT_PROCS:-1}" =~ ^[1-9][0-9]*$ ]] || die "INVARIANT_PROCS must be a positive integer"
UNIT_THREADS="${UNIT_THREADS:-4}"
[[ "$UNIT_THREADS" =~ ^[1-9][0-9]*$ ]] || die "UNIT_THREADS must be a positive integer"
SEED="${INVARIANT_SEED:-$(( (RANDOM << 30) | (RANDOM << 15) | RANDOM ))}"
[[ "$SEED" =~ ^[0-9]+$ ]] || die "INVARIANT_SEED must be a decimal integer"

if [ "$MODE" = quick ]; then
  # Also applies to a campaign that sits outside the invariant shard.
  export FOUNDRY_INVARIANT_RUNS="$INV_RUNS"
  note "QUICK: invariant campaigns at $INV_RUNS runs (configured: $CFG_INV_RUNS) -- NOT full coverage, run 'full' before merging"
fi
note "shards: ${ACTIVE[*]} | invariant campaigns: $INV_RUNS runs x depth $CFG_INV_DEPTH, base seed $SEED | fuzz runs $CFG_FUZZ_RUNS"
note "logs: $LOGS"

# How many invariant processes, decided when the invariant shard has compiled. Memory, not CPU, is the limit: a
# process at full depth grows to 0.6-0.9 GB, a compiling shard (forge + solc) takes ~1 GB. Measured on 8 cores /
# 16 threads / 15 GB, full depth: 16 processes 457 s (1.4 GB left free), 12 processes 472 s, 8 processes 550 s;
# with 7 shards still compiling from scratch next to 12 processes the machine went into swap. So: 1/2 of the
# logical CPUs when this was a long (cold-like) compile and other shards are still compiling -- they will be for
# minutes; 3/4 otherwise (an incremental compile elsewhere finishes long before the processes grow); all of them for
# a quick run (a few runs per process stay small). Usage: pick_inv_procs <seconds the invariant shard compiled>
pick_inv_procs() {
  local busy=0 o n
  for o in "${ACTIVE[@]}"; do
    [ "$o" = "$INV_SHARD" ] && continue
    [ -f "$LOGS/$o.compile.secs" ] || [ -f "$LOGS/$o.failed" ] || busy=$((busy + 1))
  done
  if [ -n "${INVARIANT_PROCS:-}" ]; then
    n="$INVARIANT_PROCS"
  elif [ "$MODE" = quick ]; then
    n="$NPROC"
  elif [ "$busy" -gt 0 ] && [ "$1" -gt 60 ]; then
    n=$(((NPROC + 1) / 2))
  else
    n=$(((NPROC * 3 + 3) / 4))
  fi
  [ "$n" -gt "$INV_RUNS" ] && n="$INV_RUNS"
  echo "$n"
}

# ---------------------------------------------------------------------------------------------------------------
# Runs the invariant campaigns: INV_PROCS processes, process i with runs_i runs and seed SEED+i.
run_invariants() {
  local s="$INV_SHARD" base=$((INV_RUNS / INV_PROCS)) extra=$((INV_RUNS % INV_PROCS)) i runs pids=() rc=0
  local t0=$SECONDS jobs=(-j 1)
  # One process (INVARIANT_PROCS=1, what CI uses): forge runs the campaigns in parallel on its own threads, each with
  # every run, exactly like a plain `forge test` -- no split by seed.
  [ "$INV_PROCS" -eq 1 ] && jobs=()
  for ((i = 0; i < INV_PROCS; i++)); do
    runs=$((base + (i < extra ? 1 : 0)))
    echo "$i $runs $((SEED + i))" >>"$LOGS/inv-chunks.txt"
    FOUNDRY_INVARIANT_RUNS="$runs" FG_CACHE="$WORK/$s/pcache/$i" \
      fg "$s" --junit "${jobs[@]}" --match-test "$INV_RE" --fuzz-seed "$((SEED + i))" \
      >"$LOGS/inv-chunk-$i.xml" 2>"$LOGS/inv-chunk-$i.log" &
    pids+=($!)
    sleep 0.5 # spread the start-up (each process loads every artifact at once), which is the memory peak
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { echo "$? " >"$LOGS/inv-chunk-$i.rc"; rc=1; }
  done
  echo $((SECONDS - t0)) >"$LOGS/inv-chunks.secs"
  return $rc
}

# Number of tests a shard lists (after its compile step). Usage: count_listed <shard> all|non-invariant
count_listed() {
  python3 - "$LOGS/$1.list.json" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
names = [t for contracts in data.values() for tests in contracts.values() for t in tests]
if sys.argv[2] == "non-invariant":
    names = [t for t in names if not t.startswith(("invariant", "statefulFuzz"))]
print(len(names))
PY
}

# One shard: compile (forge test --list, which also records what the shard should run), then run its tests. The
# invariant shard starts the invariant processes as soon as it has compiled.
run_shard() {
  local s="$1" t0=$SECONDS inv_pid="" rc=0 i
  if ! fg "$s" --list --json >"$LOGS/$s.list.json" 2>"$LOGS/$s.build.log"; then
    echo "compile" >"$LOGS/$s.failed"
    return 1
  fi
  echo $((SECONDS - t0)) >"$LOGS/$s.compile.secs"
  t0=$SECONDS
  if [ "$s" = "$INV_SHARD" ]; then
    INV_PROCS="$(pick_inv_procs "$(cat "$LOGS/$s.compile.secs")")"
    note "invariant campaigns: $INV_RUNS runs each, split over $INV_PROCS processes (seeds $SEED..$((SEED + INV_PROCS - 1)))"
    # forge rewrites the cache file on every run, even when it compiles nothing. The invariant processes all read
    # the shared, already-built out/, but each gets its own copy of the cache (made here, before any of them or
    # the shard's own test run starts), so none can read a half-written cache file and recompile into out/.
    for ((i = 0; i < INV_PROCS; i++)); do
      rm -rf "$WORK/$s/pcache/$i"
      mkdir -p "$WORK/$s/pcache/$i"
      cp "$WORK/$s/cache/solidity-files-cache.json" "$WORK/$s/pcache/$i/"
    done
    run_invariants &
    inv_pid=$!
  fi
  # The invariant shard's other tests; every other shard runs all of its tests (an invariant campaign that ends up
  # outside `inv` still runs, at the configured depth, just not split by seed).
  local filter=() kind=all
  if [ "$s" = "$INV_SHARD" ]; then
    filter=(--no-match-test "$INV_RE")
    kind=non-invariant
  fi
  if [ "$(count_listed "$s" "$kind")" -eq 0 ]; then
    echo '<testsuites/>' >"$LOGS/$s.xml" # nothing to run here (forge fails on "no tests match")
  else
    fg "$s" --junit -j "$UNIT_THREADS" "${filter[@]}" >"$LOGS/$s.xml" 2>"$LOGS/$s.log" || rc=1
  fi
  echo $((SECONDS - t0)) >"$LOGS/$s.test.secs"
  if [ -n "$inv_pid" ]; then
    wait "$inv_pid" || rc=1
  fi
  return $rc
}

T0=$SECONDS
pids=()
for s in "${ACTIVE[@]}"; do
  mkdir -p "$WORK/$s"
  run_shard "$s" &
  pids+=($!)
done
status=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || status=1
done
WALL=$((SECONDS - T0))

python3 "$ROOT/script/test-summary.py" run "$LOGS" "$MODE" "$INV_SHARD" "$INV_RUNS" "$WALL" "${ACTIVE[@]}" || status=1

if [ "$status" -ne 0 ]; then
  note "FAILED (logs: $LOGS)"
  note "replay a failed invariant process (runs and seed per process in $LOGS/inv-chunks.txt; forge also keeps the"
  note "failing sequence under cache/invariant/failures and replays it first on the next run):"
  note "  FOUNDRY_PROFILE=full FOUNDRY_SPARSE_MODE=true FOUNDRY_INVARIANT_RUNS=<runs> forge test \\"
  note "    --match-path '$INV_DIR/*Invariants.t.sol' --match-test '<name>\\(' --fuzz-seed <seed> -vvv"
  exit 1
fi
if [ "$MODE" = quick ]; then
  note "quick run passed (invariants at $INV_RUNS runs; NOT the gate -- run ./script/test.sh full before merging)"
else
  note "full run passed in ${WALL}s"
fi
