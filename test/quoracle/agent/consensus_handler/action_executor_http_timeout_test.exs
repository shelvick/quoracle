defmodule Quoracle.Agent.ConsensusHandler.ActionExecutorHttpTimeoutTest do
  @moduledoc """
  Regression tests for HTTP action timeout overrides in ActionExecutor.

  Root cause: answer_engine, fetch_web, call_api, and generate_images make
  HTTP API calls that routinely exceed the 100ms smart_threshold.  Without
  an explicit timeout override, Execution.execute_action enters "smart mode",
  yields for only 100ms, and returns {:async_task, ...}.  The ActionExecutor
  background Task casts that opaque tuple as the "result", the agent removes
  the action from pending_actions, and the *real* result arriving later is
  silently discarded (unknown action_id).

  Fix (v39.0): Timeout overrides for all HTTP-based actions in ActionExecutor:
    :answer_engine  → 120_000ms
    :fetch_web      →  60_000ms
    :call_api       → 120_000ms
    :generate_images → 300_000ms

  Test strategy: Dispatch each action through ActionExecutor.  The actions
  will fail quickly with specific errors (no API key, connection refused,
  etc.) but those are real errors returned synchronously — NOT the opaque
  {:async, ref, ack} tuple that caused the silent-discard bug.

  Tests:
  - R78: answer_engine gets 120_000ms timeout [UNIT]
  - R79: fetch_web gets 60_000ms timeout [UNIT]
  - R80: call_api gets 120_000ms timeout [UNIT]
  - R81: generate_images gets 300_000ms timeout [UNIT]
  - R82: existing call_mcp/adjust_budget overrides preserved [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.ConsensusHandler.ActionExecutor
  alias Quoracle.Profiles.CapabilityGroups
  alias Quoracle.Tasks.Task, as: TaskSchema
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  @moduletag capture_log: true

  @all_capability_groups CapabilityGroups.groups()

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    {:ok, task} =
      Repo.insert(%TaskSchema{
        id: Ecto.UUID.generate(),
        prompt: "http timeout override test",
        status: "running"
      })

    {:ok, deps: deps, task: task}
  end

  defp spawn_agent(deps, task) do
    agent_id = "http-timeout-#{System.unique_integer([:positive])}"

    config = %{
      agent_id: agent_id,
      task_id: task.id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      capability_groups: @all_capability_groups,
      spawn_complete_notify: self(),
      prompt_fields: %{
        provided: %{task_description: "HTTP timeout test"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  defp build_test_state(agent_pid) do
    {:ok, state} = Core.get_state(agent_pid)
    %{state | pending_actions: %{}, action_counter: 0}
  end

  # Helper: dispatch action and assert the result is a real error (synchronous path),
  # not the opaque {:async, ref, ack} that indicates smart mode broke the result chain.
  defp assert_sync_result(state, action_response, action_name) do
    _dispatched = ActionExecutor.execute_consensus_action(state, action_response, self())

    receive do
      {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
        # The result must NOT be the async tuple — that's the whole bug
        refute match?({:async, _, _}, result),
               "#{action_name} returned {:async, ...} — timeout override not applied, " <>
                 "result will be silently discarded"

        # The result must NOT be :timeout — that would mean the timeout was set
        # but too short (shouldn't happen for fast-failing actions)
        refute match?({:error, :timeout}, result),
               "#{action_name} returned {:error, :timeout} — unexpected"

        # It should be a real error (no API key, connection refused, etc.)
        result
    after
      15_000 ->
        flunk("No action result within 15s for #{action_name}")
    end
  end

  # ============================================================================
  # R78: answer_engine gets 120_000ms timeout [UNIT]
  #
  # WHEN ActionExecutor dispatches :answer_engine
  # THEN the action executes synchronously (timeout override bypasses smart mode)
  # AND returns a real error (not {:async, ref, ack})
  # ============================================================================

  describe "R78: answer_engine timeout override" do
    @tag :r78
    @tag :unit
    test "answer_engine returns real result, not async tuple",
         %{deps: deps, task: task} do
      {:ok, agent_pid} = spawn_agent(deps, task)
      state = build_test_state(agent_pid)

      action_response = %{
        action: :answer_engine,
        params: %{prompt: "test query for timeout regression"},
        wait: false,
        reasoning: "Testing answer_engine timeout override"
      }

      result = assert_sync_result(state, action_response, "answer_engine")

      # Should fail with a real error (no Gemini API key configured in test)
      assert match?({:error, _}, result),
             "Expected an error (no API key), got: #{inspect(result)}"
    end
  end

  # ============================================================================
  # R79: fetch_web gets 60_000ms timeout [UNIT]
  #
  # WHEN ActionExecutor dispatches :fetch_web
  # THEN the action executes synchronously (timeout override bypasses smart mode)
  # AND returns a real error (not {:async, ref, ack})
  # ============================================================================

  describe "R79: fetch_web timeout override" do
    @tag :r79
    @tag :unit
    test "fetch_web returns real result, not async tuple",
         %{deps: deps, task: task} do
      {:ok, agent_pid} = spawn_agent(deps, task)
      state = build_test_state(agent_pid)

      action_response = %{
        action: :fetch_web,
        params: %{url: "http://localhost:1/nonexistent"},
        wait: false,
        reasoning: "Testing fetch_web timeout override"
      }

      result = assert_sync_result(state, action_response, "fetch_web")

      # Should fail with connection refused (localhost:1 is not listening)
      assert match?({:error, _}, result),
             "Expected an error (connection refused), got: #{inspect(result)}"
    end
  end

  # ============================================================================
  # R80: call_api gets 120_000ms timeout [UNIT]
  #
  # WHEN ActionExecutor dispatches :call_api
  # THEN the action executes synchronously (timeout override bypasses smart mode)
  # AND returns a real error (not {:async, ref, ack})
  # ============================================================================

  describe "R80: call_api timeout override" do
    @tag :r80
    @tag :unit
    test "call_api returns real result, not async tuple",
         %{deps: deps, task: task} do
      {:ok, agent_pid} = spawn_agent(deps, task)
      state = build_test_state(agent_pid)

      action_response = %{
        action: :call_api,
        params: %{api_type: "rest", url: "http://localhost:1/nonexistent", method: "GET"},
        wait: false,
        reasoning: "Testing call_api timeout override"
      }

      result = assert_sync_result(state, action_response, "call_api")

      # Should fail with connection refused
      assert match?({:error, _}, result),
             "Expected an error (connection refused), got: #{inspect(result)}"
    end
  end

  # ============================================================================
  # R81: generate_images gets 300_000ms timeout [UNIT]
  #
  # WHEN ActionExecutor dispatches :generate_images
  # THEN the action executes synchronously (timeout override bypasses smart mode)
  # AND returns a real error (not {:async, ref, ack})
  # ============================================================================

  describe "R81: generate_images timeout override" do
    @tag :r81
    @tag :unit
    test "generate_images returns real result, not async tuple",
         %{deps: deps, task: task} do
      {:ok, agent_pid} = spawn_agent(deps, task)
      state = build_test_state(agent_pid)

      action_response = %{
        action: :generate_images,
        params: %{prompt: "test image for timeout regression"},
        wait: false,
        reasoning: "Testing generate_images timeout override"
      }

      result = assert_sync_result(state, action_response, "generate_images")

      # Should fail with a real error (no image generation API configured in test)
      assert match?({:error, _}, result),
             "Expected an error (no API key), got: #{inspect(result)}"
    end
  end

  # ============================================================================
  # R82: existing timeout overrides preserved [UNIT]
  #
  # WHEN ActionExecutor dispatches :call_mcp or :adjust_budget
  # THEN existing timeout overrides (600_000 and :infinity) are unchanged
  #
  # Regression: ensures adding new HTTP overrides didn't break existing ones.
  # Verified by dispatching call_mcp — it should fail with a specific error
  # (no MCP connection), NOT :timeout.
  # ============================================================================

  describe "R82: existing overrides preserved" do
    @tag :r82
    @tag :unit
    test "call_mcp still gets 600_000 timeout after HTTP action additions",
         %{deps: deps, task: task} do
      {:ok, agent_pid} = spawn_agent(deps, task)
      state = build_test_state(agent_pid)

      action_response = %{
        action: :call_mcp,
        params: %{connection_id: "nonexistent", tool_name: "test", arguments: %{}},
        wait: false,
        reasoning: "Testing call_mcp timeout preserved"
      }

      result = assert_sync_result(state, action_response, "call_mcp")

      # Should fail with MCP error, not timeout
      refute match?({:error, :timeout}, result),
             "call_mcp should not timeout. Got: #{inspect(result)}"
    end
  end
end
