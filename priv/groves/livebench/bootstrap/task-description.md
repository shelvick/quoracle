**RUN LIVEBENCH BENCHMARK.**

Execute the benchmark coordinator sequence:

1. Read `manifest.json` from the pre-prepared data directory
2. Create a run directory with `config.json`
3. Dispatch solvers by sequential question index via batch_async waves
4. Score all answers via `{grove_root}/scripts/score-run.sh`
5. Read report.json and present accuracy summary to human

**Hierarchy:** Coordinator → Solvers (direct dispatch, no intermediate managers)

**Dispatch efficiency:** Use `batch_async` to combine dismiss_child and spawn_child
actions in a single consensus round. Solvers write their own answer files directly.
This minimizes coordinator overhead.

**Data preparation:** The dataset must be pre-prepared via `prepare-data.sh` (one-time).
No per-run preparation is needed — the coordinator reads from pre-built question files.

**Scoring:** A single `score-run.sh` call auto-scores all categories. No manual scoring needed.

Refer to your livebench-coordinator skill for the complete procedure.
