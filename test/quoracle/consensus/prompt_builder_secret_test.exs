defmodule Quoracle.Consensus.PromptBuilderSecretTest do
  @moduledoc """
  Tests for PromptBuilder secret documentation (v9.0).

  v9.0 changed format_available_secrets to return static documentation
  instead of listing individual secrets. Secrets are now discovered via
  the search_secrets action.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.PromptBuilder

  # All capability groups to include all actions in prompts
  @all_capability_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "format_available_secrets/0 v9.0" do
    test "returns static documentation regardless of DB state", %{sandbox_owner: _owner} do
      # v9.0: Output is static, no DB query
      secrets_section = PromptBuilder.format_available_secrets()

      # Should include the header
      assert secrets_section =~ "## Secrets"

      # Should document search_secrets action
      assert secrets_section =~ "search_secrets"
      assert secrets_section =~ "search_terms"

      # Should explain the {{SECRET:name}} syntax
      assert secrets_section =~ "{{SECRET:name}}"

      # Should mention values are never visible
      assert secrets_section =~ "NEVER visible"
    end

    test "documents how to find secrets via search_secrets action", %{sandbox_owner: _owner} do
      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Documents search_secrets action for discovery
      assert secrets_section =~ "Finding Secrets"
      assert secrets_section =~ ~r/"action":\s*"search_secrets"/
      assert secrets_section =~ ~r/"search_terms":\s*\[/
    end

    test "documents how to use secrets with SECRET syntax", %{sandbox_owner: _owner} do
      secrets_section = PromptBuilder.format_available_secrets()

      # v9.0: Still explains how to USE secrets
      assert secrets_section =~ "Using Secrets"
      assert secrets_section =~ "{{SECRET:name}}"
      assert secrets_section =~ "resolved automatically"
    end
  end

  describe "build_system_prompt/0 v9.0" do
    test "includes secrets documentation in system prompt", %{sandbox_owner: _owner} do
      system_prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should include the available actions section
      assert system_prompt =~ "## Available Actions"

      # Should include the secrets section with search_secrets docs
      assert system_prompt =~ "## Secrets"
      assert system_prompt =~ "search_secrets"
      assert system_prompt =~ "{{SECRET:name}}"

      # Should include NO_EXECUTE documentation
      assert system_prompt =~ "NO_EXECUTE"
    end

    test "generate_secret action documentation exists", %{sandbox_owner: _owner} do
      system_prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # generate_secret action should still be documented
      assert system_prompt =~ "generate_secret"
    end

    test "secrets section explains values are never visible", %{sandbox_owner: _owner} do
      system_prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # v9.0: Still explains security - values never visible
      assert system_prompt =~ "NEVER visible"
    end
  end
end
