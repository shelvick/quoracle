defmodule Quoracle.Actions.SpawnFieldIntegrationTest do
  @moduledoc """
  Tests for ACTION_Spawn field system integration (v3.0).
  Tests all field-based parameter handling and propagation.
  """

  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers

  import Test.AgentTestHelpers,
    only: [
      create_test_profile: 0,
      spawn_agent_with_cleanup: 3,
      register_agent_cleanup: 2
    ]

  alias Quoracle.Actions.Spawn
  alias Quoracle.Agent.Core
  alias Quoracle.Repo

  # Helper to wait for background spawn to complete (async pattern v5.0)
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, {:ok, child_pid}} -> child_pid
      {:spawn_complete, ^child_id, {:error, _reason}} -> nil
    after
      timeout -> nil
    end
  end

  describe "field-based parameter handling" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      task = create_test_task()

      # Start parent agent
      config = %{
        agent_id: "parent-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: nil,
        parent_pid: nil,
        prompt: "Parent agent task",
        models: ["google_gemini_2_5_flash"],
        sandbox_owner: sandbox_owner,
        prompt_fields: %{
          transformed: %{
            accumulated_narrative: "Parent has been working on analysis",
            constraints: ["Be thorough", "Document everything"]
          }
        },
        test_mode: true,
        skip_auto_consensus: true,
        registry: deps.registry,
        pubsub: deps.pubsub
      }

      # Use spawn_agent_with_cleanup to register cleanup atomically (prevents race window)
      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Test process is notified when spawn completes (async pattern)
      test_pid = self()

      %{
        deps: deps,
        task: task,
        parent_pid: parent_pid,
        parent_id: config.agent_id,
        sandbox_owner: sandbox_owner,
        opts: [
          agent_pid: parent_pid,
          task_id: task.id,
          sandbox_owner: sandbox_owner,
          registry: deps.registry,
          pubsub: deps.pubsub,
          dynsup: deps.dynsup,
          test_mode: true,
          # Required by ConfigBuilder to prevent GenServer deadlock
          parent_config: config,
          # For async spawn notification
          spawn_complete_notify: test_pid
        ],
        profile: create_test_profile()
      }
    end

    # R1: Field extraction and validation
    test "extracts required fields from spawn parameters", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Research competitive pricing",
          "success_criteria" => "Identify top 5 competitors with pricing models",
          "immediate_context" => "Product is SaaS analytics tool, B2B market",
          "approach_guidance" => "Focus on direct competitors, ignore adjacent markets",
          "profile" => profile.name
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      # Verify child was spawned
      assert is_binary(result.agent_id)

      # Get child's config to verify fields were extracted
      {:ok, child_state} = Core.get_state(child_pid)

      assert child_state.prompt_fields.provided.task_description ==
               "Research competitive pricing"

      assert child_state.prompt_fields.provided.success_criteria ==
               "Identify top 5 competitors with pricing models"

      assert child_state.prompt_fields.provided.immediate_context ==
               "Product is SaaS analytics tool, B2B market"

      assert child_state.prompt_fields.provided.approach_guidance ==
               "Focus on direct competitors, ignore adjacent markets"
    end

    # R2: Missing required fields
    test "returns error when required fields are missing", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          # Missing task_description and success_criteria
          "immediate_context" => "Some context",
          "approach_guidance" => "Some guidance",
          "profile" => profile.name
        }
      }

      assert {:error, {:missing_required_fields, missing}} =
               Spawn.execute(params["params"], parent_id, opts)

      assert :task_description in missing
      assert :success_criteria in missing
    end

    # R3: Optional fields handling
    test "accepts optional fields", %{parent_id: parent_id, opts: opts, profile: profile} do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Research task",
          "success_criteria" => "Complete research",
          "immediate_context" => "Research context",
          "approach_guidance" => "Research systematically",
          "profile" => profile.name,
          "role" => "Research Analyst",
          "cognitive_style" => "systematic",
          "output_style" => "technical",
          "delegation_strategy" => "parallel",
          "sibling_context" => [
            %{"agent_id" => "sibling-1", "task" => "Related task 1"}
          ],
          "downstream_constraints" => "Stay focused and be accurate"
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      provided_fields = child_state.prompt_fields.provided

      assert provided_fields.role == "Research Analyst"
      assert provided_fields.cognitive_style == "systematic"
      assert provided_fields.output_style == "technical"
      assert provided_fields.delegation_strategy == "parallel"
      assert length(provided_fields.sibling_context) == 1
      assert provided_fields.downstream_constraints == "Stay focused and be accurate"
    end

    # R4: Field transformation and propagation
    test "transforms fields for child propagation", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Subtask for testing",
          "success_criteria" => "Complete subtask",
          "immediate_context" => "Working on child task now",
          "approach_guidance" => "Follow parent's methodology",
          "profile" => profile.name,
          "downstream_constraints" => "New constraint from spawn"
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      transformed = child_state.prompt_fields.transformed

      # Should accumulate narrative from parent
      assert transformed.accumulated_narrative =~ "Parent has been working"
      assert transformed.accumulated_narrative =~ "child task"

      # Should merge constraints
      assert "Be thorough" in transformed.constraints
      assert "Document everything" in transformed.constraints
      assert "New constraint from spawn" in transformed.constraints
    end

    # R5: Global context injection
    test "injects global context from task", %{
      parent_id: parent_id,
      task: task,
      opts: opts,
      profile: profile
    } do
      # Update task with global context
      {:ok, _updated_task} =
        task
        |> Quoracle.Tasks.Task.global_context_changeset(%{
          global_context: "System-wide context for all agents",
          initial_constraints: ["Never delete data", "Always log actions"]
        })
        |> Repo.update()

      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test global injection",
          "success_criteria" => "Verify global fields",
          "immediate_context" => "Testing context",
          "approach_guidance" => "Test thoroughly",
          "profile" => profile.name
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      injected = child_state.prompt_fields.injected

      assert injected.global_context == "System-wide context for all agents"
      assert "Never delete data" in injected.constraints
      assert "Always log actions" in injected.constraints
    end

    # R6: Prompt building from fields
    test "builds prompts from extracted fields", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Build prompts test",
          "success_criteria" => "Verify prompt structure",
          "immediate_context" => "Testing prompt generation",
          "approach_guidance" => "Check all components",
          "profile" => profile.name,
          "role" => "Prompt Tester",
          "cognitive_style" => "systematic"
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)

      # Verify prompts were built and stored
      assert is_binary(child_state.system_prompt)

      # System prompt should contain role and cognitive style
      assert child_state.system_prompt =~ "Prompt Tester"
      assert child_state.system_prompt =~ "SYSTEMATIC"

      # Task fields now flow through prompt_fields, not user_prompt
      assert child_state.prompt_fields.provided.task_description == "Build prompts test"
      assert child_state.prompt_fields.provided.success_criteria == "Verify prompt structure"
    end

    # R8: Invalid field types
    test "validates field types during extraction", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Valid task",
          "success_criteria" => "Valid criteria",
          "immediate_context" => "Valid context",
          "approach_guidance" => "Valid guidance",
          "profile" => profile.name,
          # Invalid enum value
          "cognitive_style" => "invalid_style"
        }
      }

      assert {:error, reason} = Spawn.execute(params["params"], parent_id, opts)
      assert is_binary(reason) and reason =~ ~r/cognitive_style|validation/i
    end

    # R9: Sibling context propagation
    test "propagates sibling context to child", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      # First spawn a sibling
      sibling_params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "First sibling task",
          "success_criteria" => "Complete first task",
          "immediate_context" => "First context",
          "approach_guidance" => "First guidance",
          "profile" => profile.name
        }
      }

      {:ok, sibling} = Spawn.execute(sibling_params["params"], parent_id, opts)
      sibling_pid = wait_for_spawn_complete(sibling.agent_id)
      register_agent_cleanup(sibling_pid, cleanup_tree: true, registry: opts[:registry])

      # Now spawn second child with sibling context
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Second sibling task",
          "success_criteria" => "Complete second task",
          "immediate_context" => "Second context",
          "approach_guidance" => "Second guidance",
          "profile" => profile.name,
          "sibling_context" => [
            %{"agent_id" => sibling.agent_id, "task" => "First sibling task"}
          ]
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      sibling_context = child_state.prompt_fields.provided.sibling_context

      assert length(sibling_context) == 1
      assert hd(sibling_context).agent_id == sibling.agent_id
      assert hd(sibling_context).task == "First sibling task"
    end

    # R10: Complex nested field structures
    test "handles complex nested field structures", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Complex nested test",
          "success_criteria" => "Handle all nesting levels",
          "immediate_context" => "Testing complex structures",
          "approach_guidance" => "Verify deep nesting",
          "profile" => profile.name,
          "sibling_context" => [
            %{"agent_id" => "s1", "task" => "Task 1"},
            %{"agent_id" => "s2", "task" => "Task 2"},
            %{"agent_id" => "s3", "task" => "Task 3"}
          ],
          "constraints" => [
            "Constraint 1",
            "Constraint 2",
            "Constraint 3"
          ]
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      provided = child_state.prompt_fields.provided

      assert length(provided.sibling_context) == 3
      assert length(provided.constraints) == 3
    end
  end

  describe "field validation" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      task = create_test_task()

      config = %{
        agent_id: "parent-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: nil,
        parent_pid: nil,
        prompt: "Parent agent",
        models: ["google_gemini_2_5_flash"],
        sandbox_owner: sandbox_owner,
        test_mode: true,
        skip_auto_consensus: true,
        registry: deps.registry,
        pubsub: deps.pubsub
      }

      # Use spawn_agent_with_cleanup to register cleanup atomically (prevents race window)
      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      test_pid = self()

      %{
        deps: deps,
        task: task,
        parent_pid: parent_pid,
        parent_id: config.agent_id,
        sandbox_owner: sandbox_owner,
        opts: [
          agent_pid: parent_pid,
          task_id: task.id,
          sandbox_owner: sandbox_owner,
          registry: deps.registry,
          pubsub: deps.pubsub,
          dynsup: deps.dynsup,
          test_mode: true,
          # Required by ConfigBuilder to prevent GenServer deadlock
          parent_config: config,
          spawn_complete_notify: test_pid
        ],
        profile: create_test_profile()
      }
    end

    test "accepts strings of any length", %{
      parent_id: parent_id,
      opts: opts,
      deps: deps,
      profile: profile
    } do
      # No length limits on string fields
      long_string = String.duplicate("a", 5000)

      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => long_string,
          "success_criteria" => "Valid",
          "immediate_context" => "Valid",
          "approach_guidance" => "Valid",
          "profile" => profile.name
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: deps.registry)
    end

    test "validates enum values", %{parent_id: parent_id, opts: opts, profile: profile} do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test",
          "success_criteria" => "Test",
          "immediate_context" => "Test",
          "approach_guidance" => "Test",
          "profile" => profile.name,
          # Not in [:sequential, :parallel, :none]
          "delegation_strategy" => "invalid_strategy"
        }
      }

      assert {:error, reason} = Spawn.execute(params["params"], parent_id, opts)
      assert is_binary(reason) and reason =~ ~r/delegation_strategy|validation/i
    end

    test "validates sibling_context structure", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test",
          "success_criteria" => "Test",
          "immediate_context" => "Test",
          "approach_guidance" => "Test",
          "profile" => profile.name,
          "sibling_context" => [
            # Missing required "task" field
            %{"agent_id" => "valid"},
            # Wrong type
            "not a map"
          ]
        }
      }

      assert {:error, reason} = Spawn.execute(params["params"], parent_id, opts)
      assert is_binary(reason) and reason =~ ~r/sibling_context|validation/i
    end

    test "validates constraints as list of strings", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test",
          "success_criteria" => "Test",
          "immediate_context" => "Test",
          "approach_guidance" => "Test",
          "profile" => profile.name,
          # Mixed types
          "constraints" => ["Valid", 123, %{}]
        }
      }

      assert {:error, reason} = Spawn.execute(params["params"], parent_id, opts)
      assert is_binary(reason) and reason =~ ~r/constraints|validation/i
    end
  end

  describe "prompt generation" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      task = create_test_task()

      # Update task with global context
      {:ok, task} =
        task
        |> Quoracle.Tasks.Task.global_context_changeset(%{
          global_context: "Building a distributed system",
          initial_constraints: ["Security first", "Performance matters"]
        })
        |> Repo.update()

      config = %{
        agent_id: "parent-#{System.unique_integer([:positive])}",
        task_id: task.id,
        parent_id: nil,
        prompt: "Parent agent",
        models: ["google_gemini_2_5_flash"],
        sandbox_owner: sandbox_owner,
        test_mode: true,
        registry: deps.registry,
        pubsub: deps.pubsub,
        prompt_fields: %{
          transformed: %{
            accumulated_narrative: "Root started the project. Parent built foundation.",
            constraints: ["Follow coding standards", "Write tests"]
          }
        }
      }

      # Use spawn_agent_with_cleanup to register cleanup atomically (prevents race window)
      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      test_pid = self()

      %{
        deps: deps,
        task: task,
        parent_pid: parent_pid,
        parent_id: config.agent_id,
        sandbox_owner: sandbox_owner,
        opts: [
          agent_pid: parent_pid,
          task_id: task.id,
          sandbox_owner: sandbox_owner,
          registry: deps.registry,
          pubsub: deps.pubsub,
          dynsup: deps.dynsup,
          test_mode: true,
          # Required by ConfigBuilder to prevent GenServer deadlock
          parent_config: config,
          spawn_complete_notify: test_pid
        ],
        profile: create_test_profile()
      }
    end

    test "generates system prompt with all components", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Implement authentication",
          "success_criteria" => "JWT-based auth working",
          "immediate_context" => "Setting up user management",
          "approach_guidance" => "Use standard OAuth2 flow",
          "profile" => profile.name,
          "role" => "Security Engineer",
          "cognitive_style" => "systematic",
          "output_style" => "technical"
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      system_prompt = child_state.system_prompt

      # Should include role
      assert system_prompt =~ "Security Engineer"

      # Should include cognitive style
      assert system_prompt =~ "SYSTEMATIC"

      # Should include global constraints
      assert system_prompt =~ "Security first"
      assert system_prompt =~ "Performance matters"

      # Should include downstream constraints
      assert system_prompt =~ "Follow coding standards"
      assert system_prompt =~ "Write tests"

      # Should include output style
      assert system_prompt =~ "technical"
    end

    test "generates user prompt with task details", %{
      parent_id: parent_id,
      opts: opts,
      profile: profile
    } do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Create database schema",
          "success_criteria" => "Normalized tables with indexes",
          "immediate_context" => "PostgreSQL 15, high-traffic app",
          "approach_guidance" => "Focus on query performance",
          "profile" => profile.name,
          "sibling_context" => [
            %{"agent_id" => "api-agent", "task" => "Building REST API"}
          ]
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)

      # Task fields now stored in prompt_fields.provided
      assert child_state.prompt_fields.provided.task_description == "Create database schema"

      assert child_state.prompt_fields.provided.success_criteria ==
               "Normalized tables with indexes"

      assert child_state.prompt_fields.provided.immediate_context ==
               "PostgreSQL 15, high-traffic app"

      assert child_state.prompt_fields.provided.approach_guidance == "Focus on query performance"

      # Inherited fields stored in prompt_fields.injected (from parent config setup)
      assert child_state.prompt_fields.injected.global_context == "Building a distributed system"
      assert "Security first" in child_state.prompt_fields.injected.constraints
      assert "Performance matters" in child_state.prompt_fields.injected.constraints
    end

    test "uses XML tags in prompts", %{parent_id: parent_id, opts: opts, profile: profile} do
      params = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test XML formatting",
          "success_criteria" => "Proper XML tags",
          "immediate_context" => "Formatting test",
          "approach_guidance" => "Verify structure",
          "profile" => profile.name,
          "role" => "Tester"
        }
      }

      assert {:ok, result} = Spawn.execute(params["params"], parent_id, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: opts[:registry])

      {:ok, child_state} = Core.get_state(child_pid)
      system_prompt = child_state.system_prompt

      # Check for XML tags in system_prompt (role is there)
      assert system_prompt =~ ~r/<role>/
      assert system_prompt =~ ~r/<\/role>/

      # Task fields now stored in prompt_fields.provided (not XML-wrapped user_prompt)
      assert child_state.prompt_fields.provided.task_description == "Test XML formatting"
      assert child_state.prompt_fields.provided.success_criteria == "Proper XML tags"
    end
  end

  # Helper function
  defp create_test_task do
    {:ok, task} =
      %Quoracle.Tasks.Task{}
      |> Quoracle.Tasks.Task.changeset(%{
        prompt: "Test task for spawn field integration",
        status: "running"
      })
      |> Repo.insert()

    task
  end
end
