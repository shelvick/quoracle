# lib/quoracle/consensus/

## Modules

**PromptBuilder System** (3-module architecture):
- PromptBuilder: Orchestration (289 lines, build_system_prompt/0,1,2)
- PromptBuilder.SchemaFormatter: JSON schema generation (336 lines, XOR oneOf structures)
- PromptBuilder.Sections: Content assembly (350 lines, optimal section ordering)

**Manager** (156 lines): Consensus orchestration (calls ModelQuery for multi-model consensus)
  - Model pool from ConfigModelSettings.get_consensus_models!() (config-driven, no hardcoded defaults)
  - get_model_pool/0, get_consensus_threshold/0, get_max_refinement_rounds/0
  - build_context/2: Basic consensus context building
  - build_context_with_ace/4: ACE-enriched context with lessons and model_state (v5.0)
  - update_context_with_round/3: Stores full response maps `%{action, params, reasoning}` (v7.0)
  - Raises RuntimeError if consensus models not configured
**Aggregator** (437 lines): Consensus aggregation logic
  - cluster_responses/1, find_majority_cluster/2: Response clustering
  - build_refinement_prompt/3: Multi-model aware refinement prompts (v3.0)
  - build_final_round_prompt/2: Decisive final round framing (v3.0)
  - format_action_summary/1, format_reasoning_history/1: Delegated to ActionSummary submodule
  - Blind consensus: No model attribution in prompts
**Aggregator.ActionSummary** (172 lines): Extracted formatting module
  - format_action_summary/1: 12 action-specific formatters with key params
  - format_reasoning_history/1: Round-based history with action context
  - truncate_summary/2: Smart truncation at 100 chars
**Result** (453 lines): Consensus result formatting with 3-level tie-breaking
  - format_result/3: Returns {:consensus|:forced_decision, action, confidence}
  - break_tie/1: 3-level chain (action priority → wait score → auto_complete score)
  - wait_score/1, auto_complete_score/1: Tuple scoring {true_count, finite_sum}
  - cluster_wait_score/1, cluster_auto_complete_score/1: Aggregate cluster scores
  - merge_cluster_params/1: Schema-specific parameter merging
  - calculate_confidence/3: Confidence scoring with round penalty
- calculate_cluster_priority/1: Batch-aware priority (max for batch_sync)
**Result.Scoring** (110 lines, extracted): Scoring and tiebreaking functions
  - break_tie/1, wait_score/1, auto_complete_score/1
  - cluster_wait_score/1, cluster_auto_complete_score/1
  - Result delegates to this module for API compatibility
**ActionParser**: JSON action parsing from LLM responses (154 lines, v2.0: auto_complete_todo extraction)
**Temperature** (117 lines): Round-based temperature calculation for consensus queries
  - get_max_temperature/1: Model family → max temp (2.0 for gpt/o1/o3/o4/gemini, 1.0 for others)
  - calculate_round_temperature/2: Descends 20% of max per round, clamped to floor
  - high_temp_family?/1: Prefix-based family detection (case-insensitive)
  - get_model_name/1: Extracts model from "provider:model" spec

## Key Functions

PromptBuilder:
- build_system_prompt/0,1,2: Basic prompt building with forbidden actions

SchemaFormatter:
- action_to_json_schema/1: Elixir schema → JSON Schema with param_descriptions
- format_param_type/1: Type conversions (enums, nested maps, lists)
- XOR handling: Generates oneOf structures for mutually exclusive params

Sections:
- build_integrated_prompt/3: Orchestrates section ordering
- prepare_action_docs/1: Categorizes untrusted/trusted actions
- Section builders: identity, profile, guidelines, capabilities, format

ActionParser:
- parse_json_response/1: String → {:ok, action_response} | {:error, atom}
- extract_auto_complete_todo/2: Extracts auto_complete_todo from LLM responses (v2.0)
- Returns nil for :todo action (special case, like wait parameter)

## Patterns

**Optimal section ordering**: Identity → Profile → Guidelines → Capabilities → Format

**XOR parameter schemas**: oneOf structures for execute_shell

**Graceful degradation**: DB errors return empty defaults

**Action descriptions**: WHEN/HOW guidance from ACTION_Schema metadata

## Dependencies

- ACTION_Schema: Action definitions and metadata
- Quoracle.Repo: Database access
- Jason: JSON encoding

## Test Coverage

- prompt_builder_test.exs: Core prompt generation
- field_prompt_integration_test.exs: Field prompt integration
- temperature_test.exs: 23 tests for Temperature module (R1-R21 + edge cases)
- All tests passing with module extraction

## Recent Changes

**v6.0/v5.0 - Batch Async Consensus (Jan 26, 2026, WorkGroupID: feat-20260126-batch-async)**:
- Aggregator v6.0: batch_async sorted fingerprinting (order-independent clustering)
- Result v5.0: batch_async priority calculation (max of sub-actions, same as batch_sync)
- ActionSummary: format_batch_async_summary/1 shows `[batch_async: [sorted, actions]]`
- Extract extract_action_type/1 helper (DRY refactor for fingerprinting)
- Tests: batch_async_consensus_test.exs (R42-R53 fingerprinting, priority, clustering)

**v5.0/v4.0 - Batch Sync Consensus (Jan 24, 2026, WorkGroupID: feat-20260123-batch-sync)**:
- Aggregator v5.0: batch_sync fingerprinting by action type sequence
- Result v4.0: batch_sync tie-breaking with min(max(priorities))
- Result.Scoring (110 lines): Extracted scoring/tiebreaking for <500 line modules
- ActionSummary: format_batch_sync_summary/1 shows `[batch_sync: [action1, action2]]`
- Dual atom/string key handling for LLM compatibility
- Tests: batch_consensus_test.exs (R43-R47 fingerprinting, R36-R41 tie-breaking)

**PromptBuilder v14.0 - Profile Enum Injection (Jan 8, 2026, WorkGroupID: fix-20260108-profile-injection)**:
- SchemaFormatter: spawn_child profile param shows enum with profile names from DB
- PromptBuilder: load_profile_names/1 queries Resolver.list_names() with sandbox handling
- Sections: profile_names option passed through to SchemaFormatter
- Graceful fallback to plain string when no profiles or DB error

**PromptBuilder v9.0 - Search Secrets Static Documentation (Dec 24, 2025, WorkGroupID: feat-20251224-search-secrets)**:
- format_available_secrets/0: Replaced DB query with static documentation
- No longer lists individual secret names (privacy improvement)
- Documents search_secrets action for on-demand secret discovery
- Preserves {{SECRET:name}} syntax documentation
- Deterministic output regardless of DB state

**v12.0 - Module Extraction for 500-Line Limit (Dec 9, 2025, WorkGroupID: fix-20251209-035351)**:
- Aggregator.ActionSummary extracted (607→437 lines)
- Contains: format_action_summary/1, format_reasoning_history/1, truncate_summary/2
- Action-specific formatters with dual atom/string key handling
- Delegated via defdelegate for API compatibility

**v11.0 - Enhanced Reasoning History with Action Context (Dec 9, 2025, WorkGroupID: feat-20251208-234737)**:
- Manager v7.0: `update_context_with_round/3` stores full response maps `%{action, params, reasoning}`
- Aggregator v4.0: `format_action_summary/1` with action-specific formatters
- Smart per-action truncation at 100 chars with key parameter extraction
- Dual atom/string key handling for LLM response compatibility
- `format_reasoning_history/1` shows action context: `[execute_shell: "git status"] Reasoning...`
- 29 new tests (R11-R15 in manager_test, R22-R43 in aggregator_test)

**v10.0 - Enhanced Tie-Breaking (Dec 8, 2025, WorkGroupID: tiebreak-20251208-202952)**:
- Result: 3-level tie-breaking chain (priority → wait score → auto_complete score)
- NEW: Tuple scoring `{true_count, finite_sum}` for wait/auto_complete parameters
- NEW: wait_score/1, auto_complete_score/1, cluster_wait_score/1, cluster_auto_complete_score/1
- Conservative wins: Lower tuple scores win ties (lexicographic comparison)
- Fallback clauses for clusters without :actions field
- 18 new tests (R5-R22) in result_test.exs

**v9.0 - Descending Consensus Temperature (Dec 8, 2025, WorkGroupID: feat-20251208-165509)**:
- NEW: Temperature module for round-based temperature calculation
- High-temp families (max=2.0): gpt, o1, o3, o4, gemini
- Low-temp families (max=1.0): claude, llama, mistral, etc.
- Temperature descends 20% of max per round, clamped to floor (0.4/0.2)
- Float.round/2 for floating point precision
- PerModelQuery.build_query_options/2 uses Temperature for per-model temps
- Consensus.build_query_options/2 delegates to PerModelQuery

**v8.0 - ACE Multi-Model Awareness (Dec 7, 2025, WorkGroupID: ace-20251207-140000)**:
- Manager: Added build_context_with_ace/4 for ACE-enriched consensus context
- Manager: Context now includes :lessons and :model_state fields
- Aggregator: build_refinement_prompt/3 explains multi-model deliberation process
- Aggregator: build_final_round_prompt/2 for decisive final round framing
- Blind consensus preserved: No model attribution in prompts
- Deliberation framing: Genuine consideration, not matching/voting

**v7.1 - Auto-Complete TODO Documentation (Nov 16, 2025, WorkGroupID: autocomplete-20251116-001905)**:
- Sections: auto_complete_todo documented in response format (lines 315-318, 337-340, 345)
- Response-level parameter (not in action params)
- Excluded from :todo action (like wait parameter pattern)
- ActionParser v2.0: extract_auto_complete_todo/2 function added
- Type spec updated: auto_complete_todo: boolean() | nil

**v7.0 - Wait Parameter Schema Propagation (Nov 14, 2025, WorkGroupID: wait-20251114-203234)**:
- Wait parameter schema updated: `{:union, [:boolean, :number]}` type
- Schema propagation for all actions (except :wait action itself)
- JSON schema generation includes wait parameter documentation
- Action filtering via wait_required?/1

**v6.0 - Module Extraction + Field Integration**:
- Extracted 3-module architecture (from 373 lines to ~1,000 total)
- XOR parameter schema generation with oneOf
- Action descriptions with WHEN/HOW guidance
- DB error recovery with Logger.debug
