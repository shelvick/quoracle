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
- EventHandlers (451 lines): submit_prompt (grove_skills_path forwarding, XML-tagged initial message via PromptFieldManager), pause/resume_task, delete_task, select_agent
- MessageHandlers: agent_spawned/terminated (v12.0: first-writer-wins root_agent_id guard), log_entry, task_message, agent_message, todos_updated (2025-12), send_direct_message (2025-11), link_orphaned_children (2025-12), grove_skills_path_updated (2026-02)
- TestHelpers: Test-specific handlers

## SecretManagementLive (5-module architecture, 2025-10-24)

**Main Module:** SecretManagementLive (497 lines)
**Helpers:** DataHelpers (116 lines), ValidationHelpers (139 lines), ModelConfigHelpers (228 lines), ProfileHelpers (119 lines + build_hot_reload_payload/2 added v4.0)
**Template:** secret_management_live.html.heex
**Purpose:** Unified CRUD interface for secrets, credentials, model config, profiles, and system settings
**v5.0:** System tab with skills_path configuration (feat-20260208-210722)
**v6.0 (profile hot-reload):** save_profile handler captures old name + broadcasts `{:profile_updated, ...}` after successful save (2026-02-27)
- ProfileHelpers.build_hot_reload_payload/2: Builds payload map with old_name, new_name, model_pool, max_refinement_rounds, profile_description, force_reflection (nil-filtered)
- Broadcasts on old profile name so running agents receive rename transitions
- Uses socket.assigns.pubsub (injected at mount) for test isolation

## Key Functions
- mount/3: Extract pubsub/registry/sandbox_owner from session, load tasks, subscribe to agents:lifecycle + task messages (tracked in MapSet)
- load_tasks_from_db/2: Query DB + Registry, merge state (no task selection)
- merge_task_state/3: Combine persisted tasks with live agents
- safe_subscribe/2: Prevent duplicate subscriptions via MapSet
- get_filtered_logs/2: Filter logs by selected_agent_id
- EventHandlers.handle_submit_prompt/2: FieldProcessor validation → TaskManager.create_task/3 → safe_subscribe → build XML-tagged initial message via PromptFieldManager.build_prompts_from_fields/1 → Core.send_user_message

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

## Pause/Resume Pipeline Fix (2026-02-15, fix-20260214-pause-resume-pipeline)
- **MessageHandlers v12.0**: First-writer-wins guard on root_agent_id — prevents orphaned agents from overwriting real root during restoration
- **EventHandlers**: Removed redundant TaskManager.update_task_status("running") after restore (TaskRestorer.handle_restore_result already does this)
- Pattern: `if is_nil(task[:root_agent_id])` guards root_agent_id assignment

## Grove Bootstrap Integration (2026-02, wip-20260222-grove-bootstrap)
- **DashboardLive v13.0**: mount loads groves via Loader.list_groves/1, passes to TaskTree. Assigns: grove_skills_path, skills_path
- **EventHandlers**: Forwards grove_skills_path to TaskManager.create_task opts (server-derived, SEC-2a)
- **MessageHandlers**: handle_info({:grove_skills_path_updated, path}) updates socket assigns
- **TaskTree**: Passes groves list + grove_skills_path to NewTaskModal. GroveHandlers submodule for selection events
- Flow: GroveSelector → grove_selected → GroveHandlers → BootstrapResolver → push_event → GrovePrefill JS hook → form fields

## Grove Governance Integration (2026-02-28, wip-20260226-grove-governance)
- **DashboardLive v14.0**: Adds `:loaded_grove` socket assign (cached grove struct from GroveHandlers)
- **MessageHandlers**: Handles `{:loaded_grove_updated, grove}` info message — updates loaded_grove assign (nil on clear/error)
- **EventHandlers.handle_submit_prompt/2**: Reads `socket.assigns[:loaded_grove]`; if non-nil, calls `GovernanceResolver.resolve_all/1` + `build_agent_governance/3`; governance opts passed to TaskManager
- **Governance resolution at submit time** (NOT grove selection time): Skills unknown until form submit
- **Graceful degradation**: Governance errors are non-blocking — task proceeds without governance rather than failing
- **3 governance fields passed to TaskManager**: `governance_rules`, `governance_config`, `grove_hard_rules`
- Flow: GroveHandlers → {:loaded_grove_updated, grove} → Dashboard → EventHandlers (at submit) → GovernanceResolver → TaskManager

## Grove Hard Enforcement (2026-03-03, wip-20260302-grove-hard-enforcement)
- **EventHandlers v17.0**: Extracts `grove_confinement` from `loaded_grove.confinement` at submit time
  - Added `grove_confinement = loaded_grove && Map.get(loaded_grove, :confinement)` extraction
  - Added `maybe_add_opt(:grove_confinement, grove_confinement)` to opts pipeline
  - 4 governance/enforcement fields now passed to TaskManager: `governance_rules`, `governance_config`, `grove_hard_rules`, `grove_confinement`

## Fix Initial User Message (2026-03-04, fix-20260304-initial-message-fields)
- **EventHandlers v18.0 (451 lines)**: Sends XML-tagged initial message with all prompt fields
  - Builds user prompt via `PromptFieldManager.build_prompts_from_fields(%{provided: agent_fields, injected: %{}, transformed: %{}})`
  - Includes `<task>`, `<immediate_context>`, `<success_criteria>`, `<approach_guidance>` XML tags
  - Falls back to bare `task_description` when user_prompt is empty
  - Replaces bare `task_description` send (bug: fields were being discarded since Jan 2026 user_prompt removal refactor)

Test coverage: 51 dashboard_live_test (48 base + 3 new R6-R9), 16 dashboard_delete_integration_test, 16 dashboard_3panel_integration_test, 16 buffer_integration_test (UI persistence R17-R24, R35-R42), 28+ grove_integration_test (R69 grove_confinement threading), 2 dashboard_create_task_integration_test (R71-R76 initial message acceptance tests)
