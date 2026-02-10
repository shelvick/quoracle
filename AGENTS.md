# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ CRITICAL: Test Isolation & Concurrency Are NON-NEGOTIABLE ⚠️

**STOP! Before suggesting ANY code changes, remember:**

1. **We spent WEEKS fixing concurrency bugs** - Don't reintroduce them!
   - ❌ **NEVER** suggest global PubSub topics (`logs:all`, `agents:all`, etc.)
   - ❌ **NEVER** use named processes/GenServers/ETS tables
   - ❌ **NEVER** use Process.sleep for synchronization
   - ✅ **ALWAYS** use explicit dependency injection
   - ✅ **ALWAYS** use isolated PubSub instances in tests
   - ✅ **ALWAYS** think "will this work with 100 parallel tests?"

2. **Check the tracker for concurrency fixes** - Learn from what we fixed:
   - `FIX_PubSubProcessDict` - Process dictionary breaks in Task.async (commit 50f6502)
   - `FIX_GlobalRegistryContamination` - Full test isolation via DI
   - `FIX_NamedSingletons` - Removed ALL named processes
   - `FIX_PubSubAsyncTrue` - 100% test isolation achieved
   - `FIX_DataCaseDBOwnership` - start_owner! fixes spawned process crashes (commit 70377fe)
   - `FIX_ConnCaseDBOwnership` - LiveView + DB isolation (commit c54b342)
   - `FIX_RegistryRaceCondition` - Atomic composite registration (commit 132a733)
   - `FIX_AgentCleanupLeaks` - Added on_exit cleanup with :infinity timeout for 25+ agent spawns across 6 files (Jan 2025)
     - Files: task_restorer_test.exs, core_persistence_test.exs, spawn_test.exs, router_send_message_test.exs, dyn_sup_test.exs, dyn_sup_refactor_test.exs
     - Pattern: ALWAYS use `GenServer.stop(agent_pid, :normal, :infinity)` - finite timeouts cause race conditions

3. **When in doubt, research existing patterns** - Don't guess!
   - Look at how `UI_Dashboard` handles PubSub isolation
   - Check how `ACTION_Router` injects dependencies
   - Study the test helpers in `test/support/`

**If you suggest reverting to global state, you're doing it wrong. STOP and reconsider.**

## Project: Quoracle
Phoenix LiveView app for recursive agent orchestration with multi-LLM consensus.

## Context
- Technical debt tracked in `lib/quoracle/agent/AGENTS.md`

## Commands
```bash
mix test path/to/test.exs:42        # Run specific test/line
mix test.watch                       # Auto-test on changes
mix format                           # Required before commit
mix credo --min-priority=high        # Blocks commits
mix dialyzer                         # Type checking
mix ecto.gen.migration name          # New migration
mix phx.gen.live Context Schema table field:type
mix phx.server                       # Start dev server (port 4000)
MIX_ENV=test mix phx.server         # Test server (port 4002)
iex -S mix phx.server                # Dev server with shell
mix run priv/repo/seeds.exs         # Seed database with model configs
```

## Architecture
Agents are GenServers under DynamicSupervisor. Each agent spawns children recursively, executes actions via ACTION_Router, achieves consensus across LLMs, communicates via direct PID messaging. **Full PubSub isolation via explicit dependency injection (no Process dictionary).**

Components (47 total):
- Agent System (11): AGENT_Orchestrator, AGENT_Core, AGENT_Consensus, PROC_* instances
- Action System (11): ACTION_Router + 10 action types
- LiveView UI (8): UI_Dashboard (3-panel), UI_TaskTree, UI_LogView, UI_Mailbox
- Data Layer (6): PostgreSQL/Ecto, tables: agents/tasks/logs/messages/action_results
- External (3): LLM APIs, Web services, MCP

Patterns: Actor model, OTP supervision, direct parent-child messaging, multi-model consensus, LiveView WebSocket updates, **explicit PubSub parameter passing**

### Router Lifecycle Management (CRITICAL)

**Each agent spawns its own Router GenServer** - Router must be cleaned up properly to prevent DB connection leaks.

**Two-layer safety pattern**:

```elixir
# Router.init/1 - Monitor the agent that owns this Router
def init(opts) do
  agent_pid = Keyword.get(opts, :agent_pid)

  agent_monitor =
    if agent_pid && Process.alive?(agent_pid) do
      Process.monitor(agent_pid)
    else
      nil
    end

  state = %{agent_monitor: agent_monitor, agent_pid: agent_pid, ...}
  {:ok, state}
end

# Router.handle_info/2 - Self-terminate when owner dies
def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
  cond do
    state.agent_monitor == ref && state.agent_pid == pid ->
      {:stop, :normal, state}  # Owner died, terminate cleanly

    true ->
      {:noreply, state}  # Some other process died
  end
end

# Core.terminate/2 - Stop Router FIRST with :infinity timeout
def terminate(reason, state) do
  # CRITICAL: Stop Router before cleanup to allow DB operations to complete
  if state[:router_pid] && Process.alive?(state.router_pid) do
    GenServer.stop(state.router_pid, :normal, :infinity)
  end

  # Now safe to cleanup agent state...
end
```

**Why this pattern**:
- Prevents orphaned Routers holding DB connections
- Bidirectional lifecycle coupling (Core stops Router, Router monitors Core)
- :infinity timeout allows Router to finish DB operations during shutdown
- Clean termination prevents Postgrex "client exited" errors

### Dependency Injection Architecture

**All isolated dependencies passed explicitly through opts**: `registry`, `dynsup`, `pubsub`, `sandbox_owner`

**Flow**: DashboardLive → TaskManager → DynSup → Core → Router (all deps propagated via opts)

**Production vs Test**: Production uses global `Quoracle.AgentRegistry`/`Quoracle.PubSub`, tests create isolated instances per test

## Phoenix Setup
- Dev server: http://localhost:4000 (CLOAK_ENCRYPTION_KEY required)
- Test server: http://localhost:4002 (port only, server: false by default)
- LiveDashboard: /dev/dashboard (dev only)
- Asset pipeline: esbuild + Tailwind CSS
- Templates: HEEx format in controllers/components

## Notes
- Phoenix installed with LiveView support
- Never use `--no-verify`
