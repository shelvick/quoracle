defmodule Quoracle.Agent.ModelPoolSwitchTest do
  @moduledoc """
  Integration tests for runtime model pool switching via AGENT_Core.
  WorkGroupID: wip-20251230-075616

  Tests the full flow from GenServer.call through validation, history transfer,
  and state update. Verifies OTP synchronization guarantees.

  ARC Verification Criteria:
  - AGENT_Core v21.0: R26-R33 (handle_call for switch_model_pool)
  - TEST_ModelPoolSwitch: R1-R14 (integration tests)
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core
  alias Quoracle.Models.TableCredentials

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry for this test
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    # Create test credentials for valid models
    {:ok, _} =
      TableCredentials.insert(%{
        model_id: "test-model-a",
        model_spec: "test:model-a",
        api_key: "key-a"
      })

    {:ok, _} =
      TableCredentials.insert(%{
        model_id: "test-model-b",
        model_spec: "test:model-b",
        api_key: "key-b"
      })

    {:ok, _} =
      TableCredentials.insert(%{
        model_id: "test-model-c",
        model_spec: "test:model-c",
        api_key: "key-c"
      })

    %{
      pubsub: pubsub_name,
      registry: registry_name,
      sandbox_owner: sandbox_owner
    }
  end

  # Helper to spawn agent with proper cleanup
  defp spawn_agent(context, opts \\ []) do
    %{registry: registry, pubsub: pubsub, sandbox_owner: sandbox_owner} = context

    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    task_id = Keyword.get(opts, :task_id, "test-task-#{System.unique_integer([:positive])}")

    model_pool = Keyword.get(opts, :model_pool, ["test-model-a", "test-model-b"])

    config =
      %{
        agent_id: agent_id,
        task_id: task_id,
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        model_pool: model_pool
      }
      |> Map.merge(Map.new(Keyword.delete(opts, :model_pool)))

    {:ok, pid} = Core.start_link(config)

    # Wait for initialization
    {:ok, _state} = Core.get_state(pid)
    register_agent_cleanup(pid)

    {:ok, pid}
  end

  # =============================================================
  # Core Switching Behavior (R26-R28, R1-R8)
  # =============================================================

  describe "switch_model_pool/2 - core behavior" do
    # R26/R1: WHEN switch_model_pool succeeds THEN state.model_pool contains new model IDs
    test "updates state.model_pool with new models", context do
      {:ok, agent_pid} = spawn_agent(context, model_pool: ["test-model-a"])

      new_pool = ["test-model-b", "test-model-c"]

      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)
      assert state.model_pool == new_pool
    end

    # R27/R2: WHEN switch succeeds THEN model_histories keyed under new model IDs only
    test "re-keys model_histories under new model IDs", context do
      {:ok, agent_pid} = spawn_agent(context, model_pool: ["test-model-a"])

      new_pool = ["test-model-b", "test-model-c"]
      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)

      # Old model keys should be gone
      refute Map.has_key?(state.model_histories, "test-model-a")

      # New model keys should exist
      assert Map.has_key?(state.model_histories, "test-model-b")
      assert Map.has_key?(state.model_histories, "test-model-c")
    end

    # R28/R3: WHEN switch succeeds THEN context_lessons transferred to new models
    test "transfers context_lessons to new models", context do
      lessons = [%{type: :factual, content: "important lesson", confidence: 85}]

      {:ok, agent_pid} =
        spawn_agent(context,
          model_pool: ["test-model-a"],
          context_lessons: %{"test-model-a" => lessons}
        )

      new_pool = ["test-model-b"]
      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)
      assert state.context_lessons["test-model-b"] == lessons
    end

    # R4: WHEN switch succeeds THEN model_states transferred to new models
    test "transfers model_states to new models", context do
      model_state = %{summary: "current context", updated_at: DateTime.utc_now()}

      {:ok, agent_pid} =
        spawn_agent(context,
          model_pool: ["test-model-a"],
          model_states: %{"test-model-a" => model_state}
        )

      new_pool = ["test-model-b"]
      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)
      assert state.model_states["test-model-b"] == model_state
    end

    # R5: WHEN switch succeeds THEN returns :ok
    test "returns :ok on successful switch", context do
      {:ok, agent_pid} = spawn_agent(context)

      result = GenServer.call(agent_pid, {:switch_model_pool, ["test-model-c"]}, :infinity)
      assert result == :ok
    end

    # R6: WHEN history exceeds new model limits THEN condenses
    test "condenses history if it exceeds new model limits", context do
      # Create history directly to avoid async message processing
      large_history =
        Enum.map(1..20, fn i ->
          %{
            type: :user,
            content: "message #{i} with substantial content to build up history",
            timestamp: DateTime.utc_now()
          }
        end)

      {:ok, agent_pid} =
        spawn_agent(context,
          model_pool: ["test-model-a"],
          model_histories: %{"test-model-a" => large_history},
          # Use small target_limit to force condensation during switch
          test_opts: [target_limit: 100]
        )

      {:ok, before_state} = Core.get_state(agent_pid)
      before_count = length(before_state.model_histories["test-model-a"])

      # Switch to model - condensation will be triggered due to small target_limit
      new_pool = ["test-model-b"]

      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, after_state} = Core.get_state(agent_pid)
      after_count = length(after_state.model_histories["test-model-b"])

      # History should be condensed
      assert after_count < before_count
    end

    # R8: WHEN switch succeeds THEN other state fields preserved
    test "preserves other state fields", context do
      {:ok, agent_pid} =
        spawn_agent(context,
          agent_id: "preserve-test-agent",
          task_id: "preserve-test-task",
          profile_name: "test-profile"
        )

      :ok = GenServer.call(agent_pid, {:switch_model_pool, ["test-model-c"]}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)

      # Other fields should be unchanged
      assert state.agent_id == "preserve-test-agent"
      assert state.task_id == "preserve-test-task"
      assert state.profile_name == "test-profile"
    end

    # R10: WHEN transfer completes THEN all new models share same history
    test "all new models share same history reference", context do
      {:ok, agent_pid} = spawn_agent(context, model_pool: ["test-model-a"])

      new_pool = ["test-model-b", "test-model-c"]
      assert :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)

      # All histories should be equal
      history_b = state.model_histories["test-model-b"]
      history_c = state.model_histories["test-model-c"]
      assert history_b == history_c
    end
  end

  # =============================================================
  # OTP Synchronization Guarantees (R32-R33, R9-R11)
  # =============================================================

  describe "switch_model_pool/2 - OTP guarantees" do
    # R32/R7: WHEN switch_model_pool called THEN blocks until complete
    test "blocks caller until switch completes", context do
      {:ok, agent_pid} = spawn_agent(context)

      start_time = System.monotonic_time(:millisecond)

      :ok = GenServer.call(agent_pid, {:switch_model_pool, ["test-model-c"]}, :infinity)

      end_time = System.monotonic_time(:millisecond)

      # Should complete reasonably quickly (not timeout)
      assert end_time - start_time < 5000
    end

    # R33/R9: WHEN consensus in-flight THEN switch waits (GenServer ordering)
    test "waits for in-flight operations due to GenServer ordering", context do
      {:ok, agent_pid} = spawn_agent(context)

      # GenServer guarantees message ordering - first call completes before second starts
      # Launch both operations concurrently and verify both complete
      tasks = [
        Task.async(fn ->
          Core.send_user_message(agent_pid, "trigger processing")
        end),
        Task.async(fn ->
          GenServer.call(agent_pid, {:switch_model_pool, ["test-model-c"]}, :infinity)
        end)
      ]

      # Both should complete without error (GenServer serializes them)
      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    # R11: WHEN switch completes THEN state is atomic (no partial state)
    test "switch is atomic - no partial state visible", context do
      {:ok, agent_pid} =
        spawn_agent(context, model_pool: ["test-model-a", "test-model-b"])

      new_pool = ["test-model-c"]

      :ok = GenServer.call(agent_pid, {:switch_model_pool, new_pool}, :infinity)

      {:ok, state} = Core.get_state(agent_pid)

      # Should have ALL new keys, NONE of old keys
      old_keys = MapSet.new(["test-model-a", "test-model-b"])
      new_keys = MapSet.new(new_pool)
      history_keys = MapSet.new(Map.keys(state.model_histories))

      assert MapSet.disjoint?(history_keys, old_keys)
      assert MapSet.equal?(history_keys, new_keys)
    end
  end

  # =============================================================
  # Error Handling (R29-R31, R12-R14)
  # =============================================================

  describe "switch_model_pool/2 - error handling" do
    # R29/R13: WHEN new_pool is empty THEN returns {:error, :empty_model_pool}
    test "rejects empty pool", context do
      {:ok, agent_pid} = spawn_agent(context)

      result = GenServer.call(agent_pid, {:switch_model_pool, []}, :infinity)

      assert {:error, :empty_model_pool} = result
    end

    # R30/R12: WHEN any model_id not in credentials THEN returns {:error, :invalid_models}
    test "rejects invalid model IDs", context do
      {:ok, agent_pid} = spawn_agent(context)

      # Non-existent model
      invalid_pool = ["nonexistent/fake-model"]

      result = GenServer.call(agent_pid, {:switch_model_pool, invalid_pool}, :infinity)

      assert {:error, :invalid_models} = result
    end

    # R31/R14: WHEN validation fails THEN state unchanged
    test "state unchanged when switch fails validation", context do
      original_pool = ["test-model-a", "test-model-b"]

      {:ok, agent_pid} = spawn_agent(context, model_pool: original_pool)

      {:ok, before_state} = Core.get_state(agent_pid)

      # Attempt invalid switch
      {:error, _} = GenServer.call(agent_pid, {:switch_model_pool, []}, :infinity)

      {:ok, after_state} = Core.get_state(agent_pid)

      # State should be unchanged
      assert after_state.model_pool == original_pool
      assert after_state.model_histories == before_state.model_histories
    end

    # Additional: Mixed valid/invalid models
    test "rejects pool with any invalid model", context do
      {:ok, agent_pid} = spawn_agent(context)

      # Mix of valid and invalid
      mixed_pool = ["test-model-a", "invalid-model"]

      result = GenServer.call(agent_pid, {:switch_model_pool, mixed_pool}, :infinity)

      assert {:error, :invalid_models} = result
    end
  end
end
