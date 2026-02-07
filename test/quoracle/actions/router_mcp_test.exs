defmodule Quoracle.Actions.RouterMCPTest do
  @moduledoc """
  Integration tests for Router → MCP action pathway.

  Tests the 3-arity Router.execute/3 function which is used by
  ConsensusHandler in production. This pathway differs from direct
  MCP.execute/3 calls used in unit tests.

  Regression test for bug: mcp_client not passed through Router opts.
  """

  use ExUnit.Case, async: true

  import Hammox

  # Propagate mock permissions to Tasks spawned by Router via $callers
  setup :set_mox_from_context

  alias Quoracle.Agent.Core
  alias Quoracle.Actions.Router
  alias Quoracle.MCP.Client, as: MCPClient

  setup :verify_on_exit!

  setup do
    # Isolated test dependencies per project concurrency rules
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)

    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    {:ok, dynsup} = start_supervised(DynamicSupervisor)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup,
      capability_groups: [:local_execution]
    }
  end

  describe "Router 3-arity execute with call_mcp action" do
    @tag :regression
    test "mcp_client must be passed through opts to MCP action", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      capability_groups: capability_groups
    } do
      # Start agent with test mode
      {:ok, agent_pid} =
        Core.start_link(
          {nil, "MCP Router test",
           test_mode: true,
           skip_auto_consensus: true,
           sandbox_owner: sandbox_owner,
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub,
           capability_groups: capability_groups}
        )

      # Register cleanup
      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for agent to be ready
      :ok = GenServer.call(agent_pid, :wait_for_ready)

      # Create and store MCP client in agent state
      {:ok, mcp_client} =
        MCPClient.start_link(
          agent_id: "test-mcp-router-#{System.unique_integer([:positive])}",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          sandbox_owner: sandbox_owner
        )

      # Allow mock expectations for mcp_client process
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), mcp_client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(mcp_client) do
          try do
            GenServer.stop(mcp_client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Store mcp_client in agent state
      GenServer.cast(agent_pid, {:store_mcp_client, mcp_client})

      # Verify mcp_client is stored
      {:ok, state} = Core.get_state(agent_pid)
      assert state.mcp_client == mcp_client

      # Set up mock expectation for connect
      anubis_pid = spawn(fn -> receive do: (:never -> :ok) end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, [%{name: "test_tool", description: "A test tool", inputSchema: %{}}]}
      end)

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Per-action Router (v28.0): Spawn Router explicitly so we can allow mocks for it
      # Router.execute/3 spawns an internal Router that doesn't inherit $callers,
      # so we must spawn it ourselves and use Hammox.allow
      action_id = "test-action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :call_mcp,
          action_id: action_id,
          agent_id: state.agent_id,
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Allow router and its spawned Tasks to access the mock
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), router_pid)

      on_exit(fn ->
        if Process.alive?(router_pid) do
          try do
            GenServer.stop(router_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Build execute_opts with mcp_client and other deps
      execute_opts = [
        action_id: action_id,
        agent_id: state.agent_id,
        agent_pid: agent_pid,
        pubsub: pubsub,
        registry: registry,
        dynsup: dynsup,
        mcp_client: mcp_client,
        sandbox_owner: sandbox_owner,
        capability_groups: capability_groups
      ]

      params = %{"transport" => "stdio", "command" => "test-mcp-server"}

      # Call Router.execute/5 directly with explicit Router
      result = Router.execute(router_pid, :call_mcp, params, state.agent_id, execute_opts)

      # After fix: should succeed (sync or async) with connection info
      # Before fix: crashes with {:action_crashed, "key :mcp_client not found..."}
      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # Handle both success (action_completed) and error (action_error) broadcasts
      final_result =
        case result do
          {:async, _ref} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              10_000 -> flunk("No action completion/error message received within 10s")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              10_000 -> flunk("No action completion/error message received within 10s")
            end

          other ->
            other
        end

      assert {:ok, %{connection_id: conn_id, tools: tools}} = final_result
      assert is_binary(conn_id)
      assert length(tools) == 1
    end
  end

  describe "Router 5-arity execute via ConsensusHandler pathway" do
    @tag :regression
    test "mcp_client must be in execute_opts built by ConsensusHandler", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      capability_groups: capability_groups
    } do
      # This test exercises the PRODUCTION pathway:
      # ConsensusHandler.execute_action_async → Router.execute/5
      #
      # ConsensusHandler builds execute_opts and calls Router.execute/5 directly.
      # BUG: execute_opts was missing mcp_client, causing KeyError in MCP.execute.

      # Start agent with test mode
      {:ok, agent_pid} =
        Core.start_link(
          {nil, "MCP ConsensusHandler pathway test",
           test_mode: true,
           skip_auto_consensus: true,
           sandbox_owner: sandbox_owner,
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub,
           capability_groups: capability_groups}
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok = GenServer.call(agent_pid, :wait_for_ready)

      # Create and store MCP client in agent state
      {:ok, mcp_client} =
        MCPClient.start_link(
          agent_id: "test-mcp-consensus-#{System.unique_integer([:positive])}",
          agent_pid: agent_pid,
          anubis_module: Quoracle.MCP.AnubisMock,
          sandbox_owner: sandbox_owner
        )

      Hammox.allow(Quoracle.MCP.AnubisMock, self(), mcp_client)
      # Stub get_server_capabilities to simulate initialized MCP client
      stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)

      on_exit(fn ->
        if Process.alive?(mcp_client) do
          try do
            GenServer.stop(mcp_client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      GenServer.cast(agent_pid, {:store_mcp_client, mcp_client})

      # Get agent state to build execute_opts like ConsensusHandler does
      {:ok, state} = Core.get_state(agent_pid)
      assert state.mcp_client == mcp_client

      # Set up mock expectation for connect
      # Use global mode so Router's spawned Task can access mock

      anubis_pid = spawn(fn -> receive do: (:never -> :ok) end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn ^anubis_pid ->
        {:ok, [%{name: "browser_tool", description: "Browser automation", inputSchema: %{}}]}
      end)

      # Build execute_opts EXACTLY as ConsensusHandler does (consensus_handler.ex:300-309)
      # This is the production pathway that was missing mcp_client
      execute_opts = [
        action_id: "test-action-id",
        agent_id: state.agent_id,
        task_id: Map.get(state, :task_id) || state.agent_id,
        agent_pid: agent_pid,
        pubsub: Map.get(state, :pubsub),
        registry: Map.get(state, :registry),
        dynsup: Map.get(state, :dynsup),
        mcp_client: Map.get(state, :mcp_client),
        parent_config: state,
        sandbox_owner: sandbox_owner,
        capability_groups: capability_groups
      ]

      params = %{"transport" => "stdio", "command" => "test-mcp-server"}

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Spawn per-action Router (v28.0)
      {:ok, router_pid} =
        Router.start_link(
          action_type: :call_mcp,
          action_id: "test-action-id",
          agent_id: state.agent_id,
          agent_pid: agent_pid,
          pubsub: Map.get(state, :pubsub),
          sandbox_owner: sandbox_owner
        )

      # Allow router and its spawned Tasks to access the mock
      Hammox.allow(Quoracle.MCP.AnubisMock, self(), router_pid)

      # Call Router.execute/5 directly as ConsensusHandler does
      result = Router.execute(router_pid, :call_mcp, params, state.agent_id, execute_opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # Handle both success (action_completed) and error (action_error) broadcasts
      final_result =
        case result do
          {:async, _ref} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              10_000 -> flunk("No action completion/error message received within 10s")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              10_000 -> flunk("No action completion/error message received within 10s")
            end

          other ->
            other
        end

      # Before fix: {:error, {:action_crashed, "key :mcp_client not found..."}}
      # After fix: success with connection info
      assert {:ok, %{connection_id: conn_id, tools: tools}} = final_result
      assert is_binary(conn_id)
      assert length(tools) == 1
    end

    @tag :regression
    test "Router.execute/5 lazily creates MCP client when mcp_client is nil", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    } do
      # This test exercises lazy init through the 5-arity pathway:
      # ConsensusHandler builds execute_opts with mcp_client: nil → Router.execute/5 creates client
      #
      # BUG: Router.execute/5 didn't do lazy init, only Router.execute/3 did.
      # FIX: Added maybe_lazy_init_mcp_client/2 to Router.execute/5.
      #
      # NOTE: We don't mock anubis internals here - that's tested in client_test.exs.
      # We only verify that lazy init creates an MCP client (the behavior we care about).

      # Trap exits to prevent anubis supervisor crashes from killing the test
      Process.flag(:trap_exit, true)

      # Start agent WITHOUT pre-creating MCP client
      {:ok, agent_pid} =
        Core.start_link(
          {nil, "MCP 5-arity lazy init test",
           test_mode: true,
           skip_auto_consensus: true,
           sandbox_owner: sandbox_owner,
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub}
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok = GenServer.call(agent_pid, :wait_for_ready)

      # Verify mcp_client is nil (the bug condition)
      {:ok, state} = Core.get_state(agent_pid)
      assert is_nil(state.mcp_client), "mcp_client should be nil before call_mcp"

      # Build execute_opts like ConsensusHandler does, with nil mcp_client
      # Use real AnubisWrapper (no mock) - connection will fail but that's OK
      execute_opts = [
        action_id: "test-5arity-lazy-#{System.unique_integer([:positive])}",
        agent_id: state.agent_id,
        task_id: state.agent_id,
        agent_pid: agent_pid,
        pubsub: pubsub,
        registry: registry,
        dynsup: dynsup,
        mcp_client: nil,
        sandbox_owner: sandbox_owner
        # No anubis_module override - use real wrapper
      ]

      params = %{"transport" => "stdio", "command" => "echo hello"}

      # Spawn per-action Router (v28.0)
      action_id = "test-5arity-lazy-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :call_mcp,
          action_id: action_id,
          agent_id: state.agent_id,
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Call Router.execute/5 directly - before fix: {:noproc, {GenServer, :call, [nil, ...]}}
      # After fix: Creates MCP client, then fails to connect (expected - no real server)
      result = Router.execute(router_pid, :call_mcp, params, state.agent_id, execute_opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # For failure cases, receive either action_completed with error or action_error
      final_result =
        case result do
          {:async, _ref} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end

          other ->
            other
        end

      # The action will fail (no real MCP server), but that's fine - we're testing lazy init
      # Before fix: {:noproc, {GenServer, :call, [nil, ...]}} - crashed because mcp_client was nil
      # After fix: {:error, _} - fails gracefully because MCP client was created but server unavailable
      assert {:error, _reason} = final_result

      # KEY ASSERTION: Verify MCP client was created (lazy init worked!)
      {:ok, state_after} = Core.get_state(agent_pid)
      assert is_pid(state_after.mcp_client), "mcp_client should be created by lazy init"

      # Cleanup lazily-created MCP client
      on_exit(fn ->
        if is_pid(state_after.mcp_client) and Process.alive?(state_after.mcp_client) do
          try do
            GenServer.stop(state_after.mcp_client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end
  end

  describe "MCP client lazy initialization" do
    @tag :regression
    test "call_mcp auto-creates MCP client when state.mcp_client is nil", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    } do
      # This test exercises the lazy initialization pathway via Router.execute/3:
      # Agent spawns with mcp_client: nil → call_mcp action → Router creates client
      #
      # BUG: Router.execute/3 fetches nil mcp_client and passes it through,
      # causing {:noproc, {GenServer, :call, [nil, ...]}} crash.
      # FIX: Router should lazily initialize MCP client on first call_mcp action.
      #
      # NOTE: We don't mock anubis internals here - that's tested in client_test.exs.
      # We only verify that lazy init creates an MCP client (the behavior we care about).

      # Trap exits to prevent anubis supervisor crashes from killing the test
      Process.flag(:trap_exit, true)

      # Start agent WITHOUT pre-creating MCP client
      {:ok, agent_pid} =
        Core.start_link(
          {nil, "MCP lazy init test",
           test_mode: true,
           skip_auto_consensus: true,
           sandbox_owner: sandbox_owner,
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub}
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok = GenServer.call(agent_pid, :wait_for_ready)

      # Verify mcp_client is nil (the bug condition)
      {:ok, state} = Core.get_state(agent_pid)
      assert is_nil(state.mcp_client), "mcp_client should be nil before first call_mcp"

      # Build action_map for call_mcp - use real wrapper, connection will fail but that's OK
      action_map = %{
        action: :call_mcp,
        params: %{transport: :stdio, command: "echo hello"}
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        dynsup: dynsup,
        sandbox_owner: sandbox_owner
        # No anubis_module override - use real wrapper
      ]

      # Subscribe to action events for async result notification
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Execute - before fix: {:noproc, {GenServer, :call, [nil, ...]}}
      # After fix: Router lazily creates MCP client, then fails to connect (expected)
      result = Router.execute(action_map, agent_pid, opts)

      # Per-action Router (v28.0): await_result not supported, use PubSub for async results
      # For failure cases, receive either action_completed with error or action_error
      final_result =
        case result do
          {:async, _ref} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end

          {:async, _ref, _ack} ->
            receive do
              {:action_completed, %{result: async_result}} -> async_result
              {:action_error, %{error: error}} -> {:error, error}
            after
              5000 -> flunk("No action completion message received")
            end

          other ->
            other
        end

      # The action will fail (no real MCP server), but that's fine - we're testing lazy init
      # Before fix: {:noproc, {GenServer, :call, [nil, ...]}} - crashed because mcp_client was nil
      # After fix: {:error, _} - fails gracefully because MCP client was created but server unavailable
      assert {:error, _reason} = final_result

      # KEY ASSERTION: Verify MCP client was created (lazy init worked!)
      {:ok, state_after} = Core.get_state(agent_pid)
      assert is_pid(state_after.mcp_client), "mcp_client should be created by lazy init"

      # Cleanup lazily-created MCP client to prevent DB connection leaks
      on_exit(fn ->
        if is_pid(state_after.mcp_client) and Process.alive?(state_after.mcp_client) do
          try do
            GenServer.stop(state_after.mcp_client, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)
    end
  end
end
