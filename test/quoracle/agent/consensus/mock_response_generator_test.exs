defmodule Quoracle.Agent.Consensus.MockResponseGeneratorTest do
  @moduledoc """
  Tests for MockResponseGenerator module that generates JSON action responses for testing.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.MockResponseGenerator
  alias Quoracle.Actions.Schema

  describe "generate_json_response/4" do
    test "generates valid JSON with action, params, and reasoning" do
      response =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{"wait" => 1000},
          []
        )

      assert response.model == :gpt4
      assert is_binary(response.content)
      assert response.usage == %{prompt_tokens: 100, completion_tokens: 50}

      # Parse the JSON
      {:ok, parsed} = Jason.decode(response.content)
      assert parsed["action"] == "wait"
      assert parsed["params"]["wait"] == 1000
      assert parsed["reasoning"] =~ "gpt4"
      assert parsed["reasoning"] =~ "wait"
    end

    test "generates malformed JSON when malformed option is true" do
      response =
        MockResponseGenerator.generate_json_response(
          :claude,
          :orient,
          %{},
          malformed: true
        )

      assert response.model == :claude
      # Should not be valid JSON
      assert {:error, _} = Jason.decode(response.content)
    end

    test "generates specific malformed types" do
      # Test invalid JSON
      resp1 =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{},
          malformed: true,
          malformed_type: :invalid_json
        )

      assert resp1.content == "Not valid JSON at all"

      # Test missing action
      resp2 =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{},
          malformed: true,
          malformed_type: :missing_action
        )

      {:ok, parsed} = Jason.decode(resp2.content)
      refute Map.has_key?(parsed, "action")

      # Test invalid action
      resp3 =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{},
          malformed: true,
          malformed_type: :invalid_action
        )

      {:ok, parsed} = Jason.decode(resp3.content)
      assert parsed["action"] == "not_real_action"

      # Test missing params
      resp4 =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{},
          malformed: true,
          malformed_type: :missing_params
        )

      {:ok, parsed} = Jason.decode(resp4.content)
      refute Map.has_key?(parsed, "params")

      # Test truncated JSON
      resp5 =
        MockResponseGenerator.generate_json_response(
          :gpt4,
          :wait,
          %{},
          malformed: true,
          malformed_type: :truncated
        )

      assert {:error, _} = Jason.decode(resp5.content)
    end

    test "includes context in reasoning when requested" do
      response =
        MockResponseGenerator.generate_json_response(
          :gemini,
          :spawn_child,
          %{"task" => "analyze"},
          with_context: true
        )

      {:ok, parsed} = Jason.decode(response.content)
      assert parsed["reasoning"] =~ "based on context analysis"
    end
  end

  describe "generate/2" do
    test "generates responses for all models in pool" do
      model_pool = [:gpt4, :claude, :gemini]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, [])

      assert length(responses) == 3
      assert Enum.all?(responses, &is_map/1)
      assert Enum.all?(responses, fn r -> is_binary(r.content) end)
    end

    test "generates majority consensus when requested" do
      model_pool = [:gpt4, :claude, :gemini]
      opts = [force_consensus: :wait]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      # At least 2 should have the same action
      wait_count =
        responses
        |> Enum.map(fn r ->
          case Jason.decode(r.content) do
            {:ok, p} -> p["action"]
            _ -> nil
          end
        end)
        |> Enum.count(&(&1 == "wait"))

      assert wait_count >= 2
    end

    test "generates tie scenario when requested" do
      model_pool = [:gpt4, :claude, :gemini, :bedrock]
      opts = [simulate_tie: true]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      # Should have 2-2 split
      actions =
        responses
        |> Enum.map(fn r ->
          case Jason.decode(r.content) do
            {:ok, p} -> p["action"]
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      grouped = Enum.group_by(actions, & &1)
      assert map_size(grouped) == 2
      assert Enum.all?(grouped, fn {_, list} -> length(list) == 2 end)
    end

    test "generates no consensus scenario" do
      model_pool = [:gpt4, :claude, :gemini]
      opts = [simulate_no_consensus: true]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      # All should have different actions
      actions =
        responses
        |> Enum.map(fn r ->
          case Jason.decode(r.content) do
            {:ok, p} -> p["action"]
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      assert length(Enum.uniq(actions)) == length(actions)
    end

    test "handles simulate_failure option" do
      model_pool = [:gpt4, :claude]
      opts = [simulate_failure: true]

      assert {:error, :all_models_failed} = MockResponseGenerator.generate(model_pool, opts)
    end

    test "generates partial failures when requested" do
      model_pool = [:gpt4, :claude, :gemini]
      opts = [simulate_partial_failure: true]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, opts)

      # Some should be valid JSON, some invalid
      {valid, invalid} =
        Enum.split_with(responses, fn r ->
          case Jason.decode(r.content) do
            {:ok, _} -> true
            _ -> false
          end
        end)

      assert valid != []
      assert invalid != []
    end

    test "properly stringifies atom keys in params" do
      model_pool = [:gpt4]
      opts = [seed_action: :send_message, seed_params: %{to: :parent, content: "test"}]

      {:ok, [response]} = MockResponseGenerator.generate(model_pool, opts)

      {:ok, parsed} = Jason.decode(response.content)
      # Atom keys should be stringified
      assert parsed["params"]["to"] == "parent"
      assert parsed["params"]["content"] == "test"
    end
  end

  describe "action selection" do
    test "selects from valid Schema actions" do
      model_pool = [:gpt4, :claude, :gemini]

      {:ok, responses} = MockResponseGenerator.generate(model_pool, [])

      valid_actions =
        Schema.list_actions()
        |> Enum.map(&Atom.to_string/1)

      Enum.each(responses, fn response ->
        case Jason.decode(response.content) do
          {:ok, parsed} ->
            assert parsed["action"] in valid_actions

          _ ->
            # Malformed response, that's ok for some test scenarios
            :ok
        end
      end)
    end
  end
end
