defmodule Quoracle.Agents.AgentPromptFieldsTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Repo
  alias Quoracle.Agents.Agent
  alias Quoracle.Tasks.Task

  describe "prompt_fields integration with agents table" do
    setup do
      # Create a test task
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          prompt: "Test task",
          status: "running"
        })
        |> Repo.insert()

      %{task: task}
    end

    test "agent stores prompt_fields correctly", %{task: task} do
      prompt_fields = %{
        injected: %{
          global_context: "System-wide context"
        },
        provided: %{
          task_description: "Analyze data",
          success_criteria: "Find patterns",
          immediate_context: "CSV file uploaded",
          approach_guidance: "Use statistical methods"
        },
        transformed: %{
          accumulated_narrative: "Parent found initial correlations",
          constraints: ["Safety first", "Be helpful", "Focus on outliers"]
        }
      }

      {:ok, agent} =
        %Agent{}
        |> Agent.prompt_fields_changeset(%{
          task_id: task.id,
          agent_id: "agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running",
          prompt_fields: prompt_fields
        })
        |> Repo.insert()

      # Reload and verify
      reloaded = Repo.get!(Agent, agent.id)

      assert reloaded.prompt_fields["injected"]["global_context"] == "System-wide context"
      assert reloaded.prompt_fields["provided"]["task_description"] == "Analyze data"

      assert reloaded.prompt_fields["transformed"]["accumulated_narrative"] ==
               "Parent found initial correlations"
    end

    test "agent prompt_fields defaults to empty map", %{task: task} do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "agent-#{System.unique_integer([:positive])}",
          config: %{},
          status: "running"
        })
        |> Repo.insert()

      assert agent.prompt_fields == %{}
    end

    test "update_prompt_fields_changeset updates only prompt_fields", %{task: task} do
      # Create agent with initial fields
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "agent-#{System.unique_integer([:positive])}",
          config: %{models: ["gpt-4"]},
          status: "running",
          prompt_fields: %{provided: %{task_description: "Initial task"}}
        })
        |> Repo.insert()

      # Update prompt_fields
      updated_fields = %{
        injected: %{global_context: "New context"},
        provided: %{task_description: "Updated task"},
        transformed: %{accumulated_narrative: "New narrative"}
      }

      {:ok, updated_agent} =
        agent
        |> Agent.update_prompt_fields_changeset(updated_fields)
        |> Repo.update()

      # Verify update
      assert updated_agent.prompt_fields["provided"]["task_description"] == "Updated task"
      assert updated_agent.prompt_fields["injected"]["global_context"] == "New context"
      # Config should remain unchanged (note: config uses :map type, keeps atom keys)
      assert updated_agent.config == %{models: ["gpt-4"]}
    end

    test "query agents by prompt_field values using JSONB operators", %{task: task} do
      # Create agents with different cognitive styles
      agents_data = [
        {"agent-1", "efficient"},
        {"agent-2", "creative"},
        {"agent-3", "efficient"},
        {"agent-4", "systematic"}
      ]

      for {agent_id, style} <- agents_data do
        {:ok, _} =
          %Agent{}
          |> Agent.changeset(%{
            task_id: task.id,
            agent_id: agent_id,
            config: %{},
            status: "running",
            prompt_fields: %{
              provided: %{cognitive_style: style}
            }
          })
          |> Repo.insert()
      end

      # Query for creative cognitive style
      import Ecto.Query

      creative_query =
        from(a in Agent,
          where:
            fragment("? @> ?", a.prompt_fields, ^%{provided: %{cognitive_style: "creative"}}),
          select: a.agent_id
        )

      creative_agents = Repo.all(creative_query)
      assert creative_agents == ["agent-2"]

      # Query for efficient cognitive style
      efficient_query =
        from(a in Agent,
          where:
            fragment("? @> ?", a.prompt_fields, ^%{provided: %{cognitive_style: "efficient"}}),
          order_by: a.agent_id,
          select: a.agent_id
        )

      efficient_agents = Repo.all(efficient_query)
      assert efficient_agents == ["agent-1", "agent-3"]
    end

    test "query agents with complex nested field conditions", %{task: task} do
      # Create agents with sibling context
      {:ok, _} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "parent-agent",
          config: %{},
          status: "running",
          prompt_fields: %{
            provided: %{
              sibling_context: [
                %{agent_id: "sibling-1", task: "Process data"},
                %{agent_id: "sibling-2", task: "Generate report"}
              ]
            }
          }
        })
        |> Repo.insert()

      {:ok, _} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "other-agent",
          config: %{},
          status: "running",
          prompt_fields: %{
            provided: %{
              sibling_context: []
            }
          }
        })
        |> Repo.insert()

      # Query for agents that have sibling context containing specific agent
      import Ecto.Query

      query =
        from(a in Agent,
          where:
            fragment(
              "? -> 'provided' -> 'sibling_context' @> ?",
              a.prompt_fields,
              ^[%{agent_id: "sibling-1"}]
            ),
          select: a.agent_id
        )

      results = Repo.all(query)
      assert results == ["parent-agent"]
    end

    test "prompt_fields survive serialization and deserialization", %{task: task} do
      complex_fields = %{
        injected: %{
          global_context: "Context with special chars: \n\t'\"{}\[]"
        },
        provided: %{
          task_description: "Task with\nmultiple\nlines",
          success_criteria: "JSON special: {\"key\": \"value\"}",
          cognitive_style: "creative",
          delegation_strategy: "parallel",
          sibling_context: [
            %{agent_id: "agent-α", task: "Greek letters: αβγδ"},
            %{agent_id: "agent-emoji", task: "Emojis: 🎯🎨🔧"}
          ]
        },
        transformed: %{
          accumulated_narrative: "Very long " <> String.duplicate("narrative ", 40),
          constraints:
            ["Constraint with 'quotes'", "Unicode: 🚀"] ++ Enum.map(1..10, &"Constraint #{&1}")
        }
      }

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "complex-agent",
          config: %{},
          status: "running",
          prompt_fields: complex_fields
        })
        |> Repo.insert()

      # Reload from database
      reloaded = Repo.get!(Agent, agent.id)

      # Verify all complex data preserved
      assert reloaded.prompt_fields["injected"]["global_context"] =~ "special chars"
      assert reloaded.prompt_fields["transformed"]["constraints"] |> Enum.any?(&(&1 =~ "🚀"))
      assert reloaded.prompt_fields["provided"]["task_description"] =~ "\n"
      assert length(reloaded.prompt_fields["provided"]["sibling_context"]) == 2
      assert reloaded.prompt_fields["transformed"]["constraints"] |> length() == 12
    end
  end

  describe "Agent.Queries with prompt_fields" do
    setup do
      {:ok, task} =
        %Task{}
        |> Task.changeset(%{prompt: "Test", status: "running"})
        |> Repo.insert()

      %{task: task}
    end

    test "query agents by specific field category", %{task: task} do
      # Create agents with different field structures
      {:ok, _} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "with-global",
          config: %{},
          status: "running",
          prompt_fields: %{
            injected: %{global_context: "Has global context"}
          }
        })
        |> Repo.insert()

      {:ok, _} =
        %Agent{}
        |> Agent.changeset(%{
          task_id: task.id,
          agent_id: "without-global",
          config: %{},
          status: "running",
          prompt_fields: %{
            provided: %{task_description: "Just a task"}
          }
        })
        |> Repo.insert()

      # Query for agents with injected fields
      import Ecto.Query

      with_injected =
        from(a in Agent,
          where: fragment("? \\? 'injected'", a.prompt_fields),
          select: a.agent_id
        )

      results = Repo.all(with_injected)
      assert results == ["with-global"]
    end

    test "index performance for prompt_fields queries", %{task: task} do
      # Create many agents to test index usage
      for i <- 1..100 do
        style =
          Enum.random(["efficient", "creative", "systematic", "exploratory", "problem_solving"])

        {:ok, _} =
          %Agent{}
          |> Agent.changeset(%{
            task_id: task.id,
            agent_id: "agent-#{i}",
            config: %{},
            status: "running",
            prompt_fields: %{
              provided: %{
                cognitive_style: style,
                task_description: "Task #{i}"
              }
            }
          })
          |> Repo.insert()
      end

      # Query should use GIN index for JSONB containment
      import Ecto.Query

      indexed_query =
        from(a in Agent,
          where:
            fragment("? @> ?", a.prompt_fields, ^%{provided: %{cognitive_style: "creative"}}),
          select: count(a.id)
        )

      count = Repo.one!(indexed_query)
      assert count > 0
    end
  end
end
