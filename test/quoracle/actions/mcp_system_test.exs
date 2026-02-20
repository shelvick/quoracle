defmodule Quoracle.Actions.MCPSystemTest do
  @moduledoc """
  System-level tests for MCP action through the real agent ActionExecutor path.

  WorkGroupID: fix-20260219-mcp-reliability
  Audit gap: R38 (MCP_Client), R14 (ACTION_MCP), Retry Acceptance

  These tests exercise the FULL agent path:
    ActionExecutor -> Task.Supervisor -> Router -> Actions.MCP -> MCP.Client

  Unlike unit/integration tests that call Actions.MCP.execute directly,
  these go through ActionExecutor via {:dispatch_with_crash, action, params, :none}.
  """

  use Quoracle.DataCase, async: true

  import Hammox
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.MCP.Client, as: MCPClient

  @moduletag capture_log: true

  setup :verify_on_exit!

  setup %{sandbox_owner: sandbox_owner} do
    deps = Test.IsolationHelpers.create_isolated_deps()

    %{deps: deps, sandbox_owner: sandbox_owner}
  end

  # Helper: spawn a test agent with MCP capabilities
  defp spawn_mcp_agent(deps, sandbox_owner) do
    config = %{
      agent_id: "mcp-sys-#{System.unique_integer([:positive])}",
      task_id: Ecto.UUID.generate(),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: nil,
      prompt_fields: %{
        provided: %{task_description: "MCP system test"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: [],
      capability_groups: [:hierarchy, :local_execution]
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: sandbox_owner
    )
  end

  # Helper: set up MCP client with mock for an agent
  defp setup_mcp_client(agent_pid, sandbox_owner) do
    {:ok, state} = Core.get_state(agent_pid)

    {:ok, mcp_client} =
      MCPClient.start_link(
        agent_id: state.agent_id,
        agent_pid: agent_pid,
        anubis_module: Quoracle.MCP.AnubisMock,
        sandbox_owner: sandbox_owner
      )

    Hammox.allow(Quoracle.MCP.AnubisMock, self(), mcp_client)
    stub(Quoracle.MCP.AnubisMock, :get_server_capabilities, fn _pid -> %{} end)
    stub(Quoracle.MCP.AnubisMock, :stop, fn _pid -> :ok end)

    GenServer.cast(agent_pid, {:store_mcp_client, mcp_client})
    # Sync to ensure stored
    {:ok, updated} = Core.get_state(agent_pid)
    assert updated.mcp_client == mcp_client

    on_exit(fn ->
      if Process.alive?(mcp_client) do
        try do
          GenServer.stop(mcp_client, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    mcp_client
  end

  # Helper: create a process that blocks forever (mock PID target)
  defp blocking_process do
    pid = spawn_link(fn -> receive do: (:never -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Helper: poll agent state until condition met or timeout
  defp wait_for_condition(agent_pid, condition_fn, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(agent_pid, condition_fn, deadline)
  end

  defp do_poll(agent_pid, condition_fn, deadline) do
    {:ok, state} = Core.get_state(agent_pid)

    if condition_fn.(state) do
      {:ok, state}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:timeout, state}
      else
        :erlang.yield()
        do_poll(agent_pid, condition_fn, deadline)
      end
    end
  end

  # Helper: find first :result entry in model_histories
  defp find_result_entry(state, matcher) do
    state.model_histories
    |> Map.values()
    |> List.flatten()
    |> Enum.find(fn entry ->
      entry.type == :result and matcher.(entry.result)
    end)
  end

  # Helper: check if any :result entry matches
  defp has_result?(state, matcher) do
    find_result_entry(state, matcher) != nil
  end

  # Helper: format history types for debug messages
  defp history_types(state) do
    state.model_histories
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&Map.get(&1, :type, :unknown))
  end

  # ============================================================================
  # R14: Full consensus path for agent MCP usage
  # [SYSTEM] Agent dispatches call_mcp via ActionExecutor, result in history
  # ============================================================================

  describe "R14: full consensus MCP path" do
    @tag :system
    test "call_mcp via ActionExecutor stores result",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_mcp_agent(deps, sandbox_owner)
      mcp_client = setup_mcp_client(agent_pid, sandbox_owner)

      # Connect to MCP server (prerequisite)
      anubis_pid = blocking_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok,
         [
           %{name: "read_file", description: "Read a file"},
           %{name: "write_file", description: "Write a file"}
         ]}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCPClient.connect(mcp_client, %{
          transport: :stdio,
          command: "echo test-mcp-server"
        })

      # Dispatch tool call through ActionExecutor
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid,
                                                     "read_file",
                                                     %{path: "/test.txt"},
                                                     _opts ->
        {:ok, %{content: [%{type: "text", text: "MCP result"}]}}
      end)

      GenServer.cast(
        agent_pid,
        {:dispatch_with_crash, :call_mcp,
         %{
           connection_id: conn_id,
           tool: "read_file",
           arguments: %{path: "/test.txt"}
         }, :none}
      )

      # Wait for success result in history
      {poll_result, final_state} =
        wait_for_condition(agent_pid, fn state ->
          has_result?(state, &match?({:ok, _}, &1))
        end)

      assert poll_result == :ok,
             "Result not in history. " <>
               "Pending: #{map_size(final_state.pending_actions)}, " <>
               "Types: #{inspect(history_types(final_state))}"

      # Verify pending_actions cleared
      assert map_size(final_state.pending_actions) == 0

      # Verify action field in result (consistent with other actions)
      entry = find_result_entry(final_state, &match?({:ok, _}, &1))
      {:ok, ok_result} = entry.result
      assert Map.get(ok_result, :action) == "call_mcp"
    end
  end

  # ============================================================================
  # R38: Agent resilience when MCP connection dies
  # [SYSTEM] Agent gets error result (not hang), clears pending, continues
  # ============================================================================

  describe "R38: MCP connection death resilience" do
    @tag :system
    test "error delivered and agent continues",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_mcp_agent(deps, sandbox_owner)
      mcp_client = setup_mcp_client(agent_pid, sandbox_owner)

      # Connect to MCP server
      anubis_pid = blocking_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "read_file", description: "Read a file"}]}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCPClient.connect(mcp_client, %{
          transport: :stdio,
          command: "echo test-server"
        })

      # call_tool exits (connection death), reconnect fails
      expect(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, "read_file", _args, _opts ->
        exit(:connection_dead)
      end)

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:error, :server_unavailable}
      end)

      # Dispatch through ActionExecutor
      GenServer.cast(
        agent_pid,
        {:dispatch_with_crash, :call_mcp,
         %{
           connection_id: conn_id,
           tool: "read_file",
           arguments: %{path: "/test.txt"}
         }, :none}
      )

      # Wait for error result in history
      {poll_result, final_state} =
        wait_for_condition(agent_pid, fn state ->
          has_result?(state, &match?({:error, _}, &1))
        end)

      assert poll_result == :ok,
             "Error not in history. " <>
               "Pending: #{map_size(final_state.pending_actions)}, " <>
               "Types: #{inspect(history_types(final_state))}"

      # Verify pending_actions cleared (not stalled)
      assert map_size(final_state.pending_actions) == 0

      # Verify error result wraps with action field (consistency)
      # Error results should be {:error, %{action: "call_mcp", ...}}
      # for consistent error reporting to the LLM, matching
      # how other actions (orient, shell, etc.) include action field
      entry = find_result_entry(final_state, &match?({:error, _}, &1))
      {:error, err_result} = entry.result
      assert is_map(err_result), "Error result should be a map, got: #{inspect(err_result)}"
      assert Map.get(err_result, :action) == "call_mcp"

      # Verify agent can still process messages
      GenServer.cast(
        agent_pid,
        {:send_user_message, "Still alive?"}
      )

      {msg_result, _} =
        wait_for_condition(agent_pid, fn state ->
          state.model_histories
          |> Map.values()
          |> List.flatten()
          |> Enum.any?(fn entry ->
            case entry do
              %{
                type: :event,
                content: %{from: "user", content: c}
              }
              when is_binary(c) ->
                c =~ "Still alive?"

              _ ->
                false
            end
          end)
        end)

      assert msg_result == :ok,
             "Agent stalled after MCP connection death"
    end
  end

  # ============================================================================
  # Retry acceptance: agent retries MCP call after reconnect
  # [SYSTEM] Connection dies, reconnect succeeds, retry succeeds
  # ============================================================================

  describe "retry acceptance: MCP reconnect" do
    @tag :system
    @tag :acceptance
    test "agent retries after death and reconnect",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_mcp_agent(deps, sandbox_owner)
      mcp_client = setup_mcp_client(agent_pid, sandbox_owner)

      # Connect to MCP server
      anubis_pid = blocking_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "read_file", description: "Read a file"}]}
      end)

      {:ok, %{connection_id: conn_id}} =
        MCPClient.connect(mcp_client, %{
          transport: :stdio,
          command: "echo test-retry-server"
        })

      # First call_tool exits (connection death), then retry succeeds
      call_count = :counters.new(1, [:atomics])

      stub(Quoracle.MCP.AnubisMock, :call_tool, fn _pid, _tool, _args, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          exit(:connection_dead)
        else
          {:ok,
           %{
             content: [
               %{type: "text", text: "Success after retry!"}
             ]
           }}
        end
      end)

      # Reconnect succeeds with new anubis pid
      new_anubis_pid = blocking_process()

      expect(Quoracle.MCP.AnubisMock, :start_link, fn _opts ->
        {:ok, new_anubis_pid}
      end)

      expect(Quoracle.MCP.AnubisMock, :list_tools, fn _pid ->
        {:ok, [%{name: "read_file", description: "Read"}]}
      end)

      # Dispatch through ActionExecutor
      # Note: retry delay (500ms) uses real Process.sleep
      # since delay_fn can't be injected through dispatch path
      GenServer.cast(
        agent_pid,
        {:dispatch_with_crash, :call_mcp,
         %{
           connection_id: conn_id,
           tool: "read_file",
           arguments: %{path: "/retry-test.txt"}
         }, :none}
      )

      # Wait for SUCCESS result (retry is transparent)
      {poll_result, final_state} =
        wait_for_condition(
          agent_pid,
          fn state ->
            has_result?(state, &match?({:ok, _}, &1))
          end,
          15_000
        )

      assert poll_result == :ok,
             "Retry result not in history. " <>
               "Pending: #{map_size(final_state.pending_actions)}, " <>
               "Types: #{inspect(history_types(final_state))}"

      # Verify success with action field
      entry = find_result_entry(final_state, &match?({:ok, _}, &1))
      {:ok, ok_result} = entry.result
      assert Map.get(ok_result, :action) == "call_mcp"

      # call_tool called at least twice (initial + retry)
      assert :counters.get(call_count, 1) >= 2

      # Pending actions cleared
      assert map_size(final_state.pending_actions) == 0
    end
  end
end
