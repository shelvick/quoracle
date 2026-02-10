defmodule Quoracle.Models.ModelQueryCachingTest do
  @moduledoc """
  Tests for MODEL_Query v10.0 prompt caching support.

  ARC Verification Criteria:
  - R19: No Cache Without Option [UNIT]
  - R20: Cache With True [UNIT]
  - R21: Cache With Offset [UNIT]
  - R22: Bedrock Only [UNIT]

  Note: R23 (Cache Metrics Logged) removed - logging is an implementation detail.

  WorkGroupID: cache-20251212-160000
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Models.{ModelQuery, TableCredentials}

  # Test credentials for Bedrock (Anthropic models - caching supported)
  defp create_bedrock_credential(model_id) do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "amazon-bedrock:anthropic.claude-opus-4-5-v1:0",
        api_key: "ACCESS_KEY:SECRET_KEY",
        region: "us-east-1"
      })

    credential
  end

  # Test credentials for Azure (automatic caching - no explicit options needed)
  defp create_azure_credential(model_id) do
    {:ok, credential} =
      TableCredentials.insert(%{
        model_id: model_id,
        model_spec: "azure:gpt-5.1-chat",
        api_key: "test-azure-key",
        endpoint_url: "https://test.openai.azure.com",
        deployment_id: "gpt-5-deployment"
      })

    credential
  end

  describe "R19: No Cache Without Option [UNIT]" do
    test "excludes cache options when prompt_cache not present" do
      credential = create_bedrock_credential("test_no_cache_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{})

      provider_opts = Keyword.get(opts, :provider_options, [])
      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
      refute Keyword.has_key?(provider_opts, :anthropic_cache_messages)
    end

    test "excludes cache options when prompt_cache: nil" do
      credential = create_bedrock_credential("test_nil_cache_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{prompt_cache: nil})

      provider_opts = Keyword.get(opts, :provider_options, [])
      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
      refute Keyword.has_key?(provider_opts, :anthropic_cache_messages)
    end
  end

  describe "R20: Cache With True [UNIT]" do
    test "includes cache options when prompt_cache: true" do
      credential = create_bedrock_credential("test_cache_true_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{prompt_cache: true})

      provider_opts = Keyword.get(opts, :provider_options, [])
      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
      assert Keyword.get(provider_opts, :anthropic_cache_messages) == true
    end
  end

  describe "R21: Cache With Offset [UNIT]" do
    test "includes cache offset when prompt_cache is integer" do
      credential = create_bedrock_credential("test_cache_offset_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{prompt_cache: -2})

      provider_opts = Keyword.get(opts, :provider_options, [])
      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
      assert Keyword.get(provider_opts, :anthropic_cache_messages) == -2
    end

    test "supports other integer offsets" do
      credential = create_bedrock_credential("test_cache_neg1_#{System.unique_integer()}")

      opts = ModelQuery.build_options(credential, %{prompt_cache: -1})

      provider_opts = Keyword.get(opts, :provider_options, [])
      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
      assert Keyword.get(provider_opts, :anthropic_cache_messages) == -1
    end
  end

  describe "R22: Bedrock Only [UNIT]" do
    test "cache options only added for amazon-bedrock provider" do
      bedrock_credential =
        create_bedrock_credential("test_bedrock_cache_#{System.unique_integer()}")

      azure_credential = create_azure_credential("test_azure_no_cache_#{System.unique_integer()}")

      # Bedrock should get cache options
      bedrock_opts = ModelQuery.build_options(bedrock_credential, %{prompt_cache: -2})
      bedrock_provider_opts = Keyword.get(bedrock_opts, :provider_options, [])
      assert Keyword.get(bedrock_provider_opts, :anthropic_prompt_cache) == true
      assert Keyword.get(bedrock_provider_opts, :anthropic_cache_messages) == -2

      # Azure should NOT get cache options (automatic caching)
      azure_opts = ModelQuery.build_options(azure_credential, %{prompt_cache: -2})
      azure_provider_opts = Keyword.get(azure_opts, :provider_options, [])
      refute Keyword.has_key?(azure_provider_opts, :anthropic_prompt_cache)
      refute Keyword.has_key?(azure_provider_opts, :anthropic_cache_messages)
    end

    test "google-vertex does not get anthropic cache options" do
      {:ok, credential} =
        TableCredentials.insert(%{
          model_id: "test_vertex_no_cache_#{System.unique_integer()}",
          model_spec: "google-vertex:gemini-3-pro",
          api_key: ~s({"type": "service_account", "project_id": "test"}),
          resource_id: "test-project",
          region: "us-central1"
        })

      opts = ModelQuery.build_options(credential, %{prompt_cache: -2})
      provider_opts = Keyword.get(opts, :provider_options, [])

      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
      refute Keyword.has_key?(provider_opts, :anthropic_cache_messages)
    end
  end
end
