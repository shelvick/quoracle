defmodule Quoracle.Audit.SecretUsageTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Audit.SecretUsage
  alias Quoracle.Models.TableSecretUsage

  describe "log_usage/4 - Secret Usage Logging" do
    # R1: Log Secret Usage [INTEGRATION]
    test "logs secret usage event" do
      result =
        SecretUsage.log_usage(
          "github_token",
          "agent_123",
          "execute_shell",
          "task_456"
        )

      assert {:ok, usage} = result
      assert usage.secret_name == "github_token"
      assert usage.agent_id == "agent_123"
      assert usage.action_type == "execute_shell"
      assert usage.task_id == "task_456"
      assert usage.accessed_at != nil

      # Verify it's persisted in the database
      found = Repo.get(TableSecretUsage, usage.id)
      assert found != nil
      assert found.secret_name == "github_token"
    end

    # R2: Required Fields [UNIT]
    test "requires secret_name, agent_id, and action_type" do
      # Missing secret_name
      assert {:error, changeset} =
               SecretUsage.log_usage(
                 nil,
                 "agent_123",
                 "execute_shell",
                 nil
               )

      assert "can't be blank" in errors_on(changeset).secret_name

      # Missing agent_id
      assert {:error, changeset} =
               SecretUsage.log_usage(
                 "github_token",
                 nil,
                 "execute_shell",
                 nil
               )

      assert "can't be blank" in errors_on(changeset).agent_id

      # Missing action_type
      assert {:error, changeset} =
               SecretUsage.log_usage(
                 "github_token",
                 "agent_123",
                 nil,
                 nil
               )

      assert "can't be blank" in errors_on(changeset).action_type
    end

    # R11: Task ID Optional [UNIT]
    test "allows nil task_id" do
      result =
        SecretUsage.log_usage(
          "api_key",
          "agent_789",
          "call_api",
          nil
        )

      assert {:ok, usage} = result
      assert usage.task_id == nil
    end

    # R9: Timestamp Accuracy [UNIT]
    test "uses UTC timestamps" do
      before = DateTime.utc_now()

      {:ok, usage} =
        SecretUsage.log_usage(
          "secret",
          "agent",
          "execute_shell",
          nil
        )

      after_time = DateTime.utc_now()

      assert DateTime.compare(usage.accessed_at, before) in [:gt, :eq]
      assert DateTime.compare(usage.accessed_at, after_time) in [:lt, :eq]
      assert usage.accessed_at.time_zone == "Etc/UTC"
    end

    # R10: No Secret Values [UNIT]
    test "never stores secret values, only names" do
      # The log function should only accept a name, not value
      {:ok, usage} =
        SecretUsage.log_usage(
          # Just the name
          "database_password",
          "agent_123",
          "execute_shell",
          nil
        )

      # Verify the schema doesn't have a value field
      refute Map.has_key?(usage, :value)
      refute Map.has_key?(usage, :secret_value)

      # Only the name is stored
      assert usage.secret_name == "database_password"
    end

    # R12: Action Type Validation [UNIT]
    test "validates action_type against known actions" do
      valid_actions = [
        "execute_shell",
        "call_api",
        "fetch_web",
        "spawn_child",
        "send_message",
        "wait",
        "orient",
        "todo",
        "call_mcp",
        "answer_engine",
        "generate_secret"
      ]

      # Valid action types should succeed
      for action <- valid_actions do
        assert {:ok, _} =
                 SecretUsage.log_usage(
                   "test_secret",
                   "agent_123",
                   action,
                   nil
                 )
      end

      # Invalid action type should fail
      assert {:error, changeset} =
               SecretUsage.log_usage(
                 "test_secret",
                 "agent_123",
                 "invalid_action",
                 nil
               )

      assert "is invalid" in errors_on(changeset).action_type
    end
  end

  describe "usage_by_secret/2 - Query by Secret" do
    # R3: Query By Secret [INTEGRATION]
    test "queries usage history by secret name" do
      # Create multiple usage records
      {:ok, _} = SecretUsage.log_usage("api_key", "agent_1", "call_api", nil)
      {:ok, _} = SecretUsage.log_usage("api_key", "agent_2", "call_api", "task_1")
      {:ok, _} = SecretUsage.log_usage("database_url", "agent_1", "execute_shell", nil)

      # Query for specific secret
      {:ok, results} = SecretUsage.usage_by_secret("api_key", [])

      assert length(results) == 2
      assert Enum.all?(results, &(&1.secret_name == "api_key"))

      # Should not include other secrets
      refute Enum.any?(results, &(&1.secret_name == "database_url"))
    end

    test "returns empty list for unused secret" do
      {:ok, results} = SecretUsage.usage_by_secret("never_used", [])
      assert results == []
    end

    test "supports ordering by time descending" do
      # Create records with different timestamps manually
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -1, :second)

      {:ok, older} = SecretUsage.log_usage("api_key", "agent_1", "call_api", nil)
      # Update timestamp manually for deterministic ordering
      older =
        older
        |> Ecto.Changeset.change(accessed_at: earlier)
        |> Repo.update!()

      {:ok, newer} = SecretUsage.log_usage("api_key", "agent_2", "call_api", nil)

      {:ok, results} = SecretUsage.usage_by_secret("api_key", order: :desc)

      assert [first, second] = results
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "usage_by_agent/2 - Query by Agent" do
    # R4: Query By Agent [INTEGRATION]
    test "queries usage history by agent" do
      # Create usage records for different agents
      {:ok, _} = SecretUsage.log_usage("secret_1", "agent_alpha", "call_api", nil)
      {:ok, _} = SecretUsage.log_usage("secret_2", "agent_alpha", "execute_shell", nil)
      {:ok, _} = SecretUsage.log_usage("secret_1", "agent_beta", "call_api", nil)

      # Query for specific agent
      {:ok, results} = SecretUsage.usage_by_agent("agent_alpha", [])

      assert length(results) == 2
      assert Enum.all?(results, &(&1.agent_id == "agent_alpha"))

      # Should include different secrets used by this agent
      secret_names = Enum.map(results, & &1.secret_name)
      assert "secret_1" in secret_names
      assert "secret_2" in secret_names
    end

    test "returns empty list for agent that never used secrets" do
      {:ok, results} = SecretUsage.usage_by_agent("agent_never", [])
      assert results == []
    end
  end

  describe "query_usage/1 - Advanced Queries" do
    # R5: Time Range Query [INTEGRATION]
    test "filters usage by time range" do
      # Create records at different times
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -1, :day)
      last_week = DateTime.add(now, -7, :day)

      {:ok, recent} = SecretUsage.log_usage("secret", "agent_1", "execute_shell", nil)

      # Manually update timestamp for testing
      recent
      |> Ecto.Changeset.change(accessed_at: now)
      |> Repo.update!()

      {:ok, old} = SecretUsage.log_usage("secret", "agent_2", "execute_shell", nil)

      old
      |> Ecto.Changeset.change(accessed_at: last_week)
      |> Repo.update!()

      # Query for last 2 days
      {:ok, results} =
        SecretUsage.query_usage(
          from: yesterday,
          to: DateTime.add(now, 1, :hour)
        )

      assert length(results) == 1
      assert hd(results).agent_id == "agent_1"
    end

    # R7: Pagination Support [INTEGRATION]
    test "supports pagination of results" do
      # Create 10 usage records
      for i <- 1..10 do
        SecretUsage.log_usage("secret_#{i}", "agent", "execute_shell", nil)
      end

      # First page
      {:ok, page1} = SecretUsage.query_usage(limit: 5, offset: 0)
      assert length(page1) == 5

      # Second page
      {:ok, page2} = SecretUsage.query_usage(limit: 5, offset: 5)
      assert length(page2) == 5

      # Pages should have different content
      page1_ids = MapSet.new(page1, & &1.id)
      page2_ids = MapSet.new(page2, & &1.id)
      assert MapSet.disjoint?(page1_ids, page2_ids)
    end

    test "combines multiple filters" do
      # Setup test data
      {:ok, _} = SecretUsage.log_usage("api_key", "agent_1", "call_api", nil)
      {:ok, _} = SecretUsage.log_usage("api_key", "agent_2", "execute_shell", nil)
      {:ok, _} = SecretUsage.log_usage("db_pass", "agent_1", "call_api", nil)

      # Query with multiple filters
      {:ok, results} =
        SecretUsage.query_usage(
          secret_name: "api_key",
          agent_id: "agent_1",
          action_type: "call_api"
        )

      assert length(results) == 1
      assert hd(results).secret_name == "api_key"
      assert hd(results).agent_id == "agent_1"
      assert hd(results).action_type == "call_api"
    end
  end

  describe "recent_usage/1 - Recent Activity" do
    # R6: Recent Usage [INTEGRATION]
    test "returns recent usage entries" do
      # Create records with deterministic timestamps
      now = DateTime.utc_now()

      _records =
        for i <- 1..5 do
          timestamp = DateTime.add(now, -1 * (6 - i), :second)
          {:ok, record} = SecretUsage.log_usage("secret_#{i}", "agent", "execute_shell", nil)

          # Update to specific timestamp for deterministic ordering
          record
          |> Ecto.Changeset.change(accessed_at: timestamp)
          |> Repo.update!()
        end

      # Get last 3 entries
      {:ok, recent} = SecretUsage.recent_usage(3)

      assert length(recent) == 3

      # Should be ordered by time descending (newest first)
      names = Enum.map(recent, & &1.secret_name)
      assert names == ["secret_5", "secret_4", "secret_3"]
    end

    test "returns all entries if limit exceeds total" do
      # Create only 2 records
      {:ok, _} = SecretUsage.log_usage("secret_1", "agent", "execute_shell", nil)
      {:ok, _} = SecretUsage.log_usage("secret_2", "agent", "execute_shell", nil)

      # Request 10 recent entries
      {:ok, recent} = SecretUsage.recent_usage(10)

      assert length(recent) == 2
    end

    test "supports time-based recent usage" do
      # Get usage from last hour
      {:ok, recent} = SecretUsage.recent_usage(hours: 1)

      # All results should be within last hour
      one_hour_ago = DateTime.add(DateTime.utc_now(), -1, :hour)

      assert Enum.all?(recent, fn usage ->
               DateTime.compare(usage.accessed_at, one_hour_ago) == :gt
             end)
    end
  end

  describe "cleanup_old_logs/1 - Retention Management" do
    # R8: Log Cleanup [INTEGRATION]
    test "cleans up old audit logs" do
      now = DateTime.utc_now()
      old_date = DateTime.add(now, -31, :day)
      recent_date = DateTime.add(now, -1, :day)

      # Create old and recent records
      {:ok, old_record} = SecretUsage.log_usage("old_secret", "agent", "execute_shell", nil)

      old_record
      |> Ecto.Changeset.change(accessed_at: old_date)
      |> Repo.update!()

      {:ok, recent_record} = SecretUsage.log_usage("recent_secret", "agent", "execute_shell", nil)

      recent_record
      |> Ecto.Changeset.change(accessed_at: recent_date)
      |> Repo.update!()

      # Clean up logs older than 30 days
      {:ok, deleted_count} = SecretUsage.cleanup_old_logs(30)

      assert deleted_count == 1

      # Old record should be gone
      assert Repo.get(TableSecretUsage, old_record.id) == nil

      # Recent record should remain
      assert Repo.get(TableSecretUsage, recent_record.id) != nil
    end

    test "returns zero when no old logs to clean" do
      # Create only recent records
      {:ok, _} = SecretUsage.log_usage("secret", "agent", "execute_shell", nil)

      # Try to clean logs older than 30 days
      {:ok, deleted_count} = SecretUsage.cleanup_old_logs(30)

      assert deleted_count == 0
    end

    test "handles cleanup errors gracefully" do
      # Test with invalid days parameter
      assert {:error, _reason} = SecretUsage.cleanup_old_logs(-1)
      assert {:error, _reason} = SecretUsage.cleanup_old_logs(0)
    end
  end

  describe "Schema validations" do
    test "enforces maximum lengths for fields" do
      # Secret name too long (max 64)
      long_name = String.duplicate("a", 65)

      assert {:error, changeset} =
               SecretUsage.log_usage(
                 long_name,
                 "agent",
                 "action",
                 nil
               )

      assert "should be at most 64 character(s)" in errors_on(changeset).secret_name

      # Agent ID too long (max 255)
      long_agent = String.duplicate("a", 256)

      assert {:error, changeset} =
               SecretUsage.log_usage(
                 "secret",
                 long_agent,
                 "action",
                 nil
               )

      assert "should be at most 255 character(s)" in errors_on(changeset).agent_id

      # Action type too long (max 50)
      long_action = String.duplicate("a", 51)

      assert {:error, changeset} =
               SecretUsage.log_usage(
                 "secret",
                 "agent",
                 long_action,
                 nil
               )

      assert "should be at most 50 character(s)" in errors_on(changeset).action_type
    end

    test "generates UUID for id automatically" do
      {:ok, usage} = SecretUsage.log_usage("secret", "agent", "execute_shell", nil)

      assert usage.id != nil
      # Should be a valid UUID
      assert {:ok, _} = Ecto.UUID.cast(usage.id)
    end
  end

  describe "Concurrent usage logging" do
    test "handles concurrent logs without conflicts" do
      # Simulate multiple agents logging usage simultaneously
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            SecretUsage.log_usage(
              "shared_secret",
              "agent_#{i}",
              "call_api",
              "task_#{i}"
            )
          end)
        end

      results = Task.await_many(tasks)

      # All should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result)
             end)

      # Should have 10 distinct records
      {:ok, all_usage} = SecretUsage.usage_by_secret("shared_secret", [])
      assert length(all_usage) == 10
    end
  end
end
