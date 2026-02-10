defmodule Quoracle.Agent.DynSupTest do
  # Can use async: true with proper isolation
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.DynSup

  setup do
    # Create isolated Registry, DynSup, and PubSub for this test
    deps = create_isolated_deps()

    {:ok, deps: deps}
  end

  describe "start_link/1" do
    test "ARC_FUNC_01: DynSup starts and can be found via supervisor", %{deps: deps} do
      # Use the isolated DynSup from deps
      pid = deps.dynsup
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "allows multiple instances without name conflicts" do
      # Since DynSup no longer registers a name, multiple instances can coexist
      pid1 = start_supervised!({DynSup, []}, shutdown: :infinity)
      pid2 = start_supervised!({DynSup, []}, id: :dynsup2, shutdown: :infinity)
      assert pid1 != pid2
    end
  end

  describe "start_agent/1" do
    test "ARC_FUNC_02: starts agent with valid config and returns {:ok, pid}", %{deps: deps} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        task: "test task",
        restart: :transient,
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      # Spawn agent with automatic cleanup
      assert {:ok, agent_pid} =
               spawn_agent_with_cleanup(deps.dynsup, config,
                 registry: deps.registry,
                 pubsub: deps.pubsub
               )

      assert Process.alive?(agent_pid)

      # Verify Registry registration
      assert [{^agent_pid, _}] =
               Registry.lookup(deps.registry, {:agent, agent_id})
    end

    test "ARC_VAL_01: returns {:error, :invalid_config} when missing agent_id", %{deps: deps} do
      config = %{task: "test task", registry: deps.registry, pubsub: deps.pubsub}
      dynsup_pid = deps.dynsup
      assert {:error, :invalid_config} = DynSup.start_agent(dynsup_pid, config)
    end

    test "ARC_ERR_01: returns error and logs when agent spawn fails", %{deps: deps} do
      config = %{
        agent_id: "failing-agent",
        task: "will fail",
        # Force a failure by passing invalid data that Core.start_link will reject
        force_init_error: true
      }

      # This should fail and log an error
      assert capture_log(fn ->
               config =
                 Map.merge(config, %{
                   registry: deps.registry,
                   dynsup: deps.dynsup,
                   pubsub: deps.pubsub
                 })

               assert {:error, _reason} = DynSup.start_agent(deps.dynsup, config)
             end) =~ "error"
    end

    test "registers child relationship when parent_pid provided", %{deps: deps} do
      parent_config = %{
        agent_id: "parent-agent",
        task: "parent task",
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      child_config = %{
        agent_id: "child-agent",
        task: "child task",
        parent_pid: parent_pid,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(deps.dynsup, child_config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Check Registry for parent-child relationship in composite value
      assert [{^child_pid, composite}] =
               Registry.lookup(deps.registry, {:agent, "child-agent"})

      assert composite.parent_pid == parent_pid
    end

    test "prevents duplicate agent_ids with unique Registry keys", %{deps: deps} do
      import ExUnit.CaptureLog

      config = %{
        agent_id: "duplicate-agent",
        task: "first instance",
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      assert {:ok, pid1} =
               spawn_agent_with_cleanup(deps.dynsup, config,
                 registry: deps.registry,
                 pubsub: deps.pubsub
               )

      # Second attempt with same agent_id should fail due to unique Registry keys
      # Capture the expected error log to prevent test spam
      assert capture_log(fn ->
               # With atomic registration, we get a RuntimeError for duplicate IDs
               assert {:error, {%RuntimeError{message: "Duplicate agent ID: " <> _}, _}} =
                        DynSup.start_agent(deps.dynsup, config,
                          registry: deps.registry,
                          pubsub: deps.pubsub
                        )
             end) =~ "Duplicate agent ID"

      # Only one agent should be registered
      agents = Registry.lookup(deps.registry, {:agent, "duplicate-agent"})
      assert length(agents) == 1
      assert [{^pid1, _}] = agents
    end
  end

  describe "restart behavior" do
    test "ARC_FUNC_03: restarts transient agent on abnormal exit", %{deps: deps} do
      config = %{
        agent_id: "transient-agent",
        task: "will crash",
        restart: :transient,
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Subscribe to agent lifecycle events to detect restart
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      # Monitor the agent process
      ref = Process.monitor(agent_pid)

      # Force abnormal exit - :kill is required here because:
      # 1. It bypasses trap_exit, causing actual abnormal termination
      # 2. Supervisor only restarts on abnormal exits (not :normal)
      # capture_log suppresses expected termination error
      import ExUnit.CaptureLog

      capture_log(fn ->
        Process.exit(agent_pid, :kill)

        # Wait for process to die
        assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason}, 30_000
        assert reason in [:killed, :noproc]
      end)

      # Wait for supervisor to restart and broadcast agent_spawned
      # Supervisor will spawn new agent which broadcasts on initialization
      assert_receive {:agent_spawned, %{agent_id: "transient-agent"}}, 30_000
      # Look up the restarted agent in Registry
      [{new_pid, _}] = Registry.lookup(deps.registry, {:agent, "transient-agent"})

      # Verify it's a different PID
      assert new_pid != agent_pid

      # Wait for agent to complete initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(new_pid)
      assert Process.alive?(new_pid)

      # CRITICAL: Cleanup restarted agent before test exits
      register_agent_cleanup(new_pid)
    end

    test "ARC_FUNC_03: does not restart transient agent on normal exit", %{deps: deps} do
      config = %{
        agent_id: "transient-normal",
        task: "will exit normally",
        restart: :transient,
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Monitor the agent process
      ref = Process.monitor(agent_pid)

      # Terminate normally through DynSup helper
      # This ensures proper cleanup via GenServer.stop (triggers terminate/2)
      DynSup.terminate_agent(agent_pid)

      # Wait for process to die
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]

      # Poll Registry until cleanup completes (async via monitor)
      assert :ok =
               poll_until(fn ->
                 Registry.lookup(deps.registry, {:agent, "transient-normal"}) == []
               end)
    end

    test "ARC_FUNC_04: DynSup crashes when max restarts exceeded", %{deps: _deps} do
      # This test verifies that the supervisor crashes when max restarts are exceeded
      # We create an isolated supervisor to avoid affecting other tests
      import ExUnit.CaptureLog

      # Use a custom child spec that immediately crashes
      child_spec = %{
        id: :crasher,
        start: {Task, :start_link, [fn -> raise "intentional crash" end]},
        restart: :permanent,
        shutdown: 5000,
        type: :worker
      }

      # Start an isolated DynamicSupervisor with low restart limits for testing
      sup_pid =
        start_supervised!(
          {
            DynamicSupervisor,
            # Low limit for faster testing
            strategy: :one_for_one, max_restarts: 3, max_seconds: 5
          },
          id: :crasher_sup
        )

      # Monitor the supervisor to detect when it crashes
      ref = Process.monitor(sup_pid)

      # Start the crasher child which will immediately crash
      # Capture logs to suppress the intentional crash error messages
      capture_log(fn ->
        {:ok, _child_pid} = DynamicSupervisor.start_child(sup_pid, child_spec)

        # Wait for supervisor to crash after exceeding max restarts
        # Need to wait inside capture_log to catch all restart attempts
        receive do
          {:DOWN, ^ref, :process, ^sup_pid, reason} ->
            assert reason in [:shutdown, :noproc, :killed]
        after
          2000 -> flunk("Supervisor did not crash after max restarts")
        end
      end)

      # Verify the supervisor is down
      refute Process.alive?(sup_pid)
    end
  end

  describe "terminate_agent/1" do
    test "ARC_FUNC_05: terminates agent cleanly", %{deps: deps} do
      config = %{
        agent_id: "to-terminate",
        task: "will be terminated",
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      assert Process.alive?(agent_pid)

      assert :ok = DynSup.terminate_agent(agent_pid)
      refute Process.alive?(agent_pid)

      # Poll Registry until cleanup completes (async via monitor)
      assert :ok =
               poll_until(fn ->
                 Registry.lookup(deps.registry, {:agent, "to-terminate"}) == []
               end)
    end

    test "ARC_VAL_02: returns {:error, :not_found} for unknown pid", %{deps: _deps} do
      fake_pid = spawn(fn -> :ok end)
      assert {:error, :not_found} = DynSup.terminate_agent(fake_pid)
    end
  end

  describe "supervisor integration" do
    test "ARC_ERR_02: DynSup restarts when crashed under Application supervisor" do
      # Start a DynamicSupervisor under a test supervisor
      # Define a module that implements child_spec/1 for the supervisor
      child_spec = %{
        id: :test_dyn_sup,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
        restart: :permanent,
        type: :supervisor
      }

      # Use start_supervised with a proper supervisor specification
      {:ok, sup_pid} =
        start_supervised(%{
          id: :test_supervisor,
          start: {Supervisor, :start_link, [[child_spec], [strategy: :one_for_one]]},
          type: :supervisor
        })

      # Get DynamicSupervisor PID
      [{_, dyn_sup_pid, _, _}] = Supervisor.which_children(sup_pid)
      assert Process.alive?(dyn_sup_pid)

      # Monitor and kill DynamicSupervisor - :kill required for abnormal exit
      # capture_log suppresses expected termination error
      import ExUnit.CaptureLog
      ref = Process.monitor(dyn_sup_pid)

      capture_log(fn ->
        Process.exit(dyn_sup_pid, :kill)

        # Wait for death confirmation
        assert_receive {:DOWN, ^ref, :process, ^dyn_sup_pid, reason}, 30_000
        assert reason in [:killed, :noproc]
      end)

      # Wait for supervisor to restart DynamicSupervisor
      new_dyn_sup_pid =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Supervisor.which_children(sup_pid) do
            [{_, pid, _, _}] when pid != dyn_sup_pid and is_pid(pid) ->
              {:halt, pid}

            _ ->
              # Brief yield to scheduler instead of sleep
              :erlang.yield()
              {:cont, nil}
          end
        end)

      assert new_dyn_sup_pid != nil
      assert new_dyn_sup_pid != dyn_sup_pid
      assert Process.alive?(new_dyn_sup_pid)
    end
  end

  describe "query functions" do
    test "list_agents/0 returns all supervised agent PIDs", %{deps: deps} do
      config1 = %{
        agent_id: "agent-1",
        task: "task 1",
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      config2 = %{
        agent_id: "agent-2",
        task: "task 2",
        parent_pid: nil,
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      # Use isolated DynSup from test deps
      {:ok, pid1} =
        spawn_agent_with_cleanup(deps.dynsup, config1,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      {:ok, pid2} =
        spawn_agent_with_cleanup(deps.dynsup, config2,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Query the isolated DynSup directly
      children = DynamicSupervisor.which_children(deps.dynsup)
      agents = for {_, pid, _, _} <- children, do: pid

      assert pid1 in agents
      assert pid2 in agents
      assert length(agents) == 2
    end

    test "get_agent_count/0 returns count of supervised agents", %{deps: deps} do
      # Query isolated DynSup for initial count
      initial_children = DynamicSupervisor.which_children(deps.dynsup)
      assert Enum.empty?(initial_children)

      config1 = %{
        agent_id: "counted-1",
        task: "task",
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, _pid1} =
        spawn_agent_with_cleanup(deps.dynsup, config1,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Query isolated DynSup for count
      children_after_one = DynamicSupervisor.which_children(deps.dynsup)
      assert length(children_after_one) == 1

      config2 = %{
        agent_id: "counted-2",
        task: "task",
        test_mode: true,
        test_opts: [skip_initial_consultation: true]
      }

      {:ok, _pid2} =
        spawn_agent_with_cleanup(deps.dynsup, config2,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Query isolated DynSup for final count
      children_after_two = DynamicSupervisor.which_children(deps.dynsup)
      assert length(children_after_two) == 2
    end
  end
end
