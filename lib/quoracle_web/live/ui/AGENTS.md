# lib/quoracle_web/live/ui/

## Pure Display Components (no subscriptions)
- TaskTree: Tree display, expand/collapse, select_agent→parent, enhanced modal with 10-field form, inline message forms (2025-11), budget_input field (2025-12)
- TaskFormFields: Reusable form components (text, textarea, enum_dropdown, list_input, budget_input), 250 lines
- TaskBudgetEditor: Modal for editing task budget limits (2025-12), validates against spent+committed minimum
- LogView: Log display, min_level filter, auto-scroll
- AgentNode: Recursive node rendering, status indicators, TODO accordion (2025-12), direct message forms (2025-11)
- LogEntry: Log rendering (351 lines), imports LogEntry.Helpers
- LogEntry.Helpers: Formatting helpers (279 lines, 23 @spec), timestamp/level/metadata/role styling, LLM response formatting (2025-12)
- Message: Accordion display, collapsed 80-char preview, reply forms with agent_alive control
- CostDisplay: Cost display component (385 lines), 4 modes (:badge, :summary, :detail, :request)
  - v2.0: Token breakdown table with 10 columns (Model, Req, Input, Output, Reason, Cache R, Cache W, In$, Out$, Total$)
  - Expandable detail view, lazy-loads from Aggregator
  - Helper functions: format_tokens/1, format_token_or_dash/1, format_cost_compact/1, truncate_model/1

## Stateful Components
- Mailbox: Accordion inbox, subscribes to agents:lifecycle, agent_alive_map tracking, newest-first ordering

## AgentNode TODO Display (2025-12)
- Accordion section when @expanded and @agent[:todos]
- State icons: ⏳ (todo), ⏸️ (pending), ✅ (done)
- Strikethrough + opacity for done items
- Helper functions: state_icon/1, todo_state_class/1 (lines 176-183)

## AgentNode Direct Message (2025-11)
- Inline form for alive root agents (@agent_alive and parent_id == nil)
- LiveComponent local state: message_form_expanded, message_input
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
- 11-field form in 3 sections: Agent Identity, Task Work, Budget
- Skills field added (2026-02): list_input for comma-separated skill names
- Uses TaskFormFields components for all inputs
- handle_event("create_task"): Sends {:submit_prompt, params} to parent
- No local validation (handled by Dashboard via FieldProcessor)

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
- TaskTree: 18 tests + 19 modal tests (13 original + 6 skills R41-R46) + 3 direct message tests
- TaskFormFields: 21 tests
- LogView: 22 tests, Mailbox: 24 tests
- AgentNode: 28 tests + 6 direct message tests = 34 total (then refactored to 44 tests)
- LogEntry: 25 tests, Message: 34 tests
- Dashboard integration: 18 tests + 4 direct message tests = 22 total (then 35 tests)
- CostDisplay: 69 tests (v2.0 token breakdown table)
- BudgetUI Acceptance: 19 tests (R1-R19) - full E2E from /dashboard route (2025-12)
