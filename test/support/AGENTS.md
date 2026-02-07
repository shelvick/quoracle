# test/support/

## Modules
- DataCase: Ecto.Sandbox setup with start_owner! pattern
- ConnCase: Phoenix.ConnTest with start_owner! pattern
- PubSubIsolation: Isolated PubSub instance creation
- IsolationHelpers: Isolated Registry/DynSup creation
- ConsensusTestHelpers: Consensus test utilities
- AgentTestHelpers: **CRITICAL - use for ALL agent spawns**
- mocks.ex: Hammox mock definitions

## Agent Cleanup Helpers (CRITICAL)

**Import in every agent test**: `import Test.AgentTestHelpers`

```elixir
# Single agent
{:ok, agent_pid} = spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

# Task creation (converted internally to create_task/3)
{:ok, {task, agent_pid}} = create_task_with_cleanup("Prompt", opts)

# Concurrent spawns
results = spawn_agents_concurrently(deps.dynsup, configs, opts)

# Already spawned
register_agent_cleanup(agent_pid)  # or cleanup_tree: true for hierarchies
```

**create_task_with_cleanup/2 (2025-11):**
- Accepts simple prompt string for convenience
- Internally converts to TaskManager.create_task/3 format: `create_task(%{}, %{task_description: prompt}, opts)`
- Maintains backward compatibility for existing tests

## stop_and_wait_for_unregister/3

Polls Registry until cleanup completes. Use before re-spawning same agent_id to avoid conflicts.

## Key Functions
- PubSubIsolation.setup_isolated_pubsub/0: Unique PubSub instance
- IsolationHelpers.create_isolated_deps/0: %{registry, dynsup}
- ConsensusTestHelpers: build_test_messages/2, has_system_prompt?/1
- TaskTreeTestLive: Test harness for isolated TaskTree component testing (70 lines), handles skill_not_found flash errors (2026-02)

**Mock definitions**: MockProvider (Hammox, implements ProviderInterface)

## Shell.execute() Dual-Path Returns

Shell returns EITHER async OR sync depending on whether command completes within ~100ms:

```elixir
# ❌ WRONG: Assumes always-async
{:ok, %{command_id: _cmd_id}} = Shell.execute(cmd, agent, opts)
assert_receive {:action_completed, %{result: {:ok, result}}}, 3000

# ✅ CORRECT: Handle both paths
case Shell.execute(cmd, agent, opts) do
  {:ok, %{command_id: _cmd_id}} ->
    # Async path - command still running
    assert_receive {:action_completed, %{result: {:ok, result}}}, 3000
    assert result.status == :completed

  {:ok, result} when is_map(result) ->
    # Sync path - completed immediately
    assert result.status == :completed
end
```

**Why**: Under load, fast commands may complete before async machinery engages.

## Registry Cleanup Synchronization

Registry updates are async relative to process termination (see root AGENTS.md). Use `stop_and_wait_for_unregister/3`:

```elixir
# ❌ WRONG: Race condition
GenServer.stop(pid)
refute agent_exists?(agent_id, registry)  # May fail!

# ✅ CORRECT: Wait for Registry to reflect termination
stop_and_wait_for_unregister(pid, agent_id, registry)
refute agent_exists?(agent_id, registry)
```

**When needed**: Before re-spawning same agent_id, or when asserting agent no longer exists.
