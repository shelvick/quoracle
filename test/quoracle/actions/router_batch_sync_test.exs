defmodule Quoracle.Actions.RouterBatchSyncTest do
  @moduledoc """
  Integration tests for Router dispatching batch_sync to BatchSync module.

  Addresses integration gaps found in feat-20260123-batch-sync audit:
  - R3-R5: Router dispatch integration
  - R6: ClientAPI always_sync_actions inclusion

  WorkGroupID: feat-20260123-batch-sync
  Packet: 4 (Integration Fix)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ClientAPI

  @moduletag :batch_sync

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :batch_sync,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name,
        sandbox_owner: sandbox_owner
      )

    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Create unique temp directory for file tests
    temp_dir =
      Path.join([
        System.tmp_dir!(),
        "router_batch_sync_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    {:ok,
     router: router,
     pubsub: pubsub_name,
     registry: registry_name,
     agent_id: agent_id,
     temp_dir: temp_dir}
  end

  # ===========================================================================
  # R3-R5: Router Dispatch Integration
  # ===========================================================================
  describe "R3: Router.execute dispatches batch_sync" do
    test "Router dispatches batch_sync to BatchSync module", %{router: router, agent_id: agent_id} do
      # [INTEGRATION] - WHEN Router receives batch_sync action THEN dispatches to BatchSync and executes batch
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{
          action: :orient,
          params: %{
            current_situation: "testing router dispatch",
            goal_clarity: "clear",
            available_resources: "test resources",
            key_challenges: "none",
            delegation_consideration: "not applicable"
          }
        }
      ]

      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: batch_actions},
          agent_id,
          timeout: 5000,
          agent_pid: self()
        )

      # Expect success with map containing results list
      assert {:ok, %{results: results}} = result
      assert is_list(results)
      assert length(results) == 2
      assert Enum.at(results, 0).action == "todo"
      assert Enum.at(results, 1).action == "orient"
    end

    # Note: Empty/single batch errors come from Validator (runs before ActionMapper)
    # These test that the full Router flow works correctly
    test "Router returns error for empty batch via dispatch", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_sync with empty actions THEN Validator returns batch_too_short
      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: []},
          agent_id,
          timeout: 5000
        )

      # Validator catches this before ActionMapper
      assert {:error, :batch_too_short} = result
    end

    test "Router returns error for single-action batch via dispatch", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_sync with single action THEN Validator returns batch_too_short
      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: [%{action: :todo, params: %{items: []}}]},
          agent_id,
          timeout: 5000
        )

      # Validator catches this before ActionMapper
      assert {:error, :batch_too_short} = result
    end
  end

  describe "R4: batch_sync validation through Router" do
    test "Router validates nested batch_sync is rejected", %{router: router, agent_id: agent_id} do
      # [INTEGRATION] - WHEN Router receives batch_sync containing batch_sync THEN returns nested_batch error
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: batch_actions},
          agent_id,
          timeout: 5000
        )

      # Validator catches nested batch_sync
      assert {:error, :nested_batch} = result
    end

    test "Router validates non-batchable actions are rejected", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_sync containing :wait THEN Validator returns not_batchable
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :wait, params: %{wait: 5}}
      ]

      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: batch_actions},
          agent_id,
          timeout: 5000
        )

      # Validator catches non-batchable action
      assert {:error, {:not_batchable, :wait}} = result
    end
  end

  describe "R5: batch_sync stop-on-error through Router" do
    test "Router batch_sync stops on first error with partial results", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir
    } do
      # [INTEGRATION] - WHEN batch action fails THEN stops and returns partial results
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        # This will fail - file doesn't exist
        %{action: :file_read, params: %{path: Path.join(temp_dir, "nonexistent.txt")}},
        # This should never execute
        %{action: :todo, params: %{items: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_sync,
          %{actions: batch_actions},
          agent_id,
          timeout: 5000,
          capability_groups: [:file_read],
          agent_pid: self()
        )

      # Expect error with partial results
      assert {:error, {partial_results, _error}} = result
      assert length(partial_results) == 1
      assert Enum.at(partial_results, 0).action == "todo"
    end
  end

  # ===========================================================================
  # R6: ClientAPI always_sync_actions
  # ===========================================================================
  describe "R6: batch_sync in always_sync_actions" do
    test "ClientAPI includes batch_sync in always_sync_actions" do
      # [UNIT] - WHEN always_sync_actions/0 called THEN includes :batch_sync
      sync_actions = ClientAPI.always_sync_actions()

      assert :batch_sync in sync_actions,
             "batch_sync should be in always_sync_actions for synchronous execution"
    end
  end
end
