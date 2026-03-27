# LiveBench Benchmark

A benchmark grove for evaluating whether Quoracle's multi-model consensus
improves accuracy on direct problem-solving tasks.

## Research Question

**"Does multi-model consensus improve accuracy on problem-solving?"**

Compare single-model baselines against multi-model consensus profiles
across 6 categories of questions.

## Hierarchy

Two-tier tree:

```
Coordinator → Solvers (one per question, dispatched via batch_async)
```

The coordinator dispatches solvers directly using `batch_async` in a
continuous replenishment loop. As solvers complete, the coordinator combines
dismissals and replacement spawns in the same round so concurrency stays full
until all questions are dispatched and no solver children remain. Solvers write
their own answer files directly. Only then does a single `score-run.sh` call
score everything and produce the report.

## How To Run

### Prerequisites

1. Run `scripts/setup-dataset.sh [release-date]` to download LiveBench data
   from HuggingFace (~5-10MB). Default release: 2024-11-25.
2. Run `scripts/prepare-data.sh --release 2024-11-25` (one-time) to prepare
   question files. For a subset:
   `prepare-data.sh --release 2024-11-25 --categories math --output-name 2024-11-25-math`
3. Create benchmark profiles in Quoracle (see Profile Strategy below).
4. Install `bwrap` (bubblewrap) for coding category auto-scoring.

### Starting a Run

1. Select the **livebench** grove in the UI.
2. Fill in **Immediate Context** with:
   ```
   Run configuration:
   - release: 2024-11-25         (name of prepared data directory under data/)
   - categories: all             (or comma-separated: math, reasoning, coding, ...)
   - concurrency: 25             (max solvers running at once)
   - solver_profile: my-solver-profile    (profile for solvers — any profile you've created)
   ```
3. Select a coordinator profile.
4. Submit.

### Profile Strategy

The coordinator is a pure orchestrator — it doesn't answer questions, so it
doesn't benefit from consensus. Only the **solver profile** matters for
comparison. The topology deliberately omits `profile` so the coordinator can
set it dynamically.

**Solver profiles** — create one profile per comparison condition you want
to test. Each profile needs only:

| capability_groups | rounds | Notes |
|---|---|---|
| file_read, file_write | varies | `rounds=0` for baselines, `rounds=N` for consensus |

### Categories

| Category | Tasks | Scoring Script | ~Questions |
|---|---|---|---|
| math | olympiad, AMPS_Hard, math_comp | `score-math.py` | 370 |
| reasoning | spatial, web_of_lies_v2, zebra_puzzle | `score-reasoning.py` | 150 |
| coding | LCB_generation, coding_completion | `score-coding.sh` | 130 |
| language | connections, plot_unscrambling, typos | `score-language.py` | 140 |
| data_analysis | tablereformat, cta, tablejoin | `score-tables.py` | 150 |
| instruction_following | IFEval-based constrained generation | `score-instructions.py` | 200 |

**All 6 categories are fully auto-scored via external Python/Bash scripts.**
The `score-run.sh` wrapper iterates all answers and calls the appropriate
per-category script. Each script returns JSON `{"score": 0.0-1.0}` to stdout.

### Cost Estimates

| Configuration | Multiplier | Est. Cost (full ~1,136 questions) |
|---|---|---|
| 1x baseline (single model, 0 rounds) | 1x | ~$3-7 |
| 2-model consensus, 2 refinement rounds | ~5x | ~$15-35 |
| 2-model consensus, 4 refinement rounds | ~9x | ~$25-60 |

For a cheaper first run, use `categories: math` (370 questions only).

## Directory Layout

```
livebench/
├── GROVE.md                            # Grove manifest (Quoracle config)
├── README.md                           # This file
├── skills/
│   ├── livebench-coordinator/SKILL.md  # Orchestrator + batch_async dispatch
│   └── livebench-solver/SKILL.md       # Problem-solver skill
├── schemas/
│   └── benchmark-report.schema.json    # Final report format
├── governance/
│   └── benchmark-integrity.md          # Fairness and isolation rules
├── bootstrap/
│   ├── global-context.md
│   ├── task-description.md
│   └── success-criteria.md
└── scripts/
    ├── setup-dataset.sh                # Download dataset from HF
    ├── prepare-data.sh                 # One-time data preparation (question files + manifest)
    ├── score-run.sh                    # Score all answers + generate report
    ├── score-math.py                   # Math scorer (olympiad, AMPS_Hard, math_comp)
    ├── score-reasoning.py              # Reasoning scorer (spatial, web_of_lies, zebra)
    ├── score-language.py               # Language scorer (connections, plot, typos)
    ├── score-coding.sh                 # Sandbox executor for coding solutions
    ├── score-tables.py                 # Data analysis scorer (CTA, reformat, join)
    └── score-instructions.py           # Instruction following constraint checker
```
