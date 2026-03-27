**RUN MMLU-PRO BENCHMARK.**

Execute the benchmark coordinator sequence:

1. Read `manifest.json` from the pre-prepared data directory
2. Create a run directory with `config.json`
3. Dispatch answerers by sequential question index via a continuous `batch_async` pipeline that immediately refills open slots until all questions are dispatched and all children are finished
4. Only after the dispatch-and-collect loop is fully complete, score all answers via `{grove_root}/scripts/score-run.sh`
5. Read report.json and present accuracy summary to human

**Hierarchy:** Coordinator → Answerers (direct dispatch, no intermediate managers)

**Dispatch efficiency:** Use `batch_async` to combine `dismiss_child` and `spawn_child`
actions in the same coordinator round so open slots are refilled immediately.
Do not run in waves or let the pipeline drain while questions remain. Answerers
write their own answer files directly. This minimizes coordinator overhead.

**Data preparation:** The dataset must be pre-prepared via `prepare-data.sh` (one-time).
No per-run preparation is needed — the coordinator reads from pre-built question files.

**For smoke tests:** Use `split: validation` (70 questions).
**For full runs:** Use `split: test` (12,032 questions).

**Scoring:** Run `score-run.sh` exactly once, after all questions have been dispatched and all answerer children have completed.

Refer to your mmlu-coordinator skill for the complete procedure.
