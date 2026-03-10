1. Manifest loaded from pre-prepared data directory
2. All answerers dispatched via batch_async waves with concurrency control
3. All answer files written by answerers to runs/{run-id}/answers/
4. All answers scored via score-run.sh (3-tier regex letter extraction)
5. Per-subject accuracy is reported for all subjects present in the data
6. Aggregate accuracy (total correct / total attempted) is computed
7. report.json is written and validates against benchmark-report.schema.json
8. No benchmark integrity violations occurred (no ground truth leakage, no external lookups)
9. A clear summary is presented to the human with accuracy breakdown and run location
