# lib/quoracle/agent/core/

## Modules
- ClientAPI: GenServer wrappers (209 lines, 17 functions with @spec), get_state/1, handle_message/2, adjust_child_budget/4
- Initialization: Init and DB setup (154 lines), start_link opts normalization
- Persistence: DB persistence (149 lines), extract_parent_agent_id with state.parent_id fallback (v36.0), delegates ACE to submodule
- Persistence.ACEState: ACE state serialization (332 lines), context_lessons + model_states
- MessageInfoHandler: Info message dispatch (329 lines), handle_trigger_consensus/1, handle_down/4, handle_spawn_failed/2
- TodoHandler: Per-agent task list management (57 lines)
- BudgetHandler: Budget GenServer callbacks (198 lines), adjust_child_budget/4, release_child_budget/3
- ChildrenTracker: Children state management (63 lines), handle_child_spawned/2, handle_child_dismissed/2
- TestActionHandler: Test-only action handler (191 lines), synchronous Router.execute for integration tests

## TestActionHandler (v25.0)
- handle_process_action/3: Synchronous action execution through Router
- Routes check_id via Helpers.extract_shell_check_id/2 → lookup shell_routers → use existing Router
- spawn_and_monitor_router/4: Spawn + monitor + active_routers tracking (mirrors ActionExecutor)
- shell_routers keyed by command_id from result (not action_id)
- Handles both `async: true` and `status: :running` patterns for shell_routers population

## MessageInfoHandler Key Handlers
- handle_trigger_consensus/1: Unified consensus trigger with staleness check
- handle_down/4: Cleans up active_routers (by ref) and shell_routers (by PID scan) on Router death
- handle_spawn_failed/2: Logs warning, records failure in history, removes child, schedules consensus

## Patterns
- Router lifecycle coupling: Core.terminate/2 stops Router via active_routers with :infinity timeout
- Two-layer safety: Core stops Router explicitly + Router monitors Core as backup
- Sandbox.allow in handle_continue (not init/1) to avoid race condition
