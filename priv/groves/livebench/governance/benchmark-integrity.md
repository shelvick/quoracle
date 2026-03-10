# Benchmark Integrity Rules (v1.0)

These rules protect the validity of benchmark results. Violations invalidate
the entire run.

## Rule B1: No External Lookups During Solving

Solver agents MUST NOT use any tool that accesses external information
during problem solving:

- No `fetch_web` or `answer_engine` actions
- No `execute_shell` commands that access the network
- No `call_api` to any external service
- No `call_mcp` to any tool that fetches external data

The coordinator MAY use `execute_shell` and `file_read`/`file_write` for
dataset loading, result persistence, and scoring. The coordinator MUST NOT
use external tools to help answer questions on behalf of children.

**Rationale:** Benchmark scores measure the model's problem-solving ability,
not its ability to look things up.

## Rule B2: No Dataset Contamination

- Ground truth answers MUST NOT be included in prompts sent to solvers
- Solvers receive only the question file (read via file_read) — no ground
  truth is included in question files
- The `ground_truth` field from the dataset is retained in a separate file
  for scoring only
- No agent in the hierarchy MUST hint at correct answers in task descriptions

**Rationale:** Leaking answers defeats the purpose of benchmarking.

## Rule B3: Deterministic Scoring

- All categories are auto-scored via deterministic scripts — no LLM judgment
- Scoring logic is identical regardless of which profile or model is used

**Rationale:** Consistent scoring enables fair comparison across profiles.

## Rule B4: Run Isolation

- Each run writes to its own `runs/{run-id}/` directory
- Runs MUST NOT read from other runs' directories
- The dataset in `data/` is read-only during runs
- Agents from one run MUST NOT communicate with agents from another run
  (this is structurally enforced by Quoracle's agent hierarchy)

**Rationale:** Independent runs ensure reproducibility.

## Rule B5: No Code Execution During Solving

Solver agents MUST NOT execute code to test solutions. They must submit
their best solution based on reasoning alone. This matches standard
benchmark conditions where models generate solutions without a REPL.

**Rationale:** Execution feedback creates an unfair advantage that isn't
reflected in published baseline scores.
