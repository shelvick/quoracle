defmodule Quoracle.Actions.SpawnAsyncTest do
  @moduledoc """
  Tests for ACTION_Spawn async pattern (R1-R11).

  ARC Verification Criteria:
  - R1: Spawn returns immediately (< 100ms)
  - R2: Child ID format unchanged (agent-{uuid})
  - R3: Background task spawns child
  - R4: Child receives initial message
  - R5: Spawn failure notification to parent
  - R6: Sandbox isolation in background
  - R7: Message to not-yet-spawned child returns error
  - R8: Concurrent spawns create unique children
  - R9: Full spawn flow system test
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers, only: [create_test_profile: 0]

  alias Quoracle.Actions.Spawn
  alias Quoracle.Models.TableConsensusConfig
  alias Test.IsolationHelpers

  setup do
    # Configure summarization model (required by FieldTransformer)
    {:ok, _} =
      TableConsensusConfig.upsert("summarization_model", %{
        "model_id" => "google-vertex:gemini-2.0-flash"
      })

    deps = IsolationHelpers.create_isolated_deps()

    # Subscribe to lifecycle events for testing broadcasts
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Add spawn_complete_notify so tests can wait for background task
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    # Track spawned PIDs for cleanup (prevents DB connection leaks)
    # Use Agent.start (not start_link) so Agent survives test exit for on_exit cleanup
    {:ok, pids_tracker} = Agent.start(fn -> [] end)
    deps = Map.put(deps, :pids_tracker, pids_tracker)

    on_exit(fn ->
      # Kill all tracked mock processes before sandbox_owner exits
      # These are simple spawned processes (not real GenServers), so Process.exit is fine
      if Process.alive?(pids_tracker) do
        pids = Agent.get(pids_tracker, & &1)

        Enum.each(pids, fn pid ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end)

        Agent.stop(pids_tracker)
      end
    end)

    # Parent config with long narrative to trigger LLM summarization
    deps =
      Map.put(deps, :parent_config, %{
        task_id: "test-task-123",
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{},
          transformed: %{
            # Long narrative to trigger summarization (>500 chars)
            accumulated_narrative: String.duplicate("Parent context. ", 50)
          }
        },
        models: [],
        sandbox_owner: Map.get(deps, :sandbox_owner),
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      })

    # Create test profile for spawn_child (required since v24.0)
    profile = create_test_profile()

    {:ok, deps: deps, profile: profile}
  end

  # Helper to wait for background spawn to complete (prevents sandbox cleanup race)
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, result} -> result
    after
      timeout -> {:error, :spawn_complete_timeout}
    end
  end

  # Helper to track spawned PID for cleanup
  defp track_pid(deps, pid) when is_pid(pid) do
    if tracker = deps[:pids_tracker], do: Agent.update(tracker, fn pids -> [pid | pids] end)
    pid
  end

  describe "R1: Spawn Returns Immediately" do
    # R1: WHEN spawn_child executed THEN returns {:ok, %{agent_id: ...}} before background work completes
    test "spawn_child returns immediately without blocking on LLM", %{
      deps: deps,
      profile: profile
    } do
      params = %{
        "task_description" => "Analyze the codebase",
        "success_criteria" => "Complete analysis",
        "immediate_context" => String.duplicate("Additional context. ", 30),
        "approach_guidance" => "Be thorough",
        "profile" => profile.name
      }

      test_pid = self()

      # Mock dynsup that blocks until test explicitly unblocks it.
      # If spawn were synchronous, it would deadlock here (mock waits
      # for :proceed, but :proceed is only sent after spawn returns).
      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, _config, _opts ->
          send(test_pid, {:mock_started, self()})

          receive do
            :proceed -> :ok
          after
            30_000 -> :ok
          end

          pid = spawn_link(fn -> :timer.sleep(:infinity) end)
          track_pid(deps, pid)
          {:ok, pid}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Spawn MUST return before mock completes (async dispatch)
      {:ok, spawn_result} = Spawn.execute(params, "parent-1", opts)
      assert is_binary(spawn_result.agent_id)

      # Mock is still blocking — spawn returned before background work finished
      assert_receive {:mock_started, mock_pid}, 5000

      # Unblock mock so background task can complete
      send(mock_pid, :proceed)

      # Wait for background task to complete before test cleanup
      wait_for_spawn_complete(spawn_result.agent_id)
    end
  end

  describe "R3: Background Task Spawns Child" do
    # R3: WHEN spawn_child returns THEN child agent appears in registry within reasonable time
    test "child agent appears in registry after background spawn completes", %{
      deps: deps,
      profile: profile
    } do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      child_registered = :erlang.make_ref()
      # Capture test PID before entering mock (mock runs in background Task)
      test_pid = self()
      registry = deps.registry

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, config, _opts ->
            agent_id = config.agent_id
            mock_pid = self()

            # Spawn child that registers ITSELF (not the background Task)
            child_pid =
              spawn_link(fn ->
                # Child registers itself so entry persists after Task completes
                Registry.register(registry, {:agent, agent_id}, %{
                  pid: self(),
                  parent_pid: config.parent_pid,
                  agent_id: agent_id
                })

                # Notify both mock and test that registration is complete
                send(mock_pid, :child_registered_internal)
                send(test_pid, {:child_registered, child_registered, self()})
                :timer.sleep(:infinity)
              end)

            track_pid(deps, child_pid)

            # Wait for child to actually register (event-based, not time-based)
            receive do
              :child_registered_internal -> :ok
            after
              5000 -> :ok
            end

            {:ok, child_pid}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Spawn returns immediately with child_id
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_id = result.agent_id

      # In async pattern: child may not exist immediately
      # Wait for background task to complete registration
      assert_receive {:child_registered, ^child_registered, _child_pid}, 30_000
      # Now child should be in registry
      case Registry.lookup(deps.registry, {:agent, child_id}) do
        [{_pid, meta}] ->
          assert meta.agent_id == child_id

        [] ->
          flunk("Child agent #{child_id} not found in registry after background spawn")
      end

      # Wait for background task to complete before test cleanup
      wait_for_spawn_complete(child_id)
      # Cleanup handled by on_exit via pids_tracker
    end
  end

  describe "R5: Spawn Failure Notification" do
    # R5: WHEN background spawn fails THEN parent receives failure message via send_message
    test "parent receives spawn_failed message on background failure", %{
      deps: deps,
      profile: profile
    } do
      test_pid = self()

      params = %{
        "task_description" => "This spawn will fail",
        "success_criteria" => "Never reached",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Mock dynsup to fail in background
      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, _config, _opts ->
            # Simulate background spawn failure
            {:error, :simulated_spawn_failure}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: test_pid]

      # Spawn returns immediately with child_id (even though it will fail)
      # with_log suppresses expected "Background spawn failed" warning
      {result, _log} =
        with_log(fn ->
          Spawn.execute(params, "parent-1", opts)
        end)

      # In async pattern: spawn returns {:ok, _} immediately
      # Then background task fails and notifies parent
      case result do
        {:ok, spawn_result} ->
          # Async pattern: Should receive failure notification
          assert_receive {:spawn_failed, failure_info},
                         30_000,
                         "Parent should receive spawn_failed notification"

          assert failure_info.child_id == spawn_result.agent_id
          assert failure_info.reason == :simulated_spawn_failure

          # Wait for background task to complete before test cleanup
          wait_for_spawn_complete(spawn_result.agent_id)

        {:error, _} ->
          # Current sync pattern: fails immediately
          # This is the EXPECTED behavior that should FAIL this test
          flunk(
            "Spawn returned error synchronously. " <>
              "In async pattern, spawn should return {:ok, _} immediately " <>
              "and notify parent of failure via message."
          )
      end
    end
  end

  describe "R6: Sandbox Isolation in Background" do
    # R6: WHEN spawn runs in test THEN background task has DB access via Sandbox.allow
    test "background spawn task has sandbox access in tests", %{deps: deps, profile: profile} do
      test_pid = self()

      params = %{
        "task_description" => "Test with DB access",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, config, _opts ->
            # Try to access DB in background task
            # This tests that Sandbox.allow was called properly
            try do
              # This would fail without proper sandbox access
              _result = Quoracle.Repo.query("SELECT 1")
              send(test_pid, {:db_access_success, config.agent_id})
            rescue
              DBConnection.OwnershipError ->
                send(test_pid, {:db_access_failed, :ownership_error})
            end

            pid = spawn_link(fn -> :timer.sleep(:infinity) end)
            track_pid(deps, pid)
            {:ok, pid}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "parent-1", opts)

      # Background task should have DB access
      assert_receive {:db_access_success, child_id}, 30_000
      assert child_id == result.agent_id

      # Wait for background task to complete before test cleanup
      wait_for_spawn_complete(result.agent_id)
      # Cleanup handled by on_exit via pids_tracker
    end
  end

  describe "R9: Message to Not-Yet-Spawned Child" do
    # R9: WHEN parent sends message to child_id before background spawn completes
    #     THEN message is not delivered (sent_to is empty)
    test "message to pending child is not delivered", %{deps: deps} do
      # Generate a child_id that doesn't exist in registry
      fake_child_id = "agent-#{Ecto.UUID.generate()}"

      # Try to send message to non-existent child
      send_opts =
        Map.to_list(deps) ++
          [
            agent_pid: self(),
            action_id: "test-action-#{System.unique_integer([:positive])}"
          ]

      # Capture expected "Target agent not found" error log
      capture_log(fn ->
        send_result =
          Quoracle.Actions.SendMessage.execute(
            %{to: [fake_child_id], content: "Hello child"},
            "parent-1",
            send_opts
          )

        # SendMessage returns success but with empty sent_to list
        # This tests the edge case where async spawn returns child_id
        # but child hasn't been created yet - message won't be delivered
        assert {:ok, result} = send_result

        assert result.sent_to == [],
               "Message to non-existent child should not be delivered. " <>
                 "In async pattern, child may not exist immediately after spawn returns."
      end)
    end
  end

  describe "R11: Full Spawn Flow System Test" do
    # R11: WHEN user creates task with spawn_child action
    #      THEN child appears in UI and responds
    @tag :system
    test "full spawn flow from task creation to child response", %{deps: deps, profile: profile} do
      # This is an acceptance test - tests the full user-observable flow
      parent_id = "parent-system-test"
      test_pid = self()

      params = %{
        "task_description" => "System test child task",
        "success_criteria" => "Respond to parent",
        "immediate_context" => "Full flow test",
        "approach_guidance" => "Complete the task",
        "profile" => profile.name
      }

      child_spawned_ref = make_ref()
      registry = deps.registry

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, config, _opts ->
            agent_id = config.agent_id
            mock_pid = self()

            # Spawn child that registers ITSELF (not the background Task)
            child_pid =
              spawn_link(fn ->
                # Child registers itself so entry persists after Task completes
                Registry.register(registry, {:agent, agent_id}, %{
                  pid: self(),
                  agent_id: agent_id,
                  parent_id: parent_id
                })

                # Notify mock that registration is complete, then notify test
                send(mock_pid, :child_registered_internal)
                send(test_pid, {:child_alive, child_spawned_ref, agent_id})
                :timer.sleep(:infinity)
              end)

            track_pid(deps, child_pid)

            # Wait for child to actually register (event-based, not time-based)
            receive do
              :child_registered_internal -> :ok
            after
              5000 -> :ok
            end

            {:ok, child_pid}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: test_pid]

      # Step 1: User triggers spawn_child action
      {:ok, spawn_result} = Spawn.execute(params, parent_id, opts)

      # Step 2: Spawn returns immediately with child_id
      assert is_binary(spawn_result.agent_id)
      child_id = spawn_result.agent_id

      # Step 3: User observes child in UI (via broadcast)
      assert_receive {:agent_spawned, broadcast}, 30_000
      assert broadcast.agent_id == child_id
      assert broadcast.parent_id == parent_id
      assert broadcast.task == "System test child task"

      # Step 4: Child agent is alive and working
      assert_receive {:child_alive, ^child_spawned_ref, ^child_id}, 30_000
      # Step 5: Child is findable in registry
      case Registry.lookup(deps.registry, {:agent, child_id}) do
        [{pid, _meta}] ->
          assert Process.alive?(pid)

        [] ->
          flunk("Child not found in registry after spawn")
      end

      # Wait for background task to complete before test cleanup
      wait_for_spawn_complete(child_id)
      # Cleanup handled by on_exit via pids_tracker
    end
  end
end
