defmodule Quoracle.Consensus.PromptBuilderSearchSecretsTest do
  @moduledoc """
  Tests for CONSENSUS_PromptBuilder v9.0 - Search Secrets Documentation.
  Part of Packet 2: Feature.

  Tests that format_available_secrets/0 no longer lists individual secrets
  but instead documents the search_secrets action for on-demand discovery.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Models.TableSecrets

  describe "format_available_secrets/0 v9.0" do
    # R28: No Static Secret List
    test "does not list individual secret names", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN format_available_secrets called THEN does not list individual secret names
      # Create some secrets that would have been listed in v8.x
      {:ok, _} =
        TableSecrets.create(%{
          name: "github_token",
          value: "ghp_test123",
          description: "GitHub personal access token"
        })

      {:ok, _} =
        TableSecrets.create(%{
          name: "aws_api_key",
          value: "AKIA_test",
          description: "AWS API key"
        })

      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Should NOT list individual secret names
      refute secrets_section =~ "- github_token"
      refute secrets_section =~ "- aws_api_key"
      # Should not have the old "Available secrets:" label followed by names
      refute secrets_section =~ ~r/Available secrets:\s*\n\s*-\s*\w+/
    end

    # R29: search_secrets Action Documented
    test "documents search_secrets action", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN format_available_secrets called THEN includes search_secrets action example
      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Should document how to use search_secrets action
      assert secrets_section =~ "search_secrets"
      # Should show it's an action
      assert secrets_section =~ ~r/"action":\s*"search_secrets"/
    end

    # R30: search_terms Parameter Shown
    test "shows search_terms parameter in example", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN format_available_secrets called THEN shows search_terms parameter in example
      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Should show how to provide search terms
      assert secrets_section =~ "search_terms"
      # Should show example search terms
      assert secrets_section =~ ~r/"search_terms":\s*\[/
    end

    # R31: SECRET Syntax Preserved
    test "documents SECRET syntax", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN format_available_secrets called THEN includes {{SECRET:name}} syntax documentation
      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Still needs to document how to USE secrets
      assert secrets_section =~ "{{SECRET:name}}"
      # Should have example usage
      assert secrets_section =~ "{{SECRET:"
      # Should explain automatic resolution
      assert secrets_section =~ ~r/resolv|automat/i
    end

    # R32: No DB Call
    test "makes no database calls", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN format_available_secrets called THEN does not query database
      # Create secrets that would prove a DB query happened if we see them
      {:ok, _} =
        TableSecrets.create(%{
          name: "unique_db_test_secret_12345",
          value: "value",
          description: "This proves DB was queried if visible"
        })

      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Should NOT contain DB-sourced content
      # If this secret name appears, it means a DB query happened
      refute secrets_section =~ "unique_db_test_secret_12345"

      # The content should be static documentation, not dynamic
      # Same output regardless of what's in the database
    end

    # R28 continued: No NO_EXECUTE tags for secret names
    test "no NO_EXECUTE tags wrapping secret names", %{sandbox_owner: _owner} do
      # [UNIT] - v9.0 has no secret names to wrap
      {:ok, _} =
        TableSecrets.create(%{
          name: "test_secret",
          value: "value",
          description: "Test"
        })

      secrets_section = PromptBuilder.format_available_secrets()

      # v8.x wrapped secret names in NO_EXECUTE tags - v9.0 shouldn't have this
      # because it doesn't list secret names at all
      refute secrets_section =~ ~r/<no_execute_[a-f0-9]+>.*test_secret.*<\/no_execute_[a-f0-9]+>/s
    end
  end

  describe "build_system_prompt/0 v9.0 integration" do
    # R33: Prompt Integration
    test "system prompt includes search_secrets documentation", %{sandbox_owner: _owner} do
      # [INTEGRATION] - WHEN build_system_prompt called THEN includes search_secrets documentation in Available Secrets section
      system_prompt = PromptBuilder.build_system_prompt()

      # Should have the secrets section
      assert system_prompt =~ "Secrets"

      # v9.0: Should document search_secrets action
      assert system_prompt =~ "search_secrets"
      assert system_prompt =~ "search_terms"

      # Should still explain {{SECRET:name}} usage
      assert system_prompt =~ "{{SECRET:"
    end

    # R33 continued: search_secrets documentation appears in correct section
    test "search_secrets documentation in secrets section not actions section", %{
      sandbox_owner: _owner
    } do
      # [INTEGRATION] - Documentation should be in "Available Secrets" section as usage guide
      system_prompt = PromptBuilder.build_system_prompt()

      # Find the secrets section
      case :binary.match(system_prompt, "## Secrets") do
        {secrets_start, _} ->
          # Extract content after "## Secrets" header
          secrets_content = binary_part(system_prompt, secrets_start, 2000)

          # This section should contain the search_secrets usage example
          assert secrets_content =~ "search_secrets"
          assert secrets_content =~ "search_terms"

        :nomatch ->
          # Fall back to checking for "Available Secrets" header
          case :binary.match(system_prompt, "## Available Secrets") do
            {secrets_start, _} ->
              secrets_content = binary_part(system_prompt, secrets_start, 2000)
              assert secrets_content =~ "search_secrets"
              assert secrets_content =~ "search_terms"

            :nomatch ->
              flunk("Expected '## Secrets' or '## Available Secrets' section in system prompt")
          end
      end
    end
  end

  describe "static documentation" do
    # R32 continued: Output is deterministic
    test "output is same regardless of database contents", %{sandbox_owner: _owner} do
      # [UNIT] - v9.0 returns static string, no DB dependency
      # Get output with empty DB
      output_empty = PromptBuilder.format_available_secrets()

      # Add secrets
      {:ok, _} =
        TableSecrets.create(%{
          name: "secret_a",
          value: "value_a",
          description: "A"
        })

      {:ok, _} =
        TableSecrets.create(%{
          name: "secret_b",
          value: "value_b",
          description: "B"
        })

      # Get output with secrets in DB
      output_with_secrets = PromptBuilder.format_available_secrets()

      # v9.0: Both outputs should be identical (static documentation)
      assert output_empty == output_with_secrets
    end
  end
end
