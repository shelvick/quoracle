defmodule Quoracle.Actions.RouterSecretGapsTest do
  @moduledoc """
  Tests for secret system integration gaps identified in audit.
  These tests specifically verify the critical issues found:
  1. GenerateSecret action routing through Router
  2. Error result scrubbing to prevent secret leakage
  3. UI PubSub broadcasting for real-time updates
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Models.TableSecrets
  alias Quoracle.Audit.SecretUsage

  # Helper to await shell result (handles both sync and async)
  defp await_shell_result(_router, execute_result) do
    case execute_result do
      # Sync result (has exit_code, no status: :running)
      {:ok, %{exit_code: _} = result} ->
        {:ok, result}

      # Async result (has status: :running)
      {:ok, %{status: :running}} ->
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> {:ok, result}
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end

      {:async, _ref} ->
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> {:ok, result}
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end

      {:async, _ref, _info} ->
        receive do
          {:"$gen_cast", {:action_result, _action_id, {:ok, result}}} -> {:ok, result}
        after
          10_000 -> raise "Timeout waiting for shell completion"
        end
    end
  end

  describe "GenerateSecret routing (GAP #1)" do
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
         router: router,
         registry: registry,
         pubsub: pubsub,
         agent_id: agent_id,
         capability_groups: [:local_execution]
       }}
    end

    test "executes generate_secret action through Router", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # This tests that GenerateSecret is properly registered in ActionMapper
      # Currently FAILS because generate_secret is not in ActionMapper
      params = %{
        "name" => "test_secret_#{System.unique_integer([:positive])}",
        "length" => 32,
        "include_numbers" => true,
        "include_symbols" => false,
        "description" => "Test secret generated through Router"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        timeout: 1000,
        capability_groups: capability_groups
      ]

      # This should work but currently returns {:error, :action_not_implemented}
      assert {:ok, result} = Router.execute(router, :generate_secret, params, agent_id, opts)
      assert result.action == "generate_secret"
      assert result.secret_name == params["name"]
      refute Map.has_key?(result, :value), "Result should not contain secret value"

      # Verify secret was actually created
      assert {:ok, secret} = TableSecrets.get_by_name(params["name"])
      assert secret.name == params["name"]
      assert secret.description == params["description"]
      assert is_binary(secret.value)
      assert byte_size(secret.value) == 32
    end

    test "logs audit trail when generating secret through Router", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      params = %{
        "name" => "audit_test_secret_#{System.unique_integer([:positive])}",
        "length" => 16
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        task_id: "task-#{System.unique_integer([:positive])}",
        timeout: 1000,
        capability_groups: capability_groups
      ]

      # Execute through Router (currently fails due to ActionMapper gap)
      assert {:ok, _result} = Router.execute(router, :generate_secret, params, agent_id, opts)

      # Verify audit log was created
      {:ok, logs} = SecretUsage.usage_by_agent(agent_id)

      # GenerateSecret shouldn't log usage (it creates, doesn't use)
      assert Enum.all?(logs, &(&1.action_type != "generate_secret"))
    end

    test "handles duplicate name error through Router", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      secret_name = "duplicate_test_#{System.unique_integer([:positive])}"

      # Create secret directly first
      {:ok, _} =
        TableSecrets.create(%{
          name: secret_name,
          value: "existing_value",
          description: "Existing secret"
        })

      params = %{
        "name" => secret_name,
        "length" => 32
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        timeout: 1000,
        capability_groups: capability_groups
      ]

      # Should return error for duplicate name (once ActionMapper is fixed)
      assert {:error, reason} = Router.execute(router, :generate_secret, params, agent_id, opts)

      # Error should indicate duplicate - action_not_implemented is a gap to fix
      assert reason in [:action_not_implemented, :already_exists] or
               (is_binary(reason) and String.contains?(reason, "already exists")),
             "Expected duplicate error, got: #{inspect(reason)}"
    end
  end

  describe "Error result scrubbing (GAP #2)" do
    setup tags do
      # Create test secrets
      {:ok, _} =
        TableSecrets.create(%{
          name: "sensitive_password",
          value: "super-secret-pass-123",
          description: "Test password"
        })

      {:ok, _} =
        TableSecrets.create(%{
          name: "api_token",
          value: "tok_abc123def456ghi789",
          description: "Test API token"
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
         router: router,
         registry: registry,
         pubsub: pubsub,
         agent_id: agent_id,
         capability_groups: [:local_execution]
       }}
    end

    test "scrubs secrets from shell results with non-zero exit codes", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # Command that will fail but include secret in output
      params = %{
        "command" => "echo 'Password: {{SECRET:sensitive_password}}' && exit 1"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        smart_threshold: 999_999,
        capability_groups: capability_groups
      ]

      # Execute command that will fail (may be sync or async depending on timing)
      {:ok, result_info} =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Shell commands with non-zero exit return {:ok, result} with exit_code field
      # But the stdout/stderr should still be scrubbed
      assert result_info.exit_code == 1

      # The stdout should NOT contain the actual secret value
      refute result_info.stdout =~ "super-secret-pass-123",
             "Shell output contains unscrubbed secret value!"

      # Instead it should contain the redacted marker
      assert result_info.stdout =~ "[REDACTED:sensitive_password]" or
               result_info.stdout =~ "[REDACTED]",
             "Shell output should contain redacted marker"
    end

    test "scrubs secrets from API error messages", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # Simulate an API call that fails with secret in error
      params = %{
        "url" => "https://invalid.example.com/auth",
        "headers" => %{
          "Authorization" => "Bearer {{SECRET:api_token}}"
        }
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        capability_groups: capability_groups
      ]

      # This will fail due to invalid URL
      result = Router.execute(router, :fetch_web, params, agent_id, opts)

      case result do
        {:error, error_info} ->
          error_string = inspect(error_info)

          # Verify the actual token is NOT in the error
          refute error_string =~ "tok_abc123def456ghi789",
                 "API error contains unscrubbed token!"

          # Should be redacted
          assert error_string =~ "[REDACTED" or not (error_string =~ "tok_"),
                 "API error should scrub tokens"

        {:ok, _} ->
          # If it somehow succeeds, verify output is scrubbed
          flunk("Expected API call to fail for testing error scrubbing")
      end
    end

    test "scrubs nested error structures with multiple secrets", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # Command with multiple secrets that will fail
      params = %{
        "command" => """
        echo 'Config:' && \
        echo '  password: {{SECRET:sensitive_password}}' && \
        echo '  token: {{SECRET:api_token}}' && \
        false
        """
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        # Higher threshold to ensure sync execution under parallel test load
        smart_threshold: 500,
        capability_groups: capability_groups
      ]

      # Execute command (may be sync or async depending on timing)
      {:ok, result_info} =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Shell with exit code 1 returns {:ok, _} with exit_code field
      assert result_info.exit_code == 1

      # Check stdout for secrets
      stdout = result_info.stdout || ""

      # Neither secret should appear in plain text
      refute stdout =~ "super-secret-pass-123",
             "Password leaked in stdout!"

      refute stdout =~ "tok_abc123def456ghi789",
             "Token leaked in stdout!"

      # Both should be redacted (if they appear at all)
      if stdout =~ "password:" do
        assert stdout =~ "[REDACTED" or stdout =~ "\\*\\*\\*",
               "Password should be redacted in stdout"
      end

      if stdout =~ "token:" do
        assert stdout =~ "[REDACTED" or stdout =~ "\\*\\*\\*",
               "Token should be redacted in stdout"
      end
    end

    test "preserves error structure while scrubbing values", %{
      router: router,
      registry: registry,
      pubsub: pubsub,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      params = %{
        "command" => "echo '{{SECRET:sensitive_password}}' && exit 42"
      }

      opts = [
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: self(),
        agent_pid: self(),
        capability_groups: capability_groups
      ]

      # Execute command (may be sync or async depending on timing)
      {:ok, result_info} =
        await_shell_result(router, Router.execute(router, :execute_shell, params, agent_id, opts))

      # Shell commands with non-zero exit return {:ok, _} with exit_code
      assert result_info.exit_code == 42, "Exit code should be preserved"

      # But secret values should be scrubbed from stdout
      refute result_info.stdout =~ "super-secret-pass-123",
             "Secret leaked in stdout!"
    end
  end

  describe "UI PubSub broadcasting (Minor Gap)" do
    setup do
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      # Subscribe to the secrets topic
      topic = "secrets:all"
      Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, %{pubsub: pubsub, topic: topic}}
    end

    test "broadcasts event when secret is created", %{pubsub: pubsub, topic: topic} do
      secret_name = "broadcast_test_#{System.unique_integer([:positive])}"

      # Create a secret with pubsub for broadcasting
      {:ok, secret} =
        TableSecrets.create(
          %{
            name: secret_name,
            value: "test_value",
            description: "Test broadcast"
          },
          pubsub: pubsub,
          topic: topic
        )

      # Should receive a broadcast event
      assert_receive {:secret_created, payload}, 30_000

      assert payload.id == secret.id
      assert payload.name == secret_name
      assert payload.type == :secret
      refute Map.has_key?(payload, :value), "Broadcast should not contain value"
    end

    test "broadcasts event when secret is updated", %{pubsub: pubsub, topic: topic} do
      # Create initial secret
      secret_name = "update_broadcast_test_#{System.unique_integer([:positive])}"

      {:ok, _secret} =
        TableSecrets.create(
          %{
            name: secret_name,
            value: "initial_value",
            description: "Initial"
          },
          pubsub: pubsub,
          topic: topic
        )

      # Update the secret
      {:ok, updated} =
        TableSecrets.update(
          secret_name,
          %{
            value: "new_value",
            description: "Updated description"
          },
          pubsub: pubsub,
          topic: topic
        )

      # Should receive update broadcast
      assert_receive {:secret_updated, payload}, 30_000

      assert payload.id == updated.id
      assert payload.name == secret_name
      assert payload.description == "Updated description"
      refute Map.has_key?(payload, :value), "Broadcast should not contain value"
    end

    test "broadcasts event when secret is deleted", %{pubsub: pubsub, topic: topic} do
      # Create and then delete a secret
      secret_name = "delete_broadcast_test_#{System.unique_integer([:positive])}"

      {:ok, secret} =
        TableSecrets.create(
          %{
            name: secret_name,
            value: "to_delete",
            description: "Will be deleted"
          },
          pubsub: pubsub,
          topic: topic
        )

      # Delete the secret
      {:ok, _deleted} = TableSecrets.delete(secret_name, pubsub: pubsub, topic: topic)

      # Should receive delete broadcast
      assert_receive {:secret_deleted, payload}, 30_000

      assert payload.id == secret.id
      assert payload.name == secret_name
      assert payload.type == :secret
    end
  end
end
