defmodule Quoracle.Agent.Consensus.MockResponseGenerator do
  @moduledoc """
  Generates mock LLM responses for testing consensus mechanisms.
  Centralizes all mock response logic to prevent test/production drift.
  """

  # Schema alias removed - not used in this refactored version

  @doc """
  Generates mock responses based on test options.

  Returns {:ok, responses} or {:error, reason} to match ModelQuery interface.
  """
  @spec generate(list(atom()), keyword()) :: {:ok, list(map())} | {:error, atom()}
  def generate(model_pool, opts) when is_list(opts) do
    if Keyword.get(opts, :simulate_failure, false) do
      {:error, :all_models_failed}
    else
      generate_responses(model_pool, opts)
    end
  end

  # Generate responses based on test scenario
  defp generate_responses(model_pool, opts) do
    scenario = determine_scenario(opts)
    responses = build_responses(scenario, model_pool, opts)

    {:ok, responses}
  end

  # Determine which test scenario to use
  defp determine_scenario(opts) do
    cond do
      # Seeded action for testing
      Keyword.has_key?(opts, :seed_action) ->
        :seeded_action

      # Mixed valid/invalid responses
      Keyword.get(opts, :mixed_responses, false) ->
        :mixed_responses

      # Malformed JSON
      Keyword.get(opts, :malformed, false) ->
        :malformed

      # Force consensus on a specific action
      Keyword.has_key?(opts, :force_consensus) ->
        :force_consensus

      # Force a specific action for testing
      Keyword.has_key?(opts, :force_action) ->
        :forced_action

      Keyword.get(opts, :simulate_partial_failure, false) ->
        :partial_failure

      Keyword.get(opts, :force_max_rounds, false) or
        Keyword.get(opts, :simulate_refinement_failure, false) or
        Keyword.get(opts, :force_no_consensus, false) or
          Keyword.get(opts, :simulate_no_consensus, false) ->
        :no_consensus

      Keyword.get(opts, :simulate_no_majority, false) ->
        :no_majority

      Keyword.get(opts, :simulate_tie, false) ->
        :tie

      true ->
        :consensus
    end
  end

  # Build responses for each scenario
  defp build_responses(:seeded_action, model_pool, opts) do
    action = Keyword.get(opts, :seed_action, :orient)
    params = Keyword.get(opts, :seed_params, generate_params_for_action(action))

    model_pool
    |> Enum.map(fn model ->
      response = %{
        "action" => Atom.to_string(action),
        "params" => params,
        "reasoning" => "Mock reasoning for #{model}"
      }

      # Add wait parameter for non-wait actions
      response =
        if action != :wait do
          Map.put(response, "wait", true)
        else
          response
        end

      %{
        content: Jason.encode!(response),
        model: model,
        action: action,
        params: params,
        reasoning: "Mock reasoning for #{model}",
        wait: if(action != :wait, do: true, else: nil)
      }
    end)
  end

  defp build_responses(:mixed_responses, model_pool, opts) do
    model_pool
    |> Enum.with_index()
    |> Enum.map(fn {model, idx} ->
      # Make first response invalid, rest valid
      if idx == 0 do
        %{
          content: "INVALID JSON {",
          model: model,
          action: nil,
          params: nil,
          reasoning: nil
        }
      else
        generate_json_response(model, :orient, opts)
      end
    end)
  end

  defp build_responses(:malformed, model_pool, _opts) do
    model_pool
    |> Enum.map(fn model ->
      %{
        content: ~s({"action": "wait", params: INVALID}),
        model: model,
        action: nil,
        params: nil,
        reasoning: nil
      }
    end)
  end

  defp build_responses(:force_consensus, model_pool, opts) do
    # Force consensus on a specific action
    action = Keyword.get(opts, :force_consensus, :orient)

    model_pool
    |> Enum.map(&generate_mock_response(&1, action))
  end

  defp build_responses(:forced_action, model_pool, opts) do
    action = Keyword.get(opts, :force_action, :orient)

    model_pool
    |> Enum.map(&generate_mock_response(&1, action))
  end

  defp build_responses(:partial_failure, model_pool, _opts) do
    model_pool
    |> Enum.with_index()
    |> Enum.map(fn {model, idx} ->
      if idx < 2 do
        # First 2 are valid
        generate_mock_response(model, :orient)
      else
        # Rest return nil/invalid to simulate failure
        %{
          content: "INVALID JSON",
          model: model
        }
      end
    end)
  end

  defp build_responses(:no_consensus, model_pool, _opts) do
    # Generate diverse responses to force refinement through max rounds
    # Ensure no majority by distributing actions
    actions = [:wait, :orient, :send_message]

    model_pool
    |> Enum.with_index()
    |> Enum.map(fn {model, idx} ->
      # Distribute actions to prevent majority (no action gets >50%)
      action = Enum.at(actions, rem(idx, length(actions)))
      generate_mock_response(model, action)
    end)
  end

  defp build_responses(:no_majority, model_pool, _opts) do
    model_pool
    |> Enum.map(fn model ->
      action = select_diverse_action(model)
      generate_mock_response(model, action)
    end)
  end

  defp build_responses(:tie, model_pool, _opts) do
    # For tie scenario, split models evenly between two actions
    model_pool
    |> Enum.with_index()
    |> Enum.map(fn {model, idx} ->
      # First half gets wait, second half gets orient
      action = if idx < div(length(model_pool), 2), do: :wait, else: :orient
      generate_mock_response(model, action)
    end)
  end

  defp build_responses(:consensus, model_pool, _opts) do
    model_pool
    |> Enum.map(fn model ->
      generate_mock_response(model, :orient)
    end)
  end

  @doc """
  Generates a single mock response for a given model and action.
  Returns a map with both parsed fields and :content field for compatibility.
  Used by integration tests that expect parsed format.
  """
  @spec generate_mock_response(atom(), atom()) :: map()
  def generate_mock_response(model, action) do
    params = generate_params_for_action(action)

    # Build response with wait parameter for non-wait actions
    response_map = %{
      "action" => Atom.to_string(action),
      "params" => params,
      "reasoning" => "Mock reasoning for #{model}"
    }

    # Add wait parameter for non-wait actions
    response_map =
      if action != :wait do
        Map.put(response_map, "wait", true)
      else
        response_map
      end

    response_json = Jason.encode!(response_map)

    # Return both formats for backward compatibility
    result = %{
      content: response_json,
      model: model,
      # Also include parsed fields for tests that expect them
      action: action,
      params: params,
      reasoning: "Mock reasoning for #{model}"
    }

    # Add wait to parsed fields if present
    if action != :wait do
      Map.put(result, :wait, true)
    else
      result
    end
  end

  @doc """
  Generates a mock response with JSON content for integration tests.
  Returns format matching real LLM responses.
  """
  @spec generate_json_response(atom(), atom(), keyword()) :: map()
  def generate_json_response(model, action, opts \\ []) do
    params = generate_params_for_action(action)
    generate_json_response(model, action, params, opts)
  end

  @doc """
  Generates a mock response with JSON content and explicit params.
  Returns format matching real LLM responses.
  """
  @spec generate_json_response(atom(), atom(), map(), keyword()) :: map()
  def generate_json_response(model, action, params, opts) do
    # Handle malformed responses
    content =
      case Keyword.get(opts, :malformed_type) do
        :invalid_json ->
          "Not valid JSON at all"

        :missing_action ->
          Jason.encode!(%{
            "params" => params,
            "reasoning" => "Mock reasoning for #{model}"
          })

        :invalid_action ->
          Jason.encode!(%{
            "action" => "not_real_action",
            "params" => params,
            "wait" => true,
            "reasoning" => "Mock reasoning for #{model}"
          })

        :missing_params ->
          response = %{
            "action" => Atom.to_string(action),
            "reasoning" => "Mock reasoning for #{model}"
          }

          # Add wait for non-wait actions even when params are missing
          response =
            if action != :wait do
              Map.put(response, "wait", true)
            else
              response
            end

          Jason.encode!(response)

        :truncated ->
          ~s({"action": "#{action}", "params": )

        nil ->
          # Check for general malformed flag
          if Keyword.get(opts, :malformed) do
            ~s({"action": "#{action}", params: INVALID})
          else
            # Normal valid JSON
            reasoning =
              if Keyword.get(opts, :with_context) do
                "Mock reasoning for #{model} choosing #{action} based on context analysis"
              else
                "Mock reasoning for #{model} choosing #{action}"
              end

            # Build response with wait parameter for non-wait actions
            response_data = %{
              "action" => Atom.to_string(action),
              "params" => params,
              "reasoning" => reasoning
            }

            response_data =
              if action != :wait do
                Map.put(response_data, "wait", true)
              else
                response_data
              end

            Jason.encode!(response_data)
          end
      end

    %{
      content: content,
      model: model,
      usage: %{prompt_tokens: 100, completion_tokens: 50}
    }
  end

  # Select diverse action based on model hash
  # ONLY use implemented actions
  defp select_diverse_action(model) do
    actions = [:orient, :wait]
    index = :erlang.phash2(model, length(actions))
    Enum.at(actions, index)
  end

  # Generate appropriate parameters for each action type
  defp generate_params_for_action(action) do
    case action do
      :orient ->
        %{
          "current_situation" => "Processing task",
          "goal_clarity" => "Clear objectives",
          "available_resources" => "Full capabilities",
          "key_challenges" => "None identified",
          "delegation_consideration" => "none"
        }

      :wait ->
        %{"wait" => 1000}

      :send_message ->
        %{"to" => "parent", "content" => "status update"}

      _ ->
        %{}
    end
  end
end
