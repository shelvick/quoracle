# test/quoracle_web/

## Test Files
- components/utility_components_modal_test.exs: Modal component tests (12 tests)
- live/dashboard_live_test.exs: Core mount, subscription, filtering (20+ tests)
- live/dashboard_pause_resume_integration_test.exs: Pause/resume workflows (9 tests)
- live/dashboard_async_pause_test.exs: Async pause UI behavior (17 tests) - R16-R34, acceptance test
- live/dashboard_delete_integration_test.exs: Delete functionality (16 tests)
- live/dashboard_live_mailbox_integration_test.exs: Mailbox integration
- live/dashboard_live_tasktree_integration_test.exs: TaskTree integration
- live/grove_integration_test.exs: Grove bootstrap + spawn contract integration (31+ tests) - R6-R13, R8b/R9b/R11b/R58b audit gaps, GAP-1a/1b/GAP-2 carryover, R63-R65 grove_topology/grove_path threading (added wip-20260228-spawn-contracts)

## Test Patterns
- live_isolated/3 with session-based dependency injection
- Isolated PubSub/Registry/DynSup per test (async: true)
- sandbox_owner propagation via session for DB access
- render_click/2 for event triggering
- has_element?/2 for element presence checks
- capture_log/1 for expected error logging

## Modal Component Tests (12 tests)
- Render structure validation
- Show/hide functionality
- Event attributes (phx-click, phx-value-task-id)
- Backdrop and click-away dismissal
- Button styling and layout
- Multiple modal coexistence

## Delete Integration Tests (16 tests)
- Button visibility (paused/completed/failed only)
- Modal confirmation flow (modal ID: task-tree-confirm-delete-{task_id})
- TaskManager.delete_task integration
- Socket state updates (task removal, no selection state)
- Error handling (non-existent task, concurrent deletes)
- Cascade deletion verification
- Auto-pause for running tasks
- Updated for 3-panel layout (no select_task pattern)

## 3-Panel Integration Tests (16 tests) - Packet 4
- R1: 3-panel layout verification (w-5/12 + w-1/3 + w-1/4)
- R2: TaskTree receives all tasks/agents (not filtered)
- R3: Event delegation (pause, resume, delete, submit_prompt, select_agent)
- R4: Agent selection filters logs
- R5: No current_task_id state
- R6: Mailbox integration unchanged
- R7: Panel width calculations
- R8: PubSub isolation per test

## Grove Integration Tests (grove_integration_test.exs)
- R6-R13: Bootstrap grove selection, field pre-fill, grove clear, stale carryover prevention
- R8b/R9b/R11b/R58b: Audit gap remediation tests
- GAP-1a/1b: handle_info(:loaded_grove_updated) delegation from TaskTree
- GAP-2: Governance non-blocking on error
- R63-R65 (wip-20260228-spawn-contracts): handle_submit_prompt extracts grove_topology + grove_path from loaded_grove, forwards to TaskManager opts

## Test Coverage
- All tests use async: true with perfect isolation
- No global state (PubSub/Registry/DynSup injected)
- Modern sandbox pattern (start_owner!/stop_owner)
- Zero log spam (capture_log for expected errors)
