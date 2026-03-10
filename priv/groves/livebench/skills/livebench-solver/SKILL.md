---
name: livebench-solver
description: >
  Solves a single LiveBench benchmark question. Reads the question from
  a file and answers it directly. Use when spawned by livebench-coordinator.
  Do NOT use for MMLU-Pro or non-benchmark tasks.
metadata:
  version: "1.0"
  complexity: medium
  estimated_tokens: 1500
  capability_groups_required: file_read,file_write
---

# LiveBench Solver

You solve ONE LiveBench benchmark question.

## Workflow

1. Read the question file from the path in your task description.
2. The `turns` field contains the complete question prompt with all
   instructions and format requirements already included. Long prompts
   may be split across multiple `turns` entries for readability — read
   ALL entries as one continuous prompt.
3. Answer the question directly — follow the prompt's instructions
   exactly as written.
4. Write your answer to the answer file path given in your task description
   (the `file_write` path ending in `.txt`).
5. Send a short confirmation message to your parent (the coordinator).

## How to Answer

The question prompt in `turns[0]` already tells you exactly what format
to use for your answer (e.g., `\boxed{}`, `**bold**`, `<solution>` tags,
code fences, plain text, etc.). Follow those instructions precisely.
Do NOT add any extra formatting beyond what the question asks for.

For coding questions: if `starter_code` is provided in the question file,
use that code structure as your starting point.

Write your COMPLETE answer. Do not abbreviate, summarize, or use `...`
to indicate continuation. Every word of your response will be scored.

## Response Format

Write your answer as **plain text** to the answer file — NOT JSON. Just
write your answer exactly as the question's instructions specify. This
matches the standard LiveBench evaluation format.

Do NOT wrap your answer in JSON, code fences, or any other structure
beyond what the question itself asks for.

## Integrity Rules

1. **No external lookups** — Do NOT use fetch_web, call_api, answer_engine,
   or any tool that accesses external information.
2. **No shell commands** — Do NOT use execute_shell.
3. **Answer the question** — Do not skip it. If unsure, give your best answer.
4. **Independent answer** — Ground truth is not provided. Solve from your
   own knowledge and reasoning.
