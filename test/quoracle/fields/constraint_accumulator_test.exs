defmodule Quoracle.Fields.ConstraintAccumulatorTest do
  @moduledoc """
  Tests for the ConstraintAccumulator module that merges constraints through agent hierarchy.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Fields.ConstraintAccumulator

  describe "accumulate/2" do
    # R1: Basic Accumulation - UNIT
    test "accumulates constraints from parent and new" do
      parent_fields = %{
        transformed: %{
          constraints: ["Parent constraint 1", "Parent constraint 2"]
        }
      }

      provided_fields = %{
        downstream_constraints: "New constraint"
      }

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert length(result) == 3
      assert "Parent constraint 1" in result
      assert "Parent constraint 2" in result
      assert "New constraint" in result
    end

    test "handles empty parent constraints" do
      parent_fields = %{transformed: %{}}
      provided_fields = %{downstream_constraints: "New constraint"}

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert result == ["New constraint"]
    end

    test "handles empty new constraints" do
      parent_fields = %{
        transformed: %{
          constraints: ["Parent constraint"]
        }
      }

      provided_fields = %{}

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert result == ["Parent constraint"]
    end

    # R2: Deduplication - UNIT
    test "removes duplicate constraints" do
      parent_fields = %{
        transformed: %{
          constraints: ["Constraint A", "Constraint B"]
        }
      }

      provided_fields = %{
        downstream_constraints: "Constraint B"
      }

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert length(result) == 2
      assert Enum.sort(result) == ["Constraint A", "Constraint B"]
    end

    # R4: Type Filtering - UNIT
    test "filters non-string constraints" do
      parent_fields = %{
        transformed: %{
          constraints: ["Valid string", 123, :atom, nil]
        }
      }

      provided_fields = %{
        downstream_constraints: "Another valid"
      }

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert result == ["Valid string", "Another valid"]
    end

    # R5: Empty String Filtering - UNIT
    test "removes empty string constraints" do
      parent_fields = %{
        transformed: %{
          constraints: ["Valid", "", "   ", "Another valid"]
        }
      }

      provided_fields = %{
        downstream_constraints: "New valid"
      }

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      # Note: "   " with spaces might be kept depending on implementation
      assert "" not in result
      assert "Valid" in result
      assert "Another valid" in result
      assert "New valid" in result
    end

    # R6: Nil Handling - UNIT
    test "handles nil constraints gracefully" do
      parent_fields = %{
        transformed: %{
          constraints: nil
        }
      }

      provided_fields = %{
        downstream_constraints: nil
      }

      result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

      assert result == []
    end

    test "handles missing constraint keys" do
      result = ConstraintAccumulator.accumulate(%{}, %{})
      assert result == []
    end
  end

  describe "property-based tests" do
    property "accumulation never loses valid constraints" do
      check all(
              parent_constraints <- list_of(string(:alphanumeric, min_length: 1), max_length: 10),
              new_constraint <- string(:alphanumeric, min_length: 1)
            ) do
        parent_fields = %{
          transformed: %{
            constraints: parent_constraints
          }
        }

        provided_fields = %{
          downstream_constraints: new_constraint
        }

        result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

        # All unique constraints should be present
        all_unique = Enum.uniq(parent_constraints ++ [new_constraint])
        assert Enum.sort(result) == Enum.sort(all_unique)
      end
    end

    property "deduplication produces unique list" do
      check all(constraint <- member_of(["A", "B", "C", "D"])) do
        parent_fields = %{
          transformed: %{
            constraints: [constraint, constraint]
          }
        }

        provided_fields = %{
          downstream_constraints: constraint
        }

        result = ConstraintAccumulator.accumulate(parent_fields, provided_fields)

        # Result should have no duplicates
        assert result == Enum.uniq(result)
        assert result == [constraint]
      end
    end

    property "type filtering removes all non-strings" do
      check all(
              valid_strings <- list_of(string(:alphanumeric, min_length: 1), max_length: 5),
              invalid_items <-
                list_of(
                  one_of([integer(), float(), atom(:alphanumeric), constant(nil)]),
                  max_length: 5
                )
            ) do
        mixed = Enum.shuffle(valid_strings ++ invalid_items)

        parent_fields = %{
          transformed: %{
            constraints: mixed
          }
        }

        result = ConstraintAccumulator.accumulate(parent_fields, %{})

        # Only strings should remain
        assert Enum.all?(result, &is_binary/1)
        assert Enum.sort(result) == Enum.sort(Enum.uniq(valid_strings))
      end
    end
  end
end
