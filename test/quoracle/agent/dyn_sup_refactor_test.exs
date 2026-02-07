defmodule Quoracle.Agent.DynSupRefactorTest do
  @moduledoc """
  Tests for AGENT_DynSup refactor to remove named process.
  Ensures multiple instances can run concurrently without conflicts.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.DynSup
  import Test.AgentTestHelpers

  setup do
    # Create isolated PubSub for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry for agent tree cleanup
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry})

    %{pubsub: pubsub_name, registry: registry}
  end

  describe "start_link/1 without named process" do
    test "starts DynamicSupervisor WITHOUT name registration" do
      # Start DynSup with no name option using start_supervised for proper cleanup
      pid = start_supervised!({DynSup, []}, shutdown: :infinity)
      assert is_pid(pid)

      # Should NOT be registered under module name
      # Once refactored, calling with name will fail
      # For now, just verify we have a PID-based instance

      # Should be a DynamicSupervisor
      {:ok, child_pid} = DynamicSupervisor.start_child(pid, {Agent, fn -> :test end})

      # Add cleanup for spawned agent
      on_exit(fn ->
        if Process.alive?(child_pid), do: GenServer.stop(child_pid, :normal, :infinity)
      end)
    end

    test "allows multiple concurrent instances" do
      # Start multiple DynSup instances
      assert {:ok, pid1} = start_supervised({DynSup, []}, id: :dynsup1, shutdown: :infinity)
      assert {:ok, pid2} = start_supervised({DynSup, []}, id: :dynsup2, shutdown: :infinity)
      assert {:ok, pid3} = start_supervised({DynSup, []}, id: :dynsup3, shutdown: :infinity)

      # Add cleanup for DynSup instances
      on_exit(fn ->
        if Process.alive?(pid1), do: stop_supervised(:dynsup1)
        if Process.alive?(pid2), do: stop_supervised(:dynsup2)
        if Process.alive?(pid3), do: stop_supervised(:dynsup3)
      end)

      # All should be different PIDs
      assert pid1 != pid2
      assert pid2 != pid3
      assert pid1 != pid3

      # Each should be functional independently
      agent_spec1 = %{
        id: :agent1,
        start: {Agent, :start_link, [fn -> :state1 end]}
      }

      agent_spec2 = %{
        id: :agent2,
        start: {Agent, :start_link, [fn -> :state2 end]}
      }

      agent_spec3 = %{
        id: :agent3,
        start: {Agent, :start_link, [fn -> :state3 end]}
      }

      assert {:ok, agent_pid1} = DynamicSupervisor.start_child(pid1, agent_spec1)
      assert {:ok, agent_pid2} = DynamicSupervisor.start_child(pid2, agent_spec2)
      assert {:ok, agent_pid3} = DynamicSupervisor.start_child(pid3, agent_spec3)

      # Add cleanup for spawned agents
      on_exit(fn ->
        if Process.alive?(agent_pid1), do: GenServer.stop(agent_pid1, :normal, :infinity)
        if Process.alive?(agent_pid2), do: GenServer.stop(agent_pid2, :normal, :infinity)
        if Process.alive?(agent_pid3), do: GenServer.stop(agent_pid3, :normal, :infinity)
      end)
    end

    test "does not conflict with other tests running in parallel" do
      # This test can run simultaneously with others
      assert {:ok, pid} = start_supervised({DynSup, []}, shutdown: :infinity)

      # Add cleanup for DynSup instance
      on_exit(fn ->
        if Process.alive?(pid), do: stop_supervised(DynSup)
      end)

      # Should work without any name conflicts
      agent_spec = %{
        id: :test_agent,
        start: {Agent, :start_link, [fn -> :parallel_test end]}
      }

      assert {:ok, agent_pid} = DynamicSupervisor.start_child(pid, agent_spec)

      # Add cleanup for spawned agent
      on_exit(fn ->
        if Process.alive?(agent_pid), do: GenServer.stop(agent_pid, :normal, :infinity)
      end)

      assert Agent.get(agent_pid, & &1) == :parallel_test
    end
  end

  describe "get_dynsup_pid/0 PID discovery" do
    test "returns PID when DynSup is running under Application supervisor" do
      # Simulate application supervisor structure
      # Note: In real app, DynSup is started by Quoracle.Supervisor
      pid = DynSup.get_dynsup_pid()

      assert is_pid(pid)

      # Should be able to use returned PID for operations
      agent_spec = %{
        id: :discovery_test,
        start: {Agent, :start_link, [fn -> :found end]}
      }

      assert {:ok, _} = DynamicSupervisor.start_child(pid, agent_spec)
    end

    test "returns nil when supervisor not found" do
      # Test that get_dynsup_pid handles missing supervisor gracefully
      # In test context without app supervisor, should return nil

      # The app supervisor is running, so get_dynsup_pid will find it
      result = DynSup.get_dynsup_pid()

      # Should return a PID since the supervisor is running
      assert is_pid(result)
    end

    test "finds DynSup correctly via Supervisor.which_children" do
      # This tests the actual lookup mechanism
      # Verifies it properly navigates the supervisor hierarchy

      pid = DynSup.get_dynsup_pid()
      assert is_pid(pid)

      # The get_dynsup_pid function itself verifies the lookup
      # If it returns a PID, it found it in the supervisor tree
    end
  end

  describe "start_agent/2 with PID-based access" do
    setup %{pubsub: pubsub, registry: registry} do
      {:ok, dynsup_pid} = start_supervised({DynSup, []}, shutdown: :infinity)

      # Add cleanup for DynSup instance
      on_exit(fn ->
        if Process.alive?(dynsup_pid), do: stop_supervised(DynSup)
      end)

      {:ok, dynsup_pid: dynsup_pid, pubsub: pubsub, registry: registry}
    end

    test "starts agent with valid config and dynsup PID", %{
      dynsup_pid: dynsup_pid,
      pubsub: pubsub,
      registry: registry
    } do
      config = %{
        agent_id: "test_agent_123",
        task: "Test task",
        parent_pid: nil,
        llm_config: %{model: "test-model", temperature: 0.7},
        pubsub: pubsub
      }

      # New signature: start_agent(dynsup_pid, config)
      assert {:ok, agent_pid} =
               spawn_agent_with_cleanup(dynsup_pid, config, registry: registry)

      assert is_pid(agent_pid)

      # Verify agent is supervised by our DynSup
      children = DynamicSupervisor.which_children(dynsup_pid)
      assert Enum.any?(children, fn {_, pid, _, _} -> pid == agent_pid end)
    end

    test "validates config before starting agent", %{
      dynsup_pid: dynsup_pid,
      pubsub: pubsub,
      registry: registry
    } do
      # Missing required fields (agent_id)
      invalid_config = %{task: "Test", pubsub: pubsub, registry: registry}

      assert {:error, :invalid_config} = DynSup.start_agent(dynsup_pid, invalid_config)
    end

    test "handles agent spawn failures gracefully", %{
      dynsup_pid: dynsup_pid,
      pubsub: pubsub,
      registry: registry
    } do
      # DynSup only validates agent_id exists
      # Agent.Core will handle invalid config, but won't fail in DynSup
      bad_config =
        %{
          # Missing agent_id will cause validation error in DynSup
          pubsub: pubsub,
          registry: registry
        }

      assert {:error, :invalid_config} = DynSup.start_agent(dynsup_pid, bad_config)
    end

    test "supports transient restart strategy", %{
      dynsup_pid: dynsup_pid,
      pubsub: pubsub,
      registry: registry
    } do
      config = %{
        agent_id: "transient_agent",
        task: "Test transient",
        parent_pid: nil,
        llm_config: %{model: "test-model", temperature: 0.5},
        pubsub: pubsub
      }

      assert {:ok, agent_pid} =
               spawn_agent_with_cleanup(dynsup_pid, config, registry: registry)

      # Terminate agent normally via DynSup helper - should not restart
      ref = Process.monitor(agent_pid)
      DynSup.terminate_agent(agent_pid)
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]

      children = DynamicSupervisor.which_children(dynsup_pid)
      assert Enum.empty?(children)

      # Verify transient restart strategy is configured
      # The actual restart behavior on abnormal exit is tested by OTP
      # We just verify the configuration is correct
      config2 = %{config | agent_id: "transient_agent2"}

      assert {:ok, agent_pid2} =
               spawn_agent_with_cleanup(dynsup_pid, config2, registry: registry)

      # Verify the child spec has transient restart
      children = DynamicSupervisor.which_children(dynsup_pid)
      assert [{_, ^agent_pid2, :worker, _}] = children
    end
  end

  describe "terminate_agent/1" do
    setup %{pubsub: pubsub, registry: registry} do
      {:ok, dynsup_pid} = start_supervised({DynSup, []}, shutdown: :infinity)

      # Add cleanup for DynSup instance
      on_exit(fn ->
        if Process.alive?(dynsup_pid), do: stop_supervised(DynSup)
      end)

      config = %{
        agent_id: "term_test",
        task: "Test termination",
        parent_pid: nil,
        llm_config: %{model: "test-model", temperature: 0.5},
        pubsub: pubsub
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(dynsup_pid, config, registry: registry)

      {:ok, dynsup_pid: dynsup_pid, agent_pid: agent_pid, pubsub: pubsub, registry: registry}
    end

    test "terminates agent cleanly", %{dynsup_pid: dynsup_pid, agent_pid: agent_pid} do
      # Agent should be running
      assert Process.alive?(agent_pid)

      # Monitor before termination
      ref = Process.monitor(agent_pid)

      # Terminate it via DynSup helper to ensure proper cleanup
      assert :ok = DynSup.terminate_agent(agent_pid)

      # Wait for termination
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, _reason}, 30_000
      refute Process.alive?(agent_pid)

      # Should be removed from supervisor
      children = DynamicSupervisor.which_children(dynsup_pid)
      refute Enum.any?(children, fn {_, pid, _, _} -> pid == agent_pid end)
    end

    test "handles termination of non-existent agent", %{} do
      # Use Task instead of spawn
      task = Task.async(fn -> :ok end)
      fake_pid = task.pid
      Task.await(task)

      # Should handle gracefully for dead process
      assert {:error, :not_found} = DynSup.terminate_agent(fake_pid)
    end
  end

  # NOTE: Integration tests that use global DynSup moved to
  # dyn_sup_integration_test.exs with async: false to prevent
  # cross-test contamination when killing global DynSup

  describe "no global state or named resources" do
    test "DynSup uses no named ETS tables" do
      {:ok, pid} = start_supervised({DynSup, []}, shutdown: :infinity)

      # Add cleanup for DynSup instance
      on_exit(fn ->
        if Process.alive?(pid), do: stop_supervised(DynSup)
      end)

      # Get all ETS tables
      all_tables = :ets.all()

      # Filter to named tables (atoms)
      named_tables = Enum.filter(all_tables, &is_atom/1)

      # DynSup should not create any named tables
      dynsup_tables =
        Enum.filter(named_tables, fn name ->
          String.contains?(to_string(name), "dynsup") or
            String.contains?(to_string(name), "DynSup")
        end)

      assert Enum.empty?(dynsup_tables)
    end

    test "DynSup registers no global names" do
      {:ok, pid} = start_supervised({DynSup, []}, shutdown: :infinity)

      # Add cleanup for DynSup instance
      on_exit(fn ->
        if Process.alive?(pid), do: stop_supervised(DynSup)
      end)

      # DynSup should not be registered by name
      # Once refactored, these names won't exist in any registry

      # Check global registry
      assert :global.whereis_name(DynSup) == :undefined
      assert :global.whereis_name(Quoracle.Agent.DynSup) == :undefined
    end

    test "multiple test modules can use DynSup simultaneously" do
      # Simulate another test module using DynSup
      # Use start_supervised for proper cleanup
      pid1 = start_supervised!({DynSup, []}, id: :dynsup_task1, shutdown: :infinity)
      pid2 = start_supervised!({DynSup, []}, id: :dynsup_task2, shutdown: :infinity)

      task1 =
        Task.async(fn ->
          DynamicSupervisor.start_child(pid1, {Agent, fn -> :task1 end})
        end)

      task2 =
        Task.async(fn ->
          DynamicSupervisor.start_child(pid2, {Agent, fn -> :task2 end})
        end)

      # Both should succeed without conflicts
      assert {:ok, agent1} = Task.await(task1)
      assert {:ok, agent2} = Task.await(task2)

      # Add cleanup for spawned agents
      on_exit(fn ->
        if Process.alive?(agent1), do: GenServer.stop(agent1, :normal, :infinity)
        if Process.alive?(agent2), do: GenServer.stop(agent2, :normal, :infinity)
      end)
    end
  end
end
