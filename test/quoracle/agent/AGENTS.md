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
- consensus_handler_v13_test.exs: R25-R31 TODO observability + auto_complete_todo tests
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

## Action Executor Regression Tests (Added 2026-02-14)
- action_executor_regressions_test.exs: 15 tests (R1-R14 + R5b), 1060 lines, async: true
  - Bug 1 (error stall): R1, R2, R3, R4 — always-sync error + wait:true continues consensus
  - Bug 2 (shell routing): R5, R5b, R6, R7, R8, R9 — shell_routers population, check_id/terminate routing, cleanup
  - Bug 3 (Router leak): R10, R11 — Router monitoring and active_routers tracking
  - TestActionHandler: R12 — shell_routers keyed by command_id not action_id
  - System: R13 (failed spawn recovery), R14 (shell + check_id round-trip)

## Removed Files
core_injection_test.exs, config_manager_injection_test.exs, dyn_sup_injection_test.exs (redundant after isolation)

## Consensus Continuation Tests
ARC_CONT_01-07: Verify :request_consensus/:continue_consensus return {:noreply, state}

## Persistence Tests (core/persistence_ace_test.exs)
- 21 tests: R1-R13 ACE state serialization, round-trip, persistence, restoration
- v5.0: Updated R6/R13 assertions to include model_histories in expected defaults

## Reactive Model
Agents start in ready state, wait for messages, no initial consultation
