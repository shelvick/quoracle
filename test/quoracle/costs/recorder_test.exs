defmodule Quoracle.Costs.RecorderTest do
  @moduledoc """
  Tests for COST_Recorder module.

  WorkGroupID: feat-20251212-191913
  Packet: 2 (Recording)

  Requirements:
  - R1: Successful Recording [INTEGRATION]
  - R2: Validation Failure [INTEGRATION]
  - R3: PubSub Broadcast to Task Topic [INTEGRATION]
  - R4: PubSub Broadcast to Agent Topic [INTEGRATION]
  - R5: Broadcast Event Format [UNIT]
  - R6: Nil Cost Handling [INTEGRATION]
  - R7: Silent Recording [INTEGRATION]
  - R8: Safe Broadcast [UNIT]
  - R9: Explicit PubSub Parameter [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task

  # Deferred module loading for TDD - module doesn't exist yet
  @recorder_module Quoracle.Costs.Recorder
  @agent_cost_module Quoracle.Costs.AgentCost

  # Helper to call record/2 at runtime
  defp call_record(cost_data, opts) do
    @recorder_module.record(cost_data, opts)
  end

  # Helper to call record_silent/1 at runtime
  defp call_record_silent(cost_data) do
    @recorder_module.record_silent(cost_data)
  end

  # Helper to create valid cost data
  defp valid_cost_data(task_id, overrides \\ %{}) do
    Map.merge(
      %{
        agent_id: "agent_#{System.unique_integer([:positive])}",
        task_id: task_id,
        cost_type: "llm_consensus",
        cost_usd: Decimal.new("0.0123456789"),
        metadata: %{
          "model_spec" => "anthropic/claude-sonnet-4-20250514",
          "input_tokens" => 1000,
          "output_tokens" => 500
        }
      },
      overrides
    )
  end

  # Setup: Create task and isolated PubSub
  setup do
    # Create a task for foreign key
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{
        prompt: "Test task for cost recording",
        status: "running"
      })
      |> Repo.insert()

    # Isolated PubSub per test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, task: task, pubsub: pubsub_name}
  end

  # ============================================================
  # COST_Recorder: R1 - Successful Recording [INTEGRATION]
  # ============================================================

  describe "record/2 - successful recording" do
    test "records cost to database", %{task: task, pubsub: pubsub} do
      cost_data = valid_cost_data(task.id)

      assert {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      # Verify returned cost has expected fields
      assert cost.agent_id == cost_data.agent_id
      assert cost.task_id == task.id
      assert cost.cost_type == "llm_consensus"
      assert Decimal.equal?(cost.cost_usd, Decimal.new("0.0123456789"))
      assert cost.metadata["model_spec"] == "anthropic/claude-sonnet-4-20250514"
      assert cost.id != nil
      assert cost.inserted_at != nil
    end

    test "persists cost to database", %{task: task, pubsub: pubsub} do
      cost_data = valid_cost_data(task.id)

      {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      # Verify we can fetch it from the database
      fetched = Repo.get(@agent_cost_module, cost.id)
      assert fetched != nil
      assert fetched.agent_id == cost_data.agent_id
      assert fetched.cost_type == "llm_consensus"
    end

    test "records all valid cost types", %{task: task, pubsub: pubsub} do
      cost_types = ~w(llm_consensus llm_embedding llm_answer llm_summarization)

      for cost_type <- cost_types do
        cost_data =
          valid_cost_data(task.id, %{
            cost_type: cost_type,
            agent_id: "agent_#{cost_type}_#{System.unique_integer([:positive])}"
          })

        assert {:ok, cost} = call_record(cost_data, pubsub: pubsub)
        assert cost.cost_type == cost_type
      end
    end
  end

  # ============================================================
  # COST_Recorder: R2 - Validation Failure [INTEGRATION]
  # ============================================================

  describe "record/2 - validation failure" do
    test "returns error for missing agent_id", %{task: task, pubsub: pubsub} do
      cost_data = %{
        task_id: task.id,
        cost_type: "llm_consensus"
      }

      assert {:error, changeset} = call_record(cost_data, pubsub: pubsub)
      assert "can't be blank" in errors_on(changeset).agent_id
    end

    test "returns error for missing task_id", %{pubsub: pubsub} do
      cost_data = %{
        agent_id: "test_agent",
        cost_type: "llm_consensus"
      }

      assert {:error, changeset} = call_record(cost_data, pubsub: pubsub)
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "returns error for missing cost_type", %{task: task, pubsub: pubsub} do
      cost_data = %{
        agent_id: "test_agent",
        task_id: task.id
      }

      assert {:error, changeset} = call_record(cost_data, pubsub: pubsub)
      assert "can't be blank" in errors_on(changeset).cost_type
    end

    test "returns error for invalid cost_type", %{task: task, pubsub: pubsub} do
      cost_data = valid_cost_data(task.id, %{cost_type: "invalid_type"})

      assert {:error, changeset} = call_record(cost_data, pubsub: pubsub)
      assert "is invalid" in errors_on(changeset).cost_type
    end

    test "returns error for invalid task_id (foreign key)", %{pubsub: pubsub} do
      # Use a random UUID that doesn't exist
      fake_task_id = Ecto.UUID.generate()

      cost_data = valid_cost_data(fake_task_id)

      assert {:error, changeset} = call_record(cost_data, pubsub: pubsub)
      assert "does not exist" in errors_on(changeset).task_id
    end
  end

  # ============================================================
  # COST_Recorder: R3 - PubSub Broadcast to Task Topic [INTEGRATION]
  # ============================================================

  describe "record/2 - task topic broadcast" do
    test "broadcasts to task topic on record", %{task: task, pubsub: pubsub} do
      # Subscribe to task topic
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id)
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      # Verify we received the broadcast
      assert_receive {:cost_recorded, event}, 30_000
      assert event.task_id == task.id
    end

    test "task topic uses correct format", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id)
      {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.id == cost.id
    end
  end

  # ============================================================
  # COST_Recorder: R4 - PubSub Broadcast to Agent Topic [INTEGRATION]
  # ============================================================

  describe "record/2 - agent topic broadcast" do
    test "broadcasts to agent topic on record", %{task: task, pubsub: pubsub} do
      agent_id = "test_agent_#{System.unique_integer([:positive])}"

      # Subscribe to agent topic
      agent_topic = "agents:#{agent_id}:costs"
      Phoenix.PubSub.subscribe(pubsub, agent_topic)

      cost_data = valid_cost_data(task.id, %{agent_id: agent_id})
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      # Verify we received the broadcast
      assert_receive {:cost_recorded, event}, 30_000
      assert event.agent_id == agent_id
    end

    test "agent topic uses correct format", %{task: task, pubsub: pubsub} do
      agent_id = "broadcast_test_agent"
      agent_topic = "agents:#{agent_id}:costs"
      Phoenix.PubSub.subscribe(pubsub, agent_topic)

      cost_data = valid_cost_data(task.id, %{agent_id: agent_id})
      {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.id == cost.id
    end

    test "broadcasts to both task and agent topics simultaneously", %{task: task, pubsub: pubsub} do
      agent_id = "dual_broadcast_agent"

      # Subscribe to both topics
      task_topic = "tasks:#{task.id}:costs"
      agent_topic = "agents:#{agent_id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)
      Phoenix.PubSub.subscribe(pubsub, agent_topic)

      cost_data = valid_cost_data(task.id, %{agent_id: agent_id})
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      # Should receive on both topics
      assert_receive {:cost_recorded, task_event}, 30_000
      assert_receive {:cost_recorded, agent_event}, 30_000

      assert task_event.task_id == task.id
      assert agent_event.agent_id == agent_id
    end
  end

  # ============================================================
  # COST_Recorder: R5 - Broadcast Event Format [UNIT]
  # ============================================================

  describe "broadcast event format" do
    test "event has correct structure", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data =
        valid_cost_data(task.id, %{
          metadata: %{
            "model_spec" => "google-vertex/gemini-2.5-pro",
            "input_tokens" => 2000
          }
        })

      {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000

      # Verify all required fields in event
      assert Map.has_key?(event, :id)
      assert Map.has_key?(event, :agent_id)
      assert Map.has_key?(event, :task_id)
      assert Map.has_key?(event, :cost_type)
      assert Map.has_key?(event, :cost_usd)
      assert Map.has_key?(event, :model_spec)
      assert Map.has_key?(event, :timestamp)

      # Verify values
      assert event.id == cost.id
      assert event.agent_id == cost.agent_id
      assert event.task_id == cost.task_id
      assert event.cost_type == cost.cost_type
      assert event.model_spec == "google-vertex/gemini-2.5-pro"
      assert event.timestamp == cost.inserted_at
    end

    test "event includes nil cost_usd when cost is nil", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id, %{cost_usd: nil})
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_usd == nil
    end

    test "event extracts model_spec from metadata", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data =
        valid_cost_data(task.id, %{
          metadata: %{"model_spec" => "bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0"}
        })

      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.model_spec == "bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0"
    end

    test "event has nil model_spec when metadata is nil", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id, %{metadata: nil})
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.model_spec == nil
    end
  end

  # ============================================================
  # COST_Recorder: R6 - Nil Cost Handling [INTEGRATION]
  # ============================================================

  describe "nil cost handling" do
    test "records nil cost for unsupported models", %{task: task, pubsub: pubsub} do
      cost_data =
        valid_cost_data(task.id, %{
          cost_usd: nil,
          metadata: %{
            "model_spec" => "unsupported/model",
            "input_tokens" => 500
          }
        })

      assert {:ok, cost} = call_record(cost_data, pubsub: pubsub)
      assert cost.cost_usd == nil
      assert cost.metadata["model_spec"] == "unsupported/model"
    end

    test "persists nil cost to database", %{task: task, pubsub: pubsub} do
      cost_data = valid_cost_data(task.id, %{cost_usd: nil})

      {:ok, cost} = call_record(cost_data, pubsub: pubsub)

      fetched = Repo.get(@agent_cost_module, cost.id)
      assert fetched.cost_usd == nil
    end

    test "broadcasts nil cost correctly", %{task: task, pubsub: pubsub} do
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id, %{cost_usd: nil})
      {:ok, _cost} = call_record(cost_data, pubsub: pubsub)

      assert_receive {:cost_recorded, event}, 30_000
      assert event.cost_usd == nil
    end
  end

  # ============================================================
  # COST_Recorder: R7 - Silent Recording [INTEGRATION]
  # ============================================================

  describe "record_silent/1" do
    test "inserts cost without PubSub broadcast", %{task: task, pubsub: pubsub} do
      # Subscribe to both topics
      task_topic = "tasks:#{task.id}:costs"
      Phoenix.PubSub.subscribe(pubsub, task_topic)

      cost_data = valid_cost_data(task.id)
      assert {:ok, cost} = call_record_silent(cost_data)

      # Verify cost was inserted
      assert cost.id != nil
      fetched = Repo.get(@agent_cost_module, cost.id)
      assert fetched != nil

      # Verify NO broadcast was received
      refute_receive {:cost_recorded, _}, 100
    end

    test "returns same result structure as record/2", %{task: task} do
      cost_data = valid_cost_data(task.id)

      assert {:ok, cost} = call_record_silent(cost_data)
      assert cost.agent_id == cost_data.agent_id
      assert cost.task_id == task.id
      assert cost.cost_type == "llm_consensus"
    end

    test "returns error for invalid data", %{task: task} do
      cost_data = valid_cost_data(task.id, %{cost_type: "invalid"})

      assert {:error, changeset} = call_record_silent(cost_data)
      assert "is invalid" in errors_on(changeset).cost_type
    end
  end

  # ============================================================
  # COST_Recorder: R8 - Safe Broadcast [UNIT]
  # ============================================================

  describe "safe broadcast" do
    test "handles PubSub not running gracefully", %{task: task} do
      # Use a PubSub name that doesn't exist
      fake_pubsub = :"nonexistent_pubsub_#{System.unique_integer([:positive])}"

      cost_data = valid_cost_data(task.id)

      # Should not raise, should complete successfully
      assert {:ok, cost} = call_record(cost_data, pubsub: fake_pubsub)

      # Cost should still be inserted even if broadcast failed
      fetched = Repo.get(@agent_cost_module, cost.id)
      assert fetched != nil
    end

    test "database insert succeeds even when broadcast fails", %{task: task} do
      fake_pubsub = :"dead_pubsub_#{System.unique_integer([:positive])}"

      cost_data = valid_cost_data(task.id)
      {:ok, cost} = call_record(cost_data, pubsub: fake_pubsub)

      # Verify the cost was persisted despite broadcast failure
      assert Repo.get(@agent_cost_module, cost.id) != nil
    end
  end

  # ============================================================
  # COST_Recorder: R9 - Explicit PubSub Parameter [UNIT]
  # ============================================================

  describe "explicit pubsub parameter" do
    test "requires pubsub in opts", %{task: task} do
      cost_data = valid_cost_data(task.id)

      # Should raise KeyError when pubsub is not provided
      assert_raise KeyError, ~r/key :pubsub not found/, fn ->
        call_record(cost_data, [])
      end
    end

    test "raises when opts is empty list", %{task: task} do
      cost_data = valid_cost_data(task.id)

      assert_raise KeyError, fn ->
        call_record(cost_data, [])
      end
    end

    test "accepts pubsub when provided", %{task: task, pubsub: pubsub} do
      cost_data = valid_cost_data(task.id)

      # Should not raise
      assert {:ok, _cost} = call_record(cost_data, pubsub: pubsub)
    end
  end
end
