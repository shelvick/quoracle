defmodule Quoracle.Agent.CoreContinuationMcpTest.MockMCPClient do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, opts}

  def handle_call({:connect, _config}, _from, state) do
    {:reply, {:ok, %{connection_id: "test-conn", tools: []}}, state}
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}
end

defmodule Quoracle.Agent.CoreContinuationMcpTest do
  @moduledoc """
  Split from CoreTest for better parallelism.
  Tests consensus continuation bug fix, MCP client lifecycle,
  and dismissing flag for race prevention.
  """

  use Quoracle.DataCase, async: true

  @moduletag capture_log: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.CoreContinuationMcpTest.MockMCPClient

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()

    parent_pid = self()
    initial_prompt = "Hello, I am a test agent"

    {:ok,
     parent_pid: parent_pid,
     initial_prompt: initial_prompt,
     deps: deps,
     pubsub: deps.pubsub,
     sandbox_owner: sandbox_owner}
  end

  describe "consensus continuation bug fix (WorkGroupID: fix-20250926-203000)" do
    @tag :arc_cont_01
    test "handle_info(:trigger_consensus) returns proper GenServer tuple", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      ref = Process.monitor(agent)

      send(agent, :trigger_consensus)

      assert {:ok, _state} = Core.get_state(agent)

      refute_received {:DOWN, ^ref, :process, ^agent, _reason}
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_03
    test "consensus continuation succeeds and updates state", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, initial_state} = Core.get_state(agent)
      initial_counter = initial_state.action_counter

      ref = Process.monitor(agent)

      Core.handle_message(agent, "test message")

      {:ok, new_state} = Core.get_state(agent)

      refute_received {:DOWN, ^ref, :process, ^agent, _reason}
      assert new_state.action_counter > initial_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_04
    test "consensus continuation failure broadcasts error and continues gracefully", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      ref = Process.monitor(agent)

      capture_log(fn ->
        send(agent, :trigger_consensus)
      end)

      assert {:ok, _state} = Core.get_state(agent)

      refute_received {:DOWN, ^ref, :process, ^agent, _reason}
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_05
    test "action with wait: false triggers automatic consensus continuation", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      capture_log(fn ->
        Core.handle_agent_message(agent, "Test message")
      end)

      {:ok, state_after_first} = Core.get_state(agent)
      first_counter = state_after_first.action_counter

      ref = Process.monitor(agent)

      capture_log(fn ->
        Core.handle_message(agent, "continuation message")
      end)

      {:ok, state_after_second} = Core.get_state(agent)

      refute_received {:DOWN, ^ref, :process, ^agent, _reason}
      assert state_after_second.action_counter > first_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_06
    test "timed wait expiration triggers consensus continuation", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, initial_state} = Core.get_state(agent)
      initial_counter = initial_state.action_counter

      :sys.replace_state(agent, fn state ->
        Map.put(state, :wait_timer, {make_ref(), :timed_wait})
      end)

      ref = Process.monitor(agent)

      capture_log(fn ->
        send(agent, :trigger_consensus)
      end)

      {:ok, new_state} = Core.get_state(agent)

      refute_received {:DOWN, ^ref, :process, ^agent, _reason}
      assert new_state.action_counter > initial_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_07
    test "multiple sequential actions with wait: false process without crashing", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      ref = Process.monitor(agent)

      capture_log(fn ->
        Core.handle_agent_message(agent, "First action")
        Core.handle_agent_message(agent, "Second action")
        Core.handle_agent_message(agent, "Third action")
      end)

      {:ok, state} = Core.get_state(agent)

      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}

      first_history = state.model_histories |> Map.values() |> List.first([])
      assert first_history != [], "Messages should be in history after processing"
      Process.demonitor(ref, [:flush])
    end
  end

  # ============================================================================
  # MCP Client Lifecycle Tests (v14.0)
  # ============================================================================
  describe "MCP client lifecycle" do
    setup %{parent_pid: parent_pid, deps: deps, pubsub: pubsub, sandbox_owner: sandbox_owner} do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, "MCP test agent",
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, agent: agent, pubsub: pubsub}
    end

    @tag :arc_mcp_01
    test "R4: mcp_client defaults to nil", %{agent: agent} do
      {:ok, state} = Core.get_state(agent)

      assert Map.has_key?(state, :mcp_client)
      assert is_nil(state.mcp_client)
    end

    @tag :arc_mcp_01
    test "R1: stores MCP client reference in state", %{agent: agent} do
      {:ok, mcp_client_pid} = Agent.start_link(fn -> nil end)

      on_exit(fn ->
        if Process.alive?(mcp_client_pid), do: Agent.stop(mcp_client_pid, :normal, :infinity)
      end)

      GenServer.cast(agent, {:store_mcp_client, mcp_client_pid})

      {:ok, state} = Core.get_state(agent)

      assert state.mcp_client == mcp_client_pid
    end

    @tag :arc_mcp_02
    test "R2: mcp_client passed to Router in opts", %{agent: agent} do
      {:ok, mcp_client_pid} = MockMCPClient.start_link()

      on_exit(fn ->
        if Process.alive?(mcp_client_pid), do: GenServer.stop(mcp_client_pid, :normal, :infinity)
      end)

      GenServer.cast(agent, {:store_mcp_client, mcp_client_pid})

      {:ok, state} = Core.get_state(agent)
      assert state.mcp_client == mcp_client_pid

      action_map = %{action: :call_mcp, params: %{transport: "stdio", command: "test"}}

      result = GenServer.call(agent, {:process_action, action_map, "test-action-id"})

      refute match?({:error, :mcp_client}, result)
    end

    @tag :arc_mcp_03
    test "R3: MCP client stored in agent state for lifecycle management", %{
      parent_pid: parent_pid,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      {:ok, agent} =
        Core.start_link(
          {parent_pid, "MCP storage test",
           test_mode: true,
           sandbox_owner: sandbox_owner,
           registry: deps.registry,
           dynsup: deps.dynsup,
           pubsub: pubsub}
        )

      {:ok, mcp_client} = Agent.start_link(fn -> :running end)

      GenServer.cast(agent, {:store_mcp_client, mcp_client})

      {:ok, state} = Core.get_state(agent)
      assert state.mcp_client == mcp_client

      GenServer.stop(agent, :normal, :infinity)
      if Process.alive?(mcp_client), do: Agent.stop(mcp_client)
    end
  end

  # ============================================================================
  # Dismissing Flag Tests (v19.0)
  # ============================================================================
  describe "dismissing flag for race prevention" do
    setup %{parent_pid: parent_pid, deps: deps, pubsub: pubsub, sandbox_owner: sandbox_owner} do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, "Dismissing flag test agent",
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, agent: agent}
    end

    @tag :arc_dismiss_01
    test "R18: state initializes with dismissing: false", %{agent: agent} do
      {:ok, state} = Core.get_state(agent)

      assert Map.has_key?(state, :dismissing)
      assert state.dismissing == false
    end

    @tag :arc_dismiss_02
    test "R19: set_dismissing/2 updates flag to true", %{agent: agent} do
      assert :ok = Core.set_dismissing(agent, true)

      {:ok, state} = Core.get_state(agent)
      assert state.dismissing == true
    end

    @tag :arc_dismiss_03
    test "R20: set_dismissing/2 updates flag to false", %{agent: agent} do
      :ok = Core.set_dismissing(agent, true)
      {:ok, state1} = Core.get_state(agent)
      assert state1.dismissing == true

      assert :ok = Core.set_dismissing(agent, false)

      {:ok, state2} = Core.get_state(agent)
      assert state2.dismissing == false
    end

    @tag :arc_dismiss_04
    test "R21: dismissing?/1 returns current flag value", %{agent: agent} do
      assert Core.dismissing?(agent) == false

      :ok = Core.set_dismissing(agent, true)
      assert Core.dismissing?(agent) == true

      :ok = Core.set_dismissing(agent, false)
      assert Core.dismissing?(agent) == false
    end

    @tag :arc_dismiss_05
    test "R22: set_dismissing is idempotent", %{agent: agent} do
      assert :ok = Core.set_dismissing(agent, true)
      assert :ok = Core.set_dismissing(agent, true)
      assert :ok = Core.set_dismissing(agent, true)

      {:ok, state1} = Core.get_state(agent)
      assert state1.dismissing == true

      assert :ok = Core.set_dismissing(agent, false)
      assert :ok = Core.set_dismissing(agent, false)
      assert :ok = Core.set_dismissing(agent, false)

      {:ok, state2} = Core.get_state(agent)
      assert state2.dismissing == false
    end
  end
end
