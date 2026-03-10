1. Manifest loaded from pre-prepared data directory
2. All solvers dispatched via batch_async waves with concurrency control
3. All answer files written by solvers to runs/{run-id}/answers/
4. All answers scored via score-run.sh (single script call scores everything)
5. Per-category accuracy is reported for all included categories
6. Global Average is computed
7. report.json is written and validates against benchmark-report.schema.json
8. No benchmark integrity violations occurred
9. A clear summary is presented to the human with accuracy breakdown and run location
