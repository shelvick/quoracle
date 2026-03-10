# lib/quoracle/agent/core/

## Modules
- ClientAPI: GenServer wrappers (209 lines, 17 functions with @spec), get_state/1, handle_message/2, adjust_child_budget/4
- Initialization: Init and DB setup (154 lines), start_link opts normalization
- Persistence: DB persistence (149 lines), extract_parent_agent_id with state.parent_id fallback (v36.0), delegates ACE to submodule
- Persistence.ACEState: ACE state serialization (332 lines), context_lessons + model_states
- CastHandler: GenServer cast handling (150 lines), handle_store_mcp_client/2 (v38.0: Process.monitor on MCP client PID)
- MessageInfoHandler: Info message dispatch (333 lines), handle_trigger_consensus/1, handle_down/4, handle_spawn_failed/2
- TodoHandler: Per-agent task list management (57 lines)
- BudgetHandler: Budget GenServer callbacks (247 lines), adjust_child_budget/4 (v37.0: cast-based, no child calls), handle_set_budget_allocated/2, release_child_budget/3
- ChildrenTracker: Children state management (64 lines), handle_child_spawned/2 (idempotent), handle_child_dismissed/2, handle_child_restored/2, build_child_data/1 (DRY shared helper)
- TestActionHandler: Test-only action handler (191 lines), synchronous Router.execute for integration tests

## TestActionHandler (v25.0)
- handle_process_action/3: Synchronous action execution through Router
- Routes check_id via Helpers.extract_shell_check_id/2 → lookup shell_routers → use existing Router
- spawn_and_monitor_router/4: Spawn + monitor + active_routers tracking (mirrors ActionExecutor)
- shell_routers keyed by command_id from result (not action_id)
- Matches Shell's actual async Phase 1 pattern: `{:ok, %{command_id: _, status: :running, sync: false}}`
- Passes `parent_config` in opts including `grove_hard_rules` for governance child filtering

## MessageInfoHandler Key Handlers
- handle_trigger_consensus/1: Unified consensus trigger with staleness check
- handle_down/4: Cleans up active_routers (by ref) and shell_routers (by PID scan) on Router death, clears mcp_client on MCP Client death (v38.0)
- handle_spawn_failed/2: Logs warning, records failure in history, removes child, schedules consensus
- handle_profile_updated/2: Profile hot-reload handler (v39.0) — accumulator pipeline applies max_refinement_rounds, force_reflection (forward-compat), profile_description, model_pool (via HistoryTransfer.switch_model_pool/2), profile_name (resubscribe); invalidates cached_system_prompt on any change; ignores stale events (old_name != current_profile_name); no-op on identical payload
  - maybe_update_field/4: Core accumulator helper — skips if field absent from state, value invalid, or value unchanged
  - maybe_switch_model_pool/2: Partial-apply on failure — emits Logger.warning + AgentEvents.broadcast_log(:warning), keeps old pool
  - maybe_resubscribe_profile/3: Unsubscribes old topic, subscribes new on name change
  - broadcast_warning/2: Safe broadcast_log wrapper with try/rescue for PubSub cleanup races

## Patterns
- Router lifecycle coupling: Core.terminate/2 stops Router via active_routers with :infinity timeout
- Two-layer safety: Core stops Router explicitly + Router monitors Core as backup
- MCP Client lifecycle: Core monitors MCP Client via Process.monitor, clears state.mcp_client to nil on DOWN (v38.0)
- Sandbox.allow in handle_continue (not init/1) to avoid race condition
