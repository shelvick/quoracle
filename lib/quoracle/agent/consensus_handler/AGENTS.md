# lib/quoracle/agent/consensus_handler/

## Modules
- ActionExecutor: Non-blocking consensus action execution (379 lines), dispatches Router.execute via Task.Supervisor, result returns via GenServer.cast, v36.0 outer try/rescue/catch crash protection + MCP sync timeout, v40.0 task_id fallback removal (Map.get without default), timeout overrides: :adjust_budget → :infinity, :call_mcp → 600_000, :answer_engine → 120_000, :fetch_web → 60_000, :call_api → 120_000, :generate_images → 300_000 (v39.0)
- Helpers: Shared helper functions (116 lines), self_contained_actions/0, has_pending_self_contained?/1 (v26.0), coerce_wait_value/1, extract_shell_check_id/2, normalize_sibling_context/1
- LogHelper: Logging helpers (63 lines), safe_broadcast_log/5, log_action_error/1 (v28.0: {:error, _} unwrap, {:action_crashed, tuple} clause, extended @warning_errors)
- TodoInjector: Todo list context injection (82 lines), inject_todo_context/2
- ChildrenInjector: Children context injection (150 lines), inject_children_context/2, format_children/1, v2.0: enrich_with_messages/2 cross-references state.messages to add latest_message + latest_message_at per child
- AceInjector: ACE context injection (82 lines), inject_ace_context/3
- CorrectionInjector: Per-model correction feedback injection (56 lines, v1.0), inject_correction_feedback/3 — prepends correction to last user message at MessageBuilder step 7.5
- ContextInjector: Context token injection (95 lines), inject_context_tokens/1

## Key Functions
- ActionExecutor.execute_consensus_action/3: Entry point, validates wait params, dispatches action
- ActionExecutor.dispatch_action/9: Task.Supervisor.start_child with outer try/rescue/catch, Router.execute in background, casts result to Core, crash_in_task injection for testing (v36.0)
- ActionExecutor.spawn_and_monitor_router/4: Spawn Router + Process.monitor + active_routers tracking (v25.0)
- ActionExecutor timeout overrides: Forces 600_000ms for :call_mcp (v36.0), :infinity for :adjust_budget (fix-20260223), 120_000ms for :answer_engine, 60_000ms for :fetch_web, 120_000ms for :call_api, 300_000ms for :generate_images (v39.0 — prevents 100ms smart_threshold from losing HTTP action results)
- Helpers.extract_shell_check_id/2: Detect check_id in shell params for routing through existing Router (v25.0)
- Helpers.self_contained_actions/0: 10 actions that complete instantly (wait:true would stall)
- Helpers.has_pending_self_contained?/1: Check if any pending_actions are self_contained (v26.0, used by ActionResultHandler.maybe_schedule_consensus/1)
- Helpers.coerce_wait_value/1: String "true"/"false" → boolean for wait param

## ActionExecutor Flow (v35.0 non-blocking + v25.0 fixes)
1. Validate wait param, normalize sibling_context
2. Auto-correct wait:true on self-contained actions
3. Add decision to history, generate action_id
4. Route check_id via Helpers.extract_shell_check_id → lookup shell_routers → use existing Router
5. For normal actions: spawn_and_monitor_router (spawn + monitor + active_routers)
6. Add to pending_actions
7. Timeout overrides: :call_mcp → 600_000ms (v36.0), :adjust_budget → :infinity (fix-20260223)
8. dispatch_action → Task.Supervisor.start_child → try/rescue/catch → Router.execute → cast result to Core
9. Return state immediately (Core is free for GenServer.call)

## Patterns
- Per-action Router lifecycle: new Router per action, monitored, tracked in active_routers
- Shell Router reuse: check_id routes through existing Router from shell_routers (not new Router)
- router_pid passed through result_opts for shell_routers population in ActionResultHandler
- Sandbox.allow in Task for test DB isolation
- try/catch for Router exits during dispatch
- Outer try/rescue/catch guarantees error delivery on any task crash (v36.0 FIX_DispatchTaskCrashPropagation)
- MCP sync timeout prevents retry delays from triggering smart_threshold async dispatch (v36.0)

## Dependencies
- Router: start_link/1, execute/5
- Helpers: extract_shell_check_id/2, coerce_wait_value/1
- StateUtils: add_history_entry/3, schedule_consensus_continuation/1
- Core.ClientAPI: always_sync_actions/0
- Task.Supervisor: Quoracle.SpawnTaskSupervisor
