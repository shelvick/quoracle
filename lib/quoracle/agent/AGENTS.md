# lib/quoracle/agent/

## Modules
- Core: Event-driven GenServer (498 lines), delegates message handling, stores prompt_fields + dismissing flag + capability_groups + shell_routers in state, v20.0 extracts adjust_child_budget/update_budget_data to ClientAPI, adds route_to_shell_router/3 helper
- Core.ClientAPI: GenServer wrappers (200 lines, 16 functions with @spec), v20.0 adds adjust_child_budget/4, update_budget_data/2
- Core.TodoHandler: TODO state management (57 lines), extracted for 500-line limit
- Core.ChildrenTracker: Children state management (63 lines), handle_child_spawned/2, handle_child_dismissed/2, handle_child_restored/2 (v2.1)
- Core.Initialization: Init and DB setup (154 lines), extracted for 500-line limit (2025-10-17)
- Core.Persistence: DB persistence (365 lines), model_histories + ACE state serialization, delegates ACE to submodule
- Core.Persistence.ACEState: ACE state serialization (332 lines), context_lessons + model_states + model_histories (v5.0), extracted for 500-line limit
- Core.MessageInfoHandler: Info message dispatch (263 lines), handle_wait_expired/2 with v21.0 staleness check, handle_trigger_consensus/1 (v19.0 unified handler), handle_agent_message_2tuple/3tuple, handle_down/4, handle_exit/3
- RegistryQueries: Registry queries (77 lines), composite value extraction
- MessageHandler: Message processing (423 lines), timer cancellation (R11-R13), consensus integration, NO_EXECUTE action_type tracking, delegates to ConsensusHandler (v9.0), routes images via ImageDetector (v11.0), message queueing (v12.0), v13.0 handles 3-tuple via StateUtils.merge_consensus_state, v15.0 unified run_consensus_cycle/2, handle_consensus_error/4 DRY helper, v16.0 deferred consensus via consensus_scheduled flag, v18.0 deferred consensus for idle agents + handle_send_user_message delegates to handle_agent_message
- ImageDetector: Image detection from action results (167 lines), converts MCP screenshots to multimodal content, supports base64 and URL images
- Consensus: Multi-LLM consensus (494 lines), pre-clustering validation filter (v7.0), per-model refinement context (v10.0), system prompt injection fix, v19.0 threads max_refinement_rounds from state to context
- TokenManager: Token counting (376 lines), tiktoken integration via Tiktoken.CL100K for accurate BPE tokenization (v5.0), v8.0 adds history_tokens_for_model/2 helper, v16.0 adds estimate_all_messages_tokens/1 (all messages including system) and get_model_output_limit/1 (LLMDB limits.output)
- ContextManager: History summarization (274 lines), builds field-based prompts for consensus, JSON formatting for :decision/:result entries (v2.0), 1-arity build_conversation_messages DELETED (v5.0), v7.0 ACE injection removed (now in AceInjector)
- ConfigManager: Config normalization (500 lines), atomic registration, ModelPoolInit submodule extracted, v5.0 preserves model_histories from restoration config, v8.0 extracts capability_groups, v11.0 extracts max_refinement_rounds
- ConfigManager.ModelPoolInit: Model pool initialization (37 lines), get_model_pool_for_init/2, initialize_model_histories/1
- ConsensusHandler: Consensus execution (246 lines), v20.0 single prompt_opts for UI/LLM consistency (fix-20260113-skill-injection), extracts active_skills + skills_path from state
- ConsensusHandler.Helpers: Helper functions (27 lines), normalize_sibling_context/1, self_contained_actions/0
- ConsensusHandler.LogHelper: Logging helpers (40 lines), safe_broadcast_log/5, log_action_error/1 (extracted for 500-line limit)
- ConsensusHandler.TodoInjector: TODO injection (82 lines), inject_todo_context/2, format_todos_as_xml/1, escape_xml/1
- ConsensusHandler.ChildrenInjector: Children context injection (78 lines), inject_children_context/2, format_children/1, Registry-based status check
- ConsensusHandler.AceInjector: ACE context injection (82 lines, v1.0), inject_ace_context/3 into FIRST user message (historical knowledge), format_ace_context/2
- ConsensusHandler.ContextInjector: Context token injection (95 lines, v2.0), inject_context_tokens/1 counts fully-built messages (excluding system prompt), format_context_tokens/1 with comma separators
- StateUtils: State manipulation helpers (145 lines), action_type tracking for NO_EXECUTE, v3.0 adds merge_consensus_state/2 for ACE state merging (extracted from MessageHandler/ConsensusContinuationHandler), v5.0 adds cancel_wait_timer/1 for DRY timer cancellation (4 pattern-matched clauses), v6.0 adds schedule_consensus_continuation/1 for DRY "set flag + send trigger" pattern
- ConsensusContinuationHandler: Continuation handling (59 lines), v4.0 delegates to MessageHandler.run_consensus_cycle/2 for unified message flush, v5.0 delegates cancel_wait_timer to StateUtils
- DynSup: DynamicSupervisor wrapper (185 lines), 2-arity terminate for tests, v3.0 restore_agent prefers ace_state.model_histories, v7.0 restores max_refinement_rounds from profile
- Reflector: LLM-based lesson/state extraction (278 lines), self-reflection pattern, JSON parsing with validation, v2.1 uses ContentStringifier for multimodal prompts
- LessonManager: Embedding-based lesson deduplication (175 lines), cosine similarity (0.90 threshold), O(n) accumulation
- TreeTerminator: Recursive agent tree termination (213 lines, v1.0), BFS collection, bottom-up termination, DB cleanup
- HistoryTransfer: History and ACE state transfer during model pool switching (226 lines, v1.0), select_source_model/2, condense_until_fits/4, transfer_state_to_new_pool/3

## Helpers (extracted for 500-line limit)
- MessageFormatter: XML formatting + JSON normalization (75 lines), uses JSONNormalizer for all action results
- MessageBatcher: FIFO mailbox draining (33 lines)
- TestHelpers: Test broadcast helpers (63 lines)
- ContextHelpers: Context limit management (54 lines)
- InternalMessageHandler: Internal messages (38 lines)

## Key Functions
- Core: start_link/1,/2, get_state/1, handle_message/2, terminate/2, set_dismissing/2, dismissing?/1, switch_model_pool/2 (v21.0), handle_cast({:update_todos, items}), handle_cast(:mark_first_todo_done)
- Core.TodoHandler: handle_update_todos/2, handle_get_todos/1, handle_mark_first_todo_done/1
- ClientAPI: 13 wrappers (get_agent_id, get_state, handle_message, add_pending_action, etc.)
- RegistryQueries: find_children_by_parent/1,/2, get_parent_from_registry/1,/2, find_siblings/1
- MessageHandler: handle_agent_message/3 (queues when pending, R1-R2), handle_action_result/4 (flushes queue, R3-R6), handle_message/2 (R13), cancel_wait_timer/1, run_consensus_cycle/2 (v15.0 unified entry point), flush_queued_messages/1, handle_consensus_error/4 (private DRY helper)
- ConsensusHandler: get_action_consensus/1 (v8.0 - state only), execute_consensus_action/3, handle_wait_parameter/3, inject_todo_context/2 (delegated to TodoInjector)
- Consensus: get_consensus/2, get_consensus_with_state/2, filter_invalid_responses/1 (v7.0), ensure_system_prompt/1, build_refinement_messages/2
- ConfigManager: normalize_config/1, register_agent/2, setup_agent/1,/2
- StateUtils: add_history_entry/3, add_history_entry_with_action/4 (NO_EXECUTE tracking), find_last_decision/1, find_result_for_action/2, merge_consensus_state/2 (v3.0 - ACE field merging), cancel_wait_timer/1 (v5.0 - DRY timer cancellation), schedule_consensus_continuation/1 (v6.0 - DRY consensus trigger)
- DynSup: start_agent/2,/3, terminate_agent/1,/2

## Atomic Registry Pattern (FIX_RegistryRaceCondition)
- Single Registry.register with composite value: `%{pid: pid, parent_pid: parent_pid, registered_at: integer}`
- No race window (parent relationship in single operation)
- Queries use Registry.select with map_get

## Router Lifecycle Coupling
**Core.terminate/2 stops Router FIRST with :infinity timeout** - prevents orphaned Routers holding DB connections. See root AGENTS.md for full pattern.

## Wait Parameter Support
- ConsensusHandler.handle_wait_parameter/3: Process values (false/0/true/integer)
- false/0=immediate, true=indefinite, int=timed milliseconds
- Required for non-wait actions via Schema.wait_required?/1

## TODO Management (2025-12)
- Core.TodoHandler: Extracted from Core to maintain 500-line limit
- handle_update_todos/2: Full list replacement, broadcasts via PubSub
- handle_mark_first_todo_done/1: Auto-marks first incomplete TODO
- ConsensusHandler.inject_todo_context/2: Injects up to 20 TODOs into consensus prompts
- Refactor (2025-10): Simplified cond→if for binary decision in inject_todo_context

## Children Tracking (2025-12-27)
- Core.State.children: `[%{agent_id: String.t(), spawned_at: DateTime.t()}]` (changed from `[pid()]`)
- Core.ChildrenTracker: handle_child_spawned/2 (prepend), handle_child_dismissed/2 (remove by id), handle_child_restored/2 (restoration)
- ConsensusHandler.ChildrenInjector: inject_children_context/2 (up to 20 children, Registry-filtered)
- Spawn action: Casts `{:child_spawned, %{agent_id, spawned_at}}` to parent after success
- DismissChild action: Casts `{:child_dismissed, child_id}` to parent after dispatch
- XML format: `<children>{"agent_id":"...", "spawned_at":"...", "status":"active"}</children>`
- Injection order: children→todos→content (children prepended last, appears first)

## Patterns
- Full dependency injection (registry/dynsup/pubsub via opts)
- PubSub parameter extraction from state for all 11 broadcasts
- Mailbox draining before consensus
- Batch message formatting as XML
- All public functions have @spec

## NO_EXECUTE Injection Protection (2025-10-23)
- MessageHandler.handle_action_result/3: Extracts action_type from pending_actions map
- StateUtils.add_history_entry_with_action/4: Stores action_type in result entries, wraps with NO_EXECUTE tags
- Pattern: Extract → Store with wrapping (2-step security pipeline)
- Untrusted actions (5): execute_shell, fetch_web, call_api, call_mcp, answer_engine
- Trusted actions (5): send_message, spawn_child, wait, orient, todo

## Field-Based Prompt System (2025-11)
- Core stores prompt_fields in state: %{injected:, provided:, transformed:}
- ContextManager.build_conversation_messages/1: Builds field-based prompts via PromptFieldManager
- Dual prompt system: Action schema (from PromptBuilder) + Field-based prompts
- Consensus receives both: System prompt (role, constraints, style) + User prompt (task, context, narrative)
- Backward compatible: Legacy system_prompt/user_prompt still supported if no prompt_fields
- Integration: Spawn passes prompt_fields to child config, ContextManager builds final prompts

## JSON Formatting System (2025-11-15)
- MessageFormatter: All action results use JSONNormalizer.normalize/1
- ContextManager (v2.0): :decision and :result entries formatted as JSON
- Pattern: Elixir data → JSON for all LLM-facing messages
- Tuple normalization: `{:ok, val}` → `{"type": "ok", "value": val}`
- Pretty-printing enforced for readability

## ACE (Agentic Context Engineering) (2025-12-07)
- Reflector: reflect/3 extracts lessons (factual/behavioral) and state from messages being condensed
- LessonManager: accumulate_lessons/3, deduplicate_lesson/3, prune_lessons/2
- Self-reflection pattern: Same model that owns history performs the reflection
- Embedding deduplication: Cosine similarity >= 0.90 merges lessons, increments confidence
- Pruning: Removes lowest-confidence lessons when exceeding max (100 per model)
- Injectable dependencies: query_fn, delay_fn, embedding_fn for test isolation
- Test coverage: 18 Reflector tests, 25 LessonManager tests (all async: true)

## Per-Model Conversation Histories (2025-12-07)
- Core.State uses `model_histories: %{}` (map of model_id => history list), `max_refinement_rounds: non_neg_integer()` (v33.0, default 4)
- Replaced single `conversation_history` field (removed)
- ClientAPI: `get_model_histories/1` returns full map (removed deprecated `get_conversation_history/1`)
- TokenManager: Uses all histories combined for context percentage calculations
- ContextManager: Uses all histories combined for message building and summarization
- StateUtils: `append_to_all_histories/2` adds entries to all model histories (broadcast pattern)
- Consensus: Each model queried with its own history via `query_models_with_per_model_histories/3`
- Per-model condensation: `maybe_condense_for_model/3` checks each model's history against its context limit
- Test isolation: ActionList must be loaded for isolated tests (ensures :orient atom exists)

## Pre-Clustering Validation Filter (2025-12-08)
- Consensus.filter_invalid_responses/1: Validates responses BEFORE clustering
- Uses Validator.validate_params/2 to check action parameters
- Returns {valid_responses, invalid_count} tuple for error distinction
- Logger.warning for each filtered response with action and reason
- New error: :all_responses_invalid when all responses fail validation
- Applied in both get_consensus_with_messages/2 and get_consensus_with_state/2
- Prevents invalid action parameters from winning consensus vote
- Test coverage: 10 new tests (R25-R34) in consensus_validation_filter_test.exs

## Dependencies
- FIELDS_PromptFieldManager: Prompt building from fields
- CONSENSUS_PromptBuilder: Action schema generation
- ACTION_Router: Action execution
- TABLE_Agents: Agent persistence
- UTIL_JSONNormalizer: JSON formatting for all LLM messages

## Dismissing Flag (2025-12-24)
- Core.State.dismissing: Boolean flag for race prevention during dismiss_child
- Core.set_dismissing/2: Sets flag on agent GenServer
- Core.dismissing?/1: Checks if agent is being dismissed
- TreeTerminator sets flag on each agent during BFS traversal
- ACTION_Spawn checks parent's flag before creating child
- Prevents orphan agents when parent is being dismissed

## TreeTerminator (2025-12-24)
- terminate_tree/4: Main entry point (root_agent_id, dismissed_by, reason, deps)
- BFS collection of descendants with dismissing flag set during traversal
- Bottom-up termination (leaves first) prevents orphan scenarios
- Deletes agent, logs, messages from DB after process termination
- Dual PubSub broadcasts: agent_dismissed (before) + agent_terminated (after)
- Partial failure handling: logs failures, continues with remaining agents
- Test coverage: 15 TreeTerminator tests, 12 DismissChild tests, 5 spawn race tests

## Runtime Model Pool Switching (2025-12-30)
- Core.switch_model_pool/2: GenServer.call with :infinity timeout for blocking switch
- HistoryTransfer.transfer_state_to_new_pool/3: Selects best history, condenses if needed, re-keys state
- HistoryTransfer.select_source_model/2: Picks largest fitting history from old pool
- HistoryTransfer.condense_until_fits/4: Recursive condensation until target limit met
- OTP guarantees: GenServer message ordering ensures in-flight consensus completes first
- Validation: ConfigModelSettings.validate_model_pool/1 checks credentials before mutation
- ACE alignment: context_lessons and model_states from same source model as selected history
- Test coverage: 15 HistoryTransfer tests, 15 ModelPoolSwitch integration tests

## Message Queueing During Action Execution (v12.0→v18.0)
- Fixes race condition: external messages during action execution caused history alternation errors
- Core.State.queued_messages: `[%{sender_id: atom()|String.t(), content: String.t(), queued_at: DateTime.t()}]`
- Core.State.consensus_scheduled: Boolean flag for event batching during consensus (v16.0)
- MessageHandler.handle_agent_message/3: Queues message when `pending_actions` non-empty OR `consensus_scheduled` (R1, R57), v18.0 defers consensus for idle agents
- MessageHandler.handle_action_result/4: Sets `consensus_scheduled: true`, sends `:trigger_consensus` to defer (v16.0, v19.0 unified message)
- MessageHandler.handle_send_user_message/2: v18.0 delegates to handle_agent_message with :user sender_id (DRY improvement)
- **v15.0: run_consensus_cycle/2** - Unified consensus entry point: flush → consensus → merge → execute
- **v16.0: Deferred consensus** - Action results defer consensus via `:trigger_consensus` message, allowing events to batch
- **v18.0: Deferred consensus for idle agents** - Idle agents also defer consensus, enabling rapid message batching
- flush_queued_messages/1: Public helper (called by run_consensus_cycle), FIFO order, clears queue after flush
- handle_consensus_error/4: DRY helper for error logging + retry logic (v22.0: retries retryable errors up to 3 total attempts, notifies parent on exhaustion)
- format_sender_id/1: :parent→"parent", :user→"user" (v18.0), binary→as-is
- **v19.0: MessageInfoHandler.handle_trigger_consensus/1** - Unified handler replacing handle_request_consensus, handle_continue_consensus, handle_continue_consensus_tuple. Staleness check: ignored if consensus_scheduled=false AND wait_timer=nil
- ConsensusContinuationHandler v4.0: Delegates to MessageHandler.run_consensus_cycle/2
- Test coverage: 26 tests in message_batching_test.exs (v3.0), 2 acceptance tests in message_batching_acceptance_test.exs, 8 in message_flush_test.exs, event_batching_test.exs (v16.0), 26 in consensus_staleness_test.exs (v19.0)

## Consensus Retry on Transient Failures (2026-01-29)
- Core.State.consensus_retry_count: non_neg_integer(), defaults to 0, tracks consecutive consensus failures
- MessageHandler.handle_consensus_error/4: Retries retryable errors (:all_responses_invalid, :all_models_failed) up to 3 total attempts via schedule_consensus_continuation/1
- notify_parent_of_stall/3: Sends {:agent_message, agent_id, message} to parent when retries exhausted
- Counter reset to 0 on successful consensus in both run_consensus_cycle/2 and handle_message_impl/2
- Uses cond with retryable? boolean for 3-branch control flow (retry / notify+stall / stall)
- Test coverage: 13 tests in consensus_retry_test.exs (R1-R12, R73)

## user_prompt Removal (2026-01-06, fix-20260106-user-prompt-removal)
- **Problem solved**: Initial user message was stored separately in `user_prompt` field, re-injected at query time, causing duplicate/stale context after condensation
- **State changes**: Removed `user_prompt` and `user_prompt_timestamp` fields from Core.State struct
- **ConfigManager v7.0**: No longer sets user_prompt in normalize_config
- **ConsensusHandler v18.0**: field_prompts now only contains system_prompt
- **MessageHandler v14.0**: Removed skip_initial_prompt? logic - all messages flow through history
- **SystemPromptInjector v15.0**: Removed user_prompt injection (lines 67-88 deleted)
- **DynSup v6.0**: Restoration config excludes user_prompt
- **Persistence**: Map.take excludes user_prompt from config
- **Initial messages now flow through model_histories** like all other messages
- Test coverage: 14 Packet 2 tests in user_prompt_removal_packet2_test.exs

## Consensus Continuation Fix (2026-01-17, fix-20260117-consensus-continuation)
- **Problem solved**: Self-contained actions (TODO, orient, etc.) with `wait:false` didn't auto-continue because ActionExecutor sent `:trigger_consensus` but never set `consensus_scheduled = true`
- **Root cause**: Staleness check (`consensus_scheduled == false AND wait_timer == nil`) ignored all triggers from ActionExecutor
- **StateUtils v6.0**: New `schedule_consensus_continuation/1` helper centralizes "set flag + send trigger" pattern
- **ConsensusHandler v22.0**: `handle_wait_parameter/3` uses helper for wait:false/0 case (line 225)
- **ActionExecutor**: Uses helper at 4 locations (lines 301, 313, 401, 420)
- **WaitFlow v26.0**: Simplified to no-ops - all triggers moved to Agent layer (ActionExecutor)
- Test coverage: 13 tests in state_utils_schedule_continuation_test.exs, 18 tests in consensus_continuation_test.exs

Test coverage: 55 Core tests (37 base + 7 consensus + 11 TODO), 12 ContextManager (+ 4 field integration), 18 MessageFormatter, 18 Reflector, 25 LessonManager, 15 TreeTerminator, 15 HistoryTransfer, 15 ModelPoolSwitch, all async: true
