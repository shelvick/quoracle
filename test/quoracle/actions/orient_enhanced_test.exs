defmodule Quoracle.Actions.OrientEnhancedTest do
  @moduledoc """
  Tests for enhanced Orient action with PubSub broadcasting.
  Verifies that orient actions broadcast their results for observability.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Orient
  alias Quoracle.PubSub.AgentEvents

  setup do
    # Create isolated PubSub instance
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Subscribe to agent logs on isolated PubSub
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    :ok = AgentEvents.subscribe_to_agent(agent_id, pubsub_name)

    %{agent_id: agent_id, pubsub: pubsub_name}
  end

  describe "execute/2 - PubSub broadcasting" do
    test "broadcasts orientation results as log entries", %{agent_id: agent_id, pubsub: pubsub} do
      params = valid_orient_params()

      capture_log(fn ->
        {:ok, _result} = Orient.execute(params, agent_id, pubsub: pubsub)
      end)

      # Should receive log entry with orientation
      assert_receive {:log_entry, event}, 30_000
      assert event.agent_id == agent_id
      assert event.level == :info
      assert event.message =~ "Orientation complete"
      assert event.metadata.action == "orient"
      assert event.metadata.reflection
    end

    test "includes all reflection parameters in broadcast", %{agent_id: agent_id, pubsub: pubsub} do
      params = valid_orient_params()

      capture_log(fn ->
        {:ok, _} = Orient.execute(params, agent_id, pubsub: pubsub)
      end)

      assert_receive {:log_entry, event}, 30_000
      metadata = event.metadata

      # Should include all reflection parameters
      assert metadata.current_situation == params.current_situation
      assert metadata.goal_clarity == params.goal_clarity
      assert metadata.available_resources == params.available_resources
      assert metadata.key_challenges == params.key_challenges
    end

    test "broadcasts with debug level for detailed analysis", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      params = Map.put(valid_orient_params(), :detailed_analysis, true)

      capture_log(fn ->
        {:ok, _} = Orient.execute(params, agent_id, pubsub: pubsub)
      end)

      # Should receive debug level log for detailed analysis
      assert_receive {:log_entry, event}, 30_000
      assert event.level == :debug
      assert event.metadata.detailed_analysis == true
    end

    test "broadcasts error when missing required params", %{agent_id: agent_id, pubsub: pubsub} do
      # Missing current_situation
      params = %{
        goal_clarity: "Clear",
        available_resources: "Test",
        key_challenges: "None"
      }

      capture_log(fn ->
        {:error, _} = Orient.execute(params, agent_id, pubsub: pubsub)
      end)

      # Should receive error log
      assert_receive {:log_entry, event}, 30_000
      assert event.level == :error
      assert event.message =~ "Orient failed"
      assert event.metadata.error == :missing_required_param
    end

    test "broadcasts with optional parameters when provided", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      params =
        Map.merge(valid_orient_params(), %{
          recent_outcomes: "Previous actions successful",
          emotional_state: "Focused",
          energy_level: "High"
        })

      capture_log(fn ->
        {:ok, _} = Orient.execute(params, agent_id, pubsub: pubsub)
      end)

      assert_receive {:log_entry, event}, 30_000
      assert event.metadata.recent_outcomes == "Previous actions successful"
      assert event.metadata.emotional_state == "Focused"
      assert event.metadata.energy_level == "High"
    end

    test "broadcasts timestamp of orientation", %{agent_id: agent_id, pubsub: pubsub} do
      _log =
        capture_log(fn ->
          send(
            self(),
            {:result, Orient.execute(valid_orient_params(), agent_id, pubsub: pubsub)}
          )
        end)

      assert_received {:result, {:ok, result}}
      assert result.action == "orient"

      assert_receive {:log_entry, event}, 30_000
      assert %DateTime{} = event.timestamp
      assert %DateTime{} = event.metadata.orientation_timestamp
    end
  end

  describe "execute/2 - reflection generation" do
    test "generates insightful reflection based on inputs", %{agent_id: agent_id, pubsub: pubsub} do
      params = %{
        current_situation: "Processing complex user query",
        goal_clarity: "Need to understand user intent better",
        available_resources: "LLM models, action router, child agents",
        key_challenges: "Query ambiguity, multiple possible interpretations"
      }

      _log =
        capture_log(fn ->
          send(self(), {:result, Orient.execute(params, agent_id, pubsub: pubsub)})
        end)

      assert_received {:result, {:ok, result}}

      # Result is trimmed to save tokens (params were in the action request)
      assert result.action == "orient"

      # Should broadcast with reflection in metadata
      assert_receive {:log_entry, event}, 30_000
      assert is_binary(event.metadata.reflection)
      assert String.length(event.metadata.reflection) > 50
    end

    test "adapts reflection tone based on energy level", %{agent_id: agent_id, pubsub: pubsub} do
      low_energy_params =
        Map.merge(valid_orient_params(), %{
          energy_level: "Low",
          emotional_state: "Tired"
        })

      _log =
        capture_log(fn ->
          send(
            self(),
            {:result, Orient.execute(low_energy_params, agent_id, pubsub: pubsub)}
          )
        end)

      assert_received {:result, {:ok, result}}

      # Result is trimmed to save tokens
      assert result.action == "orient"

      # Should acknowledge the state in broadcast reflection metadata
      assert_receive {:log_entry, event}, 30_000
      assert event.metadata.energy_level == "Low"
      assert event.metadata.reflection =~ ~r/conserv|careful|methodical/i
    end
  end

  describe "integration with ACTION_Router" do
    test "orient results are observable through router metrics", %{
      agent_id: agent_id,
      pubsub: pubsub
    } do
      alias Quoracle.Actions.Router

      # Per-action Router (v28.0): Spawn Router for this specific action
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: nil
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Subscribe to both action events and agent logs on isolated PubSub
      Phoenix.PubSub.subscribe(pubsub, "actions:all")
      Phoenix.PubSub.subscribe(pubsub, "agents:#{agent_id}:logs")

      # Execute orient through router
      {:ok, _} = Router.execute(router, :orient, valid_orient_params(), agent_id, pubsub: pubsub)

      # Should receive both router and orient broadcasts
      assert_receive {:action_started, start_event}, 30_000
      assert start_event.action_type == :orient

      assert_receive {:log_entry, orient_event}, 30_000
      assert orient_event.metadata.action == "orient"

      assert_receive {:action_completed, complete_event}, 30_000
      assert match?({:ok, _}, complete_event.result)
    end
  end

  # Helper functions
  defp valid_orient_params do
    %{
      current_situation: "Testing orient action",
      goal_clarity: "Clear test objectives",
      available_resources: "Test environment ready",
      key_challenges: "None identified",
      delegation_consideration: "No delegation needed for testing"
    }
  end
end
