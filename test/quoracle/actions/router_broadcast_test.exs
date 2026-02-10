defmodule Quoracle.Actions.RouterBroadcastTest do
  @moduledoc """
  Tests for ACTION_Router PubSub broadcasting functionality.
  Verifies that action lifecycle events (start, complete, error)
  are properly broadcast to subscribers.
  """

  # async: true - Uses isolated PubSub instance for test isolation
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router

  setup do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Subscribe to action events topic on isolated instance
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "actions:all")

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - use :orient for broadcast tests
    {:ok, router} =
      Router.start_link(
        action_type: :orient,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name
      )

    # Ensure router terminates before sandbox owner exits
    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, router: router, agent_id: agent_id, pubsub: pubsub_name}
  end

  describe "action lifecycle broadcasts" do
    test "broadcasts action_started when action begins execution", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute a wait action
      action_request = %{
        action: :wait,
        # > 100ms smart_threshold to trigger async
        params: %{wait: 150},
        agent_id: agent_id
      }

      # Start the action
      capture_log(fn ->
        send(
          self(),
          {:result,
           Router.execute(router, action_request.action, action_request.params, agent_id)}
        )
      end)

      assert_received {:result, {:ok, response}}
      assert response.async == true

      # Should receive action_started broadcast for our specific agent
      assert_receive {:action_started, %{agent_id: ^agent_id} = payload}, 30_000
      assert payload.action_type == :wait
      assert payload.params == %{wait: 150}
      assert is_binary(payload.action_id)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_completed for synchronous success", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute an orient action (typically synchronous)
      action_request = %{
        action: :orient,
        params: %{
          current_situation: "test",
          goal_clarity: "test",
          available_resources: "test",
          key_challenges: "test",
          delegation_consideration: "none"
        },
        agent_id: agent_id
      }

      # Execute synchronously
      {:ok, _result} =
        Router.execute(router, action_request.action, action_request.params, agent_id)

      # Should receive both started and completed
      assert_receive {:action_started, start_payload}, 30_000
      assert_receive {:action_completed, complete_payload}, 30_000
      assert complete_payload.agent_id == agent_id
      assert complete_payload.action_id == start_payload.action_id
      assert match?({:ok, _}, complete_payload.result)
      assert %DateTime{} = complete_payload.timestamp
    end

    test "broadcasts action_completed for async success", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute async wait action with duration > smart_threshold (100ms default)
      action_request = %{
        action: :wait,
        # > 100ms smart_threshold to trigger async
        params: %{wait: 150},
        agent_id: agent_id
      }

      {:ok, response} =
        Router.execute(router, action_request.action, action_request.params, agent_id)

      assert response.async == true

      # Should receive started broadcast immediately
      assert_receive {:action_started, %{agent_id: ^agent_id}}, 30_000
      # No need to await - action completed immediately

      # Should receive completed broadcast (may have already arrived during natural completion)
      # The broadcast can happen either during natural task completion (handle_info)
      # or during await_result, depending on timing
      assert_receive {:action_completed, %{agent_id: ^agent_id} = payload}, 30_000
      assert match?({:ok, _}, payload.result)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_error when action fails", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute an action that will fail
      action_request = %{
        # This should fail
        action: :unknown_action,
        params: %{},
        agent_id: agent_id
      }

      capture_log(fn ->
        send(
          self(),
          {:result,
           Router.execute(router, action_request.action, action_request.params, agent_id)}
        )
      end)

      assert_received {:result, {:error, _reason}}

      # Should receive action_error broadcast
      assert_receive {:action_error, payload}, 30_000
      assert payload.agent_id == agent_id
      assert is_binary(payload.action_id)
      assert match?({:error, _}, payload.error)
      assert %DateTime{} = payload.timestamp
    end

    test "broadcasts action_error for async failures", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute an action with invalid params that will fail
      action_request = %{
        action: :wait,
        # Invalid duration
        params: %{wait: -1},
        agent_id: agent_id
      }

      capture_log(fn ->
        send(
          self(),
          {:result,
           Router.execute(router, action_request.action, action_request.params, agent_id)}
        )
      end)

      assert_received {:result, result}

      case result do
        {:error, _} ->
          # Immediate validation error
          assert_receive {:action_error, _payload}, 30_000

        {:async, ref} ->
          # Async execution that will fail
          {:error, _} = Router.await_result(router, ref)
          assert_receive {:action_error, _payload}, 30_000
      end
    end
  end

  describe "broadcast content" do
    test "includes action_id for tracking across events", %{
      router: router,
      agent_id: agent_id
    } do
      # Execute an action
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # Capture both events
      assert_receive {:action_started, start_payload}, 30_000
      assert_receive {:action_completed, complete_payload}, 30_000

      # Action IDs should match
      assert start_payload.action_id == complete_payload.action_id
      assert is_binary(start_payload.action_id)
    end

    test "includes accurate timestamps", %{
      router: router,
      agent_id: agent_id
    } do
      before_execution = DateTime.utc_now()

      # Execute action
      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      after_execution = DateTime.utc_now()

      # Check timestamps are in correct range
      assert_receive {:action_started, payload}, 30_000
      assert DateTime.compare(payload.timestamp, before_execution) in [:gt, :eq]
      assert DateTime.compare(payload.timestamp, after_execution) in [:lt, :eq]
    end

    test "preserves action parameters in broadcast", %{
      router: router,
      agent_id: agent_id
    } do
      complex_params = %{
        wait: 200,
        message: "test message",
        nested: %{
          key: "value",
          list: [1, 2, 3]
        }
      }

      # Execute with complex params
      capture_log(fn ->
        Router.execute(router, :wait, complex_params, agent_id)
      end)

      assert_receive {:action_started, payload}, 30_000
      assert payload.params == complex_params
    end
  end

  describe "integration with AgentEvents" do
    test "Router uses AgentEvents helper functions", %{
      router: router,
      agent_id: agent_id
    } do
      # This verifies Router integrates with AgentEvents module
      # rather than doing raw broadcasts

      params = %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      }

      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :orient, params, agent_id)})
      end)

      assert_received {:result, {:ok, _result}}

      # The broadcast should follow AgentEvents message structure
      assert_receive {:action_started, payload}, 30_000

      # Verify structure matches AgentEvents contract
      assert Map.has_key?(payload, :agent_id)
      assert Map.has_key?(payload, :action_type)
      assert Map.has_key?(payload, :action_id)
      assert Map.has_key?(payload, :params)
      assert Map.has_key?(payload, :timestamp)
      assert match?(%DateTime{}, payload.timestamp)
    end
  end

  describe "error scenarios" do
    test "broadcasts error for invalid action type", %{
      router: router,
      agent_id: agent_id
    } do
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :nonexistent, %{}, agent_id)})
      end)

      assert_received {:result, {:error, :unknown_action}}

      assert_receive {:action_error, payload}, 30_000
      assert payload.error == {:error, :unknown_action}
    end

    test "broadcasts error for validation failures", %{
      router: router,
      agent_id: agent_id
    } do
      # Invalid params for wait action
      capture_log(fn ->
        send(self(), {:result, Router.execute(router, :wait, %{invalid: "params"}, agent_id)})
      end)

      assert_received {:result, {:error, _reason}}

      assert_receive {:action_error, payload}, 30_000
      assert match?({:error, _}, payload.error)
    end

    test "handles broadcast even when action crashes", %{
      router: router,
      agent_id: agent_id
    } do
      # Try to execute action that might crash
      # Router should still broadcast the error
      capture_log(fn ->
        send(
          self(),
          {:result, Router.execute(router, :wait, %{wait: "not_a_number"}, agent_id)}
        )
      end)

      assert_received {:result, result}

      case result do
        {:error, _} ->
          assert_receive {:action_error, _}, 30_000

        {:async, ref} ->
          Router.await_result(router, ref)
          assert_receive {:action_error, _}, 30_000
      end
    end
  end
end
