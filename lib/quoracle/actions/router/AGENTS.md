# lib/quoracle/actions/router/

## Sub-modules (extracted for 500-line limit, Router now 496 lines)
- MCPHelpers: MCP client lazy initialization (52 lines) - Added 2025-12-16
- MockExecution: Mock action execution (174 lines)
- WaitFlow: Wait flow control (48 lines, v26.0 simplified to no-ops - all triggers moved to Agent layer)
- Metrics: Action metrics tracking (50 lines)
- TaskManager: Async task lifecycle (96 lines)
- Execution: Smart mode execution (198 lines)
- ActionMapper: Action type→module mapping (29 lines)
- ShellCommandManager: Shell command state management (142 lines) - Added 2025-10-14, updated 2025-10-17
- Persistence: DB persistence for action results (135 lines) - Added 2025-10-14
- ShellCompletion: Shell completion notifications (66 lines) - Added 2025-10-17
- ClientHelpers: Client API wrappers (48 lines) - Added 2025-10-26
- ClientAPI: Action execution with auto_complete_todo hook (139 lines, v16.0: auto_complete_todo integration)
- Security: Secret resolution and output scrubbing (added with secret system)

## Key Functions
- MCPHelpers.get_or_init_mcp_client/1: Get existing or create new MCP client from opts
- MCPHelpers.maybe_lazy_init_mcp_client/2: Only initializes for :call_mcp action type
- MockExecution.execute_action_mock/5: Simulates action responses
- WaitFlow.handle_immediate/3: Timer notification only for timed waits (no triggers - v26.0)
- WaitFlow.handle_after_result/4: No-op (all triggers handled by ActionExecutor - v26.0)
- Metrics.track_metric/2, broadcast_metrics/2: Action metrics
- TaskManager.cleanup_task/2, track_async_task/4: Task lifecycle
- Execution.execute_action/10: Smart mode with sandbox support
- ActionMapper.get_action_module/1: Maps :execute_shell→Shell, :wait→Wait, etc.
- ShellCommandManager.init/0, register/3 (validates action_id), get/2, append_output/4, update_check_position/3, mark_completed/3, mark_terminated/2
- Persistence.execute_with_persistence/5, persist_action_result/4: DB audit trail logging
- ShellCompletion.handle_completion/5: Builds result, notifies Core, broadcasts, stores async result (2025-10-17)
- ClientAPI.execute/5: Main execution flow with auto_complete_todo hook (v16.0, lines 107-115)
- ClientHelpers.await_result/3: Wait for async action completion (default 5s timeout)
- ClientHelpers.interrupt_wait/1: Interrupt pending wait
- ClientHelpers.cancel_action/1: Cancel action execution
- ClientHelpers.task_status/2: Query task status
- Security.resolve_secrets/1: Replace {{SECRET:name}} templates
- Security.scrub_output/2: Remove secret values from results

## Router Lifecycle Management (CRITICAL)

**Router monitors owner Core agent and self-terminates when owner dies** (see root AGENTS.md for full pattern)

Two-layer safety: Core.terminate/2 stops Router explicitly + Router monitors Core as backup

ConfigManager must pass `agent_pid: self()` when spawning Router

## Auto-Complete TODO Integration (v16.0, Nov 16, 2025)

**Response-level parameter** (not in params): LLMs return auto_complete_todo alongside action, params, reasoning, wait

**Extraction flow:**
1. Router.execute/3 extracts from action_map: `Map.get(action_map, :auto_complete_todo)` (line 59)
2. Adds to opts: `Keyword.put(:auto_complete_todo, ...)` (line 59)
3. ClientAPI checks after success: `Keyword.get(opts, :auto_complete_todo) == true` (line 109)
4. Triggers: `GenServer.cast(agent_pid, :mark_first_todo_done)` (line 113)

**Behavior:**
- Only on successful actions ({:ok, result})
- Only when auto_complete_todo: true
- Silent no-op if no agent_pid or no TODOs
- Never triggers on failures

**Integration:** Core.TodoHandler handles cast, broadcasts PubSub updates