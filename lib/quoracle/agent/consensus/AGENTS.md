# lib/quoracle/agent/consensus/

## Modules
- TestMode: Test mode detection and configuration, 84 lines (v10.0: build_test_options extracted from consensus.ex)
- MockResponseGenerator: Mock LLM response generation for tests, 330 lines
- PerModelQuery: Per-model query functions for consensus, 464 lines (v15.0: Condensation extraction, v16.0: dynamic max_tokens calculation, v17.0: merge_state_test_opts/2 for DI propagation, REFACTOR: StateMerge + Helpers extraction for 500-line limit)
- PerModelQuery.Helpers: Extracted helper functions, 210 lines (v14.0: uses ContentStringifier for multimodal content, context length error detection, SHA-256 test embeddings, REFACTOR: query resolution, mock responses, test mode helpers)
- PerModelQuery.StateMerge: State merge utilities for parallel queries, 86 lines (REFACTOR: merge_parallel_results, state_changed?, unwrap_task_exit, extract_exception)
- PerModelQuery.Condensation: ACE condensation logic, 495 lines (v15.0: extraction, v3.0: batched reflection + recursive pre-summarization + fallback artifacts)
- SystemPromptInjector: System prompt injection for messages, 80 lines (v13.0: human prompt JSON with from:"parent", v38.0: cached_system_prompt check in opts before PromptBuilder call)

## TestMode Functions
- enabled?/1: keyword→boolean, checks test_mode or test flags
- test_flags/0: →list(atom), returns all recognized test flags
- extract_test_options/1: keyword→keyword, filters test options
- strip_test_options/1: keyword→keyword, removes test options
- build_test_options/1: keyword→map, maps test flags to query behavior (v10.0, extracted from consensus.ex)

## MockResponseGenerator Functions
- generate/2: list(atom)×keyword→{:ok,list}|{:error,atom}
- generate_mock_response/2: atom×atom→map, returns both content and parsed fields
- generate_json_response/3: atom×atom×keyword→map, JSON format
- generate_json_response/4: atom×atom×map×keyword→map, with params

## Test Scenarios
- :seeded_action - Fixed action with params
- :mixed_responses - Valid and invalid JSON mix
- :malformed - Invalid JSON responses
- :force_consensus - All models same action
- :forced_action - Specific action forced
- :partial_failure - Some models fail
- :no_consensus - No majority reached
- :no_majority - Diverse actions
- :tie - Split between two actions
- :consensus - Default agreement

## Test Flags
- simulate_failure, simulate_no_majority, force_no_consensus
- simulate_tie, force_max_rounds, simulate_refinement_failure
- simulate_partial_failure, track_refinement, seed
- malformed, mixed_responses, seed_action, seed_params

## PerModelQuery Functions
- build_query_messages/3: map×String.t×keyword→list(map), unified message building with all injectors (v13.0: ACE→todos→children→system→budget, v29.0: step 7.5 CorrectionInjector for per-model correction feedback)
- build_query_options/2: String.t×keyword→map, uses Temperature for per-model temps, adds prompt_cache: -2 for Bedrock caching (v10.0), v16.0: passes max_tokens from opts (no default, caller must provide via calculate_max_tokens)
- query_single_model_with_retry/3: map×String.t×keyword→{:ok,any}|{:error,atom}, supports model_query_fn injection, v16.0: dynamic max_tokens calculation with condensation floor
- query_models_with_per_model_histories/3: map×list×keyword→{:ok,list}|{:error,atom}
- calculate_max_tokens/2 (private): list(map)×String.t→pos_integer, computes min(context_window - input_tokens, output_limit) with max(..., 1) safety clamp (v16.0)
- maybe_proactive_condense/4 (private): list(map)×map×String.t×keyword→{list(map), map}, triggers condensation when available output < @output_floor (v16.0)
- @output_floor: 4096 — condensation floor, triggers proactive condensation when available output space drops below this threshold (v16.0)
- Delegated to Condensation: maybe_inline_condense/4, condense_n_oldest_messages/4, condense_model_history_with_reflection/3, maybe_condense_for_model/3
- Delegated to Helpers: resolve_query_fn/1, test_mode?/1, lightweight_test_query?/1, merge_state_test_opts/2, build_test_options/1, mock_successful_response/1
- Delegated to StateMerge: merge_parallel_results/2, state_changed?/2, unwrap_task_exit/1, extract_exception/1

## PerModelQuery.Helpers Functions (v14.0→REFACTOR)
- format_messages_for_reflection/1: list(map)→list(map), formats history entries for Reflector
- format_content_for_reflection/1: term→String.t, handles multimodal content types
- default_reflector/3: list(map)×String.t×keyword→{:ok,map}|{:error,term}
- test_embedding_fn/1: String.t→{:ok,map}, SHA-256 deterministic test embedding
- context_length_error?/1: term→boolean, detects context overflow errors across providers
- resolve_query_fn/1: keyword→function, resolves injected/mock/production query function
- test_mode?/1: keyword→boolean, checks test_mode flag
- lightweight_test_query?/1: keyword→boolean, detects lightweight test query mode
- merge_state_test_opts/2: map×keyword→keyword, merges state.test_opts into call opts
- build_test_options/1: keyword→map, builds test simulation options map for model queries
- mock_successful_response/1: String.t→map, generates mock orient response

## PerModelQuery.StateMerge Functions (REFACTOR)
- merge_parallel_results/2: map×list→{list,map}, merges disjoint per-model state slices
- state_changed?/2: map×map→boolean, checks if per-model maps were modified
- unwrap_task_exit/1: term→no_return, unwraps Task exit reason and re-raises
- extract_exception/1: term→{Exception.t,list}|nil, extracts exception from nested exit

## PerModelQuery.Condensation Functions (v15.0→v3.0)
- maybe_inline_condense/4: map×String.t×map×keyword→map, hook for inline condense parameter
- condense_n_oldest_messages/4: map×String.t×pos_integer×keyword→map, N-message condensation with validation
- condense_model_history_with_reflection/3: map×String.t×keyword→map, token-based >80% condensation
- maybe_condense_for_model/3: map×String.t×keyword→map, checks threshold first
- apply_reflection_and_finalize/5: Batched reflection pipeline — creates budget-sized batches, reflects each (or pre-summarizes oversized entries), accumulates lessons, creates fallback artifacts on failure, persists once via injectable persist_fn
- create_reflection_batches/3 (private): Splits to_discard into budget-sized groups using prepend-then-reverse
- batch_reflect_and_accumulate/5 (private): Sequential batch processing via Enum.reduce
- maybe_reflect_batch/4 (private): Infallible — reflects batch or creates fallback artifact (all paths return {:ok, ...})
- resolve_summarization/3 (private): DI model resolution: opts[:summarization_model] → ConfigModelSettings.get_summarization_model/0 → :summarization_not_available
- recursive_summarize/6 (private): Recursive summarization with depth limit (default 5)
- split_at_semantic_boundaries/2 (private): @semantic_delimiters ["\n\n", "\n", ". "] via Enum.find_value, falls back to split_at_token_boundaries/2
- create_fallback_artifact/1 (private): type: :factual, confidence: 0, first 500 chars + token count
- Injectables: reflector_fn, summarize_fn, summarization_model, persist_fn, max_batch_tokens, max_summarize_depth

## SystemPromptInjector Functions (v15.0: user_prompt injection removed)
- ensure_system_prompt/1: list(map)→list(map), adds system prompt at position 0
- ensure_system_prompts/2,3,4,5: list(map)×map×...→list(map), with field prompts (system_prompt only, user_prompt removed)
- extract_field_prompts/1: list(map)→map, extracts :system_prompt (user_prompt removed)
- ensure_system_prompt_with_filtering/2: list(map)×list→list(map), with forbidden actions

## Dependencies
- Quoracle.Actions.Schema (for action definitions)
- Quoracle.Models.ModelQuery (for LLM queries)
- Quoracle.Models.ConfigModelSettings (for summarization model resolution in condensation)
- Quoracle.Consensus.PromptBuilder (for system prompts)
- Quoracle.Agent.ContextManager (for message building)
- Quoracle.Agent.ConsensusHandler.CorrectionInjector (for per-model correction feedback at step 7.5)
- Quoracle.Agent.TokenManager (for condensation checks)
- Jason for JSON encoding

## Recent Changes

**Mar 7, 2026 - Parallel Per-Model Queries (feat-20260307-181848)**:
- **PerModelQuery v20.0**: Concurrent Task.async fan-out replaces sequential Enum.map_reduce for multi-model queries
- Single-model optimization: direct call without Task overhead when pool size is 1
- Deferred persistence: no-op persist_fn in parallel Tasks, single persist_ace_state call after merge
- trap_exit + unwrap_task_exit for proper crash propagation through Task.await_many
- Sandbox.allow propagation in each spawned Task for test DB access
- REFACTOR: StateMerge submodule (86 lines) extracted for merge_parallel_results, state_changed?, unwrap_task_exit, extract_exception
- REFACTOR: Helpers expanded (104→210 lines) with resolve_query_fn, test_mode?, mock helpers
- Module size: 478 → 601 → 464 lines (post-extraction)
- 14 tests in per_model_query_parallel_test.exs (R200-R211)

**Mar 1, 2026 - Batched Reflection + Recursive Summarization (wip-20260301-condensation-progress)**:
- **Condensation v3.0**: Batched reflection in apply_reflection_and_finalize/5 — splits to_discard into budget-sized batches, reflects each independently, accumulates lessons incrementally
- Oversized single entries pre-summarized via recursive_summarize/6 with ConfigModelSettings.get_summarization_model/0 (non-bang)
- Fallback artifacts (type: :factual, confidence: 0) guarantee no discard without preservation artifact
- Injectable: summarize_fn, summarization_model, persist_fn, max_batch_tokens, max_summarize_depth
- Module size: 186 → 495 lines (O(1) list ops via prepend-then-reverse, @semantic_delimiters module attribute)
- **PerModelQuery v17.0**: merge_state_test_opts/2 propagates state.test_opts through consensus paths
- **Helpers**: SHA-256 deterministic test embedding function (test_embedding_fn/1)

**Feb 10, 2026 - Dynamic max_tokens (fix-20260210-dynamic-max-tokens)**:
- **PerModelQuery v16.0**: Dynamic max_tokens calculation prevents context window overflow
- Root cause: LLMDB `limits.output` injected blindly as max_completion_tokens, exceeding context window when combined with large system prompts (DeepSeek-V3.2: output=128K, context=131K, system prompt=~15K → 143K > 131K)
- Formula: `min(context_window - input_tokens, output_limit)`, clamped to minimum 1
- Condensation floor: If available output < 4096 tokens, proactively condenses history before querying
- Applies universally but only changes behavior for models where `limits.output ≈ limits.context`
- **OptionsBuilder**: Now passes max_tokens from caller options to ReqLLM (was silently dropped)
- **TokenManager v16.0**: New `estimate_all_messages_tokens/1` (all messages including system), `get_model_output_limit/1`

**Jan 6, 2026 - user_prompt Removal (fix-20260106-user-prompt-removal)**:
- **SystemPromptInjector v15.0**: Removed user_prompt injection logic (lines 67-88 deleted)
- **PerModelQuery**: field_prompts now only contains system_prompt (user_prompt/user_prompt_timestamp removed)
- Initial user messages now flow through model_histories instead of separate injection