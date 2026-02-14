# lib/quoracle/agent/consensus_handler/

## Modules
- ActionExecutor: Non-blocking consensus action execution (292 lines), dispatches Router.execute via Task.Supervisor, result returns via GenServer.cast
- Helpers: Shared helper functions (99 lines), self_contained_actions/0, coerce_wait_value/1, extract_shell_check_id/2, normalize_sibling_context/1
- LogHelper: Logging helpers (40 lines), safe_broadcast_log/5, log_action_error/1
- TodoInjector: Todo list context injection (82 lines), inject_todo_context/2
- ChildrenInjector: Children context injection (78 lines), inject_children_context/2
- AceInjector: ACE context injection (82 lines), inject_ace_context/3
- ContextInjector: Context token injection (95 lines), inject_context_tokens/1

## Key Functions
- ActionExecutor.execute_consensus_action/3: Entry point, validates wait params, dispatches action
- ActionExecutor.dispatch_action/8: Task.Supervisor.start_child, Router.execute in background, casts result to Core
- ActionExecutor.spawn_and_monitor_router/4: Spawn Router + Process.monitor + active_routers tracking (v25.0)
- Helpers.extract_shell_check_id/2: Detect check_id in shell params for routing through existing Router (v25.0)
- Helpers.self_contained_actions/0: 9 actions that complete instantly (wait:true would stall)
- Helpers.coerce_wait_value/1: String "true"/"false" → boolean for wait param

## ActionExecutor Flow (v35.0 non-blocking + v25.0 fixes)
1. Validate wait param, normalize sibling_context
2. Auto-correct wait:true on self-contained actions
3. Add decision to history, generate action_id
4. Route check_id via Helpers.extract_shell_check_id → lookup shell_routers → use existing Router
5. For normal actions: spawn_and_monitor_router (spawn + monitor + active_routers)
6. Add to pending_actions
7. dispatch_action → Task.Supervisor.start_child → Router.execute → cast result to Core
8. Return state immediately (Core is free for GenServer.call)

## Patterns
- Per-action Router lifecycle: new Router per action, monitored, tracked in active_routers
- Shell Router reuse: check_id routes through existing Router from shell_routers (not new Router)
- router_pid passed through result_opts for shell_routers population in ActionResultHandler
- Sandbox.allow in Task for test DB isolation
- try/catch for Router exits during dispatch

## Dependencies
- Router: start_link/1, execute/5
- Helpers: extract_shell_check_id/2, coerce_wait_value/1
- StateUtils: add_history_entry/3, schedule_consensus_continuation/1
- Core.ClientAPI: always_sync_actions/0
- Task.Supervisor: Quoracle.SpawnTaskSupervisor
