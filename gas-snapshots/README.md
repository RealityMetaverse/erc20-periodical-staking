# Gas snapshots

One `forge snapshot` per released version, each produced from that version's own code and tests.

| File | Version | Commit |
|---|---|---|
| v0.2.3.gas-snapshot | v0.2.3 | f0a5734 |
| v0.2.4.gas-snapshot | v0.2.4 | e56c3c2 |
| v0.3.0.gas-snapshot | v0.3.0 | 13699fe |
| v0.4.0.gas-snapshot | v0.4.0 | the v0.4.0 commit |

v0.1.0 to v0.2.2 have no snapshot. Those commits do not track their libraries (no `lib/` submodules or remappings), so their tests cannot be rebuilt reliably today.

Command (run at each commit):

    forge snapshot --snap gas-snapshots/<version>.gas-snapshot --fuzz-seed 1 --no-match-path 'test/**/invariants/**'

Notes:
- Invariant suites are excluded: they take most of the run time and do not measure per-call gas.
- A fixed fuzz seed keeps fuzz-test averages reproducible.
- Each version has its own test suite, so lines are only comparable where the same test exists in both files.
