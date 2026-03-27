# MMLU-Pro Benchmark

A benchmark grove for evaluating whether Quoracle's multi-model consensus
improves accuracy on knowledge and reasoning tasks.

## Research Question

**"Does consensus improve accuracy on knowledge tasks?"**

Compare raw single-model performance against multi-model consensus on
12,032 multiple-choice questions spanning 14 academic subjects (biology,
business, chemistry, computer science, economics, engineering, health,
history, law, math, philosophy, physics, psychology, other).

## Hierarchy

Two-tier tree:

```
Coordinator → Answerers (one per question, dispatched via batch_async)
```

The coordinator dispatches answerers directly using `batch_async` in a
continuous replenishment loop. As answerers complete, the coordinator combines
dismissals and replacement spawns in the same round so concurrency stays full
until all questions are dispatched and no answerer children remain. Answerers
write their own answer files directly. Only then does a single `score-run.sh`
call apply letter extraction and produce the report.

## How To Run

### Prerequisites

1. Run `scripts/setup-dataset.sh` to download and convert the MMLU-Pro
   dataset from HuggingFace (~15MB on disk).
2. Run `scripts/prepare-data.sh --split test` (one-time) to prepare
   question files with 5-shot CoT prompts. For a subset:
   `prepare-data.sh --split test --subjects math,physics --output-name test-math`
3. Create benchmark profiles in Quoracle (see Profile Strategy below).

### Starting a Run

1. Select the **mmlu-pro** grove in the UI.
2. The form pre-fills from bootstrap. Fill in **Immediate Context** with:
   ```
   Run configuration:
   - split: test                (name of prepared data directory under data/)
   - subjects: all              (or comma-separated: math, physics, biology, ...)
   - concurrency: 25            (max answerers at once)
   - answerer_profile: my-answerer-profile  (profile for answerers — see Profile Strategy)
   ```
3. Select a coordinator profile.
4. Submit.

### Profile Strategy

The coordinator is a pure orchestrator — it doesn't answer questions, so it
doesn't benefit from consensus. Only the **answerer profile** matters for
comparison. The topology deliberately omits `profile` so the coordinator can
set it dynamically.

**Answerer profiles** — create one profile per comparison condition you want
to test. Each profile needs only:

| capability_groups | rounds | Notes |
|---|---|---|
| file_read, file_write | varies | `rounds=0` for baselines, `rounds=N` for consensus |

The model pool and round count are entirely your choice — that's the whole
point. Example comparison strategies:

- **Single-model baselines**: One profile per model, `rounds=0`, single model in pool
- **Consensus comparison**: Same models but with `rounds=2` or `rounds=4`
- **Multi-model consensus**: Multiple models in pool with refinement rounds
- **Cross-model**: Different single-model baselines compared side by side

Answerers need `file_read` (to read question files) and `file_write` (to
write their answer files). All "always allowed" actions (send_message,
orient, wait, todo) work regardless. The hard_rules in governance mechanically
block shell/internet access for answerers even if capability_groups were broader.

### Cost Estimates

| Configuration | Multiplier | Est. Cost (full 12K run) |
|---|---|---|
| 1x baseline (single model, 0 rounds) | 1x | ~$8-15 |
| 2-model consensus, 2 refinement rounds | ~5x | ~$40-75 |
| 2-model consensus, 4 refinement rounds | ~9x | ~$75-135 |

Use the **validation split** (70 questions, ~$0.50) for smoke tests.

## Scoring

Deterministic 3-tier regex letter extraction (performed by `score-run.sh`),
matching the [official MMLU-Pro evaluation](https://github.com/TIGER-AI-Lab/MMLU-Pro):

1. `answer is \(?([A-J])\)?` — canonical format (lowercase "answer", no "The" required)
2. `.*[aA]nswer:\s*([A-J])` — colon format (greedy prefix matches LAST occurrence)
3. Last standalone `\b[A-J]\b` in response — fallback

If no letter can be extracted, the answer is scored as **incorrect** (not skipped).

## Methodology

This grove uses **5-shot Chain-of-Thought** prompting, matching the
[official MMLU-Pro evaluation](https://github.com/TIGER-AI-Lab/MMLU-Pro).
The 5 few-shot examples per category come from the validation split and
are pre-assembled into each question file by `prepare-data.sh`.

The only difference from the official evaluation is the Quoracle
orchestration overhead (system prompt, action format, multi-agent dispatch).
This overhead is the same for both baseline and consensus conditions,
so the comparison remains valid for the research question.

## Directory Layout

```
mmlu-pro/
├── GROVE.md                              # Grove manifest (Quoracle config)
├── README.md                             # This file
├── skills/
│   ├── mmlu-coordinator/SKILL.md         # Orchestrator + batch_async dispatch
│   └── mmlu-answerer/SKILL.md            # Question-answerer skill
├── schemas/
│   └── benchmark-report.schema.json      # Final report format
├── governance/
│   └── benchmark-integrity.md            # Fairness and isolation rules
├── bootstrap/
│   ├── global-context.md                 # Benchmark context for form
│   ├── task-description.md               # What the coordinator does
│   └── success-criteria.md               # Completion gates
└── scripts/
    ├── setup-dataset.sh                  # Download + convert dataset
    ├── prepare-data.sh                   # One-time data preparation (question files + manifest)
    └── score-run.sh                      # Score all answers + generate report
```
