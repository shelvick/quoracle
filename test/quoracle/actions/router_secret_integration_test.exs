defmodule Quoracle.Actions.RouterSecretIntegrationTest do
  @moduledoc """
  Integration tests for Router secret resolution and audit logging.
  Tests the critical integration gaps identified in the audit.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Models.TableSecrets
  alias Quoracle.Audit.SecretUsage

  # Helper to await shell result (handles both sync and async)
  # Sync results have exit_code, async results have status: :running
  defp await_shell_result(_router, execute_result) do
    case execute_result do
      {:ok, %{exit_code: _} = result} ->
        # Sync result (has exit_code)
        result

      {:ok, %{status: :running, command_id: _cmd_id}} ->
        # Shell went async - wait for Core to receive completion
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> result
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end

      {:async, _ref} ->
        # Execution layer went async (2-tuple) - wait for completion
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> result
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end

      {:async, _ref, _info} ->
        # Execution layer went async (3-tuple with info) - wait for completion
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> result
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end
    end
  end

  describe "secret resolution integration" do
    setup tags do
      # Create test secrets
      {:ok, api_secret} =
        TableSecrets.create(%{
          name: "api_key",
          value: "secret-api-key-123",
          description: "Test API key"
        })

      {:ok, db_secret} =
        TableSecrets.create(%{
          name: "db_password",
          value: "secret-db-pass-456",
          description: "Test DB password"
        })

      # Setup mock registry and pubsub
      registry = :"test_registry_#{System.unique_integer([:positive])}"
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: tags[:sandbox_owner]
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

      {:ok,
       %{
         api_secret: api_secret,
         db_secret: db_secret,
         registry: registry,
         pubsub: pubsub,
         router: router,
         agent_id: agent_id,
         capability_groups: [:local_execution]
       }}
    end

    test "resolves {{SECRET:name}} templates in action params before execution", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      # Test params with secret templates
      params = %{
        "command" =>
          "echo 'API key: {{SECRET:api_key}}' && echo 'DB pass: {{SECRET:db_password}}'"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        capability_groups: capability_groups
      ]

      # Execute Router with params containing templates (may return sync or async)
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Verify the secrets were resolved AND scrubbed (redacted, not leaked)
      assert result.stdout =~ "[REDACTED:api_key]"
      assert result.stdout =~ "[REDACTED:db_password]"
      refute result.stdout =~ "{{SECRET:"
      refute result.stdout =~ "secret-api-key-123"
      refute result.stdout =~ "secret-db-pass-456"
    end

    test "resolves multiple secrets in nested data structures", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "url" => "https://api.example.com?key1={{SECRET:api_key}}&key2={{SECRET:db_password}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Should resolve both secrets in the URL before attempting fetch
      # (may return error for unreachable URL, but secrets should be resolved first)
      _result = Router.execute(router, :fetch_web, params, agent_id, opts)

      # Verify secrets were resolved via audit logs
      # Both secrets should be logged even if the fetch fails (logging happens after resolution)
      {:ok, logs} = SecretUsage.recent_usage(10)
      secret_names = Enum.map(logs, & &1.secret_name) |> Enum.sort()
      assert "api_key" in secret_names
      assert "db_password" in secret_names
    end

    test "passes through literal template when secret not found", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo {{SECRET:nonexistent_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Missing secrets pass-through as literals
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      assert result.stdout =~ "{{SECRET:nonexistent_secret}}"
    end

    test "handles partial string replacement", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo 'mysql -u admin -p{{SECRET:db_password}} -h localhost'"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Should resolve the embedded secret in the command
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Verify secret was resolved AND scrubbed in the middle of the string
      assert result.stdout =~ "mysql -u admin -p[REDACTED:db_password] -h localhost"
      refute result.stdout =~ "{{SECRET:"
      refute result.stdout =~ "secret-db-pass-456"
    end

    test "preserves non-string values during resolution", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      # Wait action only accepts duration (number), test that it's preserved
      params = %{
        "wait" => 5
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Should preserve the integer duration value
      assert {:ok, result} = Router.execute(router, :wait, params, agent_id, opts)

      # Verify the integer was preserved (not converted to string during resolution)
      assert result.action == "wait"
      assert result.async == true
      assert is_reference(result.timer_id)
    end
  end

  describe "audit logging integration" do
    setup tags do
      # Create test secret
      {:ok, secret} =
        TableSecrets.create(%{
          name: "audit_test_secret",
          value: "audit-value-123"
        })

      registry = :"test_registry_#{System.unique_integer([:positive])}"
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: tags[:sandbox_owner]
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

      {:ok,
       %{
         secret: secret,
         registry: registry,
         pubsub: pubsub,
         router: router,
         agent_id: agent_id,
         task_id: "task-#{System.unique_integer([:positive])}",
         capability_groups: [:local_execution]
       }}
    end

    test "logs secret usage after successful resolution", %{
      agent_id: agent_id,
      task_id: task_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo {{SECRET:audit_test_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        task_id: task_id,
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Before execution, no usage logs
      assert {:ok, []} = SecretUsage.usage_by_secret("audit_test_secret", limit: 10)

      # Execute action with secret
      _result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # After execution, usage should be logged
      {:ok, logs} = SecretUsage.usage_by_secret("audit_test_secret", limit: 10)
      assert length(logs) == 1

      [log] = logs
      assert log.secret_name == "audit_test_secret"
      assert log.agent_id == agent_id
      assert log.task_id == task_id
      assert log.action_type == "execute_shell"
      assert log.accessed_at != nil
    end

    test "logs multiple secrets used in single action", %{
      agent_id: agent_id,
      task_id: task_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      # Create additional secrets
      {:ok, _} = TableSecrets.create(%{name: "secret1", value: "value1"})
      {:ok, _} = TableSecrets.create(%{name: "secret2", value: "value2"})
      {:ok, _} = TableSecrets.create(%{name: "secret3", value: "value3"})

      params = %{
        "url" =>
          "https://api.example.com?key1={{SECRET:secret1}}&key2={{SECRET:secret2}}&key3={{SECRET:secret3}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        task_id: task_id,
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # fetch_web may fail with unreachable, but secrets are logged immediately after resolution
      _result = Router.execute(router, :fetch_web, params, agent_id, opts)

      # Should log all three secrets (logged before async execution)
      {:ok, logs} =
        SecretUsage.query_usage(
          agent_id: agent_id,
          task_id: task_id,
          order_by: {:asc, :secret_name}
        )

      assert length(logs) == 3
      secret_names = logs |> Enum.map(& &1.secret_name) |> Enum.sort()
      assert secret_names == ["secret1", "secret2", "secret3"]

      # All should have same context
      Enum.each(logs, fn log ->
        assert log.agent_id == agent_id
        assert log.task_id == task_id
        assert log.action_type == "fetch_web"
      end)
    end

    test "logs secret usage even when same secret used multiple times", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" =>
          "echo {{SECRET:audit_test_secret}} && echo {{SECRET:audit_test_secret}} && echo {{SECRET:audit_test_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      _result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Should log once per unique secret, not per occurrence
      {:ok, logs} = SecretUsage.usage_by_secret("audit_test_secret", limit: 10)
      assert length(logs) == 1
    end

    test "logs found secrets even when some are missing (pass-through)", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo {{SECRET:nonexistent}} && echo {{SECRET:audit_test_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Action executes with missing secret as literal, found secret resolved
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Missing secret kept as literal
      assert result.stdout =~ "{{SECRET:nonexistent}}"

      # Found secret SHOULD be logged since action executed
      {:ok, logs} = SecretUsage.usage_by_secret("audit_test_secret", limit: 10)
      assert length(logs) == 1
    end

    test "logs correct action type for each action", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      # Verify that action_type is correctly logged in audit trail
      params = %{
        "command" => "echo {{SECRET:audit_test_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Execute shell action
      _result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Verify correct action type logged
      {:ok, [log]} = SecretUsage.usage_by_secret("audit_test_secret", limit: 1)
      assert log.action_type == "execute_shell"
    end

    test "handles nil task_id in audit logs", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo {{SECRET:audit_test_secret}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
        # No task_id provided
      ]

      _result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      {:ok, [log]} = SecretUsage.usage_by_secret("audit_test_secret", limit: 1)
      assert log.task_id == nil
      assert log.agent_id == agent_id
    end
  end

  describe "end-to-end secret flow" do
    setup tags do
      # Create secrets
      {:ok, _} =
        TableSecrets.create(%{
          name: "github_token",
          value: "ghp_secrettoken123",
          description: "GitHub API token"
        })

      {:ok, _} =
        TableSecrets.create(%{
          name: "aws_secret",
          value: "aws_secret_key_456",
          description: "AWS secret key"
        })

      registry = :"test_registry_#{System.unique_integer([:positive])}"
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "agent-#{System.unique_integer([:positive])}"
      task_id = "task-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: tags[:sandbox_owner]
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

      {:ok,
       %{
         registry: registry,
         pubsub: pubsub,
         router: router,
         agent_id: agent_id,
         task_id: task_id,
         capability_groups: [:local_execution]
       }}
    end

    test "complete flow: resolution → execution → audit → scrubbing", %{
      agent_id: agent_id,
      task_id: task_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      # Complex params with multiple secrets
      params = %{
        "command" => "echo 'GitHub: {{SECRET:github_token}}' && echo 'AWS: {{SECRET:aws_secret}}'"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        task_id: task_id,
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Step 1: Execute action (resolution happens automatically)
      # Shell commands may return async under load - handle both cases
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Verify secrets were resolved AND scrubbed (redacted, not leaked)
      assert result.stdout =~ "[REDACTED:github_token]"
      assert result.stdout =~ "[REDACTED:aws_secret]"
      refute result.stdout =~ "{{SECRET:"
      refute result.stdout =~ "ghp_secrettoken123"
      refute result.stdout =~ "aws_secret_key_456"

      # Step 2: Verify audit logging
      {:ok, logs} =
        SecretUsage.query_usage(
          task_id: task_id,
          order_by: {:asc, :secret_name}
        )

      assert length(logs) == 2
      assert Enum.map(logs, & &1.secret_name) == ["aws_secret", "github_token"]
    end

    # NOTE: Concurrent test removed - per-action Router (v28.0) terminates after its action completes.
    # Each concurrent action would need its own Router instance. This test pattern doesn't match
    # the per-action architecture where ActionExecutor spawns a new Router for each action.
  end

  describe "error handling and edge cases" do
    setup tags do
      registry = :"test_registry_#{System.unique_integer([:positive])}"
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Phoenix.PubSub, name: pubsub})

      agent_id = "agent-#{System.unique_integer([:positive])}"

      # Per-action Router (v28.0)
      {:ok, router} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: "action-#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: self(),
          pubsub: pubsub,
          sandbox_owner: tags[:sandbox_owner]
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

      {:ok,
       %{
         registry: registry,
         pubsub: pubsub,
         router: router,
         agent_id: agent_id,
         capability_groups: [:local_execution]
       }}
    end

    test "handles malformed template syntax gracefully", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo {{SECRET:}} and {{SECRET}} and {SECRET:test}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Should treat malformed templates as literal strings and execute
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Shell executed the command with malformed templates as-is
      assert result.stdout =~ "{{SECRET:}}"
      assert result.action == "shell"

      # No audit logs since no valid templates
      {:ok, logs} = SecretUsage.recent_usage(10)
      assert logs == []
    end

    test "handles empty params", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "wait" => 1
        # No secret templates
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Should work normally without secrets
      {:ok, result} = Router.execute(router, :wait, params, agent_id, opts)
      assert result.action == "wait"

      # No audit logs
      {:ok, logs} = SecretUsage.recent_usage(10)
      assert logs == []
    end

    test "missing secrets pass through as literals in command", %{
      agent_id: agent_id,
      registry: registry,
      pubsub: pubsub,
      router: router,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo --key={{SECRET:deployment_key}} --env={{SECRET:production_env}}"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 2000,
        capability_groups: capability_groups
      ]

      # Missing secrets pass-through as literals
      result =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Both templates kept as literals in output
      assert result.stdout =~ "{{SECRET:deployment_key}}"
      assert result.stdout =~ "{{SECRET:production_env}}"
    end
  end
end
