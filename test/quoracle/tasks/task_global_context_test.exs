defmodule Quoracle.Tasks.TaskGlobalContextTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent

  describe "global_context and initial_constraints fields" do
    setup do
      :ok
    end

    test "task stores global_context text field" do
      global_context = """
      You are operating in a secure enterprise environment.
      All actions must be logged and auditable.
      Prioritize data privacy and security in all operations.
      """

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Analyze customer data",
          status: "running",
          global_context: global_context
        })
        |> Repo.insert()

      assert task.global_context == global_context

      # Reload to verify persistence
      reloaded = Repo.get!(Task, task.id)
      assert reloaded.global_context == global_context
    end

    test "task stores initial_constraints as JSONB array" do
      constraints = [
        "Do not access external APIs without permission",
        "All generated content must be factually accurate",
        "Maintain professional tone in all communications",
        "Complete within 10 minutes"
      ]

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Write a report",
          status: "running",
          initial_constraints: constraints
        })
        |> Repo.insert()

      assert task.initial_constraints == constraints
      assert length(task.initial_constraints) == 4
    end

    test "global_context can be null for backward compatibility" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Legacy task without global context",
          status: "running"
        })
        |> Repo.insert()

      assert is_nil(task.global_context)
    end

    test "initial_constraints defaults to empty array" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Task without constraints",
          status: "running"
        })
        |> Repo.insert()

      assert task.initial_constraints == []
    end

    test "update global_context independently" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Initial task",
          status: "running"
        })
        |> Repo.insert()

      # Update only global_context
      {:ok, updated} =
        task
        |> Task.update_global_context_changeset("New global context")
        |> Repo.update()

      assert updated.global_context == "New global context"
      # Unchanged
      assert updated.prompt == "Initial task"
    end

    test "update initial_constraints independently" do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Initial task",
          status: "running",
          initial_constraints: ["Old constraint"]
        })
        |> Repo.insert()

      # Update only constraints
      new_constraints = ["New constraint 1", "New constraint 2"]

      {:ok, updated} =
        task
        |> Task.update_constraints_changeset(new_constraints)
        |> Repo.update()

      assert updated.initial_constraints == new_constraints
      # Unchanged
      assert updated.prompt == "Initial task"
    end

    test "global_context supports very long text" do
      # Create a very long context (>2000 chars)
      long_context = String.duplicate("This is a long context. ", 100)
      assert String.length(long_context) > 2000

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Task with long context",
          status: "running",
          global_context: long_context
        })
        |> Repo.insert()

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.global_context == long_context
    end

    test "initial_constraints preserves order" do
      constraints = [
        "First: Do this first",
        "Second: Then do this",
        "Third: Finally this",
        "Fourth: And cleanup"
      ]

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Ordered task",
          status: "running",
          initial_constraints: constraints
        })
        |> Repo.insert()

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.initial_constraints == constraints
      assert Enum.at(reloaded.initial_constraints, 0) =~ "First"
      assert Enum.at(reloaded.initial_constraints, 3) =~ "Fourth"
    end

    test "constraints support special characters and unicode" do
      constraints = [
        "Handle JSON: {\"key\": \"value\"}",
        "Support quotes: 'single' and \"double\"",
        "Unicode emoji: 🚀 🎯 ✅",
        "Special chars: \n\t<>&"
      ]

      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Unicode task",
          status: "running",
          initial_constraints: constraints
        })
        |> Repo.insert()

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.initial_constraints == constraints
      assert Enum.at(reloaded.initial_constraints, 2) =~ "🚀"
    end

    test "query tasks by presence of global_context" do
      # Create tasks with and without global context
      {:ok, with_context} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Task with context",
          status: "running",
          global_context: "Some context"
        })
        |> Repo.insert()

      {:ok, without_context} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Task without context",
          status: "running"
        })
        |> Repo.insert()

      # Query for tasks with global_context
      import Ecto.Query

      query =
        from(t in Task,
          where: not is_nil(t.global_context),
          select: t.id
        )

      results = Repo.all(query)
      assert with_context.id in results
      refute without_context.id in results
    end

    test "query tasks by constraint content" do
      # Create tasks with different constraints
      {:ok, security_task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Security task",
          status: "running",
          initial_constraints: ["Enable encryption", "Use secure protocols"]
        })
        |> Repo.insert()

      {:ok, performance_task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Performance task",
          status: "running",
          initial_constraints: ["Optimize for speed", "Use caching"]
        })
        |> Repo.insert()

      # Query for tasks with security-related constraints
      import Ecto.Query

      query =
        from(t in Task,
          where:
            fragment(
              "? @> ?",
              t.initial_constraints,
              ^["Enable encryption"]
            ),
          select: t.id
        )

      results = Repo.all(query)
      assert security_task.id in results
      refute performance_task.id in results
    end
  end

  describe "integration with agents" do
    setup do
      :ok
    end

    test "agents can reference task's global_context" do
      # Create task with global context
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Main task",
          status: "running",
          global_context: "Shared context for all agents",
          initial_constraints: ["Be efficient", "Be accurate"]
        })
        |> Repo.insert()

      # Create agent that will use task's global context
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "agent-1",
          config: %{},
          status: "running",
          prompt_fields: %{
            injected: %{
              global_context: "Will be fetched from task",
              # Will be populated from task.initial_constraints
              global_constraints: []
            }
          }
        })
        |> Repo.insert()

      # Simulate fetching task's global context for agent
      agent_with_task = Repo.preload(agent, :task)
      assert agent_with_task.task.global_context == "Shared context for all agents"
      assert agent_with_task.task.initial_constraints == ["Be efficient", "Be accurate"]
    end

    test "multiple agents share same task global_context" do
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Multi-agent task",
          status: "running",
          global_context: "Context shared by all agents",
          initial_constraints: ["Constraint 1", "Constraint 2"]
        })
        |> Repo.insert()

      # Create multiple agents
      agent_ids =
        for i <- 1..3 do
          {:ok, agent} =
            %Agent{}
            |> Agent.changeset(%{
              task_id: task.id,
              agent_id: "agent-#{i}",
              config: %{},
              status: "running"
            })
            |> Repo.insert()

          agent.id
        end

      # All agents share the same task context
      agents = Repo.all(from(a in Agent, where: a.id in ^agent_ids, preload: :task))

      for agent <- agents do
        assert agent.task.global_context == "Context shared by all agents"
        assert agent.task.initial_constraints == ["Constraint 1", "Constraint 2"]
      end
    end

    test "task deletion cascades to agents (existing behavior preserved)" do
      {:ok, task} =
        %Task{}
        |> Task.global_context_changeset(%{
          prompt: "Task to delete",
          status: "running",
          global_context: "Will be deleted"
        })
        |> Repo.insert()

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "doomed-agent",
          config: %{},
          status: "running"
        })
        |> Repo.insert()

      # Delete task
      Repo.delete!(task)

      # Agent should be deleted due to CASCADE
      assert is_nil(Repo.get(Agent, agent.id))
    end
  end

  describe "Task.Queries extensions" do
    setup do
      :ok
    end

    test "query tasks with non-empty constraints" do
      # Create tasks with varying constraints
      {:ok, _} =
        Repo.insert(
          %Task{}
          |> Task.changeset(%{
            prompt: "No constraints",
            status: "running"
          })
        )

      {:ok, _} =
        Repo.insert(
          %Task{}
          |> Task.global_context_changeset(%{
            prompt: "With constraints",
            status: "running",
            initial_constraints: ["C1", "C2"]
          })
        )

      import Ecto.Query

      with_constraints =
        from(t in Task,
          where: fragment("jsonb_array_length(?) > 0", t.initial_constraints),
          select: t.prompt
        )

      results = Repo.all(with_constraints)
      assert "With constraints" in results
      refute "No constraints" in results
    end

    test "count constraints across all tasks" do
      # Create tasks with different numbers of constraints
      for {prompt, constraints} <- [
            {"Task 1", ["A", "B", "C"]},
            {"Task 2", ["D", "E"]},
            {"Task 3", []}
          ] do
        {:ok, _} =
          Repo.insert(
            %Task{}
            |> Task.global_context_changeset(%{
              prompt: prompt,
              status: "running",
              initial_constraints: constraints
            })
          )
      end

      import Ecto.Query

      total_constraints =
        from(t in Task,
          select: fragment("sum(jsonb_array_length(?))", t.initial_constraints)
        )

      count = Repo.one!(total_constraints)
      # 3 + 2 + 0
      assert count == 5
    end
  end
end
