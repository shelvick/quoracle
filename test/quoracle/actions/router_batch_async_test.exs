defmodule Quoracle.Actions.RouterBatchAsyncTest do
  @moduledoc """
  Integration tests for Router dispatching batch_async to BatchAsync module.

  Addresses integration gaps found in feat-20260126-batch-async audit:
  - R1: Router dispatch integration (ActionMapper entry)
  - R2-R3: Validation through Router path
  - R4: batch_async behavior through Router
  - R6: ClientAPI always_sync_actions inclusion

  WorkGroupID: feat-20260126-batch-async
  Packet: Router Integration Fix
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ClientAPI

  @moduletag :batch_async

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) for batch_async
    {:ok, router} =
      Router.start_link(
        action_type: :batch_async,
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
        "router_batch_async_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    {:ok,
     router: router,
     pubsub: pubsub_name,
     registry: registry_name,
     agent_id: agent_id,
     temp_dir: temp_dir,
     sandbox_owner: sandbox_owner}
  end

  # ===========================================================================
  # R1: Router Dispatch Integration (ActionMapper Entry)
  # ===========================================================================
  describe "R1: Router.execute dispatches batch_async" do
    test "Router dispatches batch_async to BatchAsync module", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_async action THEN dispatches to BatchAsync and executes batch
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
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000,
          agent_pid: self()
        )

      # Expect async acknowledgement immediately
      assert {:ok, result_map} = result
      assert is_binary(result_map.batch_id)
      assert String.starts_with?(result_map.batch_id, "batch_")
      assert result_map.async == true
      assert result_map.status == :running
      assert result_map.started == 2

      # Wait for batch completion notification (cast wrapper)
      assert_receive {:"$gen_cast", {:batch_completed, batch_id, results}}, 5000
      assert batch_id == result_map.batch_id
      assert is_list(results)
      assert length(results) == 2
    end

    test "Router dispatches batch_async with file_read actions", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir
    } do
      # [INTEGRATION] - WHEN Router receives batch_async with file actions THEN executes all in parallel
      file1 = Path.join(temp_dir, "file1.txt")
      file2 = Path.join(temp_dir, "file2.txt")
      File.write!(file1, "content1")
      File.write!(file2, "content2")

      batch_actions = [
        %{action: :file_read, params: %{path: file1}},
        %{action: :file_read, params: %{path: file2}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000,
          capability_groups: [:file_read],
          agent_pid: self()
        )

      # Expect async acknowledgement immediately
      assert {:ok, result_map} = result
      assert result_map.async == true
      assert result_map.status == :running
      assert result_map.started == 2

      # Wait for batch completion notification (cast wrapper)
      assert_receive {:"$gen_cast", {:batch_completed, batch_id, results}}, 5000
      assert batch_id == result_map.batch_id
      assert length(results) == 2

      # Both should succeed (order may vary due to parallel execution)
      assert Enum.all?(results, fn {status, _} -> status == :ok end)
    end
  end

  # ===========================================================================
  # R2-R3: Validation Through Router Path
  # ===========================================================================
  describe "R2: Router validates batch_async size" do
    test "Router returns error for empty batch via dispatch", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_async with empty actions THEN Validator returns error
      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: []},
          agent_id,
          timeout: 30_000
        )

      # Validator catches this before ActionMapper
      assert {:error, :empty_batch} = result
    end

    test "Router returns error for single-action batch via dispatch", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_async with single action THEN Validator returns error
      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: [%{action: :todo, params: %{items: []}}]},
          agent_id,
          timeout: 30_000
        )

      # Validator catches this before ActionMapper
      assert {:error, :batch_too_small} = result
    end
  end

  describe "R3: Router validates batch_async action types" do
    test "Router validates nested batch_async is rejected", %{router: router, agent_id: agent_id} do
      # [INTEGRATION] - WHEN Router receives batch_async containing batch_async THEN returns nested_batch error
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :batch_async, params: %{actions: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000
        )

      # Validator catches nested batch
      assert {:error, :nested_batch} = result
    end

    test "Router validates nested batch_sync is rejected", %{router: router, agent_id: agent_id} do
      # [INTEGRATION] - WHEN Router receives batch_async containing batch_sync THEN returns nested_batch error
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000
        )

      # Validator catches nested batch
      assert {:error, :nested_batch} = result
    end

    test "Router validates :wait action is rejected in batch_async", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN Router receives batch_async containing :wait THEN Validator returns unbatchable error
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :wait, params: %{wait: 5}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000
        )

      # Validator catches non-batchable action
      assert {:error, :unbatchable_action} = result
    end
  end

  # ===========================================================================
  # R4: batch_async Behavior Through Router
  # ===========================================================================
  describe "R4: batch_async through Router" do
    test "Router batch_async returns all results", %{
      router: router,
      agent_id: agent_id
    } do
      # [INTEGRATION] - WHEN batch_async executes THEN returns all results via :batch_completed
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        %{action: :todo, params: %{items: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000,
          agent_pid: self()
        )

      # Async acknowledgement immediately
      assert {:ok, result_map} = result
      assert is_binary(result_map.batch_id)
      assert result_map.async == true
      assert result_map.status == :running

      # Wait for batch completion notification (cast wrapper)
      assert_receive {:"$gen_cast", {:batch_completed, batch_id, results}}, 5000
      assert batch_id == result_map.batch_id
      assert is_list(results)
      assert length(results) == 2
    end

    test "Router batch_async continues despite individual errors", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir
    } do
      # [INTEGRATION] - WHEN batch action fails THEN other actions still complete (no early termination)
      batch_actions = [
        %{action: :todo, params: %{items: []}},
        # This will fail - file doesn't exist
        %{action: :file_read, params: %{path: Path.join(temp_dir, "nonexistent.txt")}},
        %{action: :todo, params: %{items: []}}
      ]

      result =
        Router.execute(
          router,
          :batch_async,
          %{actions: batch_actions},
          agent_id,
          timeout: 30_000,
          capability_groups: [:file_read],
          agent_pid: self()
        )

      # Async acknowledgement immediately
      assert {:ok, result_map} = result
      assert result_map.async == true
      assert result_map.status == :running
      assert result_map.started == 3

      # Wait for batch completion notification (cast wrapper)
      assert_receive {:"$gen_cast", {:batch_completed, batch_id, results}}, 5000
      assert batch_id == result_map.batch_id

      # Unlike batch_sync, batch_async completes ALL actions
      assert length(results) == 3

      # Should have 2 successes and 1 error (results are keyword list: [ok: _, error: _, ok: _])
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      errors = Enum.count(results, fn {status, _} -> status == :error end)

      assert successes == 2
      assert errors == 1
    end
  end

  # ===========================================================================
  # R6: ClientAPI always_sync_actions
  # ===========================================================================
  describe "R6: batch_async NOT in always_sync_actions" do
    test "ClientAPI excludes batch_async from always_sync_actions" do
      # [UNIT] - WHEN always_sync_actions/0 called THEN excludes :batch_async
      # batch_async should trigger consensus continuation after completion
      sync_actions = ClientAPI.always_sync_actions()

      refute :batch_async in sync_actions,
             "batch_async must NOT be in always_sync_actions - needs consensus trigger"
    end
  end
end
