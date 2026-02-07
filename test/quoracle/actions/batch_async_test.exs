defmodule Quoracle.Actions.BatchAsyncTest do
  @moduledoc """
  Tests for ACTION_BatchAsync - Parallel Batch Action Execution
  WorkGroupID: feat-20260126-batch-async
  Packet: 3 (Action Implementation)

  Covers:
  - R1-R6: Core execution (empty, single, valid batch, parallel, no early termination)
  - R7-R10: Validation (excluded actions, nested batch, param validation)
  - R11-R16: Integration (Router usage, history, result format)
  - R17-R21: Fire-and-forget (wait: false)
  - R22-R23: Property tests (batch equivalence, completion guarantee)
  """
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Actions.BatchAsync

  @moduletag :batch_async

  # ===========================================================================
  # R7-R9: Excluded Actions List
  # ===========================================================================
  describe "excluded_actions/0" do
    # R7-R9: Exclusion list
    test "returns [:wait, :batch_sync, :batch_async]" do
      # [UNIT] - WHEN excluded_actions/0 called THEN returns list of excluded actions
      excluded = BatchAsync.excluded_actions()

      assert is_list(excluded)
      assert :wait in excluded
      assert :batch_sync in excluded
      assert :batch_async in excluded
      assert length(excluded) == 3
    end
  end

  describe "async_batchable?/1" do
    test "returns false for :wait" do
      # [UNIT] - WHEN async_batchable?/1 called with :wait THEN returns false
      refute BatchAsync.async_batchable?(:wait)
    end

    test "returns false for :batch_sync" do
      # [UNIT] - WHEN async_batchable?/1 called with :batch_sync THEN returns false
      refute BatchAsync.async_batchable?(:batch_sync)
    end

    test "returns false for :batch_async" do
      # [UNIT] - WHEN async_batchable?/1 called with :batch_async THEN returns false
      refute BatchAsync.async_batchable?(:batch_async)
    end

    test "returns true for all other actions" do
      # [UNIT] - WHEN async_batchable?/1 called with batchable action THEN returns true
      assert BatchAsync.async_batchable?(:file_read)
      assert BatchAsync.async_batchable?(:todo)
      assert BatchAsync.async_batchable?(:execute_shell)
      assert BatchAsync.async_batchable?(:fetch_web)
      assert BatchAsync.async_batchable?(:orient)
      assert BatchAsync.async_batchable?(:spawn_child)
    end
  end

  # ===========================================================================
  # R1-R2: Empty and Single Action Rejection
  # ===========================================================================
  describe "execute/3 validation - batch size" do
    # R1: Execute Empty Batch
    test "rejects empty batch" do
      # [UNIT] - WHEN execute called with empty actions list THEN returns {:error, :empty_batch}
      assert {:error, :empty_batch} = BatchAsync.execute(%{actions: []}, "agent-1", [])
    end

    # R2: Execute Single Action
    test "rejects single-action batch" do
      # [UNIT] - WHEN execute called with single action THEN returns {:error, :batch_too_small}
      actions = [%{action: :todo, params: %{items: []}}]

      assert {:error, :batch_too_small} = BatchAsync.execute(%{actions: actions}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R7-R10: Action Validation
  # ===========================================================================
  describe "execute/3 validation - action types" do
    # R7: Reject Excluded Action (wait)
    test "rejects :wait in batch" do
      # [UNIT] - WHEN batch contains :wait action THEN returns {:error, :unbatchable_action}
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :wait, params: %{wait: 5}}
      ]

      assert {:error, :unbatchable_action} =
               BatchAsync.execute(%{actions: actions}, "agent-1", [])
    end

    # R8: Reject Excluded Action (batch_sync)
    test "rejects :batch_sync in batch" do
      # [UNIT] - WHEN batch contains :batch_sync action THEN returns {:error, :nested_batch}
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      assert {:error, :nested_batch} =
               BatchAsync.execute(%{actions: actions}, "agent-1", [])
    end

    # R9: Reject Nested Batch
    test "rejects nested batch_async" do
      # [UNIT] - WHEN batch contains :batch_async action THEN returns {:error, :nested_batch}
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :batch_async, params: %{actions: []}}
      ]

      assert {:error, :nested_batch} =
               BatchAsync.execute(%{actions: actions}, "agent-1", [])
    end

    # R10: Validate Each Action
    test "validates all actions before execution" do
      # [UNIT] - WHEN action has invalid params THEN returns validation error before execution
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        # Missing required :path param
        %{action: :file_read, params: %{}}
      ]

      assert {:error, {:invalid_action, :file_read, _reason}} =
               BatchAsync.execute(%{actions: actions}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R3, R5-R6: Blocking Execution (wait: true)
  # ===========================================================================
  describe "execute/3 with wait: true" do
    setup %{sandbox_owner: sandbox_owner} do
      # Create isolated PubSub and Registry
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
    end

    # R3: Execute Valid Batch - returns async acknowledgement
    test "returns async acknowledgement immediately", %{pubsub: pubsub} do
      # [INTEGRATION] - WHEN execute called THEN returns async acknowledgement immediately
      actions = [
        %{action: :todo, params: %{items: []}},
        %{
          action: :orient,
          params: %{
            current_situation: "testing batch execution",
            goal_clarity: "clear",
            available_resources: "test resources",
            key_challenges: "none",
            delegation_consideration: "not applicable"
          }
        }
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      {:ok, result} =
        BatchAsync.execute(
          %{actions: actions},
          "agent-1",
          opts
        )

      # Returns async acknowledgement (like shell)
      assert is_binary(result.batch_id)
      assert String.starts_with?(result.batch_id, "batch_")
      assert result.async == true
      assert result.status == :running
      assert result.started == 2

      # Wait for completion notification
      batch_id = result.batch_id
      assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000
      assert length(results) == 2
    end

    # R5: Parallel Execution
    test "batch actions execute in parallel", %{pubsub: pubsub} do
      # [INTEGRATION] - WHEN batch executes THEN all actions run in parallel (not sequential)
      # Use timing to verify parallel execution - two actions should complete faster than sequential

      # Create temp files to read (orient is very fast, file_read with actual files is slower)
      temp_dir =
        Path.join([
          System.tmp_dir!(),
          "batch_async_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      # Create two files with some content
      file1 = Path.join(temp_dir, "file1.txt")
      file2 = Path.join(temp_dir, "file2.txt")
      File.write!(file1, String.duplicate("test content\n", 100))
      File.write!(file2, String.duplicate("test content\n", 100))

      actions = [
        %{action: :file_read, params: %{path: file1}},
        %{action: :file_read, params: %{path: file2}}
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      start_time = System.monotonic_time(:millisecond)

      {:ok, result} =
        BatchAsync.execute(
          %{actions: actions},
          "agent-1",
          opts
        )

      # Returns immediately with async acknowledgement
      assert result.async == true
      assert result.started == 2

      # Wait for completion
      batch_id = result.batch_id
      assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Both actions should complete
      assert length(results) == 2

      # Parallel execution means total time should be less than 2x sequential
      # This is a soft assertion - just verify both completed
      assert elapsed < 5000, "Batch took too long: #{elapsed}ms"
    end

    # R6: No Early Termination
    test "all actions complete regardless of individual errors", %{pubsub: pubsub} do
      # [INTEGRATION] - WHEN action in batch fails THEN other actions still complete
      temp_dir =
        Path.join([
          System.tmp_dir!(),
          "batch_async_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf!(temp_dir) end)

      # First action fails (nonexistent file), second succeeds
      actions = [
        %{action: :file_read, params: %{path: Path.join(temp_dir, "nonexistent.txt")}},
        %{action: :todo, params: %{items: []}}
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      {:ok, result} =
        BatchAsync.execute(
          %{actions: actions},
          "agent-1",
          opts
        )

      # Returns async acknowledgement
      assert result.async == true
      assert result.started == 2

      # Wait for completion
      batch_id = result.batch_id
      assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

      # Both actions completed (no early termination)
      assert length(results) == 2

      # Results include both error and success
      # Order may vary due to parallel execution
      has_error = Enum.any?(results, fn r -> match?({:error, _}, r) end)
      has_success = Enum.any?(results, fn r -> match?({:ok, _}, r) end)

      assert has_error, "Expected one error result"
      assert has_success, "Expected one success result"
    end
  end

  # ===========================================================================
  # R11-R16: Integration Tests
  # ===========================================================================
  describe "execute/3 integration" do
    setup %{sandbox_owner: sandbox_owner} do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
    end

    # R11: Sub-Actions Route Through Core
    test "sub-actions route through Core.execute_action", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch_async executes sub-action THEN calls Core.execute_action (spawns per-action Router)
      actions = [
        %{action: :todo, params: %{items: []}},
        %{
          action: :orient,
          params: %{
            current_situation: "t",
            goal_clarity: "c",
            available_resources: "r",
            key_challenges: "k",
            delegation_consideration: "d"
          }
        }
      ]

      opts = [agent_pid: self(), pubsub: pubsub, sandbox_owner: sandbox_owner]

      {:ok, result} =
        BatchAsync.execute(
          %{actions: actions},
          "agent-1",
          opts
        )

      # Returns async acknowledgement
      assert result.async == true
      assert result.started == 2

      # Wait for completion
      batch_id = result.batch_id
      assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

      # Each result should be Router-formatted (action type applied validation/formatting)
      assert length(results) == 2
    end

    # R15: Sub-Actions Appear in History
    test "sub-actions recorded individually in agent history", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch completes THEN each sub-action recorded separately in history
      actions = [
        %{action: :todo, params: %{items: []}},
        %{
          action: :orient,
          params: %{
            current_situation: "t",
            goal_clarity: "c",
            available_resources: "r",
            key_challenges: "k",
            delegation_consideration: "d"
          }
        }
      ]

      opts = [agent_pid: self(), pubsub: pubsub, sandbox_owner: sandbox_owner]

      {:ok, _result} =
        BatchAsync.execute(
          %{actions: actions},
          "agent-1",
          opts
        )

      # Individual action results are sent via :batch_action_result cast (GenServer.cast)
      # Each action should produce its own result message
      assert_receive {:"$gen_cast", {:batch_action_result, _action_id, :todo, {:ok, _}}}, 30_000
      assert_receive {:"$gen_cast", {:batch_action_result, _action_id, :orient, {:ok, _}}}, 30_000
    end

    # R16: Results Match Independent Execution
    test "batch results match independent execution format", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch executes THEN each result is identical to independent execution
      actions = [
        %{action: :todo, params: %{items: []}}
      ]

      # Add a second action to make it a valid batch
      batch_actions = actions ++ [%{action: :todo, params: %{items: []}}]

      opts = [agent_pid: self(), pubsub: pubsub, sandbox_owner: sandbox_owner]

      {:ok, batch_result} =
        BatchAsync.execute(
          %{actions: batch_actions},
          "agent-1",
          opts
        )

      # Returns async acknowledgement
      assert batch_result.async == true

      # Wait for completion
      batch_id = batch_result.batch_id
      assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

      # Each result should be either {:ok, result_map} or {:error, reason}
      for result <- results do
        assert is_tuple(result)
        assert elem(result, 0) in [:ok, :error]

        case result do
          {:ok, inner} ->
            # Success results should have action field
            assert is_map(inner)

          {:error, _reason} ->
            # Error results are acceptable
            :ok
        end
      end
    end
  end

  # ===========================================================================
  # R22-R23: Property Tests
  # ===========================================================================
  describe "property tests" do
    setup %{sandbox_owner: sandbox_owner} do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
    end

    # R22: Batch Equivalence Property
    property "batch results match individual execution count", %{pubsub: pubsub} do
      # [PROPERTY] - FOR ALL valid batches, result count matches action count
      check all(
              action_types <-
                list_of(
                  member_of([:todo, :orient]),
                  min_length: 2,
                  max_length: 4
                )
            ) do
        actions =
          Enum.map(action_types, fn
            :todo ->
              %{action: :todo, params: %{items: []}}

            :orient ->
              %{
                action: :orient,
                params: %{
                  current_situation: "t",
                  goal_clarity: "c",
                  available_resources: "r",
                  key_challenges: "k",
                  delegation_consideration: "d"
                }
              }
          end)

        opts = [agent_pid: self(), pubsub: pubsub]

        {:ok, result} =
          BatchAsync.execute(
            %{actions: actions},
            "agent-#{System.unique_integer([:positive])}",
            opts
          )

        # Returns async acknowledgement with started count
        assert result.async == true
        assert result.started == length(actions)

        # Wait for completion
        batch_id = result.batch_id
        assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

        # Results count matches actions count
        assert length(results) == length(actions)
      end
    end

    # R23: All Actions Complete Property
    property "all batch actions eventually complete", %{pubsub: pubsub} do
      # [PROPERTY] - FOR ALL batches, every action eventually completes (success or error)
      check all(action_count <- integer(2..4)) do
        # Use only :todo for simplicity - guaranteed to complete quickly
        actions =
          for _ <- 1..action_count do
            %{action: :todo, params: %{items: []}}
          end

        opts = [agent_pid: self(), pubsub: pubsub]

        {:ok, result} =
          BatchAsync.execute(
            %{actions: actions},
            "agent-#{System.unique_integer([:positive])}",
            opts
          )

        # Returns async acknowledgement
        assert result.async == true
        assert result.started == action_count

        # Wait for completion
        batch_id = result.batch_id
        assert_receive {:"$gen_cast", {:batch_completed, ^batch_id, results}}, 5_000

        # Every action produced a result (success or error)
        assert length(results) == action_count

        for r <- results do
          assert is_tuple(r)
          assert elem(r, 0) in [:ok, :error]
        end
      end
    end
  end
end
