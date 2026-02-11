# test/quoracle/actions/

## Test Files
- answer_engine_test.exs: 3 tests (grounding, citations, model_used field) - Updated 2025-10-23 (action field + model_used assertions)
- send_message_test.exs: 16 tests (F1-F6, I2-I4, Q1-Q3, IN1-IN4)
- router_send_message_test.exs: 8 integration tests
- wait_test.exs: 46 tests - Updated 2025-11-21 (flaky test fix: 100ms→500ms timeout for timer expiry, scheduler margin), 2025-11-14 (wait parameter unification: true/false/number support, R1-R15)
- wait_unification_test.exs: 23 tests - Added 2025-11-14 (equivalence testing: wait action ≡ wait parameter)
- wait_interruption_test.exs: 10 tests - Added 2025-11-14 (timer cancellation on messages, R11-R13)
- wait_broadcast_test.exs: PubSub tests (async: false, shared global topics)
- wait_isolation_test.exs: PubSub isolation tests (async: true)
- orient_test.exs: 9 tests
- orient_enhanced_test.exs: Enhanced orient tests - Updated 2025-10-23 (action field assertions)
- orient_isolation_test.exs: PubSub isolation tests - Updated 2025-10-23 (action field assertions)
- spawn_test.exs: 24 tests - Updated 2025-10-23 (action field assertions)
- spawn_field_integration_test.exs: 22 tests - Field system integration (extraction, validation, transformation) - Added 2025-11
- spawn_field_consensus_test.exs: 3 system tests - E2E field→prompt→consensus flow - Added 2025-11
- spawn_async_test.exs: 10 tests - Async spawn pattern (R1-R11), pids_tracker cleanup pattern (2025-12)
- spawn_dismiss_test.exs: 3 tests - Spawn/DismissChild integration (2026-01) - Tests spawn blocked when agent being terminated (not when parent dismissing sibling)
- dismiss_child_test.exs: 12 tests - Recursive child termination (R1-R12), authorization, idempotent, async dispatch (2025-12)
- router_test.exs: 18 routing tests
- router_broadcast_test.exs: PubSub tests (async: false)
- router_isolation_test.exs: Isolated PubSub (async: true)
- schema_test.exs: 40 tests - Updated 2025-11-14 (wait_required?/1, wait union type validation, action priorities)
- validator_test.exs: 408 tests - Updated 2025-11-14 (boolean type support for wait parameter, nested map validation, enum validation)
- web_test.exs: 24 unit tests (async: false - ExVCR cassettes, Finch adapter)
- router_web_test.exs: 19 integration tests (async: true)
- web_property_test.exs: 13 property tests (tagged :property)
- shell_notification_fix_test.exs: 12 tests (Router-mediated protocol) - Updated 2025-10-23 (action field assertions)
- router_shell_notification_test.exs: Integration tests (Router→Core notification flow) - Updated 2025-10-17
- shell_packet2_test.exs: 19 tests (status management) - Updated 2025-10-23 (action field assertions)
- shell_integration_test.exs: 4 tests (ActionMapper) - Updated 2025-10-17
- shell_test.exs: 11 tests (command execution) - Updated 2025-10-23 (action field assertions)
- file_read_test.exs: 17 tests + 3 properties (R1-R15) - Added 2026-01-07 (feat-20260107-file-actions)
- file_write_test.exs: 15 tests + 3 properties (R1-R18) - Added 2026-01-07 (feat-20260107-file-actions)
- router_file_actions_test.exs: 9 integration tests (R15, R19-R20) - Added 2026-01-07 (feat-20260107-file-actions)
- schema_file_actions_test.exs: 20 tests (ACTION_Schema v27.0 file_read/file_write) - Added 2026-01-07
- batch_sync_test.exs: 13 tests (R1-R13 batch_sync action) - Added 2026-01-24 (feat-20260123-batch-sync Packet 3)
- router_batch_sync_test.exs: Router integration tests for batch_sync - Added 2026-01-24
- batch_async_test.exs: 28 tests + 3 properties (R1-R23 batch_async action) - Added 2026-01-26 (feat-20260126-batch-async)
- router_batch_async_test.exs: 9 Router integration tests for batch_async - Added 2026-01-26
- shared/batch_validation_test.exs: 11 tests (R1-R11 shared validation) - Added 2026-01-26
- spawn_budget_test.exs: R52, R57 (2 tests) - Budget enforcement for budgeted parents (2026-02-11)
- dismiss_child_reconciliation_test.exs: R22-R30 (9 tests) - Budget reconciliation on dismissal (2026-02-11)

## Coverage
execute/2,/3,/4 delegation, target resolution, PubSub/Registry injection, wait parameter flow, error handling, nested map validation, enum constraints, action priorities, HTTP GET, HTML→Markdown conversion, redirect tracking, SSRF protection, error status mapping, Shell notification protocol (Router-mediated Core notification with action_id propagation), consistent action field in all action returns (answer_engine, wait, orient, spawn, shell), model_used field in answer_engine

## Action Return Format Consistency (2025-10-23)
All action tests verify consistent return format with action: field:
- AnswerEngine: action: "answer_engine" + model_used: (not model:)
- Wait: action: "wait"
- Orient: action: "orient"
- Spawn: action: "spawn"
- Shell: action: "shell" (both sync and async paths)
- FileRead: action: "file_read" + content: + lines_read: + total_lines: + truncated:
- FileWrite: action: "file_write" + mode: + (bytes_written: | replacements:)

## Test Isolation Patterns
- start_owner! for DB access in spawned processes
- Isolated PubSub instances per test
- capture_log for expected warnings
- on_exit cleanup for spawned agents
