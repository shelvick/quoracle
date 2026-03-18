---
name: livebench
description: >
  LiveBench benchmark runner. ~1150 questions per release across
  6 supported categories (math, reasoning, coding, language, data_analysis,
  instruction_following). Tests whether Quoracle's multi-model consensus
  improves accuracy on direct problem-solving tasks.
  Two-tier hierarchy: coordinator → solvers.
  One solver per question (matching standard LiveBench evaluation).
version: "1.0"

# Spawn topology — two-level tree:
#   coordinator → solver
topology:
  root: livebench-coordinator
  edges:
    - parent: livebench-coordinator
      child: livebench-solver
      auto_inject:
        skills: [livebench-solver]

# Bootstrap — pre-fills the task creation form
bootstrap:
  skills: [livebench-coordinator]
  role: "LiveBench Benchmark Coordinator"
  cognitive_style: systematic
  delegation_strategy: parallel
  global_context_file: bootstrap/global-context.md
  task_description_file: bootstrap/task-description.md
  success_criteria_file: bootstrap/success-criteria.md

# Governance — benchmark integrity enforcement
governance:
  hard_rules:
    - type: shell_pattern_block
      pattern: "curl|wget|fetch|http"
      message: "Forbidden: no internet access for solvers during benchmark. Dataset must be pre-loaded."
      scope: [livebench-solver]

    - type: action_block
      actions:
        - answer_engine
        - fetch_web
        - call_api
        - call_mcp
      message: "Forbidden: solvers may not use external knowledge sources during benchmark. Answer from training knowledge only."
      scope: [livebench-solver]

  injections:
    - source: governance/benchmark-integrity.md
      inject_into: [livebench-coordinator, livebench-solver]
      priority: high

# Schema validation
schemas:
  - name: benchmark-report.json
    definition: schemas/benchmark-report.schema.json
    validate_on: file_write
    path_pattern: "runs/*/report.json"

# Workspace
workspace: "~/.quoracle/benchmarks/livebench"

# Filesystem confinement
# confinement_mode: strict  # Optional: "strict" denies unlisted skills (default: warn and allow)
confinement:
  livebench-coordinator:
    paths:
      - ~/.quoracle/benchmarks/livebench/runs/**
    read_only_paths:
      - ~/.quoracle/benchmarks/livebench/data/**

  livebench-solver:
    paths:
      - ~/.quoracle/benchmarks/livebench/runs/*/answers/*
    read_only_paths:
      - ~/.quoracle/benchmarks/livebench/data/**/questions/**
---
