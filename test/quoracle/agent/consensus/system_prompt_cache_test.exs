defmodule Quoracle.Agent.Consensus.SystemPromptCacheTest do
  @moduledoc """
  Tests for CACHE_SystemPrompt - System Prompt Caching.

  Verifies the system prompt caching mechanism works correctly:
  cache lifecycle (build, reuse, invalidate, rebuild), consistency
  with uncached builds, compatibility with Option E fast-path,
  and multi-model uniformity.

  WorkGroupID: feat-20260222-system-prompt-cache
  Packet: 1 (Single Packet)

  ARC Verification Criteria: R1-R9
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.State
  alias Quoracle.Consensus.PromptBuilder

  # ========== TEST HELPERS ==========

  # Builds a valid orient action JSON response for mock consensus
  defp orient_response do
    Jason.encode!(%{
      "action" => "orient",
      "params" => %{
        "current_situation" => "Processing",
        "goal_clarity" => "Clear",
        "available_resources" => "Available",
        "key_challenges" => "None",
        "delegation_consideration" => "none"
      },
      "reasoning" => "Test orient response",
      "wait" => true
    })
  end

  # Creates a mock model_query_fn that captures messages and returns an orient response.
  # Sends {:query_messages, model_id, messages} to the test process for each query.
  defp capturing_model_query_fn(test_pid) do
    fn messages, [model_id], _opts ->
      send(test_pid, {:query_messages, model_id, messages})

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  # Creates an agent config suitable for spawning with consensus pipeline support.
  # The model_query_fn injects a spy to capture messages sent during consensus.
  defp agent_config(deps, opts) do
    test_pid = Keyword.get(opts, :test_pid, self())
    model_pool = Keyword.get(opts, :model_pool, ["test-model-1"])
    active_skills = Keyword.get(opts, :active_skills, [])

    %{
      agent_id: "cache-test-#{System.unique_integer([:positive])}",
      test_mode: true,
      model_pool: model_pool,
      model_histories: Map.new(model_pool, fn m -> {m, []} end),
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      active_skills: active_skills,
      # model_query_fn forces real consensus pipeline (not fast-path)
      test_opts: [model_query_fn: capturing_model_query_fn(test_pid)]
    }
  end

  # Triggers consensus by sending a user message and waits for action completion.
  # Returns the system prompt(s) captured from the model_query_fn spy.
  defp trigger_consensus_and_capture(agent_pid, model_pool \\ ["test-model-1"]) do
    # Send a user message to trigger consensus
    Core.handle_message(agent_pid, "Test message for consensus")

    # Capture system prompts from each model query
    Enum.map(model_pool, fn model_id ->
      assert_receive {:query_messages, ^model_id, messages}, 5000
      system_msg = Enum.find(messages, &(&1.role == "system"))
      {model_id, system_msg && system_msg.content}
    end)
  end

  # ========== R1: STATE FIELD DEFAULT [UNIT] ==========

  describe "R1: Cache field exists in State [UNIT]" do
    test "State.new includes cached_system_prompt field defaulting to nil" do
      state =
        State.new(%{
          agent_id: "test-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :cached_system_prompt),
             "State struct must include cached_system_prompt field"

      assert state.cached_system_prompt == nil,
             "cached_system_prompt must default to nil"
    end
  end

  # ========== R2: LAZY CACHE BUILD [INTEGRATION] ==========

  describe "R2: Cache built lazily on first consensus [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self()),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "cache built lazily on first consensus cycle", %{agent_pid: agent_pid} do
      # Before consensus, cache should be nil
      {:ok, state_before} = Core.get_state(agent_pid)
      assert state_before.cached_system_prompt == nil

      # Trigger consensus (sends message, which triggers consensus pipeline)
      _captured = trigger_consensus_and_capture(agent_pid)

      # Wait for action to complete (orient with wait:true just returns)
      # Use GenServer.call to synchronize state
      {:ok, state_after} = Core.get_state(agent_pid)

      assert is_binary(state_after.cached_system_prompt),
             "cached_system_prompt should be a non-nil string after first consensus, " <>
               "got: #{inspect(state_after.cached_system_prompt)}"

      assert String.length(state_after.cached_system_prompt) > 0,
             "cached_system_prompt should be a non-empty string"
    end
  end

  # ========== R3: CACHE REUSE [INTEGRATION] ==========

  describe "R3: Cache reused on subsequent consensus [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self()),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "cache reused without rebuild on subsequent consensus", %{agent_pid: agent_pid} do
      # First consensus: builds and caches prompt
      [{_model, prompt_1}] = trigger_consensus_and_capture(agent_pid)

      # Wait for first consensus to settle
      {:ok, state_after_1} = Core.get_state(agent_pid)
      cached_after_1 = state_after_1.cached_system_prompt

      assert is_binary(cached_after_1), "Cache should be populated after first consensus"

      # Second consensus: should reuse the same cached prompt
      [{_model, prompt_2}] = trigger_consensus_and_capture(agent_pid)

      {:ok, state_after_2} = Core.get_state(agent_pid)
      cached_after_2 = state_after_2.cached_system_prompt

      # The system prompt sent to the model should be identical both times
      assert prompt_1 == prompt_2,
             "System prompt should be identical on second consensus (reused from cache)"

      # The cached value should be the same reference/string
      assert cached_after_1 == cached_after_2,
             "Cached system prompt should remain unchanged between consensus cycles"
    end
  end

  # ========== R4: LEARN_SKILLS INVALIDATION [UNIT] ==========

  describe "R4: learn_skills invalidates cached system prompt [UNIT]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self()),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "learn_skills invalidates cached system prompt", %{agent_pid: agent_pid} do
      # First, populate the cache by running consensus
      _captured = trigger_consensus_and_capture(agent_pid)

      {:ok, state_with_cache} = Core.get_state(agent_pid)

      assert is_binary(state_with_cache.cached_system_prompt),
             "Cache should be populated after consensus"

      # Cast learn_skills to the agent
      skill_metadata = [
        %{
          name: "test_skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "A test skill",
          path: "/tmp/test_skill",
          metadata: %{}
        }
      ]

      GenServer.cast(agent_pid, {:learn_skills, skill_metadata})

      # Synchronize with a GenServer.call to ensure the cast was processed
      {:ok, state_after_learn} = Core.get_state(agent_pid)

      assert state_after_learn.cached_system_prompt == nil,
             "cached_system_prompt should be nil after learn_skills"

      # Verify active_skills were updated
      assert state_after_learn.active_skills != [],
             "active_skills should be updated after learn_skills"
    end
  end

  # ========== R5: REBUILD AFTER INVALIDATION [INTEGRATION] ==========

  describe "R5: Cache rebuilt after learn_skills invalidation [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self()),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "cache rebuilt after learn_skills invalidation reflects new skills", %{
      agent_pid: agent_pid
    } do
      # First consensus: cache with no active skills
      [{_model, _prompt_before}] = trigger_consensus_and_capture(agent_pid)
      {:ok, state_1} = Core.get_state(agent_pid)
      assert is_binary(state_1.cached_system_prompt)

      # Learn a new skill (invalidates cache)
      skill_metadata = [
        %{
          name: "newly_learned_skill",
          permanent: true,
          loaded_at: DateTime.utc_now(),
          description: "A newly learned skill for cache test",
          path: "/tmp/newly_learned_skill",
          metadata: %{}
        }
      ]

      GenServer.cast(agent_pid, {:learn_skills, skill_metadata})
      {:ok, state_invalidated} = Core.get_state(agent_pid)
      assert state_invalidated.cached_system_prompt == nil

      # Second consensus: should rebuild cache with new skills
      [{_model, _prompt_after}] = trigger_consensus_and_capture(agent_pid)
      {:ok, state_2} = Core.get_state(agent_pid)

      assert is_binary(state_2.cached_system_prompt),
             "Cache should be rebuilt after invalidation"

      # The rebuilt cache should differ from the original (new skills included)
      # Note: This assertion depends on PromptBuilder including skills in the prompt.
      # If skills affect the prompt, the strings should differ.
      assert state_2.cached_system_prompt != state_1.cached_system_prompt,
             "Rebuilt cache should differ from original (new skills added)"
    end
  end

  # ========== R6: CACHE CONSISTENCY [UNIT] ==========

  describe "R6: Cache consistency with fresh build [UNIT]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self()),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "cached prompt matches fresh build with same inputs", %{agent_pid: agent_pid} do
      # Run consensus to populate the cache
      _captured = trigger_consensus_and_capture(agent_pid)

      {:ok, state} = Core.get_state(agent_pid)
      cached = state.cached_system_prompt
      assert is_binary(cached)

      # Build a fresh prompt with the same inputs
      fresh_opts = [
        profile_name: state.profile_name,
        profile_description: state.profile_description,
        capability_groups: state.capability_groups,
        active_skills: state.active_skills,
        skills_path: Map.get(state, :skills_path),
        field_prompts: %{system_prompt: state.system_prompt},
        sandbox_owner: state.sandbox_owner
      ]

      fresh = PromptBuilder.build_system_prompt_with_context(fresh_opts)

      assert cached == fresh,
             "Cached prompt should be identical to a fresh build with the same inputs"
    end
  end

  # ========== R7: FAST-PATH BYPASS [INTEGRATION] ==========

  describe "R7: Fast-path bypasses cache entirely [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      # Spawn agent WITHOUT model_query_fn so fast-path activates
      # (test_mode: true + no simulate flags + no model_query_fn = fast path)
      config = %{
        agent_id: "fast-path-#{System.unique_integer([:positive])}",
        test_mode: true,
        model_pool: ["test-model-1"],
        model_histories: %{"test-model-1" => []},
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
        # Intentionally NO test_opts with model_query_fn
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid}
    end

    test "fast-path consensus does not build or use cache", %{agent_pid: agent_pid} do
      # Verify cache starts as nil
      {:ok, state_before} = Core.get_state(agent_pid)
      assert state_before.cached_system_prompt == nil

      # Send a message to trigger consensus (fast-path will handle it)
      Core.handle_message(agent_pid, "Test message for fast path")

      # Give the agent time to process (fast path returns mock orient with wait:true)
      # Synchronize with GenServer.call
      {:ok, state_after} = Core.get_state(agent_pid)

      # Cache should still be nil because fast-path skips the entire pipeline
      assert state_after.cached_system_prompt == nil,
             "Fast-path should not build or populate the system prompt cache"
    end
  end

  # ========== R9: FIELD_PROMPTS INCLUDED IN CACHE [INTEGRATION] ==========
  # Regression: Cache build must include field_prompts so agents with role/cognitive_style
  # get those XML tags embedded in the identity section of the system prompt.

  describe "R9: Cached prompt includes field_prompts content [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      # Agent with a non-nil system_prompt (simulates field-based role/cognitive_style)
      config =
        agent_config(deps, test_pid: self())
        |> Map.put(:system_prompt, "<role>Cache Regression Test Role</role>")

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, deps: deps}
    end

    test "system prompt sent to models contains agent field_prompts content", %{
      agent_pid: agent_pid
    } do
      # Trigger consensus and capture the system prompt sent to the model
      [{_model, system_prompt}] = trigger_consensus_and_capture(agent_pid)

      assert is_binary(system_prompt), "Model should receive a system prompt"

      # The system prompt must include the agent's role from field_prompts
      assert system_prompt =~ "Cache Regression Test Role",
             "Cached system prompt must include field_prompts content (role/cognitive_style). " <>
               "Got prompt of length #{String.length(system_prompt)} without the expected role tag."
    end

    test "cached prompt matches fresh build when agent has field_prompts", %{
      agent_pid: agent_pid
    } do
      # Run consensus to populate the cache
      _captured = trigger_consensus_and_capture(agent_pid)

      {:ok, state} = Core.get_state(agent_pid)
      cached = state.cached_system_prompt
      assert is_binary(cached)

      # Build a fresh prompt with the SAME inputs including field_prompts
      fresh_opts = [
        profile_name: state.profile_name,
        profile_description: state.profile_description,
        capability_groups: state.capability_groups,
        active_skills: state.active_skills,
        skills_path: Map.get(state, :skills_path),
        field_prompts: %{system_prompt: state.system_prompt},
        sandbox_owner: state.sandbox_owner
      ]

      fresh = PromptBuilder.build_system_prompt_with_context(fresh_opts)

      assert cached == fresh,
             "Cached prompt must match fresh build with field_prompts. " <>
               "Cached length: #{String.length(cached)}, fresh length: #{String.length(fresh)}. " <>
               "Cached includes role? #{String.contains?(cached, "Cache Regression")}. " <>
               "Fresh includes role? #{String.contains?(fresh, "Cache Regression")}."
    end
  end

  # ========== R8: MULTI-MODEL UNIFORMITY [INTEGRATION] ==========

  describe "R8: All models use same cached prompt [INTEGRATION]" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      _profile = create_test_profile()

      model_pool = ["model-a", "model-b", "model-c"]

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          agent_config(deps, test_pid: self(), model_pool: model_pool),
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      {:ok, agent_pid: agent_pid, model_pool: model_pool}
    end

    test "all models in consensus pool receive same cached system prompt", %{
      agent_pid: agent_pid,
      model_pool: model_pool
    } do
      # Trigger consensus across 3 models
      captured = trigger_consensus_and_capture(agent_pid, model_pool)

      # Extract system prompts from each model's messages
      system_prompts =
        Enum.map(captured, fn {_model_id, prompt} ->
          assert is_binary(prompt),
                 "Each model should receive a system prompt"

          prompt
        end)

      # All 3 should be identical
      [first | rest] = system_prompts

      Enum.each(rest, fn prompt ->
        assert prompt == first,
               "All models should receive identical system prompt from cache"
      end)

      # Verify the cache is populated
      {:ok, state} = Core.get_state(agent_pid)

      assert is_binary(state.cached_system_prompt),
             "Cache should be populated after multi-model consensus"
    end
  end
end
