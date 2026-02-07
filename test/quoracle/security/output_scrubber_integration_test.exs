defmodule Quoracle.Security.OutputScrubberIntegrationTest do
  @moduledoc """
  Integration tests for OutputScrubber with real action outputs.

  Tests scrubbing behavior across various action types and output formats
  to ensure secrets are never leaked in real-world scenarios.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Security.OutputScrubber
  alias Quoracle.Models.TableSecrets

  setup do
    # Create test secrets
    {:ok, api_secret} =
      TableSecrets.create(%{
        name: "test_api_key",
        value: "sk-test-1234567890abcdef",
        description: "Test API key"
      })

    {:ok, db_secret} =
      TableSecrets.create(%{
        name: "test_db_password",
        value: "MyS3cr3tP@ssw0rd!",
        description: "Test database password"
      })

    secrets_used = %{
      "test_api_key" => "sk-test-1234567890abcdef",
      "test_db_password" => "MyS3cr3tP@ssw0rd!"
    }

    %{secrets_used: secrets_used, api_secret: api_secret, db_secret: db_secret}
  end

  describe "Shell action output scrubbing" do
    test "scrubs secrets from command stdout", %{secrets_used: secrets_used} do
      shell_output = %{
        action: "shell",
        command_id: "cmd-123",
        status: "completed",
        exit_code: 0,
        stdout: "Database connection successful: MyS3cr3tP@ssw0rd!",
        stderr: ""
      }

      scrubbed = OutputScrubber.scrub_result(shell_output, secrets_used)

      assert scrubbed.stdout == "Database connection successful: [REDACTED:test_db_password]"
      refute scrubbed.stdout =~ "MyS3cr3tP@ssw0rd!"
    end

    test "scrubs secrets from command stderr", %{secrets_used: secrets_used} do
      shell_output = %{
        action: "shell",
        command_id: "cmd-456",
        status: "failed",
        exit_code: 1,
        stdout: "",
        stderr: "Authentication failed with key: sk-test-1234567890abcdef"
      }

      scrubbed = OutputScrubber.scrub_result(shell_output, secrets_used)

      assert scrubbed.stderr == "Authentication failed with key: [REDACTED:test_api_key]"
      refute scrubbed.stderr =~ "sk-test-1234567890abcdef"
    end

    test "scrubs secrets from multiline output", %{secrets_used: secrets_used} do
      shell_output = %{
        action: "shell",
        stdout: """
        Starting application...
        Using API key: sk-test-1234567890abcdef
        Connecting to database with: MyS3cr3tP@ssw0rd!
        Application started successfully
        """
      }

      scrubbed = OutputScrubber.scrub_result(shell_output, secrets_used)

      assert scrubbed.stdout =~ "Using API key: [REDACTED:test_api_key]"
      assert scrubbed.stdout =~ "Connecting to database with: [REDACTED:test_db_password]"
      refute scrubbed.stdout =~ "sk-test-1234567890abcdef"
      refute scrubbed.stdout =~ "MyS3cr3tP@ssw0rd!"
    end
  end

  describe "Error result scrubbing" do
    test "scrubs secrets from error tuples", %{secrets_used: secrets_used} do
      error_result = {
        :error,
        "Authentication failed: Invalid API key sk-test-1234567890abcdef"
      }

      scrubbed = OutputScrubber.scrub_result(error_result, secrets_used)

      assert scrubbed ==
               {:error, "Authentication failed: Invalid API key [REDACTED:test_api_key]"}
    end

    test "scrubs secrets from error maps", %{secrets_used: secrets_used} do
      error_result = %{
        error: "Connection failed",
        details: "Could not connect with password: MyS3cr3tP@ssw0rd!",
        attempted_credentials: %{
          username: "admin",
          password: "MyS3cr3tP@ssw0rd!"
        }
      }

      scrubbed = OutputScrubber.scrub_result(error_result, secrets_used)

      assert scrubbed.details =~ "[REDACTED:test_db_password]"
      assert scrubbed.attempted_credentials.password == "[REDACTED:test_db_password]"
      refute inspect(scrubbed) =~ "MyS3cr3tP@ssw0rd!"
    end

    test "scrubs secrets from shell error output", %{secrets_used: secrets_used} do
      error_result = {
        :error,
        %{
          action: "shell",
          exit_code: 1,
          stderr: "Error: Invalid token sk-test-1234567890abcdef\nRetry with valid credentials"
        }
      }

      scrubbed = OutputScrubber.scrub_result(error_result, secrets_used)

      {status, error_map} = scrubbed
      assert status == :error
      assert error_map.stderr =~ "[REDACTED:test_api_key]"
      refute error_map.stderr =~ "sk-test-1234567890abcdef"
    end
  end

  describe "Complex real-world scenarios" do
    test "handles secrets in URLs and connection strings", %{secrets_used: secrets_used} do
      output = %{
        action: "shell",
        stdout:
          "Connecting to: postgresql://admin:MyS3cr3tP@ssw0rd!@db.example.com:5432/production"
      }

      scrubbed = OutputScrubber.scrub_result(output, secrets_used)

      assert scrubbed.stdout =~
               "Connecting to: postgresql://admin:[REDACTED:test_db_password]@db.example.com:5432/production"
    end

    test "preserves structure while scrubbing deeply nested secrets", %{
      secrets_used: secrets_used
    } do
      complex_output = %{
        action: "orient",
        analysis: %{
          environment: %{
            variables: [
              %{name: "API_KEY", value: "sk-test-1234567890abcdef"},
              %{name: "DB_PASS", value: "MyS3cr3tP@ssw0rd!"}
            ]
          },
          recommendations: [
            "Rotate API key: sk-test-1234567890abcdef",
            "Update database password from MyS3cr3tP@ssw0rd!"
          ]
        }
      }

      scrubbed = OutputScrubber.scrub_result(complex_output, secrets_used)

      # Verify structure preserved
      assert is_map(scrubbed)
      assert is_map(scrubbed.analysis)
      assert is_list(scrubbed.analysis.environment.variables)
      assert is_list(scrubbed.analysis.recommendations)

      # Verify secrets scrubbed
      assert Enum.at(scrubbed.analysis.environment.variables, 0).value ==
               "[REDACTED:test_api_key]"

      assert Enum.at(scrubbed.analysis.environment.variables, 1).value ==
               "[REDACTED:test_db_password]"

      assert Enum.at(scrubbed.analysis.recommendations, 0) =~ "[REDACTED:test_api_key]"
      assert Enum.at(scrubbed.analysis.recommendations, 1) =~ "[REDACTED:test_db_password]"
    end

    test "scrubs multiple occurrences of same secret", %{secrets_used: secrets_used} do
      output = %{
        action: "shell",
        stdout: """
        First occurrence: sk-test-1234567890abcdef
        Second occurrence: sk-test-1234567890abcdef
        Third occurrence: sk-test-1234567890abcdef
        """
      }

      scrubbed = OutputScrubber.scrub_result(output, secrets_used)

      # Should have exactly 3 redactions
      redaction_count =
        scrubbed.stdout
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "[REDACTED:test_api_key]"))

      assert redaction_count == 3
      refute scrubbed.stdout =~ "sk-test-1234567890abcdef"
    end
  end

  describe "Edge cases" do
    test "scrubs partial secret matches in longer strings", %{secrets_used: secrets_used} do
      output = %{
        action: "shell",
        stdout: "Token: prefix-sk-test-1234567890abcdef-suffix"
      }

      scrubbed = OutputScrubber.scrub_result(output, secrets_used)

      assert scrubbed.stdout == "Token: prefix-[REDACTED:test_api_key]-suffix"
    end

    test "handles empty secrets_used map safely" do
      output = %{action: "shell", stdout: "No secrets here"}

      scrubbed = OutputScrubber.scrub_result(output, %{})

      assert scrubbed == output
    end
  end
end
