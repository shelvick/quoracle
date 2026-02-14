defmodule Quoracle.Agent.ActionExecutorRegressionsTest do
  @moduledoc """
  Tests for FIX_ActionExecutorRegressions - Three regressions from action deadlock fix.

  WorkGroupID: fix-20260214-action-executor-regressions
  Packet: Single Packet

  Bug 1: Always-sync + wait:true + error = permanent stall
  Bug 2: Shell check_id always returns :command_not_found
  Bug 3: Router leak (ActionExecutor doesn't monitor/track Routers)

  ARC Verification Criteria: R1-R14

  Regression-detecting tests (R1, R4-R6, R8, R10, R12, R14) written in TEST phase.
  Non-regression tests (R2, R3, R7, R9, R11, R13) added in IMPLEMENT phase.
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.ConsensusHandler.ActionExecutor
  alias Quoracle.Agent.MessageHandler

  alias Test.IsolationHelpers

  @moduletag capture_log: true

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    base_state = %{
      agent_id: "agent-regr-#{System.unique_integer([:positive])}",
      task_id: "task-#{System.unique_integer([:positive])}",
      pending_actions: %{},
      model_histories: %{},
      children: [],
      wait_timer: nil,
      timer_generation: 0,
      action_counter: 0,
      state: :processing,
      context_summary: nil,
      context_limit: 4000,
      context_limits_loaded: true,
      additional_context: [],
      test_mode: true,
      skip_auto_consensus: true,
      skip_consensus: true,
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner,
      queued_messages: [],
      consensus_scheduled: false,
      budget_data: nil,
      over_budget: false,
      dismissing: false,
      capability_groups: [:hierarchy, :local_execution],
      consensus_retry_count: 0,
      prompt_fields: nil,
      system_prompt: nil,
      active_skills: [],
      todos: [],
      parent_pid: nil,
      active_routers: %{},
      shell_routers: %{}
    }

    %{state: base_state, deps: deps, sandbox_owner: sandbox_owner}
  end

  # Helper: spawn a test agent with standard config
  defp spawn_test_agent(deps, sandbox_owner, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "agent-regr-#{System.unique_integer([:positive])}")
    capability_groups = Keyword.get(opts, :capability_groups, [:hierarchy, :local_execution])

    config = %{
      agent_id: agent_id,
      task_id: Ecto.UUID.generate(),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: nil,
      prompt_fields: %{
        provided: %{task_description: "Regression test task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: [],
      capability_groups: capability_groups
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: sandbox_owner
    )
  end

  # Helper: poll agent state until condition is met or timeout.
  defp wait_for_condition(agent_pid, condition_fn, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_condition(agent_pid, condition_fn, deadline)
  end

  defp do_wait_for_condition(agent_pid, condition_fn, deadline) do
    {:ok, state} = Core.get_state(agent_pid)

    if condition_fn.(state) do
      {:ok, state}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:timeout, state}
      else
        :erlang.yield()
        do_wait_for_condition(agent_pid, condition_fn, deadline)
      end
    end
  end

  # Helper: extract state from wait_for_condition result
  defp extract_state({:ok, state}), do: state
  defp extract_state({:timeout, state}), do: state

  # ============================================================================
  # Bug 1: Error-Aware Continuation
  # ============================================================================

  describe "R1: always-sync error continues consensus" do
    @tag :unit
    test "always-sync error with wait:true continues consensus",
         %{state: state} do
      # Setup: always-sync action (spawn_child) with wait:true that returns error
      action_id = "action_r1_#{System.unique_integer([:positive])}"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :spawn_child,
              params: %{profile: "researcher"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      opts = [
        action_atom: :spawn_child,
        wait_value: true,
        always_sync: true,
        action_response: %{
          action: :spawn_child,
          params: %{profile: "researcher"},
          wait: true
        }
      ]

      # Spawn failed with error
      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:error, :invalid_budget_format},
          opts
        )

      # BUG: always_sync=true + wait_value=true unconditionally suppresses consensus,
      # even for errors. The agent stalls forever because no child/event will arrive.
      # FIX: Only suppress consensus on {:ok, _} results.
      assert new_state.consensus_scheduled,
             "Consensus should be scheduled when always-sync action errors with wait:true. " <>
               "Agent will stall forever if consensus is not continued after error."
    end
  end

  describe "R4: all always-sync errors continue" do
    @tag :unit
    test "error results continue consensus for all types",
         %{state: state} do
      # Test representative always-sync actions with errors
      always_sync_actions = [
        {:spawn_child, {:error, :invalid_budget_format}},
        {:send_message, {:error, :agent_not_found}},
        {:file_read, {:error, :enoent}},
        {:file_write, {:error, :eacces}},
        {:search_secrets, {:error, :no_results}}
      ]

      for {action_atom, error_result} <- always_sync_actions do
        action_id = "action_r4_#{action_atom}_#{System.unique_integer([:positive])}"

        test_state = %{
          state
          | pending_actions: %{
              action_id => %{
                type: action_atom,
                params: %{},
                timestamp: DateTime.utc_now()
              }
            }
        }

        opts = [
          action_atom: action_atom,
          wait_value: true,
          always_sync: true,
          action_response: %{
            action: action_atom,
            params: %{},
            wait: true
          }
        ]

        {:noreply, new_state} =
          MessageHandler.handle_action_result(
            test_state,
            action_id,
            error_result,
            opts
          )

        # BUG: All always-sync actions with wait:true + error stall.
        # FIX: Only suppress on success.
        assert new_state.consensus_scheduled,
               "#{action_atom} error with wait:true should continue consensus. " <>
                 "Agent will stall if consensus is not scheduled."
      end
    end
  end

  describe "R2: success still suppresses continuation" do
    @tag :unit
    test "always-sync success with wait:true suppresses continuation",
         %{state: state} do
      action_id = "action_r2_#{System.unique_integer([:positive])}"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :spawn_child,
              params: %{profile: "researcher"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      opts = [
        action_atom: :spawn_child,
        wait_value: true,
        always_sync: true,
        action_response: %{
          action: :spawn_child,
          params: %{profile: "researcher"},
          wait: true
        }
      ]

      # Success result: agent should wait for child message
      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:ok, %{agent_id: "child-1", spawned_at: DateTime.utc_now()}},
          opts
        )

      refute new_state.consensus_scheduled,
             "Consensus should NOT be scheduled when always-sync action succeeds with wait:true. " <>
               "Agent should wait for the child's message before continuing."
    end
  end

  describe "R3: non-always-sync unaffected" do
    @tag :unit
    test "non-always-sync error with wait:true continues consensus unchanged",
         %{state: state} do
      action_id = "action_r3_#{System.unique_integer([:positive])}"

      state = %{
        state
        | pending_actions: %{
            action_id => %{
              type: :execute_shell,
              params: %{command: "failing_cmd"},
              timestamp: DateTime.utc_now()
            }
          }
      }

      opts = [
        action_atom: :execute_shell,
        wait_value: true,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{command: "failing_cmd"},
          wait: true
        }
      ]

      {:noreply, new_state} =
        MessageHandler.handle_action_result(
          state,
          action_id,
          {:error, :command_failed},
          opts
        )

      # Non-always-sync with wait:true falls through to the default continuation branch
      assert new_state.consensus_scheduled,
             "Non-always-sync action error with wait:true should continue consensus. " <>
               "The always_sync guard should not affect non-always-sync actions."
    end
  end

  # ============================================================================
  # Bug 2: Shell check_id Routing
  # ============================================================================

  describe "R5: shell result populates shell_routers" do
    @tag :integration
    test "async shell result populates shell_routers",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Simulate an async shell result arriving with a command_id
      action_id = "action_r5_#{System.unique_integer([:positive])}"
      command_id = Ecto.UUID.generate()

      # Add shell action to pending
      GenServer.cast(
        agent_pid,
        {:add_pending_action, action_id, :execute_shell, %{command: "long_running"}}
      )

      {:ok, _mid_state} = Core.get_state(agent_pid)

      # Simulate the Router PID that would be created by ActionExecutor
      # In the fixed code, router_pid would be passed through result_opts
      router_pid = self()

      # Send async shell result with command_id (as the background task would)
      result_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{command: "long_running"},
          wait: false
        },
        router_pid: router_pid
      ]

      shell_result = {:ok, %{command_id: command_id, async: true, status: :running}}

      GenServer.cast(agent_pid, {:action_result, action_id, shell_result, result_opts})

      # Wait for result to be processed
      post_state =
        wait_for_condition(agent_pid, fn state ->
          map_size(state.pending_actions) == 0
        end)
        |> extract_state()

      # BUG: ActionExecutor doesn't pass router_pid through result_opts,
      # and ActionResultHandler doesn't populate shell_routers.
      # FIX: Pass router_pid in result_opts, populate shell_routers in
      # ActionResultHandler.maybe_track_shell_router/3
      assert map_size(post_state.shell_routers) >= 1,
             "shell_routers should contain the command_id->router_pid mapping. " <>
               "Got: #{inspect(post_state.shell_routers)}"

      assert Map.has_key?(post_state.shell_routers, command_id),
             "shell_routers should be keyed by command_id (#{command_id}), " <>
               "not action_id. Keys: #{inspect(Map.keys(post_state.shell_routers))}"
    end
  end

  describe "R5b: dispatch includes router_pid" do
    @tag :unit
    test "result_opts from dispatch includes router_pid",
         %{state: state} do
      # ActionExecutor must pass router_pid in result_opts so that
      # ActionResultHandler can populate shell_routers when an async
      # shell result (with command_id) arrives.
      action_response = %{
        action: :execute_shell,
        params: %{command: "echo test"},
        wait: false
      }

      _result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      # The background task should send a cast with router_pid in opts
      assert_receive {:"$gen_cast", {:action_result, _action_id, _result, opts}},
                     5000

      # BUG: ActionExecutor doesn't include router_pid in result_opts.
      # Without router_pid, ActionResultHandler can't populate shell_routers
      # for async shell commands (commands returning {command_id, async: true}).
      # FIX: Add router_pid to result_opts at dispatch time.
      assert Keyword.has_key?(opts, :router_pid),
             "result_opts should include :router_pid for shell Router tracking. " <>
               "Got opts keys: #{inspect(Keyword.keys(opts))}"

      router_pid = Keyword.get(opts, :router_pid)

      assert is_pid(router_pid),
             "router_pid should be a PID, got: #{inspect(router_pid)}"
    end
  end

  describe "R6: check_id routes via shell_routers" do
    @tag :integration
    test "check_id routes through existing Router",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      command_id = Ecto.UUID.generate()

      # Start a real Router for the original shell command
      {:ok, original_router} =
        Quoracle.Actions.Router.start_link(
          action_type: :execute_shell,
          action_id: "original_action",
          agent_id: "agent-r6",
          agent_pid: agent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(original_router) do
          try do
            GenServer.stop(original_router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Register shell_command state on the Router so StatusCheck finds it
      GenServer.call(
        original_router,
        {:register_shell_command, command_id,
         %{
           action_id: "original_action",
           command_id: command_id,
           status: :running,
           command: "long_running_test",
           stdout_buffer: "",
           stderr_buffer: "",
           last_check_position: {0, 0},
           started_at: DateTime.utc_now()
         }}
      )

      # Set up shell_routers with monitor owned by Core
      :sys.replace_state(agent_pid, fn old_state ->
        ref = Process.monitor(original_router)

        %{
          old_state
          | shell_routers: Map.put(old_state.shell_routers, command_id, original_router),
            active_routers: Map.put(old_state.active_routers, ref, original_router)
        }
      end)

      # Get action_state and compute the action_id ActionExecutor will generate
      action_state = :sys.get_state(agent_pid)
      counter = Map.get(action_state, :action_counter, 0)
      expected_action_id = "action_#{action_state.agent_id}_#{counter + 1}"

      # Pre-add the pending action to Core's real state so handle_action_result
      # won't drop the result as "unknown action_id"
      GenServer.cast(
        agent_pid,
        {:add_pending_action, expected_action_id, :execute_shell, %{"check_id" => command_id}}
      )

      {:ok, _} = Core.get_state(agent_pid)

      check_action = %{
        action: :execute_shell,
        params: %{"check_id" => command_id},
        wait: false
      }

      # BUG: ActionExecutor spawns a NEW Router for check_id instead of
      # routing through the existing Router from shell_routers.
      # FIX: Look up shell_routers for check_id and use existing Router.
      _result_state =
        ActionExecutor.execute_consensus_action(action_state, check_action, agent_pid)

      # Wait for result (pending_actions cleared when result processed)
      post_state =
        wait_for_condition(
          agent_pid,
          fn state ->
            not Map.has_key?(state.pending_actions, expected_action_id)
          end,
          10_000
        )
        |> extract_state()

      # Check history for :command_not_found error
      all_entries =
        post_state.model_histories
        |> Map.values()
        |> List.flatten()

      has_command_not_found =
        Enum.any?(all_entries, fn entry ->
          entry.type == :result and
            is_binary(entry.content) and
            String.contains?(entry.content, "command_not_found")
        end)

      # BUG: A new Router spawns for check_id -> :command_not_found.
      # FIX: Existing Router is used -> actual command status.
      refute has_command_not_found,
             "check_id should route through existing Router, " <>
               "not spawn a new empty Router returning :command_not_found"
    end
  end

  describe "R7: unknown check_id returns command_not_found" do
    @tag :unit
    test "check_id for unknown command returns command_not_found",
         %{state: state} do
      unknown_command_id = Ecto.UUID.generate()

      # shell_routers is empty — no Router for this command_id
      assert state.shell_routers == %{}

      check_action = %{
        action: :execute_shell,
        params: %{"check_id" => unknown_command_id},
        wait: false
      }

      # ActionExecutor should spawn a new Router (no existing Router found),
      # which has no shell_command state, correctly returning :command_not_found
      _result_state =
        ActionExecutor.execute_consensus_action(state, check_action, self())

      # Wait for the background task to send the result cast
      assert_receive {:"$gen_cast", {:action_result, _action_id, result, _opts}},
                     5000

      assert result == {:error, :command_not_found},
             "check_id for unknown command should return :command_not_found. " <>
               "Got: #{inspect(result)}"
    end
  end

  describe "R8: terminate routes via shell_routers" do
    @tag :integration
    test "terminate routes through existing Router",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      command_id = Ecto.UUID.generate()

      # Start a real Router for the original shell command
      {:ok, original_router} =
        Quoracle.Actions.Router.start_link(
          action_type: :execute_shell,
          action_id: "original_action_r8",
          agent_id: "agent-r8",
          agent_pid: agent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(original_router) do
          try do
            GenServer.stop(original_router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Register shell_command state on the Router so Termination finds it
      GenServer.call(
        original_router,
        {:register_shell_command, command_id,
         %{
           action_id: "original_action_r8",
           command_id: command_id,
           status: :running,
           command: "long_running_test",
           stdout_buffer: "",
           stderr_buffer: "",
           last_check_position: {0, 0},
           started_at: DateTime.utc_now()
         }}
      )

      # Set up shell_routers with monitor owned by Core
      :sys.replace_state(agent_pid, fn old_state ->
        ref = Process.monitor(original_router)

        %{
          old_state
          | shell_routers: Map.put(old_state.shell_routers, command_id, original_router),
            active_routers: Map.put(old_state.active_routers, ref, original_router)
        }
      end)

      # Get action_state and compute the action_id ActionExecutor will generate
      action_state = :sys.get_state(agent_pid)
      counter = Map.get(action_state, :action_counter, 0)
      expected_action_id = "action_#{action_state.agent_id}_#{counter + 1}"

      # Pre-add the pending action
      GenServer.cast(
        agent_pid,
        {:add_pending_action, expected_action_id, :execute_shell,
         %{"check_id" => command_id, "terminate" => true}}
      )

      {:ok, _} = Core.get_state(agent_pid)

      # terminate uses check_id + terminate: true (no separate terminate_id param)
      terminate_action = %{
        action: :execute_shell,
        params: %{"check_id" => command_id, "terminate" => true},
        wait: false
      }

      # BUG: ActionExecutor spawns a NEW Router for terminate instead of
      # routing through the existing Router from shell_routers.
      # The new Router has no shell_command state -> :command_not_found.
      # FIX: Look up shell_routers for check_id and use existing Router.
      _result_state =
        ActionExecutor.execute_consensus_action(action_state, terminate_action, agent_pid)

      # Wait for result
      post_state =
        wait_for_condition(
          agent_pid,
          fn state ->
            not Map.has_key?(state.pending_actions, expected_action_id)
          end,
          10_000
        )
        |> extract_state()

      # Check history for :command_not_found error
      all_entries =
        post_state.model_histories
        |> Map.values()
        |> List.flatten()

      has_command_not_found =
        Enum.any?(all_entries, fn entry ->
          entry.type == :result and
            is_binary(entry.content) and
            String.contains?(entry.content, "command_not_found")
        end)

      # BUG: A new Router spawns for terminate -> :command_not_found.
      # FIX: Existing Router routes terminate through correct Router.
      refute has_command_not_found,
             "terminate (check_id + terminate:true) should route through existing Router, " <>
               "not spawn a new empty Router returning :command_not_found"
    end
  end

  describe "R9: Router death cleans up tracking maps" do
    @tag :integration
    test "Router death cleans up shell_routers and active_routers",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      command_id = Ecto.UUID.generate()

      # Start a Router to simulate shell command Router
      {:ok, router_pid} =
        Quoracle.Actions.Router.start_link(
          action_type: :execute_shell,
          action_id: "action_r9",
          agent_id: "agent-r9",
          agent_pid: agent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Set up tracking maps on Core (simulating ActionExecutor having tracked the Router)
      :sys.replace_state(agent_pid, fn old_state ->
        ref = Process.monitor(router_pid)

        %{
          old_state
          | shell_routers: Map.put(old_state.shell_routers, command_id, router_pid),
            active_routers: Map.put(old_state.active_routers, ref, router_pid)
        }
      end)

      # Verify Router is tracked
      {:ok, pre_state} = Core.get_state(agent_pid)
      assert map_size(pre_state.active_routers) >= 1
      assert map_size(pre_state.shell_routers) >= 1

      # Kill the Router - triggers DOWN message to Core
      GenServer.stop(router_pid, :normal)

      # Wait for cleanup via handle_down
      post_state =
        wait_for_condition(agent_pid, fn state ->
          map_size(state.active_routers) == 0 and map_size(state.shell_routers) == 0
        end)
        |> extract_state()

      assert map_size(post_state.active_routers) == 0,
             "active_routers should be empty after Router death. " <>
               "Got: #{inspect(post_state.active_routers)}"

      assert map_size(post_state.shell_routers) == 0,
             "shell_routers should be empty after Router death. " <>
               "Got: #{inspect(post_state.shell_routers)}"
    end
  end

  # ============================================================================
  # Bug 3: Router Monitoring
  # ============================================================================

  describe "R10: ActionExecutor monitors Routers" do
    @tag :unit
    test "ActionExecutor monitors and tracks in active_routers",
         %{state: state} do
      action_response = %{
        action: :orient,
        params: %{thought: "testing Router monitoring"},
        wait: false
      }

      result_state = ActionExecutor.execute_consensus_action(state, action_response)

      # BUG: ActionExecutor calls Router.start_link but never:
      # 1. Process.monitor(router_pid)
      # 2. Map.put(state.active_routers, monitor_ref, router_pid)
      # FIX: Add monitoring after start_link, before dispatch.
      assert map_size(result_state.active_routers) >= 1,
             "active_routers should track the spawned Router. " <>
               "ActionExecutor must call Process.monitor and add to active_routers. " <>
               "Got: #{inspect(result_state.active_routers)}"

      # Verify structure: keys are references, values are pids
      for {ref, pid} <- result_state.active_routers do
        assert is_reference(ref),
               "active_routers keys should be monitor references, got: #{inspect(ref)}"

        assert is_pid(pid),
               "active_routers values should be Router PIDs, got: #{inspect(pid)}"
      end
    end
  end

  describe "R11: Core terminate stops ActionExecutor-spawned Routers" do
    @tag :integration
    test "Core terminate stops ActionExecutor-spawned Routers",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Start a Router simulating one spawned by ActionExecutor
      {:ok, router_pid} =
        Quoracle.Actions.Router.start_link(
          action_type: :execute_shell,
          action_id: "action_r11",
          agent_id: "agent-r11",
          agent_pid: agent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Track in active_routers (as ActionExecutor would)
      :sys.replace_state(agent_pid, fn old_state ->
        ref = Process.monitor(router_pid)

        %{
          old_state
          | active_routers: Map.put(old_state.active_routers, ref, router_pid)
        }
      end)

      # Verify Router is alive and tracked
      assert Process.alive?(router_pid)
      {:ok, pre_state} = Core.get_state(agent_pid)
      assert map_size(pre_state.active_routers) >= 1

      # Monitor the Router from test process to detect its death
      router_monitor = Process.monitor(router_pid)

      # Terminate Core — this should stop all active_routers via terminate/2
      GenServer.stop(agent_pid, :normal, :infinity)

      # Wait for Router to die (Core.terminate iterates active_routers)
      assert_receive {:DOWN, ^router_monitor, :process, ^router_pid, _reason},
                     5000,
                     "Router should be stopped when Core terminates. " <>
                       "Core.terminate/2 iterates active_routers to stop all tracked Routers."
    end
  end

  # ============================================================================
  # Bug 2: TestActionHandler shell_routers Key
  # ============================================================================

  describe "R12: shell_routers keyed by command_id" do
    @tag :integration
    test "shell_routers key is command_id not action_id",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Use a long-running shell command so the Router stays alive
      # and shell_routers entry persists until we can check it.
      # Fast commands (echo) complete before get_state, triggering
      # Router DOWN cleanup that empties shell_routers.
      shell_action = %{
        action: :execute_shell,
        params: %{command: "sleep 10"}
      }

      action_id = "test_action_r12_#{System.unique_integer([:positive])}"

      # Run in a Task since the call blocks until completion
      task =
        Task.async(fn ->
          capture_log(fn ->
            GenServer.call(
              agent_pid,
              {:process_action, shell_action, action_id},
              30_000
            )
          end)
        end)

      # Wait for shell_routers to be populated (Router spawned, command started)
      state =
        wait_for_condition(
          agent_pid,
          fn state -> map_size(state.shell_routers) > 0 end,
          5000
        )
        |> extract_state()

      # BUG: TestActionHandler stores shell_routers keyed by action_id (line 113).
      # The LLM uses command_id (a UUID from Shell) in check_id requests.
      # Using action_id as key means check_id lookups will never match.
      # FIX: Key by command_id from the shell result.

      # Verify shell_routers was populated (command still running)
      assert map_size(state.shell_routers) >= 1,
             "shell_routers should have an entry for running command"

      # Check the key format - should be command_id (UUID), not action_id
      for {key, _pid} <- state.shell_routers do
        refute String.starts_with?(key, "action_") or
                 String.starts_with?(key, "test_action_"),
               "shell_routers key should be command_id (UUID), not action_id. " <>
                 "Got key: #{key}. " <>
                 "TestActionHandler should use command_id from result."
      end

      # Cleanup: shut down the blocking task
      Task.shutdown(task, :brutal_kill)
    end
  end

  # ============================================================================
  # System-Level Tests
  # ============================================================================

  describe "R13: agent recovers from failed spawn" do
    @tag :system
    test "agent continues consensus after failed spawn_child with wait:true",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Simulate the non-blocking dispatch path:
      # ActionExecutor dispatches spawn_child, background task returns error,
      # error result arrives via GenServer.cast({:action_result, ...})
      action_id = "action_r13_#{System.unique_integer([:positive])}"

      # Add pending action (as ActionExecutor would before dispatch)
      GenServer.cast(
        agent_pid,
        {:add_pending_action, action_id, :spawn_child, %{profile: "researcher"}}
      )

      {:ok, _} = Core.get_state(agent_pid)

      # Send error result with always_sync=true, wait:true (the stall scenario)
      result_opts = [
        action_atom: :spawn_child,
        wait_value: true,
        always_sync: true,
        action_response: %{
          action: :spawn_child,
          params: %{profile: "researcher"},
          wait: true
        }
      ]

      GenServer.cast(
        agent_pid,
        {:action_result, action_id, {:error, :invalid_budget_format}, result_opts}
      )

      # Wait for result to be processed (pending_actions cleared)
      post_state =
        wait_for_condition(agent_pid, fn state ->
          map_size(state.pending_actions) == 0
        end)
        |> extract_state()

      # The agent should NOT be stalled:
      # 1. Error is recorded in history (LLM can see it)
      all_entries =
        post_state.model_histories
        |> Map.values()
        |> List.flatten()

      has_error_in_history =
        Enum.any?(all_entries, fn entry ->
          entry.type == :result and
            is_binary(entry.content) and
            (String.contains?(entry.content, "error") or
               String.contains?(entry.content, "invalid_budget"))
        end)

      assert has_error_in_history,
             "Agent should have error result in history after failed spawn. " <>
               "The LLM needs to see the error to decide what to do next. " <>
               "History entries: #{inspect(Enum.map(all_entries, & &1.type))}"

      # 2. Consensus is scheduled (agent can continue operating)
      assert post_state.consensus_scheduled,
             "Agent should have consensus_scheduled=true after error with wait:true. " <>
               "Without this, the agent stalls forever waiting for a child that was never spawned."
    end
  end

  describe "R14: shell + check_id round-trip" do
    @tag :system
    test "shell command + check_id routes correctly",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Step 1: Execute async shell command through TestActionHandler
      # Use "sleep 5" which takes long enough to get async result
      shell_action = %{
        action: :execute_shell,
        params: %{command: "sleep 5 && echo done"}
      }

      action_id_1 = "action_r14_exec_#{System.unique_integer([:positive])}"

      # capture_log returns the log string; capture result via ref
      exec_result_ref = make_ref()

      capture_log(fn ->
        result =
          GenServer.call(
            agent_pid,
            {:process_action, shell_action, action_id_1},
            30_000
          )

        send(self(), {exec_result_ref, result})
      end)

      # Retrieve the actual result from the capture_log block
      exec_result =
        receive do
          {^exec_result_ref, result} -> result
        after
          0 -> nil
        end

      {:ok, state_after_exec} = Core.get_state(agent_pid)

      # The shell command should either return async (with command_id) or sync
      case exec_result do
        {:ok, %{command_id: command_id}} when is_binary(command_id) ->
          # Async path: command is still running, we got a command_id
          # Step 2: Check status using check_id
          check_action = %{
            action: :execute_shell,
            params: %{check_id: command_id}
          }

          action_id_2 = "action_r14_check_#{System.unique_integer([:positive])}"

          check_result_ref = make_ref()

          capture_log(fn ->
            result =
              GenServer.call(
                agent_pid,
                {:process_action, check_action, action_id_2},
                30_000
              )

            send(self(), {check_result_ref, result})
          end)

          check_result =
            receive do
              {^check_result_ref, result} -> result
            after
              0 -> nil
            end

          # BUG: check_id spawns a new Router with no shell state -> :command_not_found.
          # FIX: Route through existing Router from shell_routers (keyed by command_id).
          assert check_result != {:error, :command_not_found},
                 "check_id should find the command via shell_routers, " <>
                   "not return :command_not_found. " <>
                   "shell_routers keys: #{inspect(Map.keys(state_after_exec.shell_routers))}. " <>
                   "Looking for command_id: #{command_id}"

        {:ok, result} when is_map(result) ->
          # Sync path: command completed immediately.
          # This is acceptable - fast commands don't need check_id.
          assert is_map(result), "Sync shell result should be a map"

        {:error, _reason} ->
          # Shell command failed - still valid, just can't test check_id
          :ok

        nil ->
          # Result not retrieved (capture_log timing issue)
          # Fall through to shell_routers key check
          :ok
      end

      # Regardless of sync/async path, verify shell_routers key format
      for {key, _pid} <- state_after_exec.shell_routers do
        refute String.starts_with?(key, "action_"),
               "shell_routers key should be command_id, not action_id. " <>
                 "Got: #{key}"
      end
    end
  end
end
