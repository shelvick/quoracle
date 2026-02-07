defmodule Quoracle.Agent.Consensus.PerModelQueryACETest do
  @moduledoc """
  Tests for ACE state persistence after condensation in PerModelQuery.

  Packet 1: AGENT_Consensus v9.0 - R38-R42
  WorkGroupID: fix-persistence-20251218-185708
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Hammox

  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  # Ensure Hammox mocks are verified
  setup :verify_on_exit!

  # ========== CONDENSATION PERSISTENCE (R38-R42) ==========

  describe "condense_model_history_with_reflection/3 - ACE persistence" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      agent_id = "condense-ace-agent-#{System.unique_integer([:positive])}"

      # Create agent record in DB
      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [
        task_id: task.id,
        agent_id: agent_id,
        deps: deps,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R38: persists ACE state after condensation completes", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"

      # Build state with history that needs condensation
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{
          model_id => build_large_history(20)
        },
        context_lessons: %{},
        model_states: %{}
      }

      # Mock Reflector to return lessons
      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [%{type: :factual, content: "Condensation lesson", confidence: 2}],
             state: [%{summary: "Post-condensation state", updated_at: DateTime.utc_now()}]
           }}
        end,
        test_mode: true
      ]

      # Perform condensation
      result_state = PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)

      # Verify ACE state was updated in result
      assert result_state.context_lessons[model_id] != []
      assert result_state.model_states[model_id] != nil

      # Verify ACE state was persisted to database
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
      assert Map.has_key?(db_agent.state, "context_lessons")
      assert Map.has_key?(db_agent.state, "model_states")
    end

    @tag :integration
    test "R39: persists newly accumulated lessons after reflection success", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "azure-openai:gpt-4o"

      # State with existing lessons
      existing_lessons = [%{type: :factual, content: "Existing lesson", confidence: 3}]

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{
          model_id => build_large_history(15)
        },
        context_lessons: %{model_id => existing_lessons},
        model_states: %{}
      }

      # Mock Reflector to return new lessons
      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [%{type: :behavioral, content: "New behavioral lesson", confidence: 1}],
             state: []
           }}
        end,
        test_mode: true
      ]

      result_state = PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)

      # Verify lessons accumulated
      lessons = result_state.context_lessons[model_id]
      assert length(lessons) >= 2
      assert Enum.any?(lessons, &(&1.content == "Existing lesson"))
      assert Enum.any?(lessons, &(&1.content == "New behavioral lesson"))

      # Verify persisted to DB
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      db_lessons = db_agent.state["context_lessons"][model_id]
      assert length(db_lessons) >= 2
    end

    @tag :integration
    test "R40: persists ACE state even when Reflector fails", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "google:gemini-2.0-flash"

      # State with existing ACE data
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{
          model_id => build_large_history(10)
        },
        context_lessons: %{
          model_id => [%{type: :factual, content: "Pre-existing", confidence: 5}]
        },
        model_states: %{model_id => %{summary: "Previous state", updated_at: DateTime.utc_now()}}
      }

      # Mock Reflector to fail
      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:error, :reflection_failed}
        end,
        test_mode: true
      ]

      log =
        capture_log(fn ->
          result_state =
            PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)

          # Condensation should still complete
          assert is_map(result_state.model_histories)

          # Existing ACE state should be preserved
          assert result_state.context_lessons[model_id] == state.context_lessons[model_id]
        end)

      # May log warning about reflection failure
      assert is_binary(log)

      # Existing ACE state should still be persisted
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
    end

    test "R41: condensation succeeds even if persistence fails", %{task_id: _task_id} do
      # Use non-existent agent to trigger persistence failure
      model_id = "test-model"

      state = %{
        agent_id: "nonexistent-agent-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        restoration_mode: false,
        model_histories: %{
          model_id => build_large_history(10)
        },
        context_lessons: %{},
        model_states: %{}
      }

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      log =
        capture_log(fn ->
          # Condensation should complete without crashing
          result_state =
            PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)

          # History should be condensed
          assert is_map(result_state.model_histories)
          assert length(result_state.model_histories[model_id]) < 10
        end)

      # May log persistence error
      assert is_binary(log)
    end

    test "R42: persists ACE state during restoration mode condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # Note: restoration_mode only prevents initial persist_agent (INSERT).
      # Condensation should still persist ACE state (UPDATE) to preserve learned context.
      model_id = "test-model"

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: true,
        model_histories: %{
          model_id => build_large_history(10)
        },
        context_lessons: %{},
        model_states: %{}
      }

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [%{type: :factual, content: "Should persist", confidence: 1}],
             state: []
           }}
        end,
        test_mode: true
      ]

      result_state = PerModelQuery.condense_model_history_with_reflection(state, model_id, opts)

      # Condensation should complete
      assert is_map(result_state)
      assert result_state.context_lessons[model_id] != []

      # DB SHOULD be updated (restoration_mode doesn't block persist_ace_state)
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert Map.has_key?(db_agent.state, "context_lessons")
    end
  end

  # ========== HELPERS ==========

  # Build a large history that would trigger condensation
  defp build_large_history(count) do
    Enum.map(1..count, fn i ->
      %{
        type: :event,
        content: "Message #{i} with some content to take up tokens",
        timestamp: DateTime.utc_now()
      }
    end)
  end
end
