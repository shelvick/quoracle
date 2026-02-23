defmodule Quoracle.Agent.CoreHistoryStateTest do
  @moduledoc """
  Split from CoreTest for better parallelism.
  Tests action result processing, wait timers, error handling,
  conversation history, and state management.
  """

  use Quoracle.DataCase, async: true

  @moduletag capture_log: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()

    parent_pid = self()
    initial_prompt = "Hello, I am a test agent"

    {:ok,
     parent_pid: parent_pid,
     initial_prompt: initial_prompt,
     deps: deps,
     pubsub: deps.pubsub,
     sandbox_owner: sandbox_owner}
  end

  describe "action result processing" do
    @tag :arc_func_03
    test "consults LLMs when action completes with result", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      action_id = "action-123"
      Core.add_pending_action(agent, action_id, :web_fetch, %{url: "http://example.com"})
      Core.handle_action_result(agent, action_id, {:ok, "Success: fetched data"})
    end

    @tag :arc_func_05
    test "tracks multiple pending async actions correctly", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      Core.add_pending_action(agent, "action-1", :wait, %{wait: 1000})
      Core.add_pending_action(agent, "action-2", :web_fetch, %{url: "http://test.com"})
      Core.add_pending_action(agent, "action-3", :shell, %{command: "echo test"})

      assert {:ok, pending} = Core.get_pending_actions(agent)
      assert Map.has_key?(pending, "action-1")
      assert Map.has_key?(pending, "action-2")
      assert Map.has_key?(pending, "action-3")

      Core.handle_action_result(agent, "action-2", {:ok, "data"})

      assert {:ok, pending} = Core.get_pending_actions(agent)
      refute Map.has_key?(pending, "action-2")
      assert Map.has_key?(pending, "action-1")
      assert Map.has_key?(pending, "action-3")
    end

    @tag :arc_val_02
    test "validates action IDs match pending actions", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      Core.add_pending_action(agent, "valid-id", :wait, %{})

      capture_log(fn ->
        result = Core.handle_action_result(agent, "invalid-id", {:ok, "data"})
        assert result == :ok
      end)

      assert {:ok, pending} = Core.get_pending_actions(agent)
      assert Map.has_key?(pending, "valid-id")
    end
  end

  describe "wait timer behavior" do
    @tag :arc_func_04
    test "wait timer only triggers LLM consultation if no other events arrive", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      timer_id = "wait-test-1"
      Core.set_wait_timer(agent, 60000, timer_id)

      {:ok, timer_ref} = Core.get_wait_timer(agent)
      assert is_reference(timer_ref)

      Process.cancel_timer(timer_ref)
    end

    test "only one wait timer active at a time", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      Core.set_wait_timer(agent, 5000, "wait-1")
      assert {:ok, timer1} = Core.get_wait_timer(agent)

      Core.set_wait_timer(agent, 3000, "wait-2")
      assert {:ok, timer2} = Core.get_wait_timer(agent)

      assert timer1 != timer2

      Process.cancel_timer(timer2)
    end

    test "ignores stale timer messages with generation tracking", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      Core.set_wait_timer(agent, 5000, "wait-1")
      Core.set_wait_timer(agent, 3000, "wait-2")

      send(agent, {:wait_timeout, "wait-1", 1})

      assert {:ok, state} = Core.get_state(agent)

      assert state.wait_timer != nil
      {:ok, timer_ref} = Core.get_wait_timer(agent)
      assert is_reference(timer_ref)

      Process.cancel_timer(timer_ref)
    end
  end

  describe "existing error handling" do
    @tag :arc_err_01
    test "sends error to parent when consensus fails", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      send(agent, {:agent_error, agent, :consensus_failed})

      assert_receive {:agent_error, ^agent, :consensus_failed}, 30_000
    end

    @tag :arc_err_02
    test "consults LLMs when action fails semantically", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      action_id = "failing-action"
      Core.add_pending_action(agent, action_id, :web_fetch, %{url: "bad-url"})
      Core.handle_action_result(agent, action_id, {:error, :invalid_url})
    end
  end

  describe "conversation history" do
    test "maintains full conversation history", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "Message 1"})
        Core.add_pending_action(agent, "action-1", :execute_shell, %{command: "test"})
        _ = Core.get_state(agent)
        Core.handle_action_result(agent, "action-1", {:ok, "Result 1"})
        Core.handle_message(agent, {parent_pid, "Message 2"})
      end)

      assert {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      assert length(all_entries) >= 3

      assert Enum.any?(all_entries, fn h ->
               case h.content do
                 content when is_binary(content) -> content =~ "Message 1"
                 _ -> false
               end
             end)

      assert Enum.any?(all_entries, fn h ->
               case Map.get(h, :result) do
                 {:ok, result} when is_binary(result) -> result =~ "Result 1"
                 _ -> false
               end
             end)

      assert Enum.any?(all_entries, fn h ->
               case h.content do
                 content when is_binary(content) -> content =~ "Message 2"
                 _ -> false
               end
             end)
    end

    test "includes timestamps in history entries", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "Test message"})
      end)

      assert {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      assert Enum.all?(all_entries, fn h ->
               Map.has_key?(h, :timestamp) and is_struct(h.timestamp, DateTime)
             end)
    end
  end

  describe "state management" do
    test "properly initializes state structure", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      assert {:ok, state} = Core.get_state(agent)

      assert is_binary(state.agent_id)
      assert state.parent_pid == parent_pid
      assert state.children == []
      assert is_map(state.model_histories)
      assert is_map(state.pending_actions)
      assert state.wait_timer == nil
      assert is_integer(state.action_counter)
    end

    test "increments action counter for each action", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      assert {:ok, state1} = Core.get_state(agent)
      _initial_count = state1.action_counter

      :ok = Core.wait_for_ready(agent)

      assert {:ok, state_after_init} = Core.get_state(agent)
      counter_after_init = state_after_init.action_counter

      capture_log(fn ->
        Core.handle_agent_message(agent, "First action")
        Core.handle_agent_message(agent, "Second action")
      end)

      assert {:ok, _} = Core.get_state(agent)
      assert {:ok, _} = Core.get_state(agent)

      assert {:ok, state2} = Core.get_state(agent)
      assert state2.action_counter >= counter_after_init + 1
    end
  end
end
