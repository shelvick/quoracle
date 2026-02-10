defmodule Quoracle.Actions.SpawnAutoConsensusTest do
  @moduledoc """
  Acceptance test: Child agents automatically trigger consensus after spawn.

  This test verifies the fix for regression introduced in commit cf45c0b where
  `Core.handle_agent_message` was removed without adding a replacement trigger.

  The fix adds `Core.send_user_message(child_pid, task_string)` which triggers
  consensus automatically, matching root agent behavior (event_handlers.ex:54).

  ARC Verification:
  - R1: send_user_message triggers consensus processing (state change proves this)
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  import Test.AgentTestHelpers,
    only: [
      create_test_profile: 0,
      spawn_agent_with_cleanup: 3
    ]

  alias Quoracle.Actions.Spawn
  alias Quoracle.Agent.Core
  alias Quoracle.Models.TableConsensusConfig

  setup %{sandbox_owner: sandbox_owner} do
    # Configure summarization model (required by FieldTransformer)
    {:ok, _} =
      TableConsensusConfig.upsert("summarization_model", %{
        "model_id" => "google-vertex:gemini-2.0-flash"
      })

    deps = create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    {:ok, deps: deps, profile: create_test_profile()}
  end

  describe "R1: send_user_message triggers consensus" do
    @tag :acceptance
    test "agent state changes after send_user_message (proves consensus processing)", %{
      deps: deps
    } do
      # Create an agent with skip_auto_consensus so we control when consensus triggers
      config = %{
        agent_id: "test-state-change-#{System.unique_integer([:positive])}",
        task_id: "task-test",
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup,
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{task_description: "State change test"},
          transformed: %{}
        }
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

      # Get initial state
      {:ok, initial_state} = Core.get_state(agent_pid)
      initial_history_count = count_history_entries(initial_state.model_histories)

      # Suppress expected error logs (consensus fails without credentials)
      capture_log(fn ->
        # Call send_user_message - this is what spawn.ex now calls after spawning child
        # It should trigger consensus processing (which will fail without credentials,
        # but the state change proves the consensus path was triggered)
        Core.send_user_message(agent_pid, "State change test")

        # Synchronous call to verify processing completed (get_state is a GenServer.call
        # which waits for any pending casts like send_user_message to be processed first)
        {:ok, _} = Core.get_state(agent_pid)
      end)

      # Get state after send_user_message
      {:ok, final_state} = Core.get_state(agent_pid)
      final_history_count = count_history_entries(final_state.model_histories)

      # State should have changed - either history entries added or state changed
      # This proves send_user_message triggered consensus processing
      state_changed? =
        final_history_count > initial_history_count or
          initial_state.state != final_state.state

      assert state_changed?,
             """
             Agent state did not change after send_user_message.

             Initial history entries: #{initial_history_count}
             Final history entries: #{final_history_count}
             Initial state: #{inspect(initial_state.state)}
             Final state: #{inspect(final_state.state)}

             send_user_message should trigger consensus processing which modifies state.
             This is the critical behavior that spawn.ex depends on:
             - spawn.ex calls Core.send_user_message(child_pid, task_string)
             - This triggers handle_send_user_message in MessageHandler
             - Which calls get_action_consensus and processes the result

             If this test fails, child agents won't start working after spawn.
             """
    end

    @tag :acceptance
    test "history entry added proves consensus flow triggered", %{deps: deps, profile: _profile} do
      # More specific test: verify an event entry is added to history
      config = %{
        agent_id: "test-history-#{System.unique_integer([:positive])}",
        task_id: "task-test",
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup,
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{task_description: "History test"},
          transformed: %{}
        }
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

      # Verify initial histories are empty
      {:ok, initial_state} = Core.get_state(agent_pid)

      initial_entries =
        initial_state.model_histories
        |> Map.values()
        |> List.flatten()

      assert initial_entries == [], "Expected empty histories initially"

      # Suppress expected error logs
      capture_log(fn ->
        # send_user_message with content that matches task_description should NOT add
        # to history (per handle_send_user_message logic), but should still trigger consensus
        # Use different content to ensure history is updated
        Core.send_user_message(agent_pid, "Different message to add to history")

        # Synchronous call to verify processing completed
        {:ok, _} = Core.get_state(agent_pid)
      end)

      # Verify history was updated
      {:ok, final_state} = Core.get_state(agent_pid)

      final_entries =
        final_state.model_histories
        |> Map.values()
        |> List.flatten()

      assert final_entries != [],
             """
             No history entries after send_user_message.

             send_user_message should add an :event entry to model_histories
             (when content differs from task_description).

             This proves the MessageHandler.handle_send_user_message flow was triggered.
             """
    end
  end

  describe "R2: Spawn.execute triggers child consensus (acceptance)" do
    @tag :acceptance
    test "spawned child automatically triggers consensus", %{deps: deps, profile: profile} do
      # Create parent agent (required for spawn)
      parent_config = %{
        agent_id: "parent-spawn-acceptance-#{System.unique_integer([:positive])}",
        task_id: "task-parent",
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup,
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{task_description: "Parent task"},
          transformed: %{}
        }
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config, registry: deps.registry)

      {:ok, parent_state} = Core.get_state(parent_pid)

      # Spawn params - the task that child should auto-trigger consensus for
      spawn_params = %{
        "task_description" => "Child task that should auto-trigger consensus",
        "success_criteria" => "Complete the task",
        "immediate_context" => "Testing spawn auto-consensus",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Add spawn_complete_notify to wait for background spawn
      deps_with_notify = Map.put(deps, :spawn_complete_notify, self())

      # Build opts for Spawn.execute (includes parent_config to avoid deadlock)
      opts =
        Map.to_list(deps_with_notify) ++
          [
            agent_pid: parent_pid,
            parent_config: parent_state,
            test_mode: true
          ]

      # Suppress expected consensus failure logs
      capture_log(fn ->
        # USER ENTRY POINT: Call Spawn.execute (this exercises spawn.ex line 164)
        {:ok, spawn_result} = Spawn.execute(spawn_params, parent_state.agent_id, opts)
        child_id = spawn_result.agent_id

        # Wait for background spawn to complete
        receive do
          {:spawn_complete, ^child_id, {:ok, child_pid}} ->
            # Register cleanup for child
            on_exit(fn ->
              if Process.alive?(child_pid) do
                try do
                  GenServer.stop(child_pid, :normal, :infinity)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

            # USER-OBSERVABLE OUTCOME: Verify child triggered consensus
            {:ok, child_state} = Core.get_state(child_pid)
            history_count = count_history_entries(child_state.model_histories)

            # Either history has entries OR state changed from :initializing
            # This proves the send_user_message in spawn.ex triggered consensus
            consensus_triggered? = history_count > 0 or child_state.state != :initializing

            assert consensus_triggered?,
                   """
                   Spawned child did not trigger consensus automatically.

                   History entries: #{history_count}
                   Child state: #{inspect(child_state.state)}

                   When Spawn.execute creates a child, spawn.ex should call
                   Core.send_user_message(child_pid, task_string) which triggers
                   consensus processing.

                   This is the acceptance test for the fix to regression cf45c0b.
                   If this fails, child agents appear in UI but never start working.
                   """

          {:spawn_complete, ^child_id, {:error, reason}} ->
            flunk("Spawn failed: #{inspect(reason)}")
        after
          10_000 ->
            flunk("Timeout waiting for spawn to complete")
        end
      end)
    end
  end

  # Helper to count total entries across all model histories
  defp count_history_entries(model_histories) do
    model_histories
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end
end
