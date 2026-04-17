defmodule Quoracle.Agent.TokenManagerCredentialAliasTest do
  @moduledoc """
  Regression tests for credential-alias resolution in TokenManager limit lookups.

  When a profile contains multiple credentials sharing one underlying model_spec
  (e.g., `gemini-3-flash-preview2`, `gemini-3-flash-preview3`), the credential's
  user-assigned `model_id` threads through the consensus pipeline and reaches
  `get_model_context_limit/1` / `get_model_output_limit/1`. A direct LLMDB
  lookup on that alias fails; before this fix, both helpers silently defaulted
  to 128_000, which caused Gemini/Vertex to reject requests with
  `maxOutputTokens` above the real model's cap.

  These tests verify the credential-alias fallback: when LLMDB can't resolve
  the given string, TokenManager retries the lookup using the credential's
  `model_spec` column.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.TokenManager
  alias Quoracle.Models.TableCredentials

  # A real LLMDB entry also used by token_manager_dynamic_max_tokens_test.exs.
  @canonical_spec "anthropic:claude-sonnet-4-20250514"

  describe "credential-alias fallback" do
    test "get_model_context_limit/1 resolves an alias credential via model_spec" do
      alias_id = "alias_ctx_#{System.unique_integer([:positive])}"

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: alias_id,
          model_spec: @canonical_spec,
          api_key: "test-key-#{alias_id}"
        })

      canonical_limit = TokenManager.get_model_context_limit(@canonical_spec)
      alias_limit = TokenManager.get_model_context_limit(alias_id)

      assert is_integer(alias_limit)
      assert alias_limit == canonical_limit
    end

    test "get_model_output_limit/1 resolves an alias credential via model_spec" do
      alias_id = "alias_out_#{System.unique_integer([:positive])}"

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: alias_id,
          model_spec: @canonical_spec,
          api_key: "test-key-#{alias_id}"
        })

      canonical_output = TokenManager.get_model_output_limit(@canonical_spec)
      alias_output = TokenManager.get_model_output_limit(alias_id)

      assert is_integer(alias_output)
      assert alias_output == canonical_output
    end

    test "get_model_output_limit/1 returns real cap, not the 128K default, for an alias" do
      # Guards against the specific production bug: profiles with two credentials
      # aliasing one underlying model blew past the real output cap because both
      # helpers silently returned @default_context_limit (128_000).
      alias_id = "alias_real_cap_#{System.unique_integer([:positive])}"

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: alias_id,
          model_spec: @canonical_spec,
          api_key: "test-key-#{alias_id}"
        })

      canonical_output = TokenManager.get_model_output_limit(@canonical_spec)
      alias_output = TokenManager.get_model_output_limit(alias_id)

      # If the canonical model's real output < 128_000, the alias must match it
      # (not fall back to 128_000). If it's == 128_000 we can't distinguish,
      # so skip the strict assertion but still verify equality above.
      if canonical_output < 128_000 do
        assert alias_output == canonical_output
        refute alias_output == 128_000
      end
    end

    test "unknown name with no matching credential still returns the default" do
      limit =
        TokenManager.get_model_output_limit("no_such_alias_#{System.unique_integer([:positive])}")

      assert limit == 128_000
    end

    test "credential whose model_spec is also unresolvable falls back to default" do
      alias_id = "alias_unresolvable_#{System.unique_integer([:positive])}"

      {:ok, _} =
        TableCredentials.insert(%{
          model_id: alias_id,
          model_spec: "nonexistent:fake-model-xyz-999",
          api_key: "test-key-#{alias_id}"
        })

      assert TokenManager.get_model_context_limit(alias_id) == 128_000
      assert TokenManager.get_model_output_limit(alias_id) == 128_000
    end
  end
end
