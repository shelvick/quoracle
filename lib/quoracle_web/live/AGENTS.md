# lib/quoracle_web/live/

## DashboardLive (6-module architecture, 3-panel layout)

**Modules:**
- Main coordinator (316 lines): 3-panel UI (Unified TaskTree 5/12, Logs 1/3, Mailbox 1/4), task persistence, pause/resume, real-time updates
- DataLoader (231 lines): Extracted data loading/merging helpers (2025-12 REFACTOR)
  - load_tasks_from_db/2: Query DB + Registry, merge state
  - merge_task_state/2: Combine persisted tasks with live agents
  - query_event_history/3: Query EventHistory buffer for logs/messages
  - get_filtered_logs/2: Filter logs by selected_agent_id
  - build_agent_alive_map/1: Build agent_id => alive status map
- Subscriptions: safe_subscribe with MapSet tracking, auto-subscribe to agent todos topic, task message topics
- EventHandlers: submit_prompt, pause/resume_task, delete_task, select_agent
- MessageHandlers: agent_spawned/terminated, log_entry, task_message, agent_message, todos_updated (2025-12), send_direct_message (2025-11), link_orphaned_children (2025-12)
- TestHelpers: Test-specific handlers

## SecretManagementLive (5-module architecture, 2025-10-24)

**Main Module:** SecretManagementLive (487 lines)
**Helpers:** DataHelpers (116 lines), ValidationHelpers (139 lines), ModelConfigHelpers (228 lines), ProfileHelpers (119 lines)
**Template:** secret_management_live.html.heex
**Purpose:** Unified CRUD interface for secrets, credentials, model config, profiles, and system settings
**v5.0:** System tab with skills_path configuration (feat-20260208-210722)

## Key Functions
- mount/3: Extract pubsub/registry/sandbox_owner from session, load tasks, subscribe to agents:lifecycle + task messages (tracked in MapSet)
- load_tasks_from_db/2: Query DB + Registry, merge state (no task selection)
- merge_task_state/3: Combine persisted tasks with live agents
- safe_subscribe/2: Prevent duplicate subscriptions via MapSet
- get_filtered_logs/2: Filter logs by selected_agent_id
- EventHandlers.handle_submit_prompt/2: FieldProcessor validation → TaskManager.create_task/3 → safe_subscribe

## Critical Bug Fix (2025-10-21)
- Fixed duplicate PubSub subscription in mount/3 (lines 53-60)
- Root cause: subscribe_to_existing_tasks didn't track in MapSet
- Impact: Prevented messages appearing twice in Mailbox

## Hierarchical Prompt Fields Integration (2025-11)
- EventHandlers uses FieldProcessor.process_form_params/1 for validation
- Splits form params into task_fields (global_context, global_constraints) and agent_fields (9 provided fields)
- Calls TaskManager.create_task/3 with split fields
- Error handling for {:missing_required, fields} and {:invalid_enum, field, value, allowed}
- All 11 fields passed from TaskTree modal through EventHandlers to TaskManager

## TODO Integration (2025-12)
- MessageHandlers.handle_todos_updated/2: Updates agents[agent_id].todos
- Auto-subscribe to agents:[id]:todos when agent spawned
- MessageHandlers.load_or_create_task/2: Loads tasks from DB if not in state (extracted helper)

## Restored Child Visibility Fix (2025-12)
- MessageHandlers.link_orphaned_children/2: Links children that arrived before parent
- Handles race condition during task restoration where child broadcasts arrive before parent
- Called after every agent_spawned to check for orphaned children claiming this parent
- ConfigManager broadcasts with parent_id string (not PID) for restored agents
- Safe access socket.assigns[:current_task_id] handles child-before-root race

## Direct Message Integration (2025-11)
- MessageHandlers.handle_send_direct_message/3: Registry lookup + Core.send_user_message/2
- Dashboard.handle_info({:send_direct_message, agent_id, content}): Routes to MessageHandlers
- Flow: AgentNode → Dashboard → Registry → Core → PubSub → Mailbox
- Enables messaging to root agents without prior mailbox interaction

## UI Persistence / EventHistory Integration (2025-12)
- mount/3: Extracts event_history_pid from session, queries buffer for initial logs/messages
- get_event_history_pid/1: Session extraction with fallback to EventHistory.get_pid()
- query_event_history/3: Queries buffer with agent_ids and task_ids after loading tasks
- MessageHandlers deduplication: handle_log_entry/2 and handle_agent_message/2 skip by id (MapSet O(1))
- MessageHandlers.query_agent_buffer/3: Queries buffer on agent_spawned for late-arriving agents
- Flow: mount → load_tasks → query_buffer → assign initial logs/messages
- Test isolation: Session-based event_history_pid injection

## Patterns
- Subscription Safety: MapSet tracking prevents duplicates during restarts/resumes/mount
- Event Delegation: TaskTree sends {:pause_task, id} etc to Dashboard handle_info
- Test Isolation: Session-based PubSub/Registry injection, Sandbox.allow for DB access, async: true
- State: tasks (DB+Registry merged), agents (Registry+lifecycle+todos), logs (Map, 100 limit), subscribed_topics (MapSet)

## Dependencies
TaskManager, TaskRestorer, RegistryQueries, Core, PubSub, UI.TaskTree, UI.LogView, UI.Mailbox

Test coverage: 48 dashboard_live_test (incl. 6 restored child visibility R22-R27), 16 dashboard_delete_integration_test, 16 dashboard_3panel_integration_test, 16 buffer_integration_test (UI persistence R17-R24, R35-R42)
