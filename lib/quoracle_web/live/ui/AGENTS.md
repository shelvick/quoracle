# lib/quoracle_web/live/ui/

## Pure Display Components (no subscriptions)
- TaskTree: Tree display, expand/collapse, select_agent→parent, enhanced modal with 10-field form, inline message forms (2025-11), budget_input field (2025-12), grove selector dropdown (2026-02)
- GroveSelector: Grove dropdown component (2026-02), renders `<select>` with grove names from assigns, `for="grove-select"` label + `id="grove-select"` select (accessibility), emits `grove_selected` event
- TaskFormFields: Reusable form components (text, textarea, enum_dropdown, list_input, budget_input), 250 lines
- TaskBudgetEditor: Modal for editing task budget limits (2025-12), validates against spent+committed minimum
- LogView: Log display, severity filter via pre-computed display_logs in update/2, auto-scroll (v5.0: render uses @display_logs, v6.0: forwards root_pid to LogEntry)
- AgentNode: Recursive LiveComponent (v8.0), per-node diffing, dual-mode (TaskTree integration + legacy isolated). Accepts per-node scalar assigns (agent_cost, agent_message_form) in centralized mode. assign_legacy_scalars/1 for backward compat. child_alive?/2, child_cost/2 helpers read from enriched display_agents. Delegates to MessageForm/TodoDisplay/BudgetHelpers submodules. component_prefix assign for CostDisplay ID disambiguation
- LogEntry: Log rendering (351 lines), imports LogEntry.Helpers. v3.0: effective_metadata/1, metadata_truncated?/1, truncated?/1 for lazy-load full detail. fetch_full_detail handler with nil guard on root_pid. data-truncated attribute on response containers
- LogEntry.Helpers: Formatting helpers (279 lines, 23 @spec), timestamp/level/metadata/role styling, LLM response formatting (2025-12)
- Message: Accordion display, collapsed 80-char preview, reply forms with agent_alive control
- CostDisplay: Cost display component (385 lines), 4 modes (:badge, :summary, :detail, :request)
  - v5.0: precomputed_total_cost? flag, badge mode is pure display (zero DB access), detail/summary lazy-load on expand
  - Token breakdown table with 10 columns (Model, Req, Input, Output, Reason, Cache R, Cache W, In$, Out$, Total$)
  - Correctly renders absorption records (child_budget_absorbed with model_spec) after child dismissal
  - Helper functions: format_tokens/1, format_token_or_dash/1, format_cost_compact/1, truncate_model/1, merge_cost_types/2

## Stateful Components
- Mailbox: Accordion inbox, v2.0: accepts agent_alive_map directly from parent (no lifecycle subscription), newest-first ordering

## AgentNode v8.0 (2026-03, perf-20260321-012101)
- Unified recursive LiveComponent replacing TaskTree's render_agent_node/1 function component
- Dual-mode: `has_centralized_state` check in update/2 detects TaskTree mode vs legacy isolated mode
- TaskTree mode: receives per-node scalar assigns (agent_cost, agent_message_form, agent_alive) instead of full maps
- Legacy mode: receives cost_data/message_forms/agent_alive_map via assign_new, converted to scalars via assign_legacy_scalars/1
- child_alive?/2, child_cost/2: read from enriched display_agents (ui_alive, ui_total_cost)
- Submodule delegation: MessageForm, TodoDisplay, BudgetHelpers (when @target set)
- Event routing: phx-target={@target || @myself} — TaskTree handles all events in production
- component_prefix assign: "" (legacy) or "tasktree-" (TaskTree) for CostDisplay ID disambiguation
- lookup_child/2: agents map lookup with fallback stub for legacy mode
- Null guard: render(%{agent: nil}) renders empty div

## AgentNode Direct Message (2025-11, updated 2026-03)
- Inline form for alive root agents (agent_alive_map check + parent_id == nil)
- TaskTree mode: delegates to MessageForm submodule, uses centralized message_forms map
- Legacy mode: local state message_form_expanded, message_input
- Event handlers: show_message_form, cancel_message, update_message_input, send_direct_message
- Sends {:send_direct_message, agent_id, content} to socket.root_pid
- Form clears and collapses after submission

## TaskFormFields Components (2025-11, updated 2025-12)
- text_field/1: Label + input + optional character counter
- textarea_field/1: Label + textarea + character counter (yellow warning at 90%)
- enum_dropdown/1: Label + select with options (cognitive_style, output_style, delegation_strategy)
- list_input/1: Comma-separated input with help text
- Helper functions: cognitive_style_options/0, output_style_options/0, delegation_strategy_options/0
- format_character_count/2: Returns HTML span with count and color

## TaskTree Modal (2025-11, updated 2026-02)
- 13-field form in 3 sections: Agent Identity, Task Work, Budget
- Skills field added (2026-02): list_input for comma-separated skill names
- Grove selector dropdown (2026-02): GroveSelector component, pre-fills all fields on selection
- GrovePrefill JS hook on `#new-task-form`: handles `grove_prefill` push_event, populates/clears 13 fields
- Uses TaskFormFields components for all inputs
- handle_event("create_task"): Sends {:submit_prompt, params} to parent
- No local validation (handled by Dashboard via FieldProcessor)

## TaskTree.GroveHandlers (2026-02, updated 2026-03-06)
- handle_grove_selected/2: Loads grove via Loader.load_grove/2, resolves bootstrap via BootstrapResolver.resolve_from_grove/1, nil→"" conversion, push_event("grove_prefill", fields)
- Sends {:grove_skills_path_updated, path} AND {:loaded_grove_updated, grove} to parent Dashboard
- Passes grove struct directly from Loader (confinement paths remain Sanitizer-expanded, no denormalization)
- handle_grove_cleared/2: push_event("grove_prefill", %{clear: true}), sends {:loaded_grove_updated, nil} to Dashboard
- **Does NOT resolve governance** — governance deferred to submit time (skills unknown until form submit)
- Error path also sends {:loaded_grove_updated, nil} to clear cached grove

## TaskTree Direct Message (2025-11)
- Inline message forms for alive root agents (function component pattern)
- State stored in message_forms map: %{agent_id => %{expanded: bool, input: string}}
- Event handlers: show_message_form, cancel_message_tree, update_message_input_tree, send_direct_message_tree
- Propagates agent_alive_map to recursive AgentNode renders
- Extracted components: MessageForm (70 lines), TodoDisplay (36 lines), Helpers (57 lines)

## TaskTree Refactor (2025-11)
- Main module: 498 lines (reduced from 578)
- TaskTree.Helpers: truncate_prompt, format_timestamp, status_badge_class, state_icon, todo_state_class
- TaskTree.MessageForm: Phoenix Component for inline messaging UI
- TaskTree.TodoDisplay: Phoenix Component for TODO list rendering

## Patterns
- MapSet expansion state, phx-target routing, send(root_pid) for events
- Character limits: task_description (500), global_context (2000), success_criteria (1000)
- Enum validation against Schemas module

## Test Coverage
- TaskTree: 18 tests + 19 modal tests (13 original + 6 skills R41-R46) + 3 direct message tests + grove integration tests
- TaskFormFields: 21 tests
- LogView: 22 tests, Mailbox: 24 tests
- AgentNode: 28 tests + 6 direct message tests = 34 total (then refactored to 44 tests)
- LogEntry: 25 tests, Message: 34 tests
- Dashboard integration: 18 tests + 4 direct message tests = 22 total (then 35 tests)
- CostDisplay: 72 tests (v3.0: R40-R42 absorption record acceptance tests)
- BudgetUI Acceptance: 19 tests (R1-R19) - full E2E from /dashboard route (2025-12)
