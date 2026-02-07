defmodule Quoracle.Actions.SpawnFieldConsensusTest do
  @moduledoc """
  System tests for end-to-end field-based prompt flow.
  Verifies spawn → field extraction → prompt generation → consensus integration.
  """
  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Actions.Router
  alias Quoracle.Agent.Core
  alias Quoracle.Tasks.TaskManager

  # Helper to wait for background spawn to complete (async pattern v5.0)
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, {:ok, child_pid}} -> child_pid
      {:spawn_complete, ^child_id, {:error, _reason}} -> nil
    after
      timeout -> nil
    end
  end

  describe "spawn with field prompts E2E" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
      profile = create_test_profile()

      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Test spawn with fields"},
          sandbox_owner: sandbox_owner,
          pubsub: deps.pubsub,
          registry: deps.registry,
          dynsup: deps.dynsup
        )

      # Register cleanup for task's root agent (with recursive cleanup for any spawned children)
      register_agent_cleanup(task_agent_pid, cleanup_tree: true, registry: deps.registry)

      # Per-action Router (v28.0): Don't spawn shared Router - each action spawns its own
      %{
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        task_id: task.id,
        sandbox_owner: sandbox_owner,
        profile: create_test_profile(),
        capability_groups: [:hierarchy]
      }
    end

    @tag :system
    test "spawned agent receives field prompts in consensus", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      task_id: task_id,
      sandbox_owner: sandbox_owner,
      profile: profile,
      capability_groups: capability_groups
    } do
      parent_id = "parent-#{System.unique_integer([:positive])}"
      action_id = "spawn-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0): Spawn Router for this spawn_child action
      {:ok, router} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id,
          agent_id: parent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Parent spawns child with field-based parameters
      spawn_params = %{
        "task_description" => "Analyze security vulnerabilities",
        "success_criteria" => "Identify all OWASP Top 10 issues",
        "immediate_context" => "Production web application, Django backend",
        "approach_guidance" => "Focus on authentication and authorization first",
        "role" => "Security Specialist",
        "cognitive_style" => "systematic",
        "output_style" => "technical",
        "delegation_strategy" => "parallel",
        "profile" => profile.name
      }

      test_pid = self()

      opts = [
        agent_id: parent_id,
        action_id: action_id,
        task_id: task_id,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        spawn_complete_notify: test_pid,
        capability_groups: capability_groups,
        parent_config: %{
          task_id: task_id,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        }
      ]

      # Execute spawn (handle both sync and async completion)
      result =
        case Router.execute_action(router, :spawn_child, spawn_params, opts) do
          {:ok, res} ->
            res

          {:async, ref} ->
            {:ok, res} = Router.await_result(router, ref, timeout: 5000)
            res
        end

      # Async spawn pattern: wait for background spawn to complete
      child_pid = wait_for_spawn_complete(result.agent_id)
      _child_id = result.agent_id

      # Register cleanup (with recursive cleanup for any spawned children)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: registry)

      # Get child state to verify field prompts stored
      {:ok, child_state} = Core.get_state(child_pid)

      # Verify field prompts were generated and stored
      assert child_state.system_prompt != nil
      assert String.contains?(child_state.system_prompt, "<role>Security Specialist</role>")

      # Field transformation expands cognitive_style to prose, check for the expanded content
      assert String.contains?(child_state.system_prompt, "SYSTEMATIC mode")

      assert String.contains?(
               child_state.system_prompt,
               "<output_style>technical</output_style>"
             )

      # task_description now flows through history, verify it's in prompt_fields
      assert child_state.prompt_fields.provided.task_description ==
               "Analyze security vulnerabilities"

      assert child_state.prompt_fields.provided.success_criteria ==
               "Identify all OWASP Top 10 issues"

      # Trigger consensus by sending a message
      Core.handle_message(child_pid, %{
        type: :user,
        content: "What should I check first?"
      })

      # Get agent state to verify field prompts are stored
      {:ok, updated_state} = Core.get_state(child_pid)

      # Verify field prompts are stored in agent state
      # (Field prompts are injected into consensus via Consensus.ensure_system_prompts,
      # not via build_conversation_messages/2 which only handles per-model history)
      assert updated_state.system_prompt =~ "<role>Security Specialist</role>",
             "Field system prompt not found in agent state"

      # task_description is in prompt_fields, not user_prompt
      assert updated_state.prompt_fields.provided.task_description ==
               "Analyze security vulnerabilities",
             "Task description not found in prompt_fields"

      # Verify conversation message is in history
      # Note: consecutive same-role messages are merged, so use contains? not exact match
      model_id = updated_state.model_histories |> Map.keys() |> List.first() || "default"

      messages =
        Quoracle.Agent.ContextManager.build_conversation_messages(updated_state, model_id)

      assert Enum.any?(messages, fn msg ->
               msg.role == "user" && String.contains?(msg.content, "What should I check first?")
             end),
             "User message not found in conversation history"
    end

    @tag :system
    test "child inherits parent fields correctly", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      task_id: task_id,
      sandbox_owner: sandbox_owner,
      profile: profile,
      capability_groups: capability_groups
    } do
      # Create parent with field prompts
      parent_config = %{
        agent_id: "parent-architect",
        task_id: task_id,
        prompt_fields: %{
          injected: %{
            global_context: "Building microservices platform",
            constraints: ["Use only approved cloud services", "Follow SOC2 compliance"]
          },
          provided: %{
            role: "System Architect"
          }
        },
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, parent_pid} = spawn_agent_with_cleanup(dynsup, parent_config, registry: registry)

      action_id = "spawn-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0): Spawn Router for this spawn_child action
      {:ok, router} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id,
          agent_id: "parent-architect",
          agent_pid: parent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Parent spawns child
      spawn_params = %{
        "task_description" => "Design authentication service",
        "success_criteria" => "Secure, scalable, maintainable",
        "immediate_context" => "Part of microservices architecture",
        "approach_guidance" => "Use OAuth2 standards",
        # Overrides parent's role
        "role" => "Security Engineer",
        "profile" => profile.name
      }

      test_pid = self()

      opts = [
        agent_id: "parent-architect",
        action_id: action_id,
        task_id: task_id,
        # Important: pass parent PID
        agent_pid: parent_pid,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        spawn_complete_notify: test_pid,
        capability_groups: capability_groups,
        # Required by ConfigBuilder to prevent GenServer deadlock
        parent_config: parent_config
      ]

      # Execute spawn through router
      assert {:ok, result} = Router.execute_action(router, :spawn_child, spawn_params, opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      register_agent_cleanup(child_pid, cleanup_tree: true, registry: registry)

      # Get child state
      {:ok, child_state} = Core.get_state(child_pid)

      # Verify inheritance and transformation
      assert child_state.prompt_fields != nil

      # Should inherit parent's injected fields
      assert child_state.prompt_fields.injected.global_context ==
               "Building microservices platform"

      assert child_state.prompt_fields.injected.constraints == [
               "Use only approved cloud services",
               "Follow SOC2 compliance"
             ]

      # Should have child's provided fields (role overridden)
      assert child_state.prompt_fields.provided.role == "Security Engineer"

      assert child_state.prompt_fields.provided.task_description ==
               "Design authentication service"

      # Should generate transformed fields
      assert Map.has_key?(child_state.prompt_fields, :transformed)

      # Verify prompts include inherited constraints
      assert String.contains?(child_state.system_prompt, "<constraints>")
      assert String.contains?(child_state.system_prompt, "Use only approved cloud services")
      assert String.contains?(child_state.system_prompt, "<role>Security Engineer</role>")
    end

    @tag :system
    test "consensus decisions reflect field guidance", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      task_id: task_id,
      sandbox_owner: sandbox_owner,
      profile: profile,
      capability_groups: capability_groups
    } do
      # Test that different cognitive styles lead to different approaches

      # Spawn systematic agent
      analytical_params = %{
        "task_description" => "Process data",
        "success_criteria" => "Accurate results",
        "immediate_context" => "Large dataset available",
        "approach_guidance" => "Be thorough",
        "cognitive_style" => "systematic",
        "profile" => profile.name
      }

      # Spawn creative agent with same task
      creative_params = %{
        "task_description" => "Process data",
        "success_criteria" => "Accurate results",
        "immediate_context" => "Large dataset available",
        "approach_guidance" => "Be thorough",
        "cognitive_style" => "creative",
        "profile" => profile.name
      }

      test_pid = self()

      base_opts = [
        task_id: task_id,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        spawn_complete_notify: test_pid,
        capability_groups: capability_groups,
        parent_config: %{
          task_id: task_id,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          # Don't trigger consensus automatically
          skip_auto_consensus: true
        }
      ]

      # Per-action Router (v28.0): Each spawn needs its own Router
      action_id_1 = "spawn-#{System.unique_integer([:positive])}"
      action_id_2 = "spawn-#{System.unique_integer([:positive])}"

      {:ok, router1} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id_1,
          agent_id: "parent-analytical",
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, router2} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id_2,
          agent_id: "parent-creative",
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        for r <- [router1, router2] do
          if Process.alive?(r), do: GenServer.stop(r, :normal, :infinity)
        end
      end)

      # Spawn both agents
      analytical_opts =
        Keyword.merge(base_opts, agent_id: "parent-analytical", action_id: action_id_1)

      creative_opts =
        Keyword.merge(base_opts, agent_id: "parent-creative", action_id: action_id_2)

      {:ok, analytical_result} =
        Router.execute_action(router1, :spawn_child, analytical_params, analytical_opts)

      {:ok, creative_result} =
        Router.execute_action(router2, :spawn_child, creative_params, creative_opts)

      # Wait for async spawns to complete
      analytical_pid = wait_for_spawn_complete(analytical_result.agent_id)
      creative_pid = wait_for_spawn_complete(creative_result.agent_id)

      register_agent_cleanup(analytical_pid, cleanup_tree: true, registry: registry)
      register_agent_cleanup(creative_pid, cleanup_tree: true, registry: registry)

      # Get states to verify different prompts
      {:ok, analytical_state} = Core.get_state(analytical_pid)
      {:ok, creative_state} = Core.get_state(creative_pid)

      # Verify different cognitive styles in prompts
      assert String.contains?(analytical_state.system_prompt, "SYSTEMATIC")
      assert String.contains?(creative_state.system_prompt, "CREATIVE")

      # Both should have same task (in prompt_fields, not user_prompt)
      assert analytical_state.prompt_fields.provided.task_description == "Process data"
      assert creative_state.prompt_fields.provided.task_description == "Process data"

      # In production, these different cognitive styles would lead to different
      # consensus decisions and action choices
    end
  end

  describe "hybrid prompt system" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      %{
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner
      }
    end

    @tag :integration
    test "action schema and field prompts combine correctly", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Create agent with field prompts
      config = %{
        agent_id: "test-hybrid-#{System.unique_integer([:positive])}",
        # Combined into system_prompt since user_prompt was removed
        system_prompt:
          "<role>Developer</role><cognitive_style>methodical</cognitive_style><task>Build REST API</task>",
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        skip_auto_consensus: true
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(dynsup, config, registry: registry)

      # Send message to trigger consensus message building
      Core.handle_message(agent_pid, %{
        type: :user,
        content: "How should I structure the endpoints?"
      })

      # Get agent state to verify field prompts are stored
      {:ok, state} = Core.get_state(agent_pid)

      # Verify field prompts are stored in agent state
      # (Field prompts and action schema are combined in Consensus.ensure_system_prompts,
      # not in build_conversation_messages/2 which only handles per-model history)
      assert state.system_prompt =~ "<role>Developer</role>",
             "Field-based system prompt not found in agent state"

      # user_prompt removed - task flows through history, verify config was set
      assert state.system_prompt =~ "<task>Build REST API</task>",
             "Task not found in system_prompt (was moved from user_prompt)"

      # Verify history is accessible via 2-arity function
      model_id = state.model_histories |> Map.keys() |> List.first() || "default"
      messages = Quoracle.Agent.ContextManager.build_conversation_messages(state, model_id)

      # History should contain the user message
      assert Enum.any?(messages, fn msg ->
               msg.role == "user" && String.contains?(msg.content, "How should I structure")
             end),
             "User message not found in conversation history"
    end
  end

  # Use the imported create_isolated_deps from Test.AgentTestHelpers
  # No need to redefine it here
end
