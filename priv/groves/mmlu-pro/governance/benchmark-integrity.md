# Benchmark Integrity Rules (v1.0)

These rules protect the validity of benchmark results. Violations invalidate
the entire run.

## Rule B1: No External Lookups During Answering

Answerer agents MUST NOT use any tool that accesses external information
during question answering:

- No `fetch_web` or `answer_engine` actions
- No `execute_shell` commands that access the network
- No `call_api` to any external service
- No `call_mcp` to any tool that fetches external data

The coordinator MAY use `file_read`/`file_write` for manifest loading,
result persistence, and scoring. The coordinator MAY use `execute_shell`
for creating run directories and running score-run.sh.
The coordinator MUST NOT use external tools to help answer questions on
behalf of children.

**Rationale:** Benchmark accuracy measures the model's knowledge and
reasoning ability, not its ability to look things up.

## Rule B2: No Dataset Contamination

- Ground truth answers MUST NOT be included in prompts sent to answerers
- Answerers receive only: question_id, category, and the assembled prompt
  (containing question text and options)
- The `answer` and `answer_index` fields from the dataset are retained by
  the coordinator for scoring only
- No agent in the hierarchy MUST hint at correct answers in task descriptions

**Rationale:** Leaking answers defeats the purpose of benchmarking.

## Rule B3: Deterministic Scoring

- Scoring uses regex letter extraction, not LLM judgment
- The three-tier regex pattern (implemented in score-run.sh) is the
  canonical scoring method
- If no letter can be extracted, the answer is scored as incorrect
  (counted as "unanswered" in the report, but NOT skipped from totals)
- Scoring logic is the same regardless of profile or model

**Rationale:** Consistent scoring enables fair comparison across profiles.

## Rule B4: Run Isolation

- Each run writes to its own `runs/{run-id}/` directory
- Runs MUST NOT read from other runs' directories
- The dataset in `data/` is read-only during runs
- Agents from one run MUST NOT communicate with agents from another run
  (this is structurally enforced by Quoracle's agent hierarchy)

**Rationale:** Independent runs ensure reproducibility.

## Rule B5: No Shell Commands During Answering

Answerer agents MUST NOT use `execute_shell` for any purpose. They must
answer from training knowledge only, without executing code or running
external tools. This matches standard benchmark conditions.

**Rationale:** Shell access could be used to circumvent benchmark isolation
rules or gain unfair advantages.
