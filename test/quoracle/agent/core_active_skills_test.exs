defmodule Quoracle.Agent.CoreActiveSkillsTest do
  @moduledoc """
  Tests for AGENT_Core v27.0 - active_skills state management.

  ARC Requirements (v27.0):
  - R61: active_skills field exists in State struct
  - R62: active_skills defaults to empty list
  - R63: active_skills populated from config
  - R64: learn_skills cast handler appends to active_skills
  - R65: skill metadata has required fields
  - R66: no content field in active_skills
  - R67: active_skills passed to PromptBuilder
  - R68: multiple learn_skills calls accumulate skills

  WorkGroupID: feat-20260112-skills-system
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Core

  setup do
    # Create isolated dependencies
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Registry, keys: :duplicate, name: registry})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup]]},
      shutdown: :infinity
    }

    start_supervised!(dynsup_spec)

    agent_id = "test-agent-skills-#{System.unique_integer([:positive])}"

    %{
      agent_id: agent_id,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    }
  end

  defp start_core(ctx, opts \\ []) do
    config =
      Keyword.merge(
        [
          agent_id: ctx.agent_id,
          parent_agent_id: nil,
          dynsup: ctx.dynsup,
          registry: ctx.registry,
          pubsub: ctx.pubsub,
          test_mode: true,
          skip_auto_consensus: true
        ],
        opts
      )

    {:ok, core_pid} = Core.start_link(config)

    on_exit(fn ->
      if Process.alive?(core_pid) do
        try do
          GenServer.stop(core_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    core_pid
  end

  # ==========================================================================
  # R61-R63: active_skills Field Initialization
  # ==========================================================================

  describe "active_skills field initialization (R61-R63)" do
    # R61: active_skills Field Exists
    test "State struct has active_skills field", ctx do
      core_pid = start_core(ctx)

      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert Map.has_key?(state, :active_skills),
             "State should have :active_skills field"
    end

    # R62: active_skills Default Empty List
    test "active_skills defaults to empty list", ctx do
      core_pid = start_core(ctx)

      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert state.active_skills == [],
             "active_skills should default to empty list"
    end

    # R63: active_skills From Config
    test "active_skills populated from config", ctx do
      skill_metadata = [
        %{
          name: "pre-loaded-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "A pre-loaded skill",
          path: "/path/to/skill.md",
          metadata: %{}
        }
      ]

      core_pid = start_core(ctx, active_skills: skill_metadata)

      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert length(state.active_skills) == 1
      assert hd(state.active_skills).name == "pre-loaded-skill"
    end
  end

  # ==========================================================================
  # R64-R66: learn_skills Cast Handler
  # ==========================================================================

  describe "learn_skills cast handler (R64-R66)" do
    # R64: learn_skills Cast Handler
    test "learn_skills cast appends skill metadata to state", ctx do
      core_pid = start_core(ctx)

      skill_metadata = [
        %{
          name: "learned-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "A learned skill",
          path: "/path/to/learned.md",
          metadata: %{complexity: "medium"}
        }
      ]

      GenServer.cast(core_pid, {:learn_skills, skill_metadata})

      # Sync point
      {:ok, state} = GenServer.call(core_pid, :get_state)

      assert length(state.active_skills) == 1
      assert hd(state.active_skills).name == "learned-skill"
    end

    # R65: Skill Metadata Structure
    test "skill metadata has required fields", ctx do
      core_pid = start_core(ctx)

      skill_metadata = [
        %{
          name: "structured-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "Skill with all fields",
          path: "/path/to/structured.md",
          metadata: %{tags: ["test"]}
        }
      ]

      GenServer.cast(core_pid, {:learn_skills, skill_metadata})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      skill = hd(state.active_skills)

      assert Map.has_key?(skill, :name), "Skill should have :name"
      assert Map.has_key?(skill, :permanent), "Skill should have :permanent"
      assert Map.has_key?(skill, :loaded_at), "Skill should have :loaded_at"
      assert Map.has_key?(skill, :description), "Skill should have :description"
      assert Map.has_key?(skill, :path), "Skill should have :path"
      assert Map.has_key?(skill, :metadata), "Skill should have :metadata"
    end

    # R66: No Content in State
    test "active_skills does not store content", ctx do
      core_pid = start_core(ctx)

      # Metadata should NOT include content (content read from files when needed)
      skill_metadata = [
        %{
          name: "no-content-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "Skill without content in state",
          path: "/path/to/skill.md",
          metadata: %{}
        }
      ]

      GenServer.cast(core_pid, {:learn_skills, skill_metadata})
      {:ok, state} = GenServer.call(core_pid, :get_state)

      skill = hd(state.active_skills)

      refute Map.has_key?(skill, :content),
             "Skill metadata should NOT contain :content field"
    end
  end

  # ==========================================================================
  # R67-R68: Integration and Accumulation
  # ==========================================================================

  describe "active_skills integration (R67-R68)" do
    # R67: Active Skills Passed to PromptBuilder
    test "active_skills passed to PromptBuilder", ctx do
      skill_metadata = [
        %{
          name: "prompt-skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "Skill for prompt building",
          path: "/path/to/prompt.md",
          metadata: %{}
        }
      ]

      core_pid = start_core(ctx, active_skills: skill_metadata)

      # Get prompt opts built by Core for PromptBuilder
      {:ok, prompt_opts} = GenServer.call(core_pid, :get_prompt_opts)

      # Verify active_skills is included in prompt opts
      assert Map.has_key?(prompt_opts, :active_skills)
      assert length(prompt_opts.active_skills) == 1
      assert hd(prompt_opts.active_skills).name == "prompt-skill"
    end

    # R68: Multiple Skills Append
    test "multiple learn_skills calls accumulate skills", ctx do
      core_pid = start_core(ctx)

      # First learn_skills call
      skill1 = [
        %{
          name: "skill-one",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "First skill",
          path: "/path/to/one.md",
          metadata: %{}
        }
      ]

      GenServer.cast(core_pid, {:learn_skills, skill1})
      {:ok, state1} = GenServer.call(core_pid, :get_state)
      assert length(state1.active_skills) == 1

      # Second learn_skills call
      skill2 = [
        %{
          name: "skill-two",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "Second skill",
          path: "/path/to/two.md",
          metadata: %{}
        }
      ]

      GenServer.cast(core_pid, {:learn_skills, skill2})
      {:ok, state2} = GenServer.call(core_pid, :get_state)
      assert length(state2.active_skills) == 2

      # Verify both skills are present
      skill_names = Enum.map(state2.active_skills, & &1.name)
      assert "skill-one" in skill_names
      assert "skill-two" in skill_names
    end
  end
end
