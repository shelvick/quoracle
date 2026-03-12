# test/quoracle/agent/

## Test Files
- core_test.exs: 44 tests (37 + 7 consensus continuation)
- core_integration_test.exs: Integration tests
- core_broadcast_test.exs: PubSub broadcast tests, race condition fix (synchronization after async cast)
- config_manager_test.exs: 12 tests
- dyn_sup_test.exs: 15 tests
- tree_terminator_test.exs: 18 tests (15 + R15-R17) - BFS collection, bottom-up order, DB deletion (incl. agent_costs v2.0), PubSub events, race prevention (2025-12, 2026-02)
- core_budget_test.exs: R40-R43 (4 tests) - Over-budget re-evaluation, monotonicity removal (2026-02-11)
- consensus_handler/action_executor_budget_test.exs: R59-R64 (4 tests) - ActionExecutor budget_data/spent propagation (2026-02-11)
- consensus_test.exs: 44 tests, property-based, message alternation
- consensus_integration_test.exs: 30 JSON parsing tests
- consensus_handler_test.exs: ConsensusHandler tests with wait parameter (async: false - modifies global Logger level)
- state_utils_test.exs: 9 tests (4 base + 5 NO_EXECUTE action_type tracking)
- message_handler_test.exs: Updated with NO_EXECUTE action_type extraction
- message_handler_timer_test.exs: 10 tests - Added 2025-11-14 (timer cancellation R11-R13, reference validation)
- action_continuation_test.exs: 12 integration tests (646 lines), sync flag fix verification, spawn_agent_with_cleanup pattern

## v13.0 Bug Fix Tests (Added 2025-12-11)
- consensus_handler_race_test.exs: R21-R24 wait:true race condition tests
- consensus_handler_v13_test.exs: R25-R27 TODO observability tests
- wait_true_race_acceptance_test.exs: 2 acceptance tests for Bug 1 (LLM context ordering)
- sender_info_test.exs: R31-R35 human prompt attribution tests
- sender_info_acceptance_test.exs: Acceptance tests for sender attribution

## JSON Formatting Tests (Added 2025-11-15)
- message_formatter_test.exs: 18 tests, 300 lines (JSON formatting for all message types)
- context_manager_json_test.exs: 18 tests, 546 lines (JSON for :decision/:result history entries)

## Consensus Bug Fix Tests (Added 2025-12-26)
- consensus_refinement_context_test.exs: 14 tests (R43-R50), per-model refinement context, acceptance test
- token_manager_string_keys_test.exs: 11 tests (R15-R20), DB-format string key pattern matching

## user_prompt Removal Tests (Added 2026-01-06)
- user_prompt_removal_packet2_test.exs: 14 tests (Packet 2), state/config cleanup verification
- spawn_user_prompt_removal_test.exs: 9 tests, child agent user_prompt removal
- consensus_user_prompt_removal_test.exs: 5 tests, SystemPromptInjector user_prompt removal
- dyn_sup_restore_user_prompt_test.exs: 5 tests, restoration without user_prompt

## Message Flush Bug Fix Tests (Added 2026-01-15)
- message_flush_test.exs: 8 tests (R49-R54), run_consensus_cycle/2 unit tests, sync action path verification
- message_flush_acceptance_test.exs: 2 acceptance tests (A7-A8), user follow-up message timing
- consensus_continuation_handler_v4_test.exs: R8-R12 delegation tests, timer handling preservation

## Event Batching Tests (Added 2026-01-15)
- event_batching_test.exs: 13 tests + 2 properties (R55-R62, R69-R71, A9-A10, P1-P2), consensus_scheduled flag, deferred consensus

## Stale :continue_consensus Tests (Added 2026-01-16)
- stale_continue_consensus_test.exs: 21 tests (R63-R69, A11-A12), dual-flag staleness check, race condition prevention

## Deferred Consensus for Idle Agents (Added 2026-01-17)
- message_batching_test.exs: 26 tests total (v3.0), includes R70-R75 deferred consensus, rapid message batching, mixed event batching
- message_batching_acceptance_test.exs: 2 acceptance tests (A13-A14), rapid user messages batched, user message during consensus_scheduled

## Wait Expired Staleness Tests (Added 2026-01-20)
- wait_expired_staleness_test.exs: 15 tests (R105-R115, A18-A20), validates timer_ref against state.wait_timer, both 2-tuple and 3-tuple formats

## Context Token Injection Tests (Added 2026-01-22)
- consensus_handler/context_injector_test.exs: 22 tests (R1-R11 + edge cases), token count injection, comma formatting, per-model history

## Task Crash Propagation Tests (Added 2026-02-20)
- dispatch_task_crash_test.exs: 7 tests (R1-R6, system) - Outer rescue/catch crash protection in ActionExecutor dispatch_action
- dispatch_task_crash_commentary_test.exs: 2 tests - Stale commentary verification for dispatch_task_crash_test

## Async Shell Phase 2 Lifecycle Tests (Added 2026-02-20)
- shell_phase2_lifecycle_test.exs: 9 tests (R100-R108), 589 lines, async: true
  - Unit (R100-R107): ActionResultHandler conditional pending_actions deletion, Phase 1 keeps / Phase 2 clears, both phases in history, continuation triggers, non-shell/sync unaffected
  - System (R108): End-to-end with real Core GenServer, Phase 1 + Phase 2 delivery via spawn_agent_with_cleanup

## Consensus Interleaving Deferral Tests (Added 2026-02-21)
- consensus_interleaving_test.exs: 13 tests (R60-R64, R200-R207), 605 lines, async: true
  - Unit (R60-R64): has_pending_self_contained?/1 predicate — true/false for SC/non-SC/empty/all-types/mixed
  - Unit (R200-R204): Deferral guard — wait:false, non-SC only, empty (regression), default branch, legacy branch
  - Integration (R205-R206): Sequential completion flow — last SC triggers, shell deferred for batch_sync
  - System (R207): End-to-end with real Core GenServer, stale check_id deferred until batch_sync completes

## System Prompt Cache Tests (Added 2026-02-22)
- consensus/system_prompt_cache_test.exs: 10 tests (R1-R9), 523 lines, async: true
  - Unit (R1): State.new cached_system_prompt field default
  - Integration (R2-R3): Lazy build on first consensus, reuse on subsequent
  - Unit (R4): learn_skills invalidation
  - Integration (R5): Rebuild after invalidation reflects new skills
  - Unit (R6): Cached prompt matches fresh PromptBuilder build
  - Integration (R7): Fast-path (Option E) bypasses cache entirely
  - Integration (R8): Multi-model uniformity (3-model pool)
  - Integration (R9, regression): field_prompts content included in cached prompt (2 tests)

## Action Executor Regression Tests (Added 2026-02-14)
- action_executor_regressions_test.exs: 15 tests (R1-R14 + R5b), 1060 lines, async: true
  - Bug 1 (error stall): R1, R2, R3, R4 — always-sync error + wait:true continues consensus
  - Bug 2 (shell routing): R5, R5b, R6, R7, R8, R9 — shell_routers population, check_id/terminate routing, cleanup
  - Bug 3 (Router leak): R10, R11 — Router monitoring and active_routers tracking
  - TestActionHandler: R12 — shell_routers keyed by command_id not action_id
  - System: R13 (failed spawn recovery), R14 (shell + check_id round-trip)

## HTTP Action Timeout Override Tests (Added 2026-02-23)
- consensus_handler/action_executor_http_timeout_test.exs: 5 tests (R78-R82), async: true
  - Unit (R78): answer_engine returns real result, not async tuple (120_000ms override)
  - Unit (R79): fetch_web returns real result, not async tuple (60_000ms override)
  - Unit (R80): call_api returns real result, not async tuple (120_000ms override)
  - Unit (R81): generate_images returns real result, not async tuple (300_000ms override)
  - Unit (R82): existing call_mcp/adjust_budget overrides preserved

## Profile Hot-Reload Tests (Added 2026-02-27)
- profile_hot_reload_test.exs: 15 tests (R4-R18), async: true
  - R4-R5: Agent profile subscription lifecycle (with/without profile_name)
  - R6-R8: Field updates (max_refinement_rounds, force_reflection forward-compat, profile_description + cache invalidation)
  - R9-R12: Model pool switching (success path, partial-apply on failure, empty pool rejection)
  - R11: cached_system_prompt invalidation on any field change
  - R13: capability_groups excluded from hot-reload (no-op)
  - R14-R15: Profile rename (resubscribe + future updates on new topic)
  - R16: No-op on identical payload
  - R17-R18: Rapid successive updates, termination safety

## Condensation Progress Guarantee Tests (Added 2026-03-01)
- token_manager_ace_test.exs: Extended with R34-R39 (6 tests + 1 property), async: true
  - Unit (R34-R37): Progress guarantee for oversized oldest entry, normal cap regression, non-empty discard invariant, ordering contract
  - Property (R38): StreamData — non-empty discard for any non-empty history + positive cap
  - System (R39): Acceptance — oversized entry condensation restores positive output budget
- consensus/per_model_query_condensation_regression_test.exs: 19 tests (R29-R47), 875+ lines, async: true
  - Unit (R29-R30): Single/multiple batch creation, backward compatibility
  - Integration (R31, R33): Lesson accumulation across batches, state updates
  - Unit (R32, R34): Batch failure isolation, chronological ordering
  - Integration (R35, R38): Pre-summarization of oversized entries, summarization model resolution
  - Unit (R36-R37): Recursive summarization depth, hierarchical content splitting (@semantic_delimiters)
  - Unit (R39-R40): Summarization depth limit fallback, model-not-configured fallback
  - Unit (R41-R42): Fallback artifact creation and shape (type: :factual, confidence: 0)
  - Integration (R43): No-discard-without-artifact invariant
  - Unit (R44-R45): History update with to_keep, persist called once (via persist_fn injection)
  - System (R46): Large history (10x context) condensation restores positive output budget
  - System (R47): Oversized entry summarized and output budget restored
- consensus/per_model_query_ace_test.exs: Updated ACE R40 assertion for fallback artifact behavior
- consensus_per_model_test.exs: Updated R17 for fallback artifact behavior + vacuous assertion fix

## Children Tracking Tests (fix-20260311-211553)
- children_tracking_test.exs: 13 tests (R1-R6 + R4a-R4b v2.0 + R37-R39 v3.0), race condition + dedup integration tests
  - R37: Batch-async race — children visible via Registry fallback when child_spawned casts lag
  - R38: handle_child_spawned idempotency — duplicate casts don't create duplicate children
  - R39: Mixed tracking — both state and Registry sources merge correctly
- packet2_safety_test.exs: R400-R401 (2 tests), maybe_track_child dedup unit tests
  - R400: maybe_track_child skips child already in state.children
  - R401: maybe_track_child adds new child to state.children

## Removed Files
core_injection_test.exs, config_manager_injection_test.exs, dyn_sup_injection_test.exs (redundant after isolation)

## Consensus Continuation Tests
ARC_CONT_01-07: Verify :request_consensus/:continue_consensus return {:noreply, state}

## Persistence Tests (core/persistence_ace_test.exs)
- 21 tests: R1-R13 ACE state serialization, round-trip, persistence, restoration
- v5.0: Updated R6/R13 assertions to include model_histories in expected defaults

## Reactive Model
Agents start in ready state, wait for messages, no initial consultation
