defmodule Quoracle.Utils.JSONNormalizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Utils.JSONNormalizer

  describe "normalize/1 - basic types" do
    # R1: Basic Type Normalization
    test "normalizes primitive types to JSON" do
      # Strings
      result = JSONNormalizer.normalize("hello world")
      assert result == "\"hello world\""
      assert {:ok, _} = Jason.decode(result)

      # Numbers
      result = JSONNormalizer.normalize(42)
      assert result == "42"
      assert {:ok, 42} = Jason.decode(result)

      result = JSONNormalizer.normalize(3.14)
      assert result == "3.14"
      assert {:ok, 3.14} = Jason.decode(result)

      # Booleans
      result = JSONNormalizer.normalize(true)
      assert result == "true"
      assert {:ok, true} = Jason.decode(result)

      result = JSONNormalizer.normalize(false)
      assert result == "false"
      assert {:ok, false} = Jason.decode(result)

      # Nil
      result = JSONNormalizer.normalize(nil)
      assert result == "null"
      assert {:ok, nil} = Jason.decode(result)
    end

    # R2: Atom to String Conversion
    test "converts atoms to strings" do
      result = JSONNormalizer.normalize(:ok)
      assert result == "\"ok\""
      assert {:ok, "ok"} = Jason.decode(result)

      result = JSONNormalizer.normalize(:error)
      assert result == "\"error\""
      assert {:ok, "error"} = Jason.decode(result)

      result = JSONNormalizer.normalize(:custom_atom)
      assert result == "\"custom_atom\""
      assert {:ok, "custom_atom"} = Jason.decode(result)
    end
  end

  describe "normalize/1 - tuples" do
    # R3: Success Tuple Normalization
    test "normalizes {:ok, value} tuples to JSON objects" do
      result = JSONNormalizer.normalize({:ok, "success"})
      json = Jason.decode!(result)
      assert json["type"] == "ok"
      assert json["value"] == "success"
      # Pretty printed
      assert String.contains?(result, "\n")

      # With complex value
      result = JSONNormalizer.normalize({:ok, %{data: [1, 2, 3]}})
      json = Jason.decode!(result)
      assert json["type"] == "ok"
      assert json["value"]["data"] == [1, 2, 3]
    end

    # R4: Error Tuple Normalization
    test "normalizes {:error, reason} tuples to JSON objects" do
      result = JSONNormalizer.normalize({:error, "not found"})
      json = Jason.decode!(result)
      assert json["type"] == "error"
      assert json["reason"] == "not found"
      # Pretty printed
      assert String.contains?(result, "\n")

      # With atom reason
      result = JSONNormalizer.normalize({:error, :timeout})
      json = Jason.decode!(result)
      assert json["type"] == "error"
      assert json["reason"] == "timeout"
    end

    test "normalizes other tuples appropriately" do
      # Generic 2-tuple
      result = JSONNormalizer.normalize({:custom, "data"})
      json = Jason.decode!(result)
      assert Map.has_key?(json, "custom")
      assert json["custom"] == "data"

      # 3-tuple
      result = JSONNormalizer.normalize({:reply, :ok, "state"})
      json = Jason.decode!(result)
      assert is_list(json)
    end
  end

  describe "normalize/1 - maps" do
    # R5: Map Normalization with Atom Keys
    test "normalizes maps with atom keys" do
      map = %{name: "John", age: 30, active: true}
      result = JSONNormalizer.normalize(map)
      json = Jason.decode!(result)

      assert json["name"] == "John"
      assert json["age"] == 30
      assert json["active"] == true
      # No atom keys in JSON
      refute Map.has_key?(json, :name)
    end

    # R6: Map Normalization with String Keys
    test "normalizes maps with string keys" do
      map = %{"name" => "Jane", "age" => 25, "active" => false}
      result = JSONNormalizer.normalize(map)
      json = Jason.decode!(result)

      assert json["name"] == "Jane"
      assert json["age"] == 25
      assert json["active"] == false
    end

    test "normalizes maps with mixed key types" do
      map = %{:atom_key => "value1", "string_key" => "value2"}
      result = JSONNormalizer.normalize(map)
      json = Jason.decode!(result)

      assert json["atom_key"] == "value1"
      assert json["string_key"] == "value2"
    end
  end

  describe "normalize/1 - collections" do
    # R7: List Normalization
    test "normalizes lists recursively" do
      list = [1, "two", :three, %{four: 4}]
      result = JSONNormalizer.normalize(list)
      json = Jason.decode!(result)

      assert json == [1, "two", "three", %{"four" => 4}]

      # Nested lists
      nested = [1, [2, [3, [4]]]]
      result = JSONNormalizer.normalize(nested)
      json = Jason.decode!(result)
      assert json == [1, [2, [3, [4]]]]
    end

    # R10: Nested Structure Normalization
    test "handles deeply nested structures" do
      nested = %{
        level1: %{
          level2: %{
            level3: %{
              data: [{:ok, "deep"}],
              items: [1, 2, 3]
            }
          }
        }
      }

      result = JSONNormalizer.normalize(nested)
      json = Jason.decode!(result)

      assert json["level1"]["level2"]["level3"]["data"] == [
               %{"type" => "ok", "value" => "deep"}
             ]

      assert json["level1"]["level2"]["level3"]["items"] == [1, 2, 3]
    end

    # R11: Empty Structure Handling
    test "handles empty maps and lists" do
      # Empty map
      result = JSONNormalizer.normalize(%{})
      assert result =~ ~r/^\{\s*\}$/m
      assert {:ok, %{}} = Jason.decode(result)

      # Empty list
      result = JSONNormalizer.normalize([])
      assert result =~ ~r/^\[\s*\]$/m
      assert {:ok, []} = Jason.decode(result)
    end
  end

  describe "normalize/1 - non-serializable types" do
    # R8: PID String Representation
    test "converts PIDs to string representations" do
      pid = self()
      result = JSONNormalizer.normalize(pid)
      json = Jason.decode!(result)

      assert is_binary(json)
      assert json =~ ~r/#PID<\d+\.\d+\.\d+>/
    end

    # R9: Reference String Representation
    test "converts references to string representations" do
      ref = make_ref()
      result = JSONNormalizer.normalize(ref)
      json = Jason.decode!(result)

      assert is_binary(json)
      assert json =~ ~r/#Reference<\d+\.\d+\.\d+\.\d+>/
    end

    test "handles functions" do
      fun = fn x -> x * 2 end
      result = JSONNormalizer.normalize(fun)
      json = Jason.decode!(result)

      assert is_binary(json)
      assert json =~ ~r/#Function|\[Function\]/
    end

    test "handles ports" do
      # Create a port (using a safe command)
      port = Port.open({:spawn, "echo test"}, [:binary])

      result = JSONNormalizer.normalize(port)
      json = Jason.decode!(result)

      assert is_binary(json)
      assert json =~ ~r/#Port<\d+\.\d+>/

      # Port may already be closed by the time we get here
      try do
        Port.close(port)
      catch
        :error, :badarg -> :ok
      end
    end
  end

  describe "normalize/1 - output format" do
    # R12: Pretty Printing
    test "returns pretty-printed JSON with indentation" do
      data = %{
        name: "Test",
        nested: %{
          values: [1, 2, 3]
        }
      }

      result = JSONNormalizer.normalize(data)

      # Should have newlines
      assert String.contains?(result, "\n")

      # Should have indentation (2 spaces)
      assert String.contains?(result, "  ")

      # Should be valid JSON
      assert {:ok, _} = Jason.decode(result)
    end

    test "pretty prints arrays" do
      data = [
        %{id: 1, name: "First"},
        %{id: 2, name: "Second"}
      ]

      result = JSONNormalizer.normalize(data)

      assert String.contains?(result, "\n")
      assert String.contains?(result, "  ")
    end
  end

  describe "property tests" do
    # R13: Valid JSON Output
    property "always produces valid JSON" do
      check all(term <- term()) do
        result = JSONNormalizer.normalize(term)

        # Must be a string
        assert is_binary(result)

        # Must be valid JSON
        case Jason.decode(result) do
          {:ok, _} -> assert true
          {:error, _} -> flunk("Invalid JSON produced: #{result}")
        end
      end
    end

    property "maintains data structure shape" do
      check all(map <- map_of(atom(:alphanumeric), term(), max_length: 10)) do
        result = JSONNormalizer.normalize(map)
        json = Jason.decode!(result)

        # Same number of keys (atoms converted to strings)
        assert map_size(map) == map_size(json)

        # All keys present (as strings)
        Enum.each(map, fn {key, _value} ->
          string_key = Atom.to_string(key)
          assert Map.has_key?(json, string_key)
        end)
      end
    end

    property "lists maintain order and length" do
      check all(list <- list_of(one_of([integer(), string(:ascii), boolean()]), max_length: 20)) do
        result = JSONNormalizer.normalize(list)
        json = Jason.decode!(result)

        assert length(list) == length(json)

        # Basic types should match directly
        Enum.zip(list, json)
        |> Enum.each(fn {original, decoded} ->
          assert original == decoded
        end)
      end
    end
  end

  describe "edge cases" do
    # R14: Comprehensive Edge Cases
    test "handles edge cases (long strings, special chars, mixed types)" do
      # Very long string
      long_string = String.duplicate("a", 10_000)
      result = JSONNormalizer.normalize(long_string)
      json = Jason.decode!(result)
      assert json == long_string

      # Special characters
      special = "Hello\nWorld\t\"Quotes\"\r\nUnicode: 你好 👋"
      result = JSONNormalizer.normalize(special)
      json = Jason.decode!(result)
      assert json == special

      # Mixed complex structure
      mixed = %{
        string: "text",
        number: 42,
        float: 3.14,
        bool: true,
        nil: nil,
        atom: :atom_value,
        tuple: {:ok, %{nested: "data"}},
        list: [1, "two", :three],
        pid: self(),
        ref: make_ref(),
        empty_map: %{},
        empty_list: []
      }

      result = JSONNormalizer.normalize(mixed)
      json = Jason.decode!(result)

      assert json["string"] == "text"
      assert json["number"] == 42
      assert json["float"] == 3.14
      assert json["bool"] == true
      assert json["nil"] == nil
      assert json["atom"] == "atom_value"
      assert json["tuple"]["type"] == "ok"
      assert json["list"] == [1, "two", "three"]
      assert json["pid"] =~ ~r/#PID/
      assert json["ref"] =~ ~r/#Reference/
      assert json["empty_map"] == %{}
      assert json["empty_list"] == []
    end

    test "handles improper lists gracefully" do
      # Improper lists can't be directly created in Elixir syntax,
      # but the normalizer should handle whatever it gets
      # This becomes [1, 2, 3] in Elixir
      data = [1, 2 | 3]
      result = JSONNormalizer.normalize(data)
      assert {:ok, _} = Jason.decode(result)
    end

    test "handles keyword lists" do
      kwlist = [name: "John", age: 30, active: true]
      result = JSONNormalizer.normalize(kwlist)
      json = Jason.decode!(result)

      # Keyword lists should be treated as lists of tuples
      assert is_list(json)
      assert length(json) == 3

      # Each tuple should be normalized appropriately
      Enum.each(json, fn item ->
        assert is_map(item)
      end)
    end

    test "handles structs" do
      # Using DateTime as an example struct
      datetime = ~U[2023-01-01 12:00:00Z]
      result = JSONNormalizer.normalize(datetime)
      json = Jason.decode!(result)

      # Struct should be converted to a map
      assert is_map(json)
      # Should have struct fields as keys
      assert Map.has_key?(json, "year")
    end

    test "handles MapSet" do
      # Will dedupe to [1, 2, 3]
      mapset = MapSet.new([1, 2, 3, 2, 1])
      result = JSONNormalizer.normalize(mapset)

      # MapSet should become a list or appropriate structure
      assert {:ok, _} = Jason.decode(result)
    end

    test "handles nested error tuples" do
      nested_error = {:error, {:invalid, %{reason: "bad input", code: 400}}}
      result = JSONNormalizer.normalize(nested_error)
      json = Jason.decode!(result)

      assert json["type"] == "error"
      assert is_map(json["reason"])
    end

    test "handles circular-like structures" do
      # Elixir doesn't have true circular references due to immutability,
      # but we can have deep nesting
      deep = %{a: %{b: %{c: %{d: %{e: %{f: "deep"}}}}}}
      result = JSONNormalizer.normalize(deep)
      json = Jason.decode!(result)

      assert json["a"]["b"]["c"]["d"]["e"]["f"] == "deep"
    end
  end
end
