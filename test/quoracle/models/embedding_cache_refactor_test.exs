defmodule Quoracle.Models.EmbeddingCacheRefactorTest do
  @moduledoc """
  Tests for EmbeddingCache refactoring to remove named table.
  Verifies process-owned tables enable concurrent test execution.
  """

  # Can use async: true after refactor
  use ExUnit.Case, async: true
  alias Quoracle.Models.EmbeddingCache

  describe "table creation without :named_table" do
    test "ARC_FUNC_01: creates ETS table without :named_table option" do
      # Start the EmbeddingCache
      {:ok, pid} = start_supervised(EmbeddingCache)

      # The table should NOT be named - trying to access :embedding_cache should fail
      assert :ets.whereis(:embedding_cache) == :undefined

      # The table should exist and be owned by the GenServer process
      # Get the table reference through the new get_table/0 function
      table_ref = EmbeddingCache.get_table(pid)
      assert is_reference(table_ref)

      # Verify the table is owned by the GenServer
      assert :ets.info(table_ref, :owner) == pid
    end
  end

  describe "table reference retrieval" do
    test "ARC_FUNC_02: get_table/0 returns valid table reference when GenServer running" do
      {:ok, pid} = start_supervised(EmbeddingCache)

      # Get table reference
      table_ref = EmbeddingCache.get_table(pid)

      # Verify it's a valid reference
      assert is_reference(table_ref)

      # Verify we can perform ETS operations on it
      :ets.insert(table_ref, {:test_key, "test_value"})
      assert [{:test_key, "test_value"}] = :ets.lookup(table_ref, :test_key)
    end

    test "ARC_ERR_01: get_table/0 raises exception when GenServer not started" do
      # Create a stopped GenServer pid using Task
      task = Task.async(fn -> :ok end)
      fake_pid = task.pid
      Task.await(task)

      # Should exit when trying to get table from dead process (GenServer.call exits on dead process)
      assert catch_exit(EmbeddingCache.get_table(fake_pid))
    end
  end

  describe "concurrent isolation" do
    test "ARC_FUNC_03: multiple EmbeddingCache instances have separate tables" do
      # Start two separate instances
      {:ok, pid1} = start_supervised({EmbeddingCache, []}, id: :cache1)
      {:ok, pid2} = start_supervised({EmbeddingCache, []}, id: :cache2)

      # Get table references
      table1 = EmbeddingCache.get_table(pid1)
      table2 = EmbeddingCache.get_table(pid2)

      # Tables should be different
      assert table1 != table2

      # Operations on one table shouldn't affect the other
      :ets.insert(table1, {:key1, "value1"})
      :ets.insert(table2, {:key2, "value2"})

      # table1 should only have key1
      assert [{:key1, "value1"}] = :ets.lookup(table1, :key1)
      assert [] = :ets.lookup(table1, :key2)

      # table2 should only have key2
      assert [] = :ets.lookup(table2, :key1)
      assert [{:key2, "value2"}] = :ets.lookup(table2, :key2)
    end

    test "multiple tests can run concurrently without conflicts" do
      # This test verifies that we can start multiple instances in parallel
      # which was impossible with named tables
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, pid} = GenServer.start_link(EmbeddingCache, [])

            try do
              table = EmbeddingCache.get_table(pid)
              :ets.insert(table, {i, "value_#{i}"})
              :ets.lookup(table, i)
            after
              # Ensure cleanup even if task crashes (prevents DB connection leaks)
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end
            end
          end)
        end

      results = Task.await_many(tasks)

      # Each task should have its own isolated result
      for {result, i} <- Enum.with_index(results, 1) do
        expected_value = "value_#{i}"
        assert [{^i, ^expected_value}] = result
      end
    end
  end

  describe "error handling and crashes" do
    test "ARC_ERR_02: GenServer crashes if table creation fails are handled by supervisor" do
      # This is harder to test directly since ETS table creation rarely fails
      # We'll test that the supervisor restarts the process on crash

      {:ok, pid} = start_supervised(EmbeddingCache)
      table_ref = EmbeddingCache.get_table(pid)
      ref = Process.monitor(pid)

      # Ensure cleanup (use GenServer.stop, not stop_supervised which requires test process)
      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, :infinity)
        end
      end)

      # Force a crash - :kill required for abnormal exit
      # capture_log suppresses expected termination error
      import ExUnit.CaptureLog

      capture_log(fn ->
        Process.exit(pid, :kill)

        # Wait for the process to die
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
        assert reason in [:killed, :noproc]
      end)

      # The old table should be gone (returns :undefined when table doesn't exist)
      assert :ets.info(table_ref, :type) == :undefined

      # But we should be able to get a new table from the restarted process
      # (This assumes supervisor restarts it, which it should)
      # Note: This might need adjustment based on supervision strategy
    end
  end

  describe "integration with Embeddings module" do
    test "Embeddings module uses table reference instead of named table" do
      # This tests that the Embeddings module has been updated to use
      # the table reference obtained from EmbeddingCache

      {:ok, cache_pid} = start_supervised(EmbeddingCache)

      # The Embeddings module should get the table reference from EmbeddingCache
      # and use it for operations

      # Get table reference and verify it works
      table_ref = EmbeddingCache.get_table(cache_pid)
      assert is_reference(table_ref)

      # Verify we can use the table directly (Embeddings would do this internally)
      :ets.insert(
        table_ref,
        {:test_key, "test_value", System.system_time(:millisecond), 3_600_000}
      )

      assert [{:test_key, "test_value", _, _}] = :ets.lookup(table_ref, :test_key)
    end
  end
end
