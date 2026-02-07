# lib/quoracle/boot/

## Modules
- AgentRevival: Boot-time restoration of running tasks from database

## Key Functions
- restore_running_tasks/0: Production entry point, uses global Registry/PubSub
- restore_running_tasks/1: Testable with DI (registry, pubsub, sandbox_owner opts)

## Patterns
- Always returns :ok (fire-and-forget, never crashes boot)
- Sequential restoration via Enum.map
- Per-task failure isolation via try/rescue/catch
- Delegates to TaskRestorer.restore_task/4

## Dependencies
- TaskManager.list_tasks/1: Query tasks by status
- TaskRestorer.restore_task/4: Actual restoration logic

## Integration
- Called from Application.start/2 after supervisor starts
- Placement: After MCP handler registration
