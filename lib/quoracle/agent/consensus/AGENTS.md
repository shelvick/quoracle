# lib/quoracle/agent/consensus/

## Modules
- TestMode: Test mode detection and configuration, 84 lines (v10.0: build_test_options extracted from consensus.ex)
- MockResponseGenerator: Mock LLM response generation for tests, 330 lines
- PerModelQuery: Per-model query functions for consensus, 340 lines (v15.0: Condensation extraction for <500 line limit)
- PerModelQuery.Helpers: Extracted helper functions, 106 lines (v14.0: uses ContentStringifier for multimodal content, context length error detection)
- PerModelQuery.Condensation: ACE condensation logic, 186 lines (v15.0: extracted from PerModelQuery for <500 line limit)
- SystemPromptInjector: System prompt injection for messages, 142 lines (v13.0: human prompt JSON with from:"parent")

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
- build_query_messages/3: map×String.t×keyword→list(map), unified message building with all injectors (v13.0: ACE→todos→children→system→budget)
- build_query_options/2: String.t×keyword→map, uses Temperature for per-model temps, adds prompt_cache: -2 for Bedrock caching (v10.0)
- query_single_model_with_retry/3: map×String.t×keyword→{:ok,any}|{:error,atom}, supports model_query_fn injection
- query_models_with_per_model_histories/3: map×list×keyword→{:ok,list}|{:error,atom}
- Delegated to Condensation: maybe_inline_condense/4, condense_n_oldest_messages/4, condense_model_history_with_reflection/3, maybe_condense_for_model/3

## PerModelQuery.Condensation Functions (v15.0)
- maybe_inline_condense/4: map×String.t×map×keyword→map, hook for inline condense parameter
- condense_n_oldest_messages/4: map×String.t×pos_integer×keyword→map, N-message condensation with validation
- condense_model_history_with_reflection/3: map×String.t×keyword→map, token-based >80% condensation
- maybe_condense_for_model/3: map×String.t×keyword→map, checks threshold first
- apply_reflection_and_finalize/5: Shared helper for Reflector + LessonManager integration

## SystemPromptInjector Functions (v15.0: user_prompt injection removed)
- ensure_system_prompt/1: list(map)→list(map), adds system prompt at position 0
- ensure_system_prompts/2,3,4,5: list(map)×map×...→list(map), with field prompts (system_prompt only, user_prompt removed)
- extract_field_prompts/1: list(map)→map, extracts :system_prompt (user_prompt removed)
- ensure_system_prompt_with_filtering/2: list(map)×list→list(map), with forbidden actions

## Dependencies
- Quoracle.Actions.Schema (for action definitions)
- Quoracle.Models.ModelQuery (for LLM queries)
- Quoracle.Consensus.PromptBuilder (for system prompts)
- Quoracle.Agent.ContextManager (for message building)
- Quoracle.Agent.TokenManager (for condensation checks)
- Jason for JSON encoding

## Recent Changes

**Jan 6, 2026 - user_prompt Removal (fix-20260106-user-prompt-removal)**:
- **SystemPromptInjector v15.0**: Removed user_prompt injection logic (lines 67-88 deleted)
- **PerModelQuery**: field_prompts now only contains system_prompt (user_prompt/user_prompt_timestamp removed)
- Initial user messages now flow through model_histories instead of separate injection