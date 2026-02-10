defmodule Quoracle.Consensus.ActionParserCondenseTest do
  @moduledoc """
  Tests for ActionParser.extract_condense/1 function.

  Extracts optional `condense` field from raw LLM JSON responses.
  Like `bug_report`, this is per-model-response (not per-consensus).

  WorkGroupID: wip-20260104-condense-param
  Packet: 2 (Feature Integration)
  Requirements: R31-R40 from CONSENSUS_ActionParser v4.0 spec
  """

  use ExUnit.Case, async: true

  alias Quoracle.Consensus.ActionParser

  describe "R31-R32: Valid condense extraction" do
    test "extracts positive integer condense value" do
      raw_map = %{"condense" => 5, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == 5
    end

    test "extracts large positive condense value" do
      raw_map = %{"condense" => 100, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == 100
    end

    test "extracts condense value of 1" do
      raw_map = %{"condense" => 1, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == 1
    end
  end

  describe "R33-R34: Nil/null condense returns nil" do
    test "returns nil when condense key absent" do
      raw_map = %{"action" => "wait", "params" => %{}, "reasoning" => "test"}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for null condense value" do
      raw_map = %{"condense" => nil, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end

  describe "R35: Zero condense invalid" do
    test "returns nil for zero" do
      raw_map = %{"condense" => 0, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end

  describe "R36: Negative condense invalid" do
    test "returns nil for negative" do
      raw_map = %{"condense" => -3, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for large negative" do
      raw_map = %{"condense" => -100, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end

  describe "R37: String condense invalid" do
    test "returns nil for string" do
      raw_map = %{"condense" => "five", "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for numeric string" do
      raw_map = %{"condense" => "5", "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end

  describe "R38: Float condense invalid" do
    test "returns nil for float" do
      raw_map = %{"condense" => 5.5, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for float that looks like integer" do
      raw_map = %{"condense" => 5.0, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end

  describe "R39: Non-map input returns nil" do
    test "returns nil for non-map input" do
      assert ActionParser.extract_condense("not a map") == nil
    end

    test "returns nil for nil input" do
      assert ActionParser.extract_condense(nil) == nil
    end

    test "returns nil for list input" do
      assert ActionParser.extract_condense([1, 2, 3]) == nil
    end

    test "returns nil for tuple input" do
      assert ActionParser.extract_condense({:ok, %{}}) == nil
    end

    test "returns nil for integer input" do
      assert ActionParser.extract_condense(42) == nil
    end
  end

  describe "R40: Does not affect parsed response" do
    test "extraction does not modify parsed action response" do
      # Parse a response with condense field
      json = """
      {
        "action": "wait",
        "params": {},
        "reasoning": "Testing condense extraction",
        "condense": 5
      }
      """

      # Parse should succeed regardless of condense field
      assert {:ok, parsed} = ActionParser.parse_json_response(json)
      assert parsed.action == :wait
      assert parsed.reasoning == "Testing condense extraction"

      # Extract condense separately
      raw_map = %{"condense" => 5, "action" => "wait", "params" => %{}}
      condense_value = ActionParser.extract_condense(raw_map)
      assert condense_value == 5

      # Parsed response should not have condense field
      # (it's extracted separately, not part of action_response)
      refute Map.has_key?(parsed, :condense)
    end

    test "extraction is idempotent" do
      raw_map = %{"condense" => 5, "action" => "wait", "params" => %{}}

      # Multiple extractions should return same value
      result1 = ActionParser.extract_condense(raw_map)
      result2 = ActionParser.extract_condense(raw_map)
      result3 = ActionParser.extract_condense(raw_map)

      assert result1 == result2
      assert result2 == result3
      assert result1 == 5
    end
  end

  describe "edge cases" do
    test "handles empty map" do
      assert ActionParser.extract_condense(%{}) == nil
    end

    test "handles map with only condense key" do
      raw_map = %{"condense" => 10}

      assert ActionParser.extract_condense(raw_map) == 10
    end

    test "returns nil for boolean condense value" do
      raw_map = %{"condense" => true, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for list condense value" do
      raw_map = %{"condense" => [1, 2, 3], "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end

    test "returns nil for map condense value" do
      raw_map = %{"condense" => %{"value" => 5}, "action" => "wait", "params" => %{}}

      assert ActionParser.extract_condense(raw_map) == nil
    end
  end
end
