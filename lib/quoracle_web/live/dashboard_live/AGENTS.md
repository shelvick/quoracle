# lib/quoracle_web/live/dashboard_live/

## Modules
- DataLoader (231 lines): Data loading/merging helpers for Dashboard mount
- EventHandlers (451 lines): User action handlers — submit_prompt, pause/resume/delete task, select_agent
- MessageHandlers (498 lines): PubSub message handlers — agent_spawned/terminated, log_entry, task_message, todos_updated, grove handlers (4 extracted from DashboardLive in REFACTOR fix-20260311-211553)
- Subscriptions: PubSub subscription management with MapSet tracking
- TestHelpers: Test-specific handlers

## Subdirectories
- message_handlers/helpers.ex: Shared helper functions for MessageHandlers

## Extracted Grove Handlers (fix-20260311-211553 REFACTOR)
4 grove-related `handle_info` handlers extracted from `dashboard_live.ex` to `message_handlers.ex` for 500-line limit compliance:
- `handle_selected_grove_updated/2`
- `handle_loaded_grove_updated/2`
- `handle_grove_skills_path_updated/2`
- `handle_grove_error/2`
