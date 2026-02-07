defmodule Quoracle.Agent.Core.PersistenceACETest do
  @moduledoc """
  Tests for ACE state persistence (context_lessons, model_states).

  Packet 1: PERSIST_ACEState - R1-R13
  WorkGroupID: fix-persistence-20251218-185708
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core.Persistence
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  import Test.IsolationHelpers

  # ========== SERIALIZATION (R1-R3) ==========

  describe "serialize_ace_state/1" do
    test "R1: serializes context_lessons with atom types to strings" do
      state = %{
        context_lessons: %{
          "model-1" => [
            %{type: :factual, content: "User prefers concise answers", confidence: 3},
            %{type: :behavioral, content: "Always confirm before actions", confidence: 1}
          ]
        },
        model_states: %{}
      }

      result = Persistence.serialize_ace_state(state)

      assert is_map(result)
      assert Map.has_key?(result, "context_lessons")

      lessons = result["context_lessons"]["model-1"]
      assert length(lessons) == 2

      [lesson1, lesson2] = lessons
      assert lesson1["type"] == "factual"
      assert lesson1["content"] == "User prefers concise answers"
      assert lesson1["confidence"] == 3

      assert lesson2["type"] == "behavioral"
      assert lesson2["content"] == "Always confirm before actions"
      assert lesson2["confidence"] == 1
    end

    test "R2: serializes model_states with DateTime to ISO8601" do
      timestamp = ~U[2025-01-15 10:30:00Z]

      state = %{
        context_lessons: %{},
        model_states: %{
          "model-1" => %{
            summary: "Agent is tracking a file refactoring task",
            updated_at: timestamp
          }
        }
      }

      result = Persistence.serialize_ace_state(state)

      assert is_map(result)
      assert Map.has_key?(result, "model_states")

      model_state = result["model_states"]["model-1"]
      assert model_state["summary"] == "Agent is tracking a file refactoring task"
      assert model_state["updated_at"] == "2025-01-15T10:30:00Z"
    end

    test "R3: handles nil context_lessons and model_states" do
      state = %{
        context_lessons: nil,
        model_states: nil
      }

      result = Persistence.serialize_ace_state(state)

      assert result["context_lessons"] == %{}
      assert result["model_states"] == %{}
    end

    test "R3: handles missing context_lessons and model_states keys" do
      state = %{}

      result = Persistence.serialize_ace_state(state)

      assert result["context_lessons"] == %{}
      assert result["model_states"] == %{}
    end
  end

  # ========== DESERIALIZATION (R4-R6) ==========

  describe "deserialize_ace_state/1" do
    test "R4: deserializes context_lessons with string types to atoms" do
      stored_data = %{
        "context_lessons" => %{
          "model-1" => [
            %{"type" => "factual", "content" => "Important fact", "confidence" => 5},
            %{"type" => "behavioral", "content" => "Key behavior", "confidence" => 2}
          ]
        },
        "model_states" => %{}
      }

      result = Persistence.deserialize_ace_state(stored_data)

      assert is_map(result)
      assert Map.has_key?(result, :context_lessons)

      lessons = result.context_lessons["model-1"]
      assert length(lessons) == 2

      [lesson1, lesson2] = lessons
      assert lesson1.type == :factual
      assert lesson1.content == "Important fact"
      assert lesson1.confidence == 5

      assert lesson2.type == :behavioral
      assert lesson2.content == "Key behavior"
      assert lesson2.confidence == 2
    end

    test "R5: deserializes model_states with ISO8601 to DateTime" do
      stored_data = %{
        "context_lessons" => %{},
        "model_states" => %{
          "model-1" => %{
            "summary" => "Working on API integration",
            "updated_at" => "2025-01-15T14:45:30Z"
          }
        }
      }

      result = Persistence.deserialize_ace_state(stored_data)

      assert is_map(result)
      assert Map.has_key?(result, :model_states)

      model_state = result.model_states["model-1"]
      assert model_state.summary == "Working on API integration"
      assert %DateTime{} = model_state.updated_at
      assert DateTime.to_iso8601(model_state.updated_at) == "2025-01-15T14:45:30Z"
    end

    test "R6: handles empty or nil stored state" do
      # v5.0: Now includes model_histories in restored ACE state
      expected = %{context_lessons: %{}, model_states: %{}, model_histories: %{}}

      # Empty map
      result1 = Persistence.deserialize_ace_state(%{})
      assert result1 == expected

      # Nil
      result2 = Persistence.deserialize_ace_state(nil)
      assert result2 == expected

      # Non-map
      result3 = Persistence.deserialize_ace_state("invalid")
      assert result3 == expected
    end

    test "R6: handles partial stored state" do
      # Only context_lessons
      result1 = Persistence.deserialize_ace_state(%{"context_lessons" => %{"m" => []}})
      assert result1.context_lessons == %{"m" => []}
      assert result1.model_states == %{}

      # Only model_states
      result2 = Persistence.deserialize_ace_state(%{"model_states" => %{"m" => nil}})
      assert result2.context_lessons == %{}
      assert result2.model_states == %{"m" => nil}
    end
  end

  # ========== ROUND-TRIP (R7-R8) ==========

  describe "round-trip serialization" do
    test "R7: round-trip serialization preserves all data" do
      original = %{
        context_lessons: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :factual, content: "User's codebase uses Elixir", confidence: 5},
            %{type: :behavioral, content: "Prefers functional patterns", confidence: 3}
          ],
          "azure-openai:gpt-4o" => [
            %{type: :factual, content: "Project uses Phoenix LiveView", confidence: 4}
          ]
        },
        model_states: %{
          "anthropic:claude-sonnet-4" => %{
            summary: "Refactoring authentication module",
            updated_at: ~U[2025-01-15 12:00:00Z]
          },
          "azure-openai:gpt-4o" => nil
        }
      }

      serialized = Persistence.serialize_ace_state(original)
      deserialized = Persistence.deserialize_ace_state(serialized)

      # Compare context_lessons
      assert length(Map.keys(deserialized.context_lessons)) ==
               length(Map.keys(original.context_lessons))

      for {model_id, lessons} <- original.context_lessons do
        restored_lessons = deserialized.context_lessons[model_id]
        assert length(restored_lessons) == length(lessons)

        for {orig_lesson, restored_lesson} <- Enum.zip(lessons, restored_lessons) do
          assert restored_lesson.type == orig_lesson.type
          assert restored_lesson.content == orig_lesson.content
          assert restored_lesson.confidence == orig_lesson.confidence
        end
      end

      # Compare model_states
      for {model_id, state_entry} <- original.model_states do
        restored_entry = deserialized.model_states[model_id]

        if state_entry == nil do
          assert restored_entry == nil
        else
          assert restored_entry.summary == state_entry.summary
          assert DateTime.compare(restored_entry.updated_at, state_entry.updated_at) == :eq
        end
      end
    end

    @tag :property
    test "R8: property - round-trip preserves arbitrary ACE states" do
      # Generate multiple test cases with different structures
      test_cases = [
        # Empty state
        %{context_lessons: %{}, model_states: %{}},
        # Single model, single lesson
        %{
          context_lessons: %{"m1" => [%{type: :factual, content: "c1", confidence: 1}]},
          model_states: %{"m1" => %{summary: "s1", updated_at: DateTime.utc_now()}}
        },
        # Multiple models, multiple lessons
        %{
          context_lessons: %{
            "m1" => [
              %{type: :factual, content: "f1", confidence: 1},
              %{type: :behavioral, content: "b1", confidence: 2}
            ],
            "m2" => [%{type: :factual, content: "f2", confidence: 3}]
          },
          model_states: %{
            "m1" => %{summary: "s1", updated_at: DateTime.utc_now()},
            "m2" => nil
          }
        },
        # Empty lessons list
        %{
          context_lessons: %{"m1" => []},
          model_states: %{}
        }
      ]

      for original <- test_cases do
        serialized = Persistence.serialize_ace_state(original)
        deserialized = Persistence.deserialize_ace_state(serialized)

        # Verify structure preserved
        assert Map.keys(deserialized.context_lessons) |> Enum.sort() ==
                 Map.keys(original.context_lessons) |> Enum.sort()

        assert Map.keys(deserialized.model_states) |> Enum.sort() ==
                 Map.keys(original.model_states) |> Enum.sort()
      end
    end
  end

  # ========== PERSISTENCE (R9-R11) ==========

  describe "persist_ace_state/1" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      # Create task and agent in DB
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      {:ok, agent} =
        Repo.insert(%AgentSchema{
          agent_id: "ace-persist-agent-#{System.unique_integer([:positive])}",
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil
        })

      [
        task_id: task.id,
        agent_id: agent.agent_id,
        deps: deps,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R9: persists ACE state to database", %{agent_id: agent_id, task_id: task_id} do
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        context_lessons: %{
          "model-1" => [%{type: :factual, content: "Learned fact", confidence: 2}]
        },
        model_states: %{
          "model-1" => %{summary: "Current state", updated_at: DateTime.utc_now()}
        }
      }

      # This should call TaskManager.update_agent_state
      assert :ok = Persistence.persist_ace_state(state)

      # Verify state saved in DB
      {:ok, updated_agent} = TaskManager.get_agent(agent_id)
      assert is_map(updated_agent.state)
      assert Map.has_key?(updated_agent.state, "context_lessons")
      assert Map.has_key?(updated_agent.state, "model_states")
    end

    test "R10: persists ACE state even in restoration mode", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # Note: restoration_mode only prevents initial persist_agent (INSERT).
      # persist_ace_state (UPDATE) should work regardless of restoration_mode
      # to allow restored agents to persist learned context.
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: true,
        context_lessons: %{"m1" => [%{type: :factual, content: "Test", confidence: 1}]},
        model_states: %{}
      }

      assert :ok = Persistence.persist_ace_state(state)

      # Verify ACE state WAS saved (restoration_mode doesn't block persist_ace_state)
      {:ok, agent} = TaskManager.get_agent(agent_id)
      assert Map.has_key?(agent.state, "context_lessons")
    end

    test "R10: skips persistence when task_id is nil" do
      state = %{
        agent_id: "no-task-agent",
        task_id: nil,
        restoration_mode: false,
        context_lessons: %{},
        model_states: %{}
      }

      # Should return :ok without attempting DB write
      assert :ok = Persistence.persist_ace_state(state)
    end

    @tag :integration
    test "R11: handles DB errors gracefully without crashing" do
      import ExUnit.CaptureLog

      state = %{
        agent_id: "nonexistent-agent-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        restoration_mode: false,
        context_lessons: %{},
        model_states: %{}
      }

      # Should log error but not crash - capture log to suppress output
      _log =
        capture_log(fn ->
          result = Persistence.persist_ace_state(state)
          assert result == :ok
        end)

      # Log may be empty or contain error - the key is that function returns :ok
    end
  end

  # ========== RESTORATION (R12-R13) ==========

  describe "restore_ace_state/1" do
    test "R12: restores ACE state from database agent" do
      db_agent = %{
        state: %{
          "context_lessons" => %{
            "model-1" => [
              %{"type" => "factual", "content" => "Restored lesson", "confidence" => 4}
            ]
          },
          "model_states" => %{
            "model-1" => %{"summary" => "Restored state", "updated_at" => "2025-01-15T10:00:00Z"}
          }
        }
      }

      result = Persistence.restore_ace_state(db_agent)

      assert is_map(result)
      assert Map.has_key?(result, :context_lessons)
      assert Map.has_key?(result, :model_states)

      # Verify lessons restored
      lessons = result.context_lessons["model-1"]
      assert length(lessons) == 1
      assert hd(lessons).type == :factual
      assert hd(lessons).content == "Restored lesson"

      # Verify state restored
      model_state = result.model_states["model-1"]
      assert model_state.summary == "Restored state"
      assert %DateTime{} = model_state.updated_at
    end

    test "R13: returns empty defaults for nil state" do
      db_agent = %{state: nil}

      result = Persistence.restore_ace_state(db_agent)

      # v5.0: Now includes model_histories in restored ACE state
      assert result == %{context_lessons: %{}, model_states: %{}, model_histories: %{}}
    end

    test "R13: returns empty defaults for empty state" do
      db_agent = %{state: %{}}

      result = Persistence.restore_ace_state(db_agent)

      # v5.0: Now includes model_histories in restored ACE state
      assert result == %{context_lessons: %{}, model_states: %{}, model_histories: %{}}
    end
  end
end
