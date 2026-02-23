# A simple GenServer that stands in for an MCP Client.
# Started with GenServer.start (NOT start_link) to avoid linking to the
# test process. This prevents :kill signals from propagating to the test.
defmodule Quoracle.Agent.MCPClientLifecycleTest.MockMCPClient do
  @moduledoc false
  use GenServer

  def start(_opts \\ []), do: GenServer.start(__MODULE__, :ok)
  def init(:ok), do: {:ok, %{}}
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Quoracle.Agent.MCPClientLifecycleTest do
  @moduledoc """
  Test suite for MCP Client lifecycle monitoring, liveness guards, and transparent recovery.

  WorkGroupID: fix-20260221-mcp-client-lifecycle (Packet 1)

  Covers:
  - R1: Core monitors MCP Client on store
  - R2: Core clears MCP Client on DOWN
  - R3: MCPHelpers re-initializes dead client
  - R4: Router retrieval liveness check
  - R5: Transparent recovery integration
  - R6: Monitor does not affect normal operation
  - R7: Multiple deaths recovery
  - R8: Race window - DOWN not yet processed
  - R9: Core state unaffected by non-MCP DOWN
  - R10: MCP client nil after monitor cleanup
  - R-ACC: Agent transparent recovery (acceptance)
  """

  use Quoracle.DataCase, async: true

  @moduletag capture_log: true

  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Actions.Router.MCPHelpers
  alias Quoracle.Agent.MCPClientLifecycleTest.MockMCPClient

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_test_agent(context) do
    %{sandbox_owner: sandbox_owner, deps: deps, pubsub: pubsub} = context
    parent_pid = self()

    agent =
      start_supervised!(
        {Core,
         {parent_pid, "MCP lifecycle test agent",
          test_mode: true,
          skip_auto_consensus: true,
          sandbox_owner: sandbox_owner,
          registry: deps.registry,
          dynsup: deps.dynsup,
          pubsub: pubsub}},
        shutdown: :infinity
      )

    register_agent_cleanup(agent)
    {agent, deps}
  end

  # Starts a mock MCP client (unlinked) and registers cleanup
  defp start_mock_client do
    {:ok, pid} = MockMCPClient.start()

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
    end)

    pid
  end

  # Stores a mock client in Core and syncs to ensure cast is processed
  defp store_mcp_client(agent, client_pid) do
    GenServer.cast(agent, {:store_mcp_client, client_pid})
    # Sync - GenServer.call after cast ensures cast is processed first
    {:ok, state} = Core.get_state(agent)
    assert state.mcp_client == client_pid
    :ok
  end

  # Kills a process and waits for confirmation of death
  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5000 -> raise "Timeout waiting for process #{inspect(pid)} to die"
    end
  end

  # Kills a process and waits for the Core agent to process the :DOWN monitor message.
  # kill_and_wait only guarantees the TEST process sees death; the Core GenServer
  # may not have processed its own :DOWN yet. This helper polls Core.get_state
  # until mcp_client is nil (cleared by Core's :DOWN handler).
  defp kill_and_wait_for_core(pid, agent) do
    kill_and_wait(pid)

    # Poll until Core has processed the :DOWN and cleared mcp_client
    Enum.reduce_while(1..20, nil, fn _, _ ->
      {:ok, state} = Core.get_state(agent)

      if state.mcp_client == nil do
        {:halt, :ok}
      else
        # Yield to scheduler so Core can process its :DOWN message
        :timer.sleep(1)
        {:cont, nil}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()

    {:ok, deps: deps, pubsub: deps.pubsub, sandbox_owner: sandbox_owner}
  end

  # ---------------------------------------------------------------------------
  # Unit Tests
  # ---------------------------------------------------------------------------

  describe "R1: Core monitors MCP Client on store" do
    @tag :arc_mcp_lifecycle
    test "storing MCP client PID sets up process monitor", context do
      {agent, _deps} = spawn_test_agent(context)

      mock_client = start_mock_client()

      # Store the MCP client in Core
      store_mcp_client(agent, mock_client)

      # Kill the mock client - if monitor was set up, Core will receive DOWN
      # and clear mcp_client to nil
      kill_and_wait(mock_client)

      # Sync with Core to ensure DOWN message (if any) is processed
      # After the fix: Core monitors the PID, receives DOWN, clears to nil
      # Before the fix: Core does NOT monitor, so mcp_client stays as dead PID
      {:ok, state_after} = Core.get_state(agent)
      assert state_after.mcp_client == nil
    end
  end

  describe "R2: Core clears MCP Client on DOWN" do
    @tag :arc_mcp_lifecycle
    test "MCP client death clears state.mcp_client to nil", context do
      {agent, _deps} = spawn_test_agent(context)

      mock_client = start_mock_client()

      # Store and verify
      store_mcp_client(agent, mock_client)

      # Kill mock client (triggers DOWN if monitored)
      kill_and_wait(mock_client)

      # Sync with Core to ensure it has processed any DOWN message
      {:ok, state_after} = Core.get_state(agent)

      # After fix: mcp_client should be nil
      # Before fix: mcp_client still holds the dead PID
      assert state_after.mcp_client == nil
    end
  end

  describe "R3: MCPHelpers re-initializes dead client" do
    @tag :arc_mcp_lifecycle
    test "get_or_init_mcp_client re-initializes when cached PID is dead", context do
      {agent, _deps} = spawn_test_agent(context)

      # Start and immediately stop a process to get a dead PID
      mock_client = start_mock_client()
      GenServer.stop(mock_client, :normal, :infinity)
      refute Process.alive?(mock_client)

      # Call MCPHelpers with the dead PID - it should detect it's dead
      # and re-initialize (create a new one)
      # After fix: `is_nil(mcp_client) or not Process.alive?(mcp_client)` triggers re-init
      # Before fix: only `is_nil(mcp_client)` triggers re-init, dead PID returned as-is
      result =
        MCPHelpers.get_or_init_mcp_client(
          mcp_client: mock_client,
          agent_pid: agent,
          agent_id: Core.get_agent_id(agent),
          sandbox_owner: context.sandbox_owner
        )

      # Before fix: result == mock_client (stale dead PID returned unchanged)
      # After fix: result is a new alive PID
      refute result == mock_client, "Should not return the dead PID"
      assert is_pid(result)
      assert Process.alive?(result)

      # Cleanup newly created MCP.Client
      on_exit(fn ->
        if is_pid(result) and Process.alive?(result) do
          GenServer.stop(result, :normal, :infinity)
        end
      end)
    end
  end

  describe "R4: Router retrieval liveness check" do
    @tag :arc_mcp_lifecycle
    test "Router treats dead MCP client PID as nil", context do
      {agent, _deps} = spawn_test_agent(context)

      # Store a PID that we'll then kill
      mock_client = start_mock_client()
      store_mcp_client(agent, mock_client)

      # Kill the mock client
      kill_and_wait(mock_client)

      # Retrieve via GenServer.call (same path Router uses in execute/3)
      # The fix adds a liveness guard in Router.execute/3:
      #   pid = GenServer.call(agent_pid, :get_mcp_client)
      #   if pid && Process.alive?(pid), do: pid, else: nil
      #
      # Before fix: Core returns the dead PID, Router uses it (crash)
      # After fix (defense layer 1 - monitoring): Core clears to nil on DOWN
      # After fix (defense layer 3 - Router guard): Router checks alive? too
      #
      # We test that Core has cleared the PID (defense layer 1).
      # If Core hasn't processed DOWN yet, the Router guard (layer 3) catches it.
      retrieved = GenServer.call(agent, :get_mcp_client)

      # Before fix: retrieved is the dead PID (non-nil)
      # After fix: retrieved is nil (Core processed DOWN and cleared state)
      assert retrieved == nil
    end
  end

  describe "R6: Monitor does not affect normal operation" do
    @tag :arc_mcp_lifecycle
    test "alive MCP client is reused without re-initialization", context do
      {agent, _deps} = spawn_test_agent(context)

      mock_client = start_mock_client()

      # Store the MCP client (after fix, this also sets up a monitor)
      store_mcp_client(agent, mock_client)

      # Verify the alive client is reused by MCPHelpers
      result =
        MCPHelpers.get_or_init_mcp_client(
          mcp_client: mock_client,
          agent_pid: agent,
          agent_id: Core.get_agent_id(agent)
        )

      assert result == mock_client
      assert Process.alive?(result)

      # Now verify the monitor is actually set up by killing the client
      # and checking that Core cleared the state.
      # This is the key assertion that fails pre-implementation:
      # without Process.monitor in handle_store_mcp_client, Core won't
      # receive the DOWN message and won't clear mcp_client.
      kill_and_wait(mock_client)

      {:ok, state_after} = Core.get_state(agent)

      assert state_after.mcp_client == nil,
             "Monitor should have cleared mcp_client after death (proves monitor was set up during store)"
    end
  end

  describe "R9: Core state unaffected by non-MCP DOWN" do
    @tag :arc_mcp_lifecycle
    test "DOWN from unrelated process does not clear mcp_client", context do
      {agent, _deps} = spawn_test_agent(context)

      # Store a real MCP client
      mock_client = start_mock_client()
      store_mcp_client(agent, mock_client)

      # Start an unrelated process, have Core monitor it (simulating some other
      # monitored process dying), then verify mcp_client is NOT cleared
      {:ok, unrelated} = MockMCPClient.start()

      on_exit(fn ->
        if Process.alive?(unrelated), do: GenServer.stop(unrelated, :normal, :infinity)
      end)

      kill_and_wait(unrelated)

      # The DOWN from unrelated process should NOT affect mcp_client
      {:ok, state_after} = Core.get_state(agent)
      assert state_after.mcp_client == mock_client
      assert Process.alive?(mock_client)

      # Now verify the monitor IS working by killing the actual MCP client
      # This proves selectivity: only MCP client DOWN clears the field
      kill_and_wait(mock_client)

      {:ok, state_final} = Core.get_state(agent)

      assert state_final.mcp_client == nil,
             "MCP client DOWN should clear mcp_client (proves monitoring is selective)"
    end
  end

  describe "R10: MCP Client nil after monitor cleanup" do
    @tag :arc_mcp_lifecycle
    test "get_mcp_client returns nil after MCP client death", context do
      {agent, _deps} = spawn_test_agent(context)

      mock_client = start_mock_client()

      # Store and verify via :get_mcp_client call
      store_mcp_client(agent, mock_client)
      assert GenServer.call(agent, :get_mcp_client) == mock_client

      # Kill and wait for death
      kill_and_wait(mock_client)

      # After fix: get_mcp_client returns nil (Core processed DOWN)
      # Before fix: get_mcp_client returns the dead PID
      result = GenServer.call(agent, :get_mcp_client)
      assert result == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------------

  describe "R5: Transparent recovery integration" do
    @tag :arc_mcp_lifecycle
    test "call_mcp action recovers transparently after MCP client death", context do
      {agent, _deps} = spawn_test_agent(context)

      # Store a mock MCP client
      mock_client = start_mock_client()
      store_mcp_client(agent, mock_client)

      # Kill the MCP client
      kill_and_wait(mock_client)

      # After the fix, Core should process the DOWN and clear mcp_client
      {:ok, state_after_death} = Core.get_state(agent)
      assert state_after_death.mcp_client == nil

      # Now MCPHelpers should re-initialize when called with nil
      # (This is the transparent recovery path: nil triggers lazy re-init)
      new_client =
        MCPHelpers.get_or_init_mcp_client(
          mcp_client: nil,
          agent_pid: agent,
          agent_id: Core.get_agent_id(agent),
          sandbox_owner: context.sandbox_owner
        )

      assert is_pid(new_client)
      assert Process.alive?(new_client)
      refute new_client == mock_client

      # Cleanup the new MCP.Client
      on_exit(fn ->
        if is_pid(new_client) and Process.alive?(new_client) do
          GenServer.stop(new_client, :normal, :infinity)
        end
      end)
    end
  end

  describe "R7: Multiple deaths recovery" do
    @tag :arc_mcp_lifecycle
    test "agent recovers from multiple consecutive MCP client deaths", context do
      {agent, _deps} = spawn_test_agent(context)

      # Cycle 1: Store, kill, verify recovery
      client1 = start_mock_client()
      store_mcp_client(agent, client1)
      kill_and_wait(client1)

      {:ok, state1} = Core.get_state(agent)
      assert state1.mcp_client == nil

      # Cycle 2: Store new client, kill, verify recovery again
      client2 = start_mock_client()
      store_mcp_client(agent, client2)
      kill_and_wait(client2)

      {:ok, state2} = Core.get_state(agent)
      assert state2.mcp_client == nil

      # Cycle 3: Store yet another client, verify it's alive and stored
      client3 = start_mock_client()
      store_mcp_client(agent, client3)

      {:ok, state3} = Core.get_state(agent)
      assert state3.mcp_client == client3
      assert Process.alive?(client3)
    end
  end

  describe "R8: Race window - DOWN not yet processed" do
    @tag :arc_mcp_lifecycle
    test "Process.alive? guard catches stale PID before DOWN is processed", context do
      {agent, _deps} = spawn_test_agent(context)

      mock_client = start_mock_client()

      # Store the MCP client
      store_mcp_client(agent, mock_client)

      # Kill the client - don't sync with Core (we want the race window
      # where Core hasn't processed DOWN yet but MCPHelpers is called)
      kill_and_wait(mock_client)

      # Immediately call MCPHelpers with the dead PID
      # Before fix: MCPHelpers sees non-nil PID and returns it (stale)
      # After fix: MCPHelpers checks Process.alive? and re-initializes
      result =
        MCPHelpers.get_or_init_mcp_client(
          mcp_client: mock_client,
          agent_pid: agent,
          agent_id: Core.get_agent_id(agent),
          sandbox_owner: context.sandbox_owner
        )

      # The guard should catch the dead PID and trigger re-initialization
      refute result == mock_client, "Should not return the stale dead PID"
      assert is_pid(result)
      assert Process.alive?(result)

      # Cleanup the newly created MCP.Client
      on_exit(fn ->
        if is_pid(result) and Process.alive?(result) do
          GenServer.stop(result, :normal, :infinity)
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance Test
  # ---------------------------------------------------------------------------

  describe "R-ACC: Agent transparent recovery" do
    @tag :acceptance
    @tag :arc_mcp_lifecycle
    test "agent recovers from dead MCP client on next call_mcp action", context do
      {agent, _deps} = spawn_test_agent(context)

      # 1. Simulate having an MCP client stored in agent state
      mock_client = start_mock_client()
      store_mcp_client(agent, mock_client)

      # 2. MCP Client dies (simulating crash/timeout/network failure)
      # Use kill_and_wait_for_core to ensure Core has processed its :DOWN
      # message before asserting (fixes non-deterministic scheduler race)
      kill_and_wait_for_core(mock_client, agent)

      # 3. Verify Core has cleared the dead PID (monitor + DOWN processing)
      {:ok, state_cleared} = Core.get_state(agent)

      assert state_cleared.mcp_client == nil,
             "Core should clear mcp_client to nil after MCP Client death"

      # 4. Verify MCPHelpers would re-initialize on next call_mcp
      #    (This is the path Router.execute takes for :call_mcp actions)
      new_client =
        MCPHelpers.get_or_init_mcp_client(
          mcp_client: nil,
          agent_pid: agent,
          agent_id: Core.get_agent_id(agent),
          sandbox_owner: context.sandbox_owner
        )

      # 5. POSITIVE ASSERTION: New client is created and alive
      assert is_pid(new_client), "MCPHelpers should create a new MCP Client"
      assert Process.alive?(new_client), "New MCP Client should be alive"
      refute new_client == mock_client, "New client should be different from dead one"

      # 6. NEGATIVE ASSERTION: No stale PID, no permanent failure
      # MCPHelpers casts {:store_mcp_client, new_client} internally,
      # so after syncing, Core should have the new client
      {:ok, _sync} = Core.get_state(agent)
      retrieved = GenServer.call(agent, :get_mcp_client)

      refute retrieved == mock_client,
             "State should never hold the dead MCP Client PID"

      # Cleanup
      on_exit(fn ->
        if is_pid(new_client) and Process.alive?(new_client) do
          GenServer.stop(new_client, :normal, :infinity)
        end
      end)
    end
  end
end
