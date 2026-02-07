defmodule Quoracle.Agent.ConsensusHandlerChildrenTest do
  @moduledoc """
  Integration tests for children context injection in ConsensusHandler.

  Tests that ConsensusHandler properly calls ChildrenInjector during consensus.

  WorkGroupID: feat-20251227-children-inject
  Packet: 2 (Injection Logic)

  Requirements tested:
  - R32: Children Injector Called in Handler
  - R33: Consistent with PerModelQuery
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler

  # Test helpers
  defp make_child(id, offset_seconds \\ 0) do
    %{
      agent_id: id,
      spawned_at: DateTime.add(~U[2025-12-27 01:00:00Z], offset_seconds, :second)
    }
  end

  defp start_test_registry! do
    name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: name})
    name
  end

  defp register_agent(registry, agent_id) do
    Registry.register(registry, {:agent, agent_id}, %{pid: self()})
  end

  defp make_live_registry(children) do
    registry = start_test_registry!()
    for child <- children, do: register_agent(registry, child.agent_id)
    registry
  end

  describe "R32: ChildrenInjector in consensus" do
    test "consensus injects children into messages sent to LLM" do
      children = [make_child("agent-child-1")]
      registry = make_live_registry(children)
      test_pid = self()

      # Mock query function that captures messages sent to LLM
      mock_query_fn = fn messages, [model_id], _opts ->
        send(test_pid, {:query_messages, model_id, messages})

        response =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{
              "current_situation" => "Processing",
              "goal_clarity" => "Clear",
              "available_resources" => "Available",
              "key_challenges" => "None",
              "delegation_consideration" => "none"
            },
            "reasoning" => "Test"
          })

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        children: children,
        registry: registry,
        model_histories: %{
          "test-model" => [%{type: :user, content: "What's next?", timestamp: DateTime.utc_now()}]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      opts = [
        test_mode: true,
        model_pool: ["test-model"],
        model_query_fn: mock_query_fn
      ]

      # Use Consensus module which accepts opts with model_query_fn
      alias Quoracle.Agent.Consensus
      {:ok, _result, _updated_state} = Consensus.get_consensus_with_state(state, opts)

      # Verify children context was injected into messages sent to LLM
      assert_receive {:query_messages, "test-model", messages}, 30_000

      # Find the user message and verify it contains children XML
      user_messages = Enum.filter(messages, &(&1.role == "user" || &1[:role] == "user"))
      message_contents = Enum.map(user_messages, &(&1.content || &1[:content]))
      combined = Enum.join(message_contents, " ")

      assert combined =~ "<children>",
             "Expected children XML in messages, got: #{inspect(message_contents)}"

      assert combined =~ "agent-child-1",
             "Expected child agent ID in messages, got: #{inspect(message_contents)}"
    end
  end

  describe "R33: consistent injection across paths" do
    test "PerModelQuery path also injects children context" do
      children = [make_child("agent-permodel-1")]
      registry = make_live_registry(children)
      test_pid = self()

      # Mock query function that captures messages
      mock_query_fn = fn messages, [model_id], _opts ->
        send(test_pid, {:permodel_messages, model_id, messages})

        response =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{
              "current_situation" => "Processing",
              "goal_clarity" => "Clear",
              "available_resources" => "Available",
              "key_challenges" => "None",
              "delegation_consideration" => "none"
            },
            "reasoning" => "Test"
          })

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        children: children,
        registry: registry,
        model_histories: %{
          "model-x" => [%{type: :user, content: "Task query", timestamp: DateTime.utc_now()}]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      opts = [
        test_mode: true,
        model_pool: ["model-x"],
        model_query_fn: mock_query_fn
      ]

      # Use the Consensus module path (which uses PerModelQuery internally)
      alias Quoracle.Agent.Consensus
      {:ok, _result, _updated_state} = Consensus.get_consensus_with_state(state, opts)

      # Verify children context was injected
      assert_receive {:permodel_messages, "model-x", messages}, 30_000

      user_messages = Enum.filter(messages, &(&1.role == "user" || &1[:role] == "user"))
      message_contents = Enum.map(user_messages, &(&1.content || &1[:content]))
      combined = Enum.join(message_contents, " ")

      assert combined =~ "<children>",
             "Expected children XML in PerModelQuery path, got: #{inspect(message_contents)}"

      assert combined =~ "agent-permodel-1",
             "Expected child agent ID in PerModelQuery path, got: #{inspect(message_contents)}"
    end
  end

  describe "inject_children_context delegation" do
    test "ConsensusHandler delegates to ChildrenInjector" do
      # Test that inject_children_context is accessible via ConsensusHandler
      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      state = %{children: children, registry: registry}
      messages = [%{role: "user", content: "Hello"}]

      # Should delegate to ChildrenInjector
      result = ConsensusHandler.inject_children_context(state, messages)

      # Children should be injected
      assert hd(result).content =~ "<children>"
      assert hd(result).content =~ "agent-1"
    end

    test "returns messages unchanged when children empty" do
      state = %{children: [], registry: nil}
      messages = [%{role: "user", content: "Hello"}]

      result = ConsensusHandler.inject_children_context(state, messages)

      assert result == messages
    end
  end
end
