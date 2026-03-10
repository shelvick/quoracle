---
name: mmlu-coordinator
description: >
  Coordinates MMLU-Pro benchmark runs. Reads a pre-built manifest, dispatches
  one answerer per question by sequential index using batch_async, then scores
  all answers via score-run.sh and produces the benchmark report.
  Use when running MMLU-Pro evaluations.
  Do NOT use for general Q&A tasks.
metadata:
  version: "1.0"
  complexity: high
  estimated_tokens: 2000
  capability_groups_required: file_read,file_write,hierarchy,local_execution
---

# MMLU-Pro Benchmark Coordinator

You coordinate MMLU-Pro benchmark runs. You dispatch one **answerer** per
question directly (no intermediate managers). You run a **continuous
pipeline**: as answerers complete, you dismiss them and spawn replacements
— all in a SINGLE `batch_async` call per round. Answerers write their own
answer files directly. Concurrency slots stay full at all times. After all
answerers complete, you score everything via a single script call.

Your grove root is visible in your system prompt under "Grove Context".
Scripts live at `{grove_root}/scripts/`.

## Run Configuration

Read these parameters from your task's Immediate Context:

- `answerer_profile`: Profile name for answerer children (any profile the user has created)
- `concurrency`: Max answerers running at once (default: 25)
- `split`: Dataset name under `data/` (default: "test"; also "validation" for smoke tests)
- `subjects`: Which subjects to run — "all" or comma-separated list (default: "all")
- `max_questions`: Optional limit — dispatch at most this many questions

## Session Contract

```
PROCEDURE run_benchmark(config):

    # ── 1. READ MANIFEST ──────────────────────────────────────────────
    # The dataset is pre-prepared. No per-run preparation needed.

    data_dir = ~/.quoracle/benchmarks/mmlu-pro/data/{split}

    Read {data_dir}/manifest.json → manifest

    # manifest.categories is a map: subject_name → {start, count}
    # Questions are numbered sequentially, sorted by subject.
    # Each subject occupies a contiguous range of indices.

    # ── Compute dispatch ranges from subject filter ───────────────────
    IF subjects == "all" OR subjects is not specified:
        ranges = [(0, manifest.total)]
    ELSE:
        ranges = []
        FOR EACH subject in subjects (comma-separated):
            IF subject in manifest.categories:
                cat = manifest.categories[subject]
                ranges.append( (cat.start, cat.start + cat.count) )
            ELSE:
                Report warning: "Subject '{subject}' not found in manifest, skipping"
        END FOR
        Sort ranges by start index
    END IF

    total_to_dispatch = sum of (end - start) for each (start, end) in ranges
    IF max_questions is set AND max_questions < total_to_dispatch:
        total_to_dispatch = max_questions
    END IF

    Report: "Manifest: {manifest.total} questions total. Dispatching {total_to_dispatch} across {len(ranges)} range(s)."

    # ── 2. CREATE RUN DIRECTORY ────────────────────────────────────────

    result = execute_shell(
        command: "RUN_ID=run-$(date -u +%Y%m%dT%H%M%SZ) && " +
            "RUN_DIR=$HOME/.quoracle/benchmarks/mmlu-pro/runs/$RUN_ID && " +
            "mkdir -p \"$RUN_DIR/answers\" && " +
            "echo \"run_dir=$RUN_DIR\"",
        working_dir: "$HOME/.quoracle/benchmarks/mmlu-pro/runs"
    )

    run_dir = extract path after "run_dir=" from result.stdout

    file_write: {run_dir}/config.json with JSON:
        {
            "run_id": (extracted run_id),
            "benchmark": "mmlu-pro",
            "answerer_profile": answerer_profile,
            "split": split,
            "subjects": subjects,
            "concurrency": concurrency,
            "total_dispatched": total_to_dispatch,
            "data_dir": data_dir,
            "started_at": (current UTC timestamp)
        }

    # ── 3. DISPATCH + COLLECT (continuous flow via batch_async) ────────
    #
    # This is a CONTINUOUS PIPELINE, not batch-of-25-then-wait.
    # Keep concurrency slots full at all times. Each round:
    #   1. Gather ALL completed children (every pending message)
    #   2. Build ONE batch_async combining dismissals + new spawns
    #   3. Execute — the pipeline never drains to zero mid-run
    #
    # NOTE: Workers write their own answer files, so the coordinator
    # only needs dismiss + spawn — use batch_async (not batch_sync)
    # since these are independent fire-and-forget actions.
    #
    # EFFICIENCY RULES (critical — each coordinator round is expensive):
    #   - Process ALL pending messages per round, not one at a time
    #   - ALWAYS combine dismiss + spawn in the SAME batch_async
    #   - NEVER submit a batch with only dismissals when questions remain
    #   - Target: 1 coordinator round per N completions (not N rounds per 1)
    #
    # Track three values: range_idx, next_index, dispatched.
    # <children> block (injected into your prompt) is ground truth for
    # active children count.
    #
    range_idx = 0
    next_index = ranges[0].start      # first index in first range
    dispatched = 0

    WHILE dispatched < total_to_dispatch OR <children> is not empty:

        batch = []

        # A) Gather ALL completed children — dismiss each
        #    Look at ALL children in <children> that have sent a message.
        #    If 8 children have responded, add all 8 to the batch here.
        #    IMPORTANT: Only process children listed in <children>. Once a
        #    child is dismissed it leaves <children> — do NOT re-process it.
        #    (Workers write their own answer files — no file_write needed here.)
        FOR EACH child in <children> that has sent a message:
            batch.append({
                action: dismiss_child,
                params: {agent_id: the child's agent_id from <children>}
            })
        END FOR

        # B) Immediately fill open slots with new spawns (same batch!)
        children_remaining = (count of <children>) - (number of dismiss actions in batch)
        WHILE children_remaining < concurrency AND dispatched < total_to_dispatch:

            batch.append({
                action: spawn_child,
                params: {
                    skill: mmlu-answerer,
                    profile: answerer_profile,
                    task: "Answer the MMLU-Pro question in {data_dir}/questions/{next_index:05d}.json.
                           Read the file, follow the prompt exactly. Write your answer
                           to {run_dir}/answers/{next_index:05d}.txt then confirm."
                }
            })
            dispatched += 1
            next_index += 1
            children_remaining += 1

            # Advance to next range if we've exhausted the current one
            IF range_idx < len(ranges) AND next_index >= ranges[range_idx].end:
                range_idx += 1
                IF range_idx < len(ranges):
                    next_index = ranges[range_idx].start
            END IF

        END WHILE

        # C) Execute the SINGLE combined batch
        #    Example steady-state batch with 5 completions:
        #      [dismiss, dismiss, ..., spawn, spawn, spawn, spawn, spawn]
        #      = 10 actions in ONE batch_async call = ONE coordinator round
        IF batch is not empty:
            batch_async(batch)
        ELSE:
            wait
        END IF

    END WHILE

    # ── 4. SCORE ────────────────────────────────────────────────────
    result = execute_shell(
        command: "{grove_root}/scripts/score-run.sh --run-dir {run_dir} --data-dir {data_dir}",
        working_dir: run_dir
    )

    IF result.exit_code != 0:
        Report: "Scoring failed: {result.stderr}"
    END IF

    # ── 5. REPORT ───────────────────────────────────────────────────
    Read {run_dir}/report.json → report

    Report summary to human:
      - Overall accuracy: X.XX%
      - Per-subject breakdown
      - Questions unanswered (extraction failures)
      - Run directory location

END PROCEDURE
```

## Error Handling

- If an answerer fails entirely, its question has no answer file — scored as incorrect by score-run.sh.
- If scoring fails, report the error and the run directory so the user can debug.
- If the manifest is missing, tell the user to run `prepare-data.sh --split {split}` first.
