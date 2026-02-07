defmodule Quoracle.Agent.ConsensusCachingTest do
  @moduledoc """
  Tests for AGENT_Consensus v8.0 prompt caching support.

  ARC Verification Criteria:
  - R35: Prompt Cache Option Included [UNIT]
  - R36: Prompt Cache Reaches ModelQuery [INTEGRATION]
  - R37: Test Mode Preserves Cache Option [UNIT]

  WorkGroupID: cache-20251212-160000
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.PerModelQuery

  describe "R35: Prompt Cache Option Included [UNIT]" do
    test "build_query_options includes prompt_cache: -2" do
      opts = [round: 1]

      query_opts = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts)

      assert query_opts.prompt_cache == -2
    end
  end

  describe "R36: Cache Reaches ModelQuery [INTEGRATION]" do
    test "prompt_cache option flows to ModelQuery.query_models" do
      test_pid = self()

      model_query_mock = fn _messages, _models, query_opts ->
        send(test_pid, {:query_opts, query_opts})

        {:ok,
         %{
           successful_responses: [%{model: "anthropic:claude-sonnet-4", content: "{}"}],
           failed_models: []
         }}
      end

      state = %{
        model_histories: %{
          "anthropic:claude-sonnet-4" => [
            %{type: :user, content: "Test", timestamp: DateTime.utc_now()}
          ]
        }
      }

      opts = [round: 1, model_query_fn: model_query_mock]

      _result =
        PerModelQuery.query_single_model_with_retry(state, "anthropic:claude-sonnet-4", opts)

      assert_receive {:query_opts, received_opts}
      assert received_opts.prompt_cache == -2
    end
  end

  describe "R37: Test Mode Preserves Cache Option [UNIT]" do
    test "test mode preserves prompt_cache option" do
      opts = [round: 1, test_mode: true]

      query_opts = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts)

      # prompt_cache should still be present even in test mode
      assert query_opts.prompt_cache == -2
    end
  end
end
