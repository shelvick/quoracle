# lib/quoracle/agent/message_handler/

## Modules
- ActionResultHandler: Action result processing (271 lines, extracted from MessageHandler 2026-02-13)

## Key Functions
- handle_action_result/4: Process action results with extended wait parameter handling. Routes through process_action_result → store in history → maybe_track_child → maybe_update_budget_committed → handle_action_result_continuation
- handle_batch_action_result/4: Process batch sub-action results
- flush_queued_messages/1: FIFO queue flush, clears queue after processing
- format_sender_id/1: :parent→"parent", :user→"user", binary→as-is

## Private Helpers
- maybe_track_child/3: Track spawned children from non-blocking dispatch results (spawn_child action only)
- maybe_update_budget_committed/3: Update budget_data.committed for spawn_child results (replaces removed Core.update_budget_committed callback)
- handle_action_result_continuation/3: Extended wait parameter cond with 6 branches: legacy path, always_sync+wait:true, :wait with timer, wait:false/0/true, timed wait, default
- map_result_with_timer?/1: Detect {:ok, %{timer_id: ref}} pattern
- get_timer_from_result/1: Extract timer_id from {:ok, result} tuple

## Patterns
- Delegates from MessageHandler (MessageHandler.handle_action_result/4 → ActionResultHandler)
- Uses StateUtils for timer cancellation and consensus continuation
- Budget committed update uses Decimal arithmetic inside Core process (no concurrent access)
- Child tracking uses Map.update with prepend pattern

## Dependencies
- StateUtils: cancel_wait_timer/1, schedule_consensus_continuation/1, add_history_entry_with_action/4
- ConsensusHandler: handle_wait_parameter/3 (for timed waits)
- ImageDetector: detect/2 (for image result routing)
