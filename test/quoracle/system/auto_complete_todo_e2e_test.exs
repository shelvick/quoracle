defmodule Quoracle.System.AutoCompleteTodoE2ETest do
  @moduledoc """
  System test for auto_complete_todo end-to-end flow (R12)
  WorkGroupID: autocomplete-20251116-001905
  Tests full flow from LLM consensus to UI update
  """
  use ExUnit.Case, async: true
  import Test.AgentTestHelpers

  setup do
    # Create isolated dependencies
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"

    {:ok, _} = start_supervised({Registry, keys: :unique, name: registry_name})

    # CRITICAL: shutdown must be in child spec, not ExUnit options (ExUnit ignores it)
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: dynsup_name]]},
      shutdown: :infinity
    }

    {:ok, _} = start_supervised(dynsup_spec)
    {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Start sandbox owner for DB access
    sandbox_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox_owner) end)

    %{
      registry: registry_name,
      dynsup: dynsup_name,
      pubsub: pubsub_name,
      sandbox_owner: sandbox_owner
    }
  end

  describe "R12: Auto-Complete TODO System Test" do
    @tag :system
    test "end-to-end auto_complete_todo flow from consensus to UI update", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with TODOs
      # TEST-FIX: spawn_agent_with_cleanup signature changed, and TODO fields are content/state not item/status
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        objective: "Complete tasks with auto-complete",
        todos: [
          %{content: "Research topic", state: :todo},
          %{content: "Write summary", state: :todo},
          %{content: "Send results", state: :todo}
        ]
      }

      # TEST-FIX: Subscribe to agent-specific TODO topic and actions topic before spawning
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(dynsup, config,
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Simulate consensus returning an action with auto_complete_todo=true (at response level)
      # This would normally come from LLM consensus
      # TEST-FIX: orient requires 4 required params
      consensus_action = %{
        action: :orient,
        params: %{
          current_situation: "Starting research task",
          goal_clarity: "Clear",
          available_resources: "Test environment",
          key_challenges: "None",
          delegation_consideration: "No delegation needed for research"
        },
        auto_complete_todo: true,
        reasoning: "Getting oriented to complete the research task"
      }

      # Execute the action through the router (simulating consensus execution)
      # Per-action Router (v28.0): pubsub required in opts
      {:ok, action_result} =
        Quoracle.Actions.Router.execute(
          consensus_action,
          agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Verify action result includes the action field
      assert action_result.action == "orient"

      # Wait for and verify TODO update broadcast
      # TEST-FIX: PubSub message format is {:todos_updated, %{todos: [...]}} and fields are content/state
      assert_receive {:todos_updated, update_data}, 30_000
      assert [first_todo, second_todo, third_todo] = update_data.todos
      assert first_todo.content == "Research topic"
      assert first_todo.state == :done
      assert second_todo.state == :todo
      assert third_todo.state == :todo

      # Verify action completion broadcast (for UI)
      # TEST-FIX: action is inside result map, not at top level
      assert_receive {:action_completed, action_data}, 30_000
      assert action_data.agent_id == agent_id
      assert {:ok, result} = action_data.result
      assert result.action == "orient"

      # Verify agent state persistence
      # TEST-FIX: GenServer.call returns {:ok, state} not bare state
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [persisted_first | _] = state.todos
      assert persisted_first.state == :done

      # Simulate second action to verify continued functionality
      second_action = %{
        action: :wait,
        params: %{
          wait: 0
        },
        auto_complete_todo: true,
        reasoning: "Brief pause before writing summary"
      }

      # Per-action Router (v28.0): pubsub required in opts
      {:ok, _} =
        Quoracle.Actions.Router.execute(
          second_action,
          agent_pid,
          registry: registry,
          agent_pid: agent_pid,
          pubsub: pubsub
        )

      # Verify second TODO marked done
      # TEST-FIX: PubSub message format and field names
      assert_receive {:todos_updated, second_update}, 30_000
      assert [first, second, third] = second_update.todos
      assert first.state == :done
      assert second.state == :done
      assert third.state == :todo
    end

    @tag :system
    test "auto_complete_todo with failed action doesn't update UI", %{
      registry: registry,
      dynsup: dynsup,
      pubsub: pubsub,
      sandbox_owner: owner
    } do
      # Spawn an agent with TODOs
      # TEST-FIX: spawn_agent_with_cleanup signature and TODO fields
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        objective: "Test failure scenario",
        todos: [
          %{content: "Task that should not complete", state: :todo}
        ]
      }

      # TEST-FIX: Subscribe to agent-specific TODO topic to verify NO broadcast occurs
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:todos")

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(dynsup, config,
          registry: registry,
          pubsub: pubsub,
          sandbox_owner: owner
        )

      # Execute failing action with auto_complete_todo=true
      # TEST-FIX: call_api uses endpoint (not url) and method is enum (:get not "GET")
      failing_action = %{
        action: :call_api,
        params: %{
          endpoint: "invalid://not-a-url",
          method: :get,
          auto_complete_todo: true
        },
        reasoning: "This should fail"
      }

      # Execute and expect failure
      # Per-action Router (v28.0): pubsub required in opts
      assert {:error, _} =
               Quoracle.Actions.Router.execute(
                 failing_action,
                 agent_pid,
                 registry: registry,
                 agent_pid: agent_pid,
                 pubsub: pubsub
               )

      # Should NOT receive todo_updated broadcast
      # TEST-FIX: PubSub message format is {:todos_updated, ...}
      refute_receive {:todos_updated, _}, 500

      # Verify TODO remains unchanged
      # TEST-FIX: GenServer.call returns {:ok, state} and field is state not status
      {:ok, state} = GenServer.call(agent_pid, :get_state)
      assert [todo] = state.todos
      assert todo.state == :todo
    end
  end
end
