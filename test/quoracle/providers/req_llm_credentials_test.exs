defmodule Quoracle.Providers.ReqLLMCredentialsTest do
  @moduledoc """
  Tests for ReqLLMCredentials - formats CredentialManager output for req_llm.

  ARC Verification Criteria from LIB_ReqLLM spec:
  - R2: Google Credential Formatting [UNIT]
  - R3: Bedrock Credential Formatting [UNIT]
  - R4: Azure Credential Formatting [UNIT]
  - R5: Credential Error Handling [UNIT]
  - R6: Region Extraction [UNIT]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Providers.ReqLLMCredentials
  alias Quoracle.Models.TableCredentials

  describe "dependency" do
    # R1: WHEN mix deps.get runs THEN req_llm and dependencies compile successfully
    test "req_llm module is available" do
      # Verify req_llm library is available by checking module info
      # This will fail until req_llm is added to mix.exs
      # Using apply/3 to avoid compile-time module reference
      module = apply(ReqLLM, :__info__, [:module])
      assert module == ReqLLM
    end
  end

  describe "for_google/1" do
    # R2: WHEN for_google/1 called with valid model_id THEN returns keyword list
    # with service_account_json, project_id, region
    test "formats Google credentials for req_llm" do
      service_account_json = ~s({"type": "service_account", "project_id": "test-project"})

      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "test_google_vertex",
          model_spec: "google-vertex:gemini-2.0-flash",
          api_key: service_account_json,
          resource_id: "test-gcp-project",
          region: "us-east4"
        })

      {:ok, opts} = ReqLLMCredentials.for_google("test_google_vertex")

      assert Keyword.get(opts, :service_account_json) == service_account_json
      assert Keyword.get(opts, :project_id) == "test-gcp-project"
      assert Keyword.get(opts, :region) == "us-east4"
    end

    test "uses default region when region not in credentials" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "google_no_location",
          model_spec: "google-vertex:gemini",
          api_key: ~s({"type": "service_account"}),
          resource_id: "project-123"
        })

      {:ok, opts} = ReqLLMCredentials.for_google("google_no_location")

      assert Keyword.get(opts, :region) == "global"
    end
  end

  describe "for_bedrock/1" do
    # R3: WHEN for_bedrock/1 called with valid model_id THEN returns keyword list
    # with access_key_id, secret_access_key, region
    test "formats Bedrock credentials for req_llm" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "test_bedrock_claude",
          model_spec: "anthropic-bedrock:claude-sonnet-4",
          api_key: "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          endpoint_url: "https://bedrock-runtime.us-west-2.amazonaws.com"
        })

      {:ok, opts} = ReqLLMCredentials.for_bedrock("test_bedrock_claude")

      assert Keyword.get(opts, :access_key_id) == "AKIAIOSFODNN7EXAMPLE"
      assert Keyword.get(opts, :secret_access_key) == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      assert Keyword.get(opts, :region) == "us-west-2"
    end

    # R6: WHEN Bedrock endpoint_url contains region THEN extracts region correctly
    test "extracts region from Bedrock endpoint URL" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "bedrock_eu_west",
          model_spec: "anthropic-bedrock:claude",
          api_key: "ACCESS:SECRET",
          endpoint_url: "https://bedrock-runtime.eu-west-1.amazonaws.com"
        })

      {:ok, opts} = ReqLLMCredentials.for_bedrock("bedrock_eu_west")

      assert Keyword.get(opts, :region) == "eu-west-1"
    end

    test "extracts region from various AWS endpoint formats" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "bedrock_ap_northeast",
          model_spec: "anthropic-bedrock:claude",
          api_key: "ACCESS:SECRET",
          endpoint_url: "https://bedrock.ap-northeast-1.amazonaws.com"
        })

      {:ok, opts} = ReqLLMCredentials.for_bedrock("bedrock_ap_northeast")

      assert Keyword.get(opts, :region) == "ap-northeast-1"
    end
  end

  describe "for_azure/1" do
    # R4: WHEN for_azure/1 called with valid model_id THEN returns keyword list
    # with api_key, resource_name, deployment_name, api_version
    test "formats Azure credentials for req_llm" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "test_azure_o1",
          model_spec: "azure:o1",
          api_key: "azure-api-key-12345",
          resource_id: "my-azure-resource",
          deployment_id: "o1-deployment",
          endpoint_url: "https://my-azure-resource.openai.azure.com"
        })

      {:ok, opts} = ReqLLMCredentials.for_azure("test_azure_o1")

      assert Keyword.get(opts, :api_key) == "azure-api-key-12345"
      assert Keyword.get(opts, :resource_name) == "my-azure-resource"
      assert Keyword.get(opts, :deployment_name) == "o1-deployment"
      assert Keyword.get(opts, :api_version) == "2024-02-15-preview"
    end

    test "formats Azure Custom credentials for req_llm" do
      {:ok, _cred} =
        TableCredentials.insert(%{
          model_id: "test_azure_deepseek",
          model_spec: "azure:deepseek-r1",
          api_key: "deepseek-key",
          resource_id: "custom-resource",
          deployment_id: "deepseek-deployment"
        })

      {:ok, opts} = ReqLLMCredentials.for_azure("test_azure_deepseek")

      assert Keyword.get(opts, :api_key) == "deepseek-key"
      assert Keyword.get(opts, :resource_name) == "custom-resource"
      assert Keyword.get(opts, :deployment_name) == "deepseek-deployment"
    end
  end

  describe "error handling" do
    # R5: WHEN credential lookup fails THEN returns {:error, reason} tuple
    test "returns error for missing credentials" do
      assert {:error, :not_found} = ReqLLMCredentials.for_google("nonexistent_model")
      assert {:error, :not_found} = ReqLLMCredentials.for_bedrock("nonexistent_model")
      assert {:error, :not_found} = ReqLLMCredentials.for_azure("nonexistent_model")
    end

    test "propagates credential manager errors" do
      # Insert corrupted encrypted value directly to test decryption failure
      {:ok, binary_id} = Ecto.UUID.dump(Ecto.UUID.generate())

      Ecto.Adapters.SQL.query!(
        Quoracle.Repo,
        "INSERT INTO credentials (id, model_id, model_spec, api_key, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
        [
          binary_id,
          "corrupted_creds",
          "anthropic-bedrock:claude",
          "corrupted",
          DateTime.utc_now(),
          DateTime.utc_now()
        ]
      )

      assert {:error, :decryption_failed} = ReqLLMCredentials.for_bedrock("corrupted_creds")
    end
  end
end
