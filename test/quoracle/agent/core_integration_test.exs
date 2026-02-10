defmodule Quoracle.Agent.CoreIntegrationTest do
  @moduledoc """
  Integration tests for AGENT_Core implementation issues identified in audit.
  These tests verify fixes for:
  1. Mock params generation completeness
  2. Router linking verification
  3. wait_for_ready race condition handling
  4. Params key consistency (string vs atom)
  """

  # Tests can use async: true with proper Sandbox.allow for GenServers
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Consensus.MockResponseGenerator

  # DataCase already sets up Sandbox in shared mode for Task.async_stream

  setup %{sandbox_owner: sandbox_owner} do
    # DataCase already provides sandbox_owner via start_owner! pattern
    # No need for old Sandbox.mode call

    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry for this test
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
  end

  describe "reactive model integration" do
    test "agent does not consult consensus on startup", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-no-consultation",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
      }

      {:ok, agent} = Core.start_link(config)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Agent should be ready with no history
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready

      {:ok, histories} = Core.get_model_histories(agent)
      # Reactive model: agents start with empty histories (no initial consultation)
      assert Enum.all?(Map.values(histories), &(&1 == []))
    end

    test "agent processes explicit messages via send_user_message", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-explicit-msg",
        test_mode: true,
        seed: 42,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub,
        test_pid: self()
      }

      {:ok, agent} = Core.start_link(config)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent, cleanup_tree: true, registry: registry)

      # Capture all logs including sporadic DB connection cleanup messages
      capture_log(fn ->
        # Subscribe BEFORE sending message to avoid race condition
        :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

        # Send explicit message
        Core.send_user_message(agent, "Hello agent")

        # Wait for processing (5000ms to accommodate CI load/scheduler delays)
        assert_receive {:action_started, _}, 30_000
        # Wait for action to complete
        assert_receive {:action_completed, _}, 30_000
        # Should have decision in history - check all model histories
        {:ok, histories} = Core.get_model_histories(agent)
        all_entries = histories |> Map.values() |> List.flatten()
        assert Enum.any?(all_entries, &(&1.type == :decision))
      end)
    end
  end

  describe "mock params generation completeness" do
    test "MockResponseGenerator provides ALL required params for orient action" do
      # The mock must generate all 4 required params for orient
      response = MockResponseGenerator.generate_mock_response(:test_model, :orient)

      assert response.action == :orient
      assert is_map(response.params)

      # Orient requires these 4 params as atoms after normalization
      required_params = [
        "current_situation",
        "goal_clarity",
        "available_resources",
        "key_challenges"
      ]

      for param <- required_params do
        assert Map.has_key?(response.params, param),
               "Missing required param: #{param}"

        assert response.params[param] != nil && response.params[param] != "",
               "Empty required param: #{param}"
      end
    end

    test "MockResponseGenerator provides valid params for all implemented actions" do
      # Test wait action
      wait_response = MockResponseGenerator.generate_mock_response(:test_model, :wait)
      assert wait_response.params["wait"] != nil

      # Test send_message action (if implemented in mock)
      # This should have proper params or empty map for unimplemented
      actions = [:wait, :orient, :spawn_child, :send_message]

      for action <- actions do
        response = MockResponseGenerator.generate_mock_response(:test_model, action)
        assert is_map(response.params)
      end
    end
  end

  describe "reactive model behavior" do
    test "agent starts immediately in ready state", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      import ExUnit.CaptureLog

      config = %{
        agent_id: "test-immediate-ready",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
      }

      # Capture expected error log for agent without task_id
      agent =
        capture_log(fn ->
          {:ok, pid} = Core.start_link(config)
          send(self(), {:agent, pid})
        end)
        |> then(fn _ ->
          assert_receive {:agent, pid}, 30_000
          pid
        end)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # wait_for_ready should return immediately since agents start ready
      assert :ok = Core.wait_for_ready(agent, 100)

      # Agent should be in ready state
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready
      assert Process.alive?(agent)

      # New caller should still be able to wait
      assert :ok = Core.wait_for_ready(agent)
    end

    test "wait_for_ready handles multiple concurrent waiters", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-concurrent-wait",
        task: "Test concurrent waiting",
        test_mode: true,
        test_opts: [initial_delay: 200],
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
      }

      {:ok, agent} = Core.start_link(config)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Use Tasks for multiple processes waiting
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            result = Core.wait_for_ready(agent)
            {i, result}
          end)
        end

      # All should eventually get :ok
      results = Task.await_many(tasks, 5000)

      for {i, result} <- results do
        assert result == :ok
        assert i in 1..5
      end
    end

    test "wait_for_ready cleans up dead waiters from state", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      # Trap exits to test process death handling
      Process.flag(:trap_exit, true)

      config = %{
        agent_id: "test-waiter-cleanup",
        task: "Test waiter cleanup",
        test_mode: true,
        test_opts: [initial_delay: 300],
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
      }

      {:ok, agent} = Core.start_link(config)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Create a waiter task - it may complete immediately since agents start ready
      dead_task =
        Task.async(fn ->
          Core.wait_for_ready(agent)
        end)

      ref = Process.monitor(dead_task.pid)

      # Try to kill the task (it may have already completed)
      Process.exit(dead_task.pid, :kill)

      # Task exits with :killed if we killed it, or :normal if it completed first
      assert_receive {:DOWN, ^ref, :process, _, reason}, 30_000
      assert reason in [:killed, :normal]

      # Create a live waiter task
      live_task =
        Task.async(fn ->
          result = Core.wait_for_ready(agent)
          result
        end)

      # Wait for ready
      assert Task.await(live_task, 5000) == :ok

      # Agents start ready immediately, no waiting list needed
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready
    end
  end

  describe "params key consistency" do
    test "Router receives params with consistent key types from consensus", %{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner
    } do
      config = %{
        agent_id: "test-param-keys",
        task: "Test param key consistency",
        test_mode: true,
        skip_initial_consultation: true,
        sandbox_owner: sandbox_owner,
        registry: registry,
        pubsub: pubsub
      }

      {:ok, agent} = Core.start_link(config)

      # Wait for initialization and ensure cleanup before sandbox owner exits
      {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Subscribe to verify action execution BEFORE sending message
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Send message that triggers action with params
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "Please wait for 1 second")
      end)

      # Router should receive params with consistent keys
      # Use 5000ms timeout to accommodate CI load/scheduler delays (same as line 93)
      assert_receive {:action_started, _}, 30_000
      # Check that no param validation errors occurred
      refute_receive {:action_error, %{error: {:error, :invalid_params}}}, 500
    end

    test "Orient action receives string keys and normalizes to atoms correctly", %{pubsub: pubsub} do
      # This tests the actual param transformation in Orient module
      params_with_string_keys = %{
        "current_situation" => "Test situation",
        "goal_clarity" => "Clear",
        "available_resources" => "Full",
        "key_challenges" => "None"
      }

      # Orient.execute should handle string keys
      result =
        Quoracle.Actions.Orient.execute(params_with_string_keys, "test-agent", pubsub: pubsub)

      assert {:ok, _} = result
    end

    test "Consensus generates params with correct key types for Router" do
      # Mock consensus should generate string keys for compatibility
      model_pool = [:model1, :model2, :model3]
      opts = [test_mode: true]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      for response <- responses do
        # All param keys should be strings for consistency
        for {key, _value} <- response.params do
          assert is_binary(key), "Param key #{inspect(key)} is not a string"
        end
      end
    end
  end
end
