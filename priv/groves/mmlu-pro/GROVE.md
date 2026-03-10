---
name: mmlu-pro
description: >
  MMLU-Pro benchmark runner. 12,032 multiple-choice questions with 10 options
  (A-J) across 14 academic subjects. Tests whether multi-model consensus
  improves accuracy on knowledge-heavy tasks. Two-tier hierarchy:
  coordinator → answerers. One answerer per question (matching standard
  MMLU-Pro evaluation).
version: "1.0"

# Spawn topology — two-level tree:
#   coordinator → answerer
topology:
  root: mmlu-coordinator
  edges:
    - parent: mmlu-coordinator
      child: mmlu-answerer
      auto_inject:
        skills: [mmlu-answerer]

# Bootstrap — pre-fills the task creation form when this grove is selected.
bootstrap:
  skills: [mmlu-coordinator]
  role: "MMLU-Pro Benchmark Coordinator"
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
      message: "Forbidden: no internet access for answerers during benchmark. Dataset must be pre-loaded."
      scope: [mmlu-answerer]

    - type: action_block
      actions:
        - answer_engine
        - fetch_web
        - call_api
        - call_mcp
      message: "Forbidden: answerers may not use external knowledge sources during benchmark. Answer from training knowledge only."
      scope: [mmlu-answerer]

  injections:
    - source: governance/benchmark-integrity.md
      inject_into: [mmlu-coordinator, mmlu-answerer]
      priority: high

# Schema validation
schemas:
  - name: benchmark-report.json
    definition: schemas/benchmark-report.schema.json
    validate_on: file_write
    path_pattern: "runs/*/report.json"

# Workspace
workspace: "~/.quoracle/benchmarks/mmlu-pro"

# Filesystem confinement
confinement:
  mmlu-coordinator:
    paths:
      - ~/.quoracle/benchmarks/mmlu-pro/runs/**
    read_only_paths:
      - ~/.quoracle/benchmarks/mmlu-pro/data/**

  mmlu-answerer:
    paths:
      - ~/.quoracle/benchmarks/mmlu-pro/runs/*/answers/*
    read_only_paths:
      - ~/.quoracle/benchmarks/mmlu-pro/data/**/questions/**
---
