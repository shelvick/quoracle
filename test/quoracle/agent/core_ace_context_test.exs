defmodule Quoracle.Agent.Core.ACEContextTest do
  @moduledoc """
  Tests for AGENT_Core v15.0 ACE Context Management fields.
  WorkGroupID: ace-20251207-140000
  Packet: 1 (Foundation)

  Tests R5-R8 from AGENT_Core.md v15.0 spec:
  - R5: context_lessons field initialized as empty map per model
  - R6: model_states field initialized as nil per model
  - R7: context_lessons persisted in agent state JSONB
  - R8: model_states persisted in agent state JSONB
  """
  use Quoracle.DataCase, async: true
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core.State

  # Setup isolated deps for integration tests
  setup %{sandbox_owner: sandbox_owner} do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    deps = %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    }

    %{deps: deps}
  end

  # Helper to create a minimal state struct with model pool
  defp create_test_state_with_models(model_pool) do
    State.new(%{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      registry: :test_registry,
      dynsup: self(),
      pubsub: :test_pubsub,
      # ACE: model pool for initialization
      models: model_pool
    })
  end

  describe "R5: Context Lessons Field" do
    test "context_lessons initialized as empty map per model" do
      model_pool = ["anthropic:claude-sonnet-4", "google:gemini-2.0-flash"]
      state = create_test_state_with_models(model_pool)

      # Field must exist
      assert Map.has_key?(state, :context_lessons),
             "State struct must have :context_lessons field"

      # Must be a map with empty list per model
      assert is_map(state.context_lessons),
             "context_lessons must be a map"

      # Each model in pool should have empty list
      for model_id <- model_pool do
        assert Map.has_key?(state.context_lessons, model_id),
               "context_lessons must have key for #{model_id}"

        assert state.context_lessons[model_id] == [],
               "context_lessons[#{model_id}] must be empty list"
      end
    end

    test "context_lessons defaults to empty map when no model pool" do
      state =
        State.new(%{
          agent_id: "test-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :context_lessons),
             "context_lessons field must exist even without model pool"

      assert state.context_lessons == %{},
             "context_lessons must default to empty map"
    end
  end

  describe "R6: Model States Field" do
    test "model_states initialized as nil per model" do
      model_pool = ["anthropic:claude-sonnet-4", "google:gemini-2.0-flash"]
      state = create_test_state_with_models(model_pool)

      # Field must exist
      assert Map.has_key?(state, :model_states),
             "State struct must have :model_states field"

      # Must be a map with nil per model
      assert is_map(state.model_states),
             "model_states must be a map"

      # Each model in pool should have nil
      for model_id <- model_pool do
        assert Map.has_key?(state.model_states, model_id),
               "model_states must have key for #{model_id}"

        assert state.model_states[model_id] == nil,
               "model_states[#{model_id}] must be nil initially"
      end
    end

    test "model_states defaults to empty map when no model pool" do
      state =
        State.new(%{
          agent_id: "test-agent",
          registry: :test_registry,
          dynsup: self(),
          pubsub: :test_pubsub
        })

      assert Map.has_key?(state, :model_states),
             "model_states field must exist even without model pool"

      assert state.model_states == %{},
             "model_states must default to empty map"
    end
  end

  describe "R7: Lessons Serialization" do
    @tag :integration
    test "context_lessons persisted in agent state", %{deps: deps} do
      # Create a task with proper deps
      opts = [
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      ]

      {:ok, {_task, agent_pid}} = create_task_with_cleanup("Test task for ACE", opts)

      # Get initial state
      {:ok, state} = GenServer.call(agent_pid, :get_state)

      # Verify context_lessons field exists and can be persisted
      assert Map.has_key?(state, :context_lessons),
             "Agent state must have context_lessons field"

      # Simulate updating context_lessons
      updated_lessons = %{
        "anthropic:claude-sonnet-4" => [
          %{type: :factual, content: "API uses bearer auth", confidence: 2},
          %{type: :behavioral, content: "User prefers concise output", confidence: 1}
        ]
      }

      # Update state with lessons
      updated_state = %{state | context_lessons: updated_lessons}

      # Persist to DB
      {:ok, _agent} =
        Quoracle.Tasks.TaskManager.update_agent_state(state.agent_id, updated_state)

      # Retrieve from DB
      {:ok, persisted_agent} = Quoracle.Tasks.TaskManager.get_agent(state.agent_id)

      # Verify lessons were persisted
      assert persisted_agent.state["context_lessons"] != nil,
             "context_lessons must be persisted in agent state JSONB"

      # Verify structure preserved
      persisted_lessons = persisted_agent.state["context_lessons"]

      assert is_map(persisted_lessons),
             "Persisted context_lessons must be a map"
    end
  end

  describe "R8: Model States Serialization" do
    @tag :integration
    test "model_states persisted in agent state", %{deps: deps} do
      # Create a task with proper deps
      opts = [
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      ]

      {:ok, {_task, agent_pid}} = create_task_with_cleanup("Test task for ACE", opts)

      # Get initial state
      {:ok, state} = GenServer.call(agent_pid, :get_state)

      # Verify model_states field exists and can be persisted
      assert Map.has_key?(state, :model_states),
             "Agent state must have model_states field"

      # Simulate updating model_states
      updated_model_states = %{
        "anthropic:claude-sonnet-4" => %{
          summary: "Working on auth implementation, 3/5 complete",
          updated_at: DateTime.utc_now()
        }
      }

      # Update state with model states
      updated_state = %{state | model_states: updated_model_states}

      # Persist to DB
      {:ok, _agent} =
        Quoracle.Tasks.TaskManager.update_agent_state(state.agent_id, updated_state)

      # Retrieve from DB
      {:ok, persisted_agent} = Quoracle.Tasks.TaskManager.get_agent(state.agent_id)

      # Verify model_states were persisted
      assert persisted_agent.state["model_states"] != nil,
             "model_states must be persisted in agent state JSONB"

      # Verify structure preserved
      persisted_states = persisted_agent.state["model_states"]

      assert is_map(persisted_states),
             "Persisted model_states must be a map"
    end
  end
end
