---
name: mmlu-coordinator
description: >
  Coordinates MMLU-Pro benchmark runs. Reads a pre-built manifest, dispatches
  one answerer per question by sequential index using batch_async, then scores
  all answers via score-run.sh and produces the benchmark report.
  Use when running MMLU-Pro evaluations.
  Do NOT use for general Q&A tasks.
metadata:
  version: "1.1"
  complexity: high
  estimated_tokens: 2000
  capability_groups_required: file_read,file_write,hierarchy,local_execution
---

# MMLU-Pro Benchmark Coordinator

You coordinate MMLU-Pro benchmark runs. You dispatch one **answerer** per
question directly (no intermediate managers). Answerers write their own answer
files. After every answerer has finished, you score everything via a single
script call.

Your grove root is visible in your system prompt under "Grove Context".
Scripts live at `{grove_root}/scripts/`.

## Run Configuration

Read these parameters from your task's Immediate Context:

- `answerer_profile`: Profile name for answerer children (any profile the user has created)
- `concurrency`: Max answerers running at once (default: 25)
- `split`: Dataset name under `data/` (default: "test"; also "validation" for smoke tests)
- `subjects`: Which subjects to run — "all" or comma-separated list (default: "all")
- `max_questions`: Optional limit — dispatch at most this many questions

## Setup Phase (do these once, in order)

### 1. Read Manifest

```
data_dir = ~/.quoracle/benchmarks/mmlu-pro/data/{split}
```

Read `{data_dir}/manifest.json`. The manifest has `categories` (a map of
subject_name → `{start, count}`) and `total`. Questions are numbered
sequentially, sorted by subject.

Compute dispatch ranges from the subject filter:
- If `subjects` is "all" or unset: one range `(0, manifest.total)`
- Otherwise: for each requested subject, add `(cat.start, cat.start + cat.count)`, sort by start

Compute `total_to_dispatch` = sum of range lengths, capped by `max_questions` if set.

### 2. Create Run Directory

```
execute_shell: RUN_ID=run-$(date -u +%Y%m%dT%H%M%SZ) && \
  RUN_DIR=$HOME/.quoracle/benchmarks/mmlu-pro/runs/$RUN_ID && \
  mkdir -p "$RUN_DIR/answers" && echo "run_dir=$RUN_DIR"
```

Write `{run_dir}/config.json` with run metadata (run_id, benchmark, answerer_profile,
split, subjects, concurrency, total_dispatched, data_dir, started_at).

### 3. Initialize Dispatch Tracker

Use a `todo` action to create your dispatch tracker. This is your durable
state — it survives context condensation. Example:

```
todo: [
  {"content": "DISPATCH: 0/70 dispatched | next_index=0 range_idx=0 | run_dir=/path/to/run", "state": "pending"},
  {"content": "PHASE: dispatching", "state": "pending"}
]
```

Update the DISPATCH line's numbers every round. This is how you remember
where you are even if your conversation history is condensed.

## Dispatch Phase — Per-Round Decision Table

**Every consensus round**, read your `<children>` block and your todo tracker,
then follow the FIRST matching rule:

| # | Condition | Action | wait |
|---|-----------|--------|------|
| 1 | Children with messages AND questions remain | `batch_async`: dismiss every child that sent a message + spawn replacements to fill concurrency. Update todo DISPATCH line. | `true` |
| 2 | Children with messages AND no questions remain | `batch_async`: dismiss every child that sent a message. Update todo DISPATCH line. | `true` |
| 3 | No children at all AND questions remain (first round, or error recovery) | `batch_async`: spawn up to `concurrency` children. Update todo DISPATCH line. | `true` |
| 4 | No children at all AND no questions remain | **Dispatch complete.** Update todo PHASE to "scoring". Proceed to Scoring Phase. | — |
| 5 | Children active but none have sent messages | Nothing to do yet. | `true` |

**How many to spawn each round:**
```
children_after_dismiss = (children in <children>) - (children being dismissed)
spawn_count = min(concurrency - children_after_dismiss, questions_remaining)
```
Never exceed `concurrency` active children. The `<children>` block is ground
truth for the current count.

**Rules that apply to EVERY round:**
- Process ALL children that have sent a message, not just one.
- Combine all dismiss + spawn actions into a SINGLE `batch_async` call.
- NEVER issue a batch of only dismissals when questions remain — always pair with spawns.
- The `<children>` block is ground truth for active children. Your todo tracks dispatched/total.

**How to spawn an answerer:**
```json
{
  "action": "spawn_child",
  "params": {
    "skill": "mmlu-answerer",
    "profile": "<answerer_profile>",
    "task": "Answer the MMLU-Pro question in <data_dir>/questions/<INDEX>.json. Read the file, follow the prompt exactly. Write your answer to <run_dir>/answers/<INDEX>.txt then confirm."
  }
}
```
Index is zero-padded to 5 digits (e.g., `00042`). Advance through ranges sequentially.

**Advancing through ranges:** When `next_index` reaches the end of the current
range, move `range_idx` forward and set `next_index` to the next range's start.

## Scoring Phase

**PREREQUISITE:** Your `<children>` block shows NO active children AND your
todo says all questions have been dispatched. If either condition is false,
you are still in the Dispatch Phase — go back to the decision table.

```
execute_shell: {grove_root}/scripts/score-run.sh --run-dir {run_dir} --data-dir {data_dir}
```

If scoring fails, report the error and the run directory.

## Report Phase

Read `{run_dir}/report.json` and present to the human:
- Overall accuracy: X.XX%
- Per-subject breakdown
- Questions unanswered (extraction failures)
- Run directory location

## Error Handling

- If an answerer fails entirely, its question has no answer file — scored as incorrect by score-run.sh.
- If scoring fails, report the error and the run directory so the user can debug.
- If the manifest is missing, tell the user to run `prepare-data.sh --split {split}` first.
