defmodule Quoracle.Actions.SearchSecretsTest do
  @moduledoc """
  Tests for ACTION_SearchSecrets (v1.0).
  Part of Packet 2: Feature.

  Tests SearchSecrets execute/3 function for:
  - Parameter validation (R6-R8)
  - Search behavior (R1-R5, R11-R12)
  - Response format (R9-R10)
  - Integration with Router/Validator (R13-R14)
  """

  # Ecto.Sandbox provides transaction isolation - each test has clean DB view
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.SearchSecrets
  alias Quoracle.Actions.Schema
  alias Quoracle.Models.TableSecrets

  # Ensure Schema module is loaded so all action atoms exist for validator tests
  setup do
    Schema.list_actions()
    :ok
  end

  # Helper to create test secrets
  defp create_test_secret(name, description \\ nil) do
    TableSecrets.create(%{
      name: name,
      value: "test_value_#{name}",
      description: description
    })
  end

  describe "execute/3 - search behavior" do
    # R1: Valid Search Returns Matches
    test "returns matching secret names", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF search_terms match secrets THEN returns matching names
      {:ok, _} = create_test_secret("aws_api_key")
      {:ok, _} = create_test_secret("github_token")
      {:ok, _} = create_test_secret("database_password")

      params = %{"search_terms" => ["api"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert response.action == "search_secrets"
      # Packet 2: Response uses :matching_secrets (not :matching_names)
      assert "aws_api_key" in response.matching_secrets
      refute "github_token" in response.matching_secrets
      assert length(response.matching_secrets) == 1
    end

    # R2: Empty Results Handling
    test "returns empty list when no matches", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF no secrets match THEN returns empty list with count 0
      {:ok, _} = create_test_secret("aws_api_key")

      params = %{"search_terms" => ["nonexistent"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert response.matching_secrets == []
    end

    # R3: Multiple Terms OR Logic
    test "multiple terms use OR logic", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF multiple terms THEN returns names matching ANY term
      {:ok, _} = create_test_secret("aws_api_key")
      {:ok, _} = create_test_secret("github_token")
      {:ok, _} = create_test_secret("database_password")

      params = %{"search_terms" => ["aws", "github"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert "aws_api_key" in response.matching_secrets
      assert "github_token" in response.matching_secrets
      refute "database_password" in response.matching_secrets
      assert length(response.matching_secrets) == 2
    end

    # R4: Case Insensitive Matching
    test "search is case insensitive", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF term differs by case THEN still matches
      {:ok, _} = create_test_secret("AWS_API_KEY")

      params = %{"search_terms" => ["aws"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert "AWS_API_KEY" in response.matching_secrets

      # Also test uppercase search finding lowercase
      {:ok, _} = create_test_secret("github_token")
      params2 = %{"search_terms" => ["GITHUB"]}
      result2 = SearchSecrets.execute(params2, "agent_123", [])

      assert {:ok, response2} = result2
      assert "github_token" in response2.matching_secrets
    end

    # R5: Empty Terms List
    test "empty search terms returns empty results", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF search_terms is empty list THEN returns empty results
      {:ok, _} = create_test_secret("aws_api_key")

      params = %{"search_terms" => []}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert response.matching_secrets == []
    end

    # R11: Empty String Filtering
    test "filters out empty string terms", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF terms contains empty strings THEN they are filtered out
      {:ok, _} = create_test_secret("aws_api_key")

      # Empty strings should be filtered, leaving only "aws"
      params = %{"search_terms" => ["", "aws", ""]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert "aws_api_key" in response.matching_secrets
    end

    # R12: Wildcard Escaping
    test "SQL wildcards treated as literal characters", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF terms contain % or _ THEN treated as literal characters
      {:ok, _} = create_test_secret("api_key_v1")
      {:ok, _} = create_test_secret("api_key_v2")

      # Search with underscore should match literally, not as wildcard
      params = %{"search_terms" => ["key_v"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert length(response.matching_secrets) == 2

      # Search with % character (can't appear in secret names)
      params2 = %{"search_terms" => ["%"]}
      result2 = SearchSecrets.execute(params2, "agent_123", [])

      assert {:ok, response2} = result2
      # Should not match anything since no secret names contain %
      assert response2.matching_secrets == []
    end
  end

  describe "execute/3 - parameter validation" do
    # R6: Missing Parameter Error
    test "returns error when search_terms missing", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF search_terms missing THEN returns error
      params = %{}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:error, reason} = result
      assert reason =~ "search_terms"
    end

    # R7: Invalid Type Error
    test "returns error when search_terms is not a list", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF search_terms not a list THEN returns error
      params = %{"search_terms" => "not_a_list"}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:error, reason} = result
      assert reason =~ "list"
    end

    # R8: Non-String Terms Error
    test "returns error when terms contain non-strings", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute called IF any term is not a string THEN returns error
      params = %{"search_terms" => ["valid", 123, "also_valid"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:error, reason} = result
      assert reason =~ "string"
    end
  end

  describe "execute/3 - response format" do
    # R9: Standard Response Format
    test "response includes standard action format", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute succeeds THEN response includes action, matching_secrets, count, message
      {:ok, _} = create_test_secret("test_secret")

      params = %{"search_terms" => ["test"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      assert Map.has_key?(response, :action)
      assert Map.has_key?(response, :matching_secrets)
      assert response.action == "search_secrets"
    end

    # R10: Never Returns Values
    test "response never includes secret values", %{sandbox_owner: _owner} do
      # [UNIT] - WHEN execute succeeds THEN response contains only names, never secret values
      secret_value = "super_secret_value_12345"

      {:ok, _} =
        TableSecrets.create(%{
          name: "test_secret",
          value: secret_value,
          description: "test"
        })

      params = %{"search_terms" => ["test"]}
      result = SearchSecrets.execute(params, "agent_123", [])

      assert {:ok, response} = result
      response_string = inspect(response)
      refute String.contains?(response_string, secret_value)
    end
  end

  describe "integration" do
    # R14: Integration with Validator
    test "validator validates search_secrets parameters", %{sandbox_owner: _owner} do
      # [INTEGRATION] - WHEN validator receives search_secrets action THEN validates against schema
      alias Quoracle.Actions.Validator

      # Valid action
      valid_action = %{
        "action" => "search_secrets",
        "params" => %{"search_terms" => ["test"]},
        "reasoning" => "Testing search"
      }

      assert {:ok, _} = Validator.validate_action(valid_action)

      # Invalid - missing required param
      invalid_action = %{
        "action" => "search_secrets",
        "params" => %{},
        "reasoning" => "Missing search_terms"
      }

      assert {:error, _} = Validator.validate_action(invalid_action)

      # Invalid - wrong type
      wrong_type = %{
        "action" => "search_secrets",
        "params" => %{"search_terms" => "not_a_list"},
        "reasoning" => "Wrong type"
      }

      assert {:error, _} = Validator.validate_action(wrong_type)
    end
  end
end
