defmodule Quoracle.Actions.BatchSyncTest do
  @moduledoc """
  Tests for ACTION_BatchSync - Batched Action Execution
  WorkGroupID: feat-20260123-batch-sync
  Packet: 3 (Action Implementation)

  Covers:
  - R1-R5: Core execution (empty, single, valid batch, stop-on-error, order)
  - R6-R8: Validation (non-batchable, nested, param validation)
  - R9-R11: Batchable actions list
  - R12-R13: Integration (result format, router usage)
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.BatchSync

  @moduletag :batch_sync

  # ===========================================================================
  # R9-R11: Batchable Actions List
  # ===========================================================================
  describe "batchable_actions/0" do
    # R9: Batchable Actions Function
    test "returns list of batchable action atoms" do
      # [UNIT] - WHEN batchable_actions/0 called THEN returns list of batchable action atoms
      actions = BatchSync.batchable_actions()

      assert is_list(actions)
      assert :file_read in actions
      assert :file_write in actions
      assert :todo in actions
      assert :orient in actions
      assert :send_message in actions
      assert :spawn_child in actions
      assert :generate_secret in actions
      assert :adjust_budget in actions
      assert :search_secrets in actions
    end

    # R10: Wait Excluded
    test "wait excluded from batchable actions" do
      # [UNIT] - WHEN batchable_actions/0 called THEN :wait is not in list
      actions = BatchSync.batchable_actions()

      refute :wait in actions
    end

    # R11: Batch Sync Excluded
    test "batch_sync excluded from batchable actions (no nesting)" do
      # [UNIT] - WHEN batchable_actions/0 called THEN :batch_sync is not in list
      actions = BatchSync.batchable_actions()

      refute :batch_sync in actions
    end
  end

  # ===========================================================================
  # R1-R2: Empty and Single Action Rejection
  # ===========================================================================
  describe "execute/3 validation - batch size" do
    # R1: Execute Empty Batch
    test "rejects empty batch" do
      # [UNIT] - WHEN execute called with empty actions list THEN returns {:error, :empty_batch}
      assert {:error, :empty_batch} = BatchSync.execute(%{actions: []}, "agent-1", [])
    end

    # R2: Execute Single Action
    test "rejects single-action batch" do
      # [UNIT] - WHEN execute called with single action THEN returns {:error, :batch_too_small}
      actions = [%{action: :todo, params: %{items: []}}]

      assert {:error, :batch_too_small} = BatchSync.execute(%{actions: actions}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R6-R8: Action Validation
  # ===========================================================================
  describe "execute/3 validation - action types" do
    # R6: Reject Non-Batchable Action
    test "rejects non-batchable actions" do
      # [UNIT] - WHEN batch contains non-batchable action (e.g., :wait) THEN returns {:error, {:unbatchable_action, action}}
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :wait, params: %{wait: 5}}
      ]

      assert {:error, {:unbatchable_action, :wait}} =
               BatchSync.execute(%{actions: actions}, "agent-1", [])
    end

    # R7: Reject Nested Batch
    test "rejects nested batch_sync" do
      # [UNIT] - WHEN batch contains :batch_sync action THEN returns {:error, :nested_batch}
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      assert {:error, :nested_batch} = BatchSync.execute(%{actions: actions}, "agent-1", [])
    end

    # R8: Validate Each Action
    test "validates all actions before execution" do
      # [UNIT] - WHEN action has invalid params THEN returns validation error before execution
      actions = [
        %{action: :file_read, params: %{path: "/tmp/a.txt"}},
        %{action: :file_read, params: %{}}
      ]

      assert {:error, {:validation_error, _reason}} =
               BatchSync.execute(%{actions: actions}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R3-R5: Execution Flow
  # ===========================================================================
  describe "execute/3 execution flow" do
    setup do
      # Create isolated PubSub
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      # Create isolated Registry
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      # BatchSync calls action modules directly (not via Router) to avoid deadlock
      # No Router needed in this setup
      %{pubsub: pubsub_name, registry: registry_name}
    end

    # R3: Execute Valid Batch
    test "runs valid batch sequentially", %{pubsub: pubsub} do
      # [UNIT] - WHEN execute called with valid batch THEN executes all actions sequentially and returns {:ok, results}
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

      # BatchSync calls modules directly, no router_pid needed
      opts = [agent_pid: self(), pubsub: pubsub]

      assert {:ok, %{results: results}} = BatchSync.execute(%{actions: actions}, "agent-1", opts)
      assert length(results) == 2
      assert Enum.at(results, 0).action == "todo"
      assert Enum.at(results, 1).action == "orient"
    end

    # R4: Stop on First Error
    test "stops on first error with partial results", %{pubsub: pubsub} do
      # [UNIT] - WHEN action in batch fails THEN stops execution and returns {:error, {partial_results, error}}
      # Create a temp dir for the test
      temp_dir =
        Path.join([
          System.tmp_dir!(),
          "batch_sync_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf!(temp_dir) end)

      # First action succeeds, second fails (nonexistent file), third never reached
      actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :file_read, params: %{path: Path.join(temp_dir, "nonexistent.txt")}},
        %{action: :todo, params: %{items: []}}
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      assert {:error, {partial_results, _error}} =
               BatchSync.execute(%{actions: actions}, "agent-1", opts)

      # Only first action succeeded
      assert length(partial_results) == 1
      assert Enum.at(partial_results, 0).action == "todo"
    end

    # R5: Preserve Result Order
    test "results preserve input order", %{pubsub: pubsub} do
      # [UNIT] - WHEN batch executes successfully THEN results are in same order as input actions
      # Use different action types to verify order is preserved
      orient_params = %{
        current_situation: "test",
        goal_clarity: "clear",
        available_resources: "test",
        key_challenges: "none",
        delegation_consideration: "n/a"
      }

      actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :orient, params: orient_params},
        %{action: :todo, params: %{items: []}}
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      assert {:ok, %{results: results}} = BatchSync.execute(%{actions: actions}, "agent-1", opts)
      assert length(results) == 3

      # Verify order preserved via action type
      action_types = Enum.map(results, & &1.action)
      assert action_types == ["todo", "orient", "todo"]
    end
  end

  # ===========================================================================
  # R12-R13: Integration
  # ===========================================================================
  describe "execute/3 integration" do
    setup %{sandbox_owner: sandbox_owner} do
      # Create isolated PubSub
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      # Create isolated Registry
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      # BatchSync calls modules directly, no Router needed for batch execution
      %{pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
    end

    # R12: Results Match Independent Execution
    test "batch results match independent execution format", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch executes THEN each result is identical to independent execution
      # Execute via batch
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{
          action: :orient,
          params: %{
            current_situation: "test",
            goal_clarity: "clear",
            available_resources: "test",
            key_challenges: "none",
            delegation_consideration: "n/a"
          }
        }
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      {:ok, %{results: [batch_todo_result | _]}} =
        BatchSync.execute(%{actions: batch_actions}, "agent-1", opts)

      # Per-action Router (v28.0): Spawn Router for independent execution comparison
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router} =
        Quoracle.Actions.Router.start_link(
          action_type: :todo,
          action_id: action_id,
          agent_id: "agent-1",
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Execute independently via Router
      {:ok, independent_result} =
        Quoracle.Actions.Router.execute(
          router,
          :todo,
          %{items: []},
          "agent-1",
          opts
        )

      # v2.0: Batch wraps results as %{action: "todo", result: inner_result}
      # Router.execute returns raw result, so compare batch's inner result to Router result
      assert batch_todo_result.action == "todo"
      assert batch_todo_result.result.count == independent_result.count
      assert batch_todo_result.result.action == independent_result.action

      # Batch result has wrapped format
      assert Map.has_key?(batch_todo_result, :action)
      assert Map.has_key?(batch_todo_result, :result)
    end

    # R13: Direct Module Calls (not Router)
    test "batch uses direct module calls for actions", %{pubsub: pubsub} do
      # [INTEGRATION] - WHEN batch executes THEN calls modules directly (not via Router)
      # BatchSync calls ActionMapper.get_action_module then module.execute directly
      # to avoid deadlock (Router blocked in Task.yield when BatchSync dispatched)
      actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :todo, params: %{items: []}}
      ]

      opts = [agent_pid: self(), pubsub: pubsub]

      # Both should succeed via direct module calls
      assert {:ok, %{results: results}} = BatchSync.execute(%{actions: actions}, "agent-1", opts)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.action == "todo"))
    end
  end
end
