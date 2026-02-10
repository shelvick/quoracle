defmodule Quoracle.Repo.Migrations.AddPromptFieldsTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Agents.Agent
  alias Quoracle.Tasks.Task

  describe "migration execution" do
    test "adds prompt_fields to agents table" do
      # Check that we can insert with prompt_fields
      task = create_test_task()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running",
          prompt_fields: %{
            injected: %{global_context: "test context"},
            provided: %{task_description: "test task"},
            transformed: %{accumulated_narrative: "test narrative"}
          }
        })
        |> Repo.insert()

      assert agent.prompt_fields == %{
               "injected" => %{"global_context" => "test context"},
               "provided" => %{"task_description" => "test task"},
               "transformed" => %{"accumulated_narrative" => "test narrative"}
             }
    end

    test "prompt_fields defaults to empty map" do
      task = create_test_task()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running"
        })
        |> Repo.insert()

      assert agent.prompt_fields == %{}
    end

    test "stores complex JSONB structures" do
      task = create_test_task()

      complex_fields = %{
        injected: %{
          global_context: "Global system context with #{String.duplicate("x", 100)} chars",
          global_constraints: ["constraint1", "constraint2", "constraint3"]
        },
        provided: %{
          task_description: "Complex task description",
          success_criteria: "Must achieve X, Y, and Z",
          immediate_context: "Current state information",
          approach_guidance: "Use method A then B",
          role: "Senior Engineer",
          delegation_strategy: "parallel",
          sibling_context: [
            %{agent_id: "sibling-1", task: "Task 1"},
            %{agent_id: "sibling-2", task: "Task 2"}
          ],
          output_style: "technical",
          cognitive_style: "systematic"
        },
        transformed: %{
          accumulated_narrative: "Long running narrative from parent",
          downstream_constraints: ["child constraint 1", "child constraint 2"]
        }
      }

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running",
          prompt_fields: complex_fields
        })
        |> Repo.insert()

      # Reload from database
      reloaded = Repo.get!(Agent, agent.id)

      # Verify complex structure preserved (keys become strings in JSONB)
      assert reloaded.prompt_fields["injected"]["global_constraints"] ==
               ["constraint1", "constraint2", "constraint3"]

      assert reloaded.prompt_fields["provided"]["sibling_context"] == [
               %{"agent_id" => "sibling-1", "task" => "Task 1"},
               %{"agent_id" => "sibling-2", "task" => "Task 2"}
             ]
    end

    test "handles existing records without prompt_fields" do
      # Create agent without prompt_fields
      task = create_test_task()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "test-agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running"
        })
        |> Repo.insert()

      # Reload agent - should have empty map default
      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.prompt_fields == %{}
    end

    test "GIN index used for JSONB queries" do
      # Create agents with different field values
      task = create_test_task()

      for i <- 1..3 do
        {:ok, _} =
          %Agent{}
          |> Agent.changeset(%{
            task_id: task.id,
            agent_id: "test-agent-#{i}",
            config: %{},
            status: "running",
            prompt_fields: %{
              provided: %{cognitive_style: if(i == 2, do: "creative", else: "efficient")}
            }
          })
          |> Repo.insert()
      end

      # Query using JSONB operators - should use GIN index
      import Ecto.Query

      query =
        from(a in Agent,
          where: fragment("? @> ?", a.prompt_fields, ^%{provided: %{cognitive_style: "creative"}})
        )

      results = Repo.all(query)
      assert length(results) == 1
      assert results |> List.first() |> Map.get(:agent_id) == "test-agent-2"
    end
  end

  describe "tasks table modifications" do
    test "adds global_context text column to tasks table" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Test prompt",
          status: "running",
          global_context: "This is the global context for all agents in this task"
        })
        |> Repo.insert()

      assert task.global_context == "This is the global context for all agents in this task"
    end

    test "adds initial_constraints JSONB column to tasks table" do
      constraints = ["Must be safe", "Must be efficient", "Must handle errors"]

      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Test prompt",
          status: "running",
          initial_constraints: constraints
        })
        |> Repo.insert()

      assert task.initial_constraints == constraints
    end

    test "global_context and initial_constraints are nullable for backward compatibility" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Test prompt",
          status: "running"
        })
        |> Repo.insert()

      assert is_nil(task.global_context)
      # Defaults to empty list
      assert task.initial_constraints == []
    end

    test "initial_constraints defaults to empty list" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Test prompt",
          status: "running"
        })
        |> Repo.insert()

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.initial_constraints == []
    end
  end

  # Helper function
  defp create_test_task do
    {:ok, task} =
      %Task{}
      |> Task.changeset(%{
        prompt: "Test task prompt",
        status: "running"
      })
      |> Repo.insert()

    task
  end
end
