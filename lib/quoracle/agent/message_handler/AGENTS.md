# lib/quoracle/agent/message_handler/

## Modules
- ActionResultHandler: Action result processing (383 lines, extracted from MessageHandler 2026-02-13, v25.0 shell_routers + error-aware continuation, v27.0 consensus deferral, v28.0 LogHelper.log_action_error wiring for server-side error logging)

## Key Functions
- handle_action_result/4: Process action results with extended wait parameter handling. Routes through process_action_result → store in history → maybe_track_child → maybe_update_budget_committed → maybe_track_shell_router → flush_queued_messages → handle_action_result_continuation
- handle_batch_action_result/4: Process batch sub-action results
- flush_queued_messages/1: FIFO queue flush, clears queue after processing
- format_sender_id/1: :parent→"parent", :user→"user", binary→as-is

## Private Helpers
- maybe_track_child/3: Track spawned children from non-blocking dispatch results (spawn_child action only)
- maybe_update_budget_committed/3: Update budget_data.committed for spawn_child results (replaces removed Core.update_budget_committed callback)
- maybe_track_shell_router/3: Populate shell_routers with {command_id, router_pid} from async shell Phase 1 results (v25.0, v26.0 refactor: uses shared `async_shell_phase1?/1` predicate). Matches `{:ok, %{status: :running, command_id: binary, sync: false}}`.
- async_shell_phase1?/1: Shared predicate detecting async shell Phase 1 ack. Used by both pending_actions guard and shell_routers tracking. Pattern: `{:ok, %{status: :running, command_id: binary, sync: false}}`.
- maybe_schedule_consensus/1: DRY helper (v27.0) — checks Helpers.has_pending_self_contained?/1, defers if true, else calls StateUtils.schedule_consensus_continuation/1. Used by all 4 consensus-scheduling branches. Also normalizes legacy branch to use StateUtils instead of raw Map.put+send.
- handle_action_result_continuation/3: Extended wait parameter dispatch with 6 branches: legacy path, always_sync+wait:true+success (v25.0: error guard), :wait with timer, wait:false/0/true, timed wait, default. All consensus-scheduling branches delegate to maybe_schedule_consensus/1.
- map_result_with_timer?/1: Detect {:ok, %{timer_id: ref}} pattern
- get_timer_from_result/1: Extract timer_id from {:ok, result} tuple

## v25.0 Changes
- Error-aware continuation: `match?({:ok, _}, result)` guard on always_sync+wait:true branch prevents permanent agent stall on error results
- Shell Router tracking: `maybe_track_shell_router/3` populates shell_routers keyed by command_id from router_pid in result_opts

## Patterns
- Delegates from MessageHandler (MessageHandler.handle_action_result/4 → ActionResultHandler)
- Uses StateUtils for timer cancellation and consensus continuation
- Budget committed update uses Decimal arithmetic inside Core process (no concurrent access)
- Child tracking uses Map.update with prepend pattern

## Dependencies
- StateUtils: cancel_wait_timer/1, schedule_consensus_continuation/1, add_history_entry_with_action/4
- ConsensusHandler: handle_wait_parameter/3 (for timed waits)
- ConsensusHandler.LogHelper: log_action_error/1 (v28.0, server-side action error logging)
- ImageDetector: detect/2 (for image result routing)
