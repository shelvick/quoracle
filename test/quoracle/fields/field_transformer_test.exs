defmodule Quoracle.Fields.FieldTransformerTest do
  @moduledoc """
  Tests for MOD_FieldTransformer - Field Transformation Module.

  ARC Verification Criteria:
  - R1, R4-R5: Unit tests for narrative transformation
  - R7-R8: Config-driven model tests

  Note: LLM integration tests (R2, R3, R6) moved to google_vertex_integration_test.exs
  to consolidate all Google Vertex tests that require serial execution.
  """
  # Unit tests only - LLM tests moved to google_vertex_integration_test.exs
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Fields.FieldTransformer

  describe "summarize_narrative/2" do
    # R1: Narrative Combination - UNIT
    test "combines narratives when under limit" do
      parent_fields = %{
        transformed: %{
          accumulated_narrative: "Parent found initial patterns."
        }
      }

      provided_fields = %{
        immediate_context: "Child analyzing specific subset."
      }

      result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

      assert result == "Parent found initial patterns. Child analyzing specific subset."
      assert String.length(result) <= 500
    end

    test "returns new context when parent narrative is empty" do
      parent_fields = %{transformed: %{}}
      provided_fields = %{immediate_context: "Fresh context from child"}

      result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

      assert result == "Fresh context from child"
    end

    test "returns parent narrative when new context is empty" do
      parent_fields = %{
        transformed: %{
          accumulated_narrative: "Existing parent narrative"
        }
      }

      provided_fields = %{}

      result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

      assert result == "Existing parent narrative"
    end

    # R4: Empty Narrative Handling - UNIT
    test "handles empty narratives correctly" do
      assert FieldTransformer.summarize_narrative(%{}, %{}) == ""

      assert FieldTransformer.summarize_narrative(
               %{transformed: %{accumulated_narrative: ""}},
               %{immediate_context: ""}
             ) == ""
    end

    test "handles nil values in narratives" do
      parent_fields = %{transformed: %{accumulated_narrative: nil}}
      provided_fields = %{immediate_context: nil}

      result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

      assert result == ""
    end

    # R5: Character Limit Enforcement - UNIT
    test "enforces character limit on output" do
      # Create a narrative that's exactly 500 chars
      exact_500 = String.duplicate("a", 500)
      parent_fields = %{transformed: %{accumulated_narrative: exact_500}}
      provided_fields = %{immediate_context: ""}

      result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

      assert String.length(result) <= 500
      assert result == exact_500
    end
  end

  # NOTE: LLM integration tests (R2, R3, R6) moved to google_vertex_integration_test.exs
  # to consolidate all Google Vertex tests that require serial execution.

  describe "apply_transformations/2" do
    test "returns map with accumulated_narrative" do
      parent_fields = %{
        transformed: %{
          accumulated_narrative: "Parent context"
        }
      }

      child_fields = %{
        immediate_context: "Child context"
      }

      result = FieldTransformer.apply_transformations(parent_fields, child_fields)

      assert is_map(result)
      assert Map.has_key?(result, :accumulated_narrative)
      assert is_binary(result.accumulated_narrative)
    end

    test "handles missing parent fields" do
      result = FieldTransformer.apply_transformations(%{}, %{immediate_context: "New"})

      assert result.accumulated_narrative == "New"
    end
  end

  describe "property-based tests" do
    # Note: These tests stay under 500 chars to avoid triggering LLM calls.
    # Property tests should be deterministic without network dependencies.

    property "combines narratives correctly when under limit" do
      # Keep combined length under 500 to avoid LLM trigger
      # With max 200 each + 1 space separator = max 401 chars
      check all(
              parent <- string(:alphanumeric, max_length: 200),
              child <- string(:alphanumeric, max_length: 200)
            ) do
        parent_fields = %{transformed: %{accumulated_narrative: parent}}
        provided_fields = %{immediate_context: child}

        result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

        expected =
          case {parent, child} do
            {"", child} -> child
            {parent, ""} -> parent
            {parent, child} -> "#{parent} #{child}"
          end

        # Under 500 chars, should be exact combination
        assert result == expected
        assert String.length(result) <= 500
      end
    end

    property "handles empty strings correctly" do
      check all(
              parent <- one_of([constant(""), string(:alphanumeric, max_length: 100)]),
              child <- one_of([constant(""), string(:alphanumeric, max_length: 100)])
            ) do
        parent_fields = %{transformed: %{accumulated_narrative: parent}}
        provided_fields = %{immediate_context: child}

        result = FieldTransformer.summarize_narrative(parent_fields, provided_fields)

        # Verify empty handling
        cond do
          parent == "" and child == "" -> assert result == ""
          parent == "" -> assert result == child
          child == "" -> assert result == parent
          true -> assert result == "#{parent} #{child}"
        end
      end
    end
  end

  # =============================================================
  # Config-Driven Summarization Model (R7-R8) - NEW
  # These tests require database access for ConfigModelSettings
  # =============================================================

  describe "summarize_narrative/2 with config-driven model" do
    alias Quoracle.Models.ConfigModelSettings

    setup do
      # Setup database sandbox for these tests
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Quoracle.Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    # R7: WHEN summarizing THEN uses model from ConfigModelSettings.get_summarization_model!()
    test "uses configured summarization model" do
      # Verify the implementation calls ConfigModelSettings.get_summarization_model!()
      # instead of using a hardcoded model string
      {:ok, code} = File.read("lib/quoracle/fields/field_transformer.ex")

      # Implementation MUST call the config function to get the model
      assert code =~ "ConfigModelSettings.get_summarization_model!()",
             "Implementation must call ConfigModelSettings.get_summarization_model!() " <>
               "instead of hardcoded model. Found hardcoded: google-vertex:gemini-2.5-pro"

      # Implementation MUST NOT have hardcoded model string
      refute code =~ ~s("google-vertex:gemini-2.5-pro"),
             "Implementation must not contain hardcoded model string"
    end

    # R8: WHEN summarization model not configured IF narrative exceeds limit THEN raises RuntimeError
    test "raises RuntimeError when summarization model not configured" do
      # Ensure summarization_model is NOT configured
      # (sandbox starts with empty DB)

      # Verify not configured
      assert {:error, :not_configured} = ConfigModelSettings.get_summarization_model()

      # Create text that exceeds 500 chars to trigger LLM summarization
      long_text = String.duplicate("X", 600)

      parent_fields = %{
        transformed: %{
          accumulated_narrative: long_text
        }
      }

      provided_fields = %{immediate_context: ""}

      # Should raise RuntimeError because get_summarization_model!() is called
      # and model is not configured
      assert_raise RuntimeError, ~r/not configured/i, fn ->
        FieldTransformer.summarize_narrative(parent_fields, provided_fields)
      end
    end
  end
end
