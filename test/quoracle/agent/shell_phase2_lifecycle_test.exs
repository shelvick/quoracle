defmodule Quoracle.Agent.ShellPhase2LifecycleTest do
  @moduledoc """
  Tests for fix-20260220-shell-phase2-lost — Phase 2 shell result delivery.

  WorkGroupID: fix-20260220-shell-phase2-lost
  Packet: Single Packet

  Bug: Async shell commands (1-5s range) permanently lose their completion results.
  Phase 1 (async ack) deletes the action from pending_actions. When Phase 2 (completion
  with stdout/exit_code) arrives with the same action_id, it's silently discarded.

  ARC Verification Criteria: R100-R108
  """

  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.MessageHandler.ActionResultHandler

  @moduletag capture_log: true

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()

    # Base state for unit tests against ActionResultHandler directly.
    # Mirrors the pattern from action_executor_regressions_test.exs.
    base_state = %{
      agent_id: "agent-phase2-#{System.unique_integer([:positive])}",
      task_id: "task-#{System.unique_integer([:positive])}",
      pending_actions: %{},
      model_histories: %{},
      children: [],
      wait_timer: nil,
      timer_generation: 0,
      action_counter: 0,
      state: :processing,
      context_summary: nil,
      context_limit: 4000,
      context_limits_loaded: true,
      additional_context: [],
      test_mode: true,
      skip_auto_consensus: true,
      skip_consensus: true,
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner,
      queued_messages: [],
      consensus_scheduled: false,
      budget_data: nil,
      over_budget: false,
      dismissing: false,
      capability_groups: [:hierarchy, :local_execution],
      consensus_retry_count: 0,
      prompt_fields: nil,
      system_prompt: nil,
      active_skills: [],
      todos: [],
      parent_pid: nil,
      active_routers: %{},
      shell_routers: %{}
    }

    %{state: base_state, deps: deps, sandbox_owner: sandbox_owner}
  end

  # Helper: add an execute_shell action to pending_actions
  defp with_pending_shell(state, action_id, command \\ "echo hello") do
    %{
      state
      | pending_actions:
          Map.put(state.pending_actions, action_id, %{
            type: :execute_shell,
            params: %{command: command},
            timestamp: DateTime.utc_now()
          })
    }
  end

  # Helper: build Phase 1 (async ack) result - status: :running, has command_id
  defp phase1_result(command_id) do
    {:ok,
     %{
       command_id: command_id,
       status: :running,
       sync: false,
       action: "shell",
       command: "echo hello",
       started_at: DateTime.utc_now()
     }}
  end

  # Helper: build Phase 1 opts (as ActionExecutor dispatch would send)
  defp phase1_opts do
    [
      action_atom: :execute_shell,
      wait_value: false,
      always_sync: false,
      action_response: %{action: :execute_shell, params: %{command: "echo hello"}, wait: false}
    ]
  end

  # Helper: build Phase 2 (completion) result - status: :completed, has stdout/exit_code
  defp phase2_result(command \\ "echo hello") do
    {:ok,
     %{
       action: "shell",
       command: command,
       stdout: "hello\n",
       stderr: "",
       exit_code: 0,
       execution_time_ms: 1500,
       status: :completed,
       sync: false
     }}
  end

  # Helper: build Phase 2 opts (as ShellCompletion would send after fix)
  defp phase2_opts do
    [action_atom: :execute_shell]
  end

  # ============================================================================
  # R100: Phase 1 Does NOT Clear pending_actions
  # ============================================================================

  describe "R100: Phase 1 keeps pending_actions" do
    @tag :unit
    test "async shell ack (Phase 1) keeps action in pending_actions",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      command_id = Ecto.UUID.generate()
      state = with_pending_shell(state, action_id)

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase1_result(command_id),
          phase1_opts()
        )

      # BUG: Phase 1 (async ack) unconditionally deletes action from pending_actions.
      # When Phase 2 arrives 1-5s later with the same action_id, Map.get returns nil
      # and the completion result (stdout, exit_code) is silently discarded.
      # FIX: Detect async shell ack (status: :running, has command_id) and skip deletion.
      assert Map.has_key?(new_state.pending_actions, action_id),
             "Phase 1 async ack should NOT remove action from pending_actions. " <>
               "Phase 2 (completion with stdout/exit_code) still needs to find it. " <>
               "Got pending_actions keys: #{inspect(Map.keys(new_state.pending_actions))}"
    end
  end

  # ============================================================================
  # R101: Phase 2 Clears pending_actions
  # ============================================================================

  describe "R101: Phase 2 clears pending_actions" do
    @tag :unit
    test "shell completion (Phase 2) removes action from pending_actions",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      state = with_pending_shell(state, action_id)

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase2_result(),
          phase2_opts()
        )

      # Phase 2 (completion) should clear pending_actions as normal.
      # This is the standard behavior for completed actions.
      refute Map.has_key?(new_state.pending_actions, action_id),
             "Phase 2 completion should remove action from pending_actions. " <>
               "Got pending_actions keys: #{inspect(Map.keys(new_state.pending_actions))}"
    end
  end

  # ============================================================================
  # R102: Phase 2 Result Stored in History
  # ============================================================================

  describe "R102: Phase 2 result in history" do
    @tag :unit
    test "shell completion result stored in history",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      state = with_pending_shell(state, action_id)

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase2_result(),
          phase2_opts()
        )

      # Verify result is in at least one model history
      all_entries =
        new_state.model_histories
        |> Map.values()
        |> List.flatten()

      result_entries = Enum.filter(all_entries, fn entry -> entry.type == :result end)

      refute result_entries == [],
             "Phase 2 completion should be stored in model histories. " <>
               "Got entry types: #{inspect(Enum.map(all_entries, & &1.type))}"
    end
  end

  # ============================================================================
  # R103: Phase 1 Still Triggers Continuation
  # ============================================================================

  describe "R103: Phase 1 triggers continuation" do
    @tag :unit
    test "async shell ack triggers consensus continuation",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      command_id = Ecto.UUID.generate()
      state = with_pending_shell(state, action_id, "sleep 2")

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase1_result(command_id),
          phase1_opts()
        )

      # Phase 1 should trigger consensus continuation so the agent can
      # proceed (issue check_id, take other actions, etc.)
      assert new_state.consensus_scheduled == true,
             "Phase 1 ack should schedule consensus continuation so agent can proceed. " <>
               "consensus_scheduled: #{inspect(new_state.consensus_scheduled)}"
    end
  end

  # ============================================================================
  # R104: Phase 2 Triggers Continuation
  # ============================================================================

  describe "R104: Phase 2 triggers continuation" do
    @tag :unit
    test "shell completion triggers consensus continuation",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      state = with_pending_shell(state, action_id)

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase2_result(),
          phase2_opts()
        )

      # Phase 2 should trigger consensus so the agent sees the output.
      assert new_state.consensus_scheduled == true,
             "Phase 2 completion should schedule consensus continuation. " <>
               "consensus_scheduled: #{inspect(new_state.consensus_scheduled)}"
    end
  end

  # ============================================================================
  # R105: Both Phases Stored in History
  # ============================================================================

  describe "R105: both phases in history" do
    @tag :unit
    test "both Phase 1 ack and Phase 2 completion stored in history",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      command_id = Ecto.UUID.generate()
      state = with_pending_shell(state, action_id)

      # Process Phase 1 (async ack)
      {:noreply, state_after_p1} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          phase1_result(command_id),
          phase1_opts()
        )

      # Process Phase 2 (completion with stdout)
      # BUG: Phase 1 deleted action_id from pending_actions, so Phase 2
      # finds nil and the result is discarded with a warning log.
      # Use a ref to capture the return value from inside capture_log
      result_ref = make_ref()

      capture_log(fn ->
        result =
          ActionResultHandler.handle_action_result(
            state_after_p1,
            action_id,
            phase2_result(),
            phase2_opts()
          )

        send(self(), {result_ref, result})
      end)

      {:noreply, state_after_p2} =
        receive do
          {^result_ref, result} -> result
        after
          1000 -> flunk("Phase 2 handle_action_result did not return within timeout")
        end

      # Both entries should be in history
      all_entries =
        state_after_p2.model_histories
        |> Map.values()
        |> List.flatten()

      result_entries = Enum.filter(all_entries, fn entry -> entry.type == :result end)

      # Need at least 2 result entries: Phase 1 ack + Phase 2 completion
      assert length(result_entries) >= 2,
             "Both Phase 1 ack and Phase 2 completion should be in history. " <>
               "Got #{length(result_entries)} result entries. " <>
               "Expected >= 2 (ack + completion). " <>
               "Entry types: #{inspect(Enum.map(all_entries, & &1.type))}"
    end
  end

  # ============================================================================
  # R106: Non-Shell Results Unaffected
  # ============================================================================

  describe "R106: non-shell results unaffected" do
    @tag :unit
    test "non-shell action results still clear pending_actions",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"

      state = %{
        state
        | pending_actions:
            Map.put(state.pending_actions, action_id, %{
              type: :orient,
              params: %{},
              timestamp: DateTime.utc_now()
            })
      }

      orient_result = {:ok, %{action: "orient", status: "reviewed context"}}

      orient_opts = [
        action_atom: :orient,
        wait_value: false,
        always_sync: true,
        action_response: %{action: :orient, params: %{}, wait: false}
      ]

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          orient_result,
          orient_opts
        )

      # Non-shell results should be deleted from pending_actions as before.
      # The async_shell_phase1? guard must NOT false-positive on non-shell results.
      refute Map.has_key?(new_state.pending_actions, action_id),
             "Non-shell action results should still clear pending_actions. " <>
               "The async_shell_phase1? guard should not match orient results."
    end
  end

  # ============================================================================
  # R107: Sync Shell Results Unaffected
  # ============================================================================

  describe "R107: sync shell clears pending_actions" do
    @tag :unit
    test "sync shell results clear pending_actions immediately",
         %{state: state} do
      action_id = "action_#{state.agent_id}_1"
      state = with_pending_shell(state, action_id, "echo fast")

      sync_result =
        {:ok,
         %{
           action: "shell",
           sync: true,
           stdout: "fast\n",
           stderr: "",
           exit_code: 0,
           execution_time_ms: 10
         }}

      sync_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{action: :execute_shell, params: %{command: "echo fast"}, wait: false}
      ]

      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          state,
          action_id,
          sync_result,
          sync_opts
        )

      # Sync shell results (sync: true) complete immediately — no Phase 2 coming.
      # pending_actions should be cleared as normal.
      refute Map.has_key?(new_state.pending_actions, action_id),
             "Sync shell results should clear pending_actions immediately. " <>
               "No Phase 2 will arrive for sync completions."
    end
  end

  # ============================================================================
  # R108: End-to-End Async Shell Lifecycle (System Test)
  # ============================================================================

  describe "R108: end-to-end async shell lifecycle" do
    @tag :system
    test "end-to-end async shell: Phase 1, Phase 2, both in history",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      # Spawn a real agent with test_mode + skip_consensus
      config = %{
        agent_id: "agent-e2e-shell-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        budget_data: nil,
        prompt_fields: %{
          provided: %{task_description: "E2E shell Phase 2 test"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: [],
        capability_groups: [:hierarchy, :local_execution]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: sandbox_owner
        )

      # Step 1: Simulate Phase 1 (async ack) arriving from ActionExecutor dispatch
      action_id = "action_#{config.agent_id}_1"
      command_id = Ecto.UUID.generate()

      # Add pending action (as ActionExecutor would before dispatch)
      GenServer.cast(
        agent_pid,
        {:add_pending_action, action_id, :execute_shell, %{command: "echo phase2_test_output"}}
      )

      # Wait for pending action to be registered
      poll_pending = fn ->
        {:ok, s} = Quoracle.Agent.Core.get_state(agent_pid)
        Map.has_key?(s.pending_actions, action_id)
      end

      Test.IsolationHelpers.poll_until(poll_pending, 5000)

      # Send Phase 1 (async ack) with command_id
      phase1_opts = [
        action_atom: :execute_shell,
        wait_value: false,
        always_sync: false,
        action_response: %{
          action: :execute_shell,
          params: %{command: "echo phase2_test_output"},
          wait: false
        },
        router_pid: self()
      ]

      phase1_result =
        {:ok,
         %{
           command_id: command_id,
           status: :running,
           sync: false,
           action: "shell",
           command: "echo phase2_test_output",
           started_at: DateTime.utc_now()
         }}

      GenServer.cast(agent_pid, {:action_result, action_id, phase1_result, phase1_opts})

      # Wait for Phase 1 to be processed (history should have an entry)
      poll_phase1 = fn ->
        {:ok, s} = Quoracle.Agent.Core.get_state(agent_pid)

        all_entries =
          s.model_histories
          |> Map.values()
          |> List.flatten()

        Enum.any?(all_entries, fn e -> e.type == :result end)
      end

      Test.IsolationHelpers.poll_until(poll_phase1, 5000)

      # Verify Phase 1 processed: action_id should still be in pending_actions
      {:ok, state_after_p1} = Quoracle.Agent.Core.get_state(agent_pid)

      # BUG: Phase 1 deleted action_id from pending_actions
      assert Map.has_key?(state_after_p1.pending_actions, action_id),
             "After Phase 1, action_id should still be in pending_actions " <>
               "(Phase 2 hasn't arrived yet). " <>
               "pending_actions keys: #{inspect(Map.keys(state_after_p1.pending_actions))}"

      # Step 2: Send Phase 2 (completion with stdout) — same action_id
      phase2_result =
        {:ok,
         %{
           action: "shell",
           command: "echo phase2_test_output",
           stdout: "phase2_test_output\n",
           stderr: "",
           exit_code: 0,
           execution_time_ms: 1500,
           status: :completed,
           sync: false
         }}

      # Phase 2 opts (from ShellCompletion after fix)
      phase2_opts = [action_atom: :execute_shell]

      capture_log(fn ->
        GenServer.cast(agent_pid, {:action_result, action_id, phase2_result, phase2_opts})
      end)

      # Wait for Phase 2 to be processed (pending_actions should be cleared)
      poll_phase2 = fn ->
        {:ok, s} = Quoracle.Agent.Core.get_state(agent_pid)
        not Map.has_key?(s.pending_actions, action_id)
      end

      Test.IsolationHelpers.poll_until(poll_phase2, 5000)

      # Verify Phase 2 processed
      {:ok, final_state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Action should be cleared from pending_actions
      refute Map.has_key?(final_state.pending_actions, action_id),
             "After Phase 2, action_id should be removed from pending_actions. " <>
               "Got: #{inspect(Map.keys(final_state.pending_actions))}"

      # Both Phase 1 and Phase 2 should be in history
      all_entries =
        final_state.model_histories
        |> Map.values()
        |> List.flatten()

      result_entries = Enum.filter(all_entries, fn entry -> entry.type == :result end)

      # BUG: Only Phase 1 is in history. Phase 2 was discarded because
      # pending_actions no longer contained the action_id.
      assert length(result_entries) >= 2,
             "Both Phase 1 ack and Phase 2 completion should be in history. " <>
               "Got #{length(result_entries)} result entries. " <>
               "All entry types: #{inspect(Enum.map(all_entries, & &1.type))}"

      # Verify Phase 2 content (stdout) is in at least one history entry
      has_stdout_content =
        Enum.any?(result_entries, fn entry ->
          is_binary(entry.content) and String.contains?(entry.content, "phase2_test_output")
        end)

      assert has_stdout_content,
             "Phase 2 completion should have stdout content in history. " <>
               "Expected to find 'phase2_test_output' in result entries."
    end
  end
end
