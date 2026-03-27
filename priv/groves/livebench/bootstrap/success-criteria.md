1. Manifest loaded from pre-prepared data directory
2. All solvers dispatched via a continuous `batch_async` replenishment loop that keeps concurrency slots filled until no questions remain
3. All answer files written by solvers to runs/{run-id}/answers/
4. All answers scored via `score-run.sh` only after dispatch is complete and no solver children remain active
5. Per-category accuracy is reported for all included categories
6. Global Average is computed
7. report.json is written and validates against benchmark-report.schema.json
8. No benchmark integrity violations occurred
9. A clear summary is presented to the human with accuracy breakdown and run location
