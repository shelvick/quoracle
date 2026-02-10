# test/

## CRITICAL: Use Test.AgentTestHelpers for ALL Agent Spawning

**Import in every agent test**: `import Test.AgentTestHelpers`

**Primary helpers**:
- `spawn_agent_with_cleanup/3` - Spawn + wait + cleanup (most common)
- `create_task_with_cleanup/2` - TaskManager.create_task + cleanup
- `register_agent_cleanup/2` - Cleanup for existing agents
- `spawn_agents_concurrently/3` - Parallel spawning with cleanup

**Why**: Prevents DB connection leaks and Postgrex "owner exited" errors. See test/support/AGENTS.md for full patterns.

## LiveView Testing

**PubSub isolation**: Create isolated PubSub per test, pass via session, render(view) after broadcasts

**DB access**: Pass sandbox_owner through session, Sandbox.allow in mount

**Sync**: Call `render(view)` after PubSub.broadcast to force message processing (prevents race conditions)

## ExVCR

- `async: false` (adapter conflicts with concurrent module loading)
- Adapter per module: Finch for Azure, Hackney for Bedrock/Google
- Cannot mix adapters in same module
- Empty cassettes (2 bytes) = adapter mismatch

## Hammox

- Strict type checking: mock returns must match behaviour @type exactly
- Extra fields in mock returns cause TypeMatchError

**See test/support/AGENTS.md for complete cleanup patterns and examples**
