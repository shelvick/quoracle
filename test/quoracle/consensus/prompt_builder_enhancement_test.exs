defmodule Quoracle.Consensus.PromptBuilderEnhancementTest do
  @moduledoc """
  Tests for enhanced type conversion in PromptBuilder.
  Verifies nested map structures, enum types, and recursive type handling
  for proper JSON schema generation that guides LLMs.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Actions.Schema

  describe "enhanced format_param_type/1 - simple types" do
    test "ARC_TYPE_01: format_param_type(:string) returns 'string'" do
      assert PromptBuilder.format_param_type(:string) == "string"
    end

    test "ARC_TYPE_02: format_param_type(:integer) returns 'integer'" do
      assert PromptBuilder.format_param_type(:integer) == "integer"
    end

    test "ARC_TYPE_03: format_param_type(:atom) returns 'string'" do
      assert PromptBuilder.format_param_type(:atom) == "string"
    end

    test "ARC_TYPE_04: format_param_type(:boolean) returns 'boolean'" do
      assert PromptBuilder.format_param_type(:boolean) == "boolean"
    end

    test "ARC_TYPE_06: format_param_type(:map) returns generic object" do
      assert PromptBuilder.format_param_type(:map) == "object"
    end

    test "format_param_type(:number) returns 'number'" do
      assert PromptBuilder.format_param_type(:number) == "number"
    end
  end

  describe "enhanced format_param_type/1 - list types" do
    test "ARC_TYPE_05: format_param_type({:list, type}) returns array with recursive items" do
      result = PromptBuilder.format_param_type({:list, :string})

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "handles nested list of integers" do
      result = PromptBuilder.format_param_type({:list, :integer})

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }
    end

    test "handles list of atoms (converted to strings)" do
      result = PromptBuilder.format_param_type({:list, :atom})

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "handles list of generic maps" do
      result = PromptBuilder.format_param_type({:list, :map})

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "object"}
             }
    end
  end

  describe "enhanced format_param_type/1 - enum types" do
    test "ARC_TYPE_08: format_param_type({:enum, [values]}) returns enum constraint" do
      result = PromptBuilder.format_param_type({:enum, [:todo, :pending, :done]})

      assert result == %{
               "type" => "string",
               "enum" => ["todo", "pending", "done"]
             }
    end

    test "converts atom values to strings in enum" do
      result = PromptBuilder.format_param_type({:enum, [:get, :post, :put, :delete]})

      assert result == %{
               "type" => "string",
               "enum" => ["get", "post", "put", "delete"]
             }
    end

    test "handles single-value enum" do
      result = PromptBuilder.format_param_type({:enum, [:json]})

      assert result == %{
               "type" => "string",
               "enum" => ["json"]
             }
    end

    test "handles empty enum list" do
      result = PromptBuilder.format_param_type({:enum, []})

      assert result == %{
               "type" => "string",
               "enum" => []
             }
    end
  end

  describe "enhanced format_param_type/1 - nested map types" do
    test "ARC_TYPE_07: format_param_type({:map, %{field: type}}) returns detailed object schema" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             name: :string,
             age: :integer
           }}
        )

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"}
               },
               # Alphabetically sorted
               "required" => ["age", "name"]
             }
    end

    test "handles nested map with enum field" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             content: :string,
             state: {:enum, [:todo, :pending, :done]}
           }}
        )

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "content" => %{"type" => "string"},
                 "state" => %{
                   "type" => "string",
                   "enum" => ["todo", "pending", "done"]
                 }
               },
               "required" => ["content", "state"]
             }
    end

    test "handles nested map with single property" do
      result = PromptBuilder.format_param_type({:map, %{id: :string}})

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "id" => %{"type" => "string"}
               },
               "required" => ["id"]
             }
    end

    test "converts atom keys to string keys in properties" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             user_name: :string,
             is_active: :boolean
           }}
        )

      assert Map.has_key?(result["properties"], "user_name")
      assert Map.has_key?(result["properties"], "is_active")
      refute Map.has_key?(result["properties"], :user_name)
      refute Map.has_key?(result["properties"], :is_active)
    end

    test "all properties marked as required" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             a: :string,
             b: :integer,
             c: :boolean
           }}
        )

      assert length(result["required"]) == 3
      assert "a" in result["required"]
      assert "b" in result["required"]
      assert "c" in result["required"]
    end
  end

  describe "enhanced format_param_type/1 - recursive nested structures" do
    test "ARC_TYPE_09: handles {:list, {:map, %{...}}} recursively" do
      result =
        PromptBuilder.format_param_type(
          {:list,
           {:map,
            %{
              content: :string,
              state: {:enum, [:todo, :pending, :done]}
            }}}
        )

      assert result == %{
               "type" => "array",
               "items" => %{
                 "type" => "object",
                 "properties" => %{
                   "content" => %{"type" => "string"},
                   "state" => %{
                     "type" => "string",
                     "enum" => ["todo", "pending", "done"]
                   }
                 },
                 "required" => ["content", "state"]
               }
             }
    end

    test "handles deeply nested map within map" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             user:
               {:map,
                %{
                  name: :string,
                  role: {:enum, [:admin, :user]}
                }}
           }}
        )

      assert result == %{
               "type" => "object",
               "properties" => %{
                 "user" => %{
                   "type" => "object",
                   "properties" => %{
                     "name" => %{"type" => "string"},
                     "role" => %{
                       "type" => "string",
                       "enum" => ["admin", "user"]
                     }
                   },
                   "required" => ["name", "role"]
                 }
               },
               "required" => ["user"]
             }
    end

    test "handles list of lists" do
      result = PromptBuilder.format_param_type({:list, {:list, :string}})

      assert result == %{
               "type" => "array",
               "items" => %{
                 "type" => "array",
                 "items" => %{"type" => "string"}
               }
             }
    end

    test "handles complex nested structure with multiple levels" do
      result =
        PromptBuilder.format_param_type(
          {:map,
           %{
             items:
               {:list,
                {:map,
                 %{
                   id: :integer,
                   tags: {:list, :string}
                 }}}
           }}
        )

      assert result["properties"]["items"]["type"] == "array"
      assert result["properties"]["items"]["items"]["type"] == "object"
      assert result["properties"]["items"]["items"]["properties"]["id"] == %{"type" => "integer"}

      assert result["properties"]["items"]["items"]["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end
  end

  describe "enhanced format_param_type/1 - error handling" do
    test "ARC_TYPE_10: unknown type raises FunctionClauseError" do
      # Should crash with pattern match error (fail fast)
      # Use apply/3 to avoid compile-time type warnings
      assert_raise FunctionClauseError, fn ->
        apply(PromptBuilder, :format_param_type, [:unknown_type])
      end
    end

    test "invalid nested structure raises error" do
      # Use apply/3 to avoid compile-time type warnings
      assert_raise FunctionClauseError, fn ->
        apply(PromptBuilder, :format_param_type, [{:invalid, :structure}])
      end
    end

    test "nil type raises error" do
      # Use apply/3 to avoid compile-time type warnings
      assert_raise FunctionClauseError, fn ->
        apply(PromptBuilder, :format_param_type, [nil])
      end
    end
  end

  describe "TODO action JSON schema generation" do
    test "ARC_TODO_01: action_to_json_schema(:todo) has detailed nested object schema" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      items_spec = json_schema["params"]["properties"]["items"]

      assert items_spec["type"] == "array"
      assert items_spec["items"]["type"] == "object"
      assert is_map(items_spec["items"]["properties"])
      assert is_list(items_spec["items"]["required"])
    end

    test "ARC_TODO_02: TODO schema includes 'content' property with type 'string'" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      item_properties = json_schema["params"]["properties"]["items"]["items"]["properties"]

      assert Map.has_key?(item_properties, "content")
      assert item_properties["content"] == %{"type" => "string"}
    end

    test "ARC_TODO_03: TODO schema includes 'state' property with enum" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      item_properties = json_schema["params"]["properties"]["items"]["items"]["properties"]

      assert Map.has_key?(item_properties, "state")
      assert item_properties["state"]["type"] == "string"
      assert item_properties["state"]["enum"] == ["todo", "pending", "done"]
    end

    test "ARC_TODO_04: TODO schema marks 'content' and 'state' as required" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      required_fields = json_schema["params"]["properties"]["items"]["items"]["required"]

      assert "content" in required_fields
      assert "state" in required_fields
      assert length(required_fields) == 2
    end

    test "ARC_TODO_05: TODO schema prevents field name invention" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      item_properties = json_schema["params"]["properties"]["items"]["items"]["properties"]

      # Should have ONLY content and state, no other fields
      assert Map.keys(item_properties) |> Enum.sort() == ["content", "state"]

      # Should NOT have fields like "task", "description", "details", etc.
      refute Map.has_key?(item_properties, "task")
      refute Map.has_key?(item_properties, "description")
      refute Map.has_key?(item_properties, "details")
      # It's "state", not "status"
      refute Map.has_key?(item_properties, "status")
    end

    test "TODO action still has wait parameter required" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      assert "wait" in json_schema["required"]
      assert Map.has_key?(json_schema, "wait")
    end

    test "TODO params marked as required" do
      json_schema = PromptBuilder.action_to_json_schema(:todo)

      assert "items" in json_schema["params"]["required"]
    end
  end

  describe "backward compatibility" do
    test "generic :map still returns simple object type" do
      # call_api headers field uses generic :map
      json_schema = PromptBuilder.action_to_json_schema(:call_api)

      headers_spec = json_schema["params"]["properties"]["headers"]

      # Should be simple object with optional description, not detailed structure
      assert headers_spec["type"] == "object"
      refute Map.has_key?(headers_spec, "properties")
      refute Map.has_key?(headers_spec, "required")
    end

    test "existing enum types still work" do
      # call_api has api_type as enum (REST/GraphQL/JSON-RPC protocol selection)
      json_schema = PromptBuilder.action_to_json_schema(:call_api)

      api_type_spec = json_schema["params"]["properties"]["api_type"]

      assert api_type_spec["type"] == "string"
      assert api_type_spec["enum"] == ["rest", "graphql", "jsonrpc"]
    end

    test "all non-TODO actions unchanged" do
      non_todo_actions = Schema.list_actions() -- [:todo]

      for action <- non_todo_actions do
        # Should not crash
        json_schema = PromptBuilder.action_to_json_schema(action)
        assert is_map(json_schema)
        assert json_schema["action"] == Atom.to_string(action)
      end
    end
  end

  describe "system prompt includes enhanced TODO structure" do
    test "system prompt contains TODO action with detailed schema" do
      prompt = PromptBuilder.build_system_prompt()

      # Should mention todo action
      assert prompt =~ "todo"

      # Should mention the required fields
      assert prompt =~ "content"
      assert prompt =~ "state"

      # Should mention the enum values
      assert prompt =~ "pending"
      assert prompt =~ "done"
    end

    test "system prompt educates about TODO item structure" do
      prompt = PromptBuilder.build_system_prompt()

      # Look for structure explanation
      assert prompt =~ ~r/[Ii]tems/

      # Should explain this is an array of objects
      assert prompt =~ ~r/(array|list)/
      assert prompt =~ "object"
    end
  end

  describe "type conversion completeness" do
    test "handles all types from ACTION_Schema" do
      # Test a sampling of types used in actual schemas
      test_cases = [
        {:string, "string"},
        {:integer, "integer"},
        {:number, "number"},
        {:boolean, "boolean"},
        {:atom, "string"},
        {:map, "object"},
        {{:list, :string}, %{"type" => "array", "items" => %{"type" => "string"}}},
        {{:enum, [:a, :b]}, %{"type" => "string", "enum" => ["a", "b"]}},
        {{:map, %{x: :string}},
         %{
           "type" => "object",
           "properties" => %{"x" => %{"type" => "string"}},
           "required" => ["x"]
         }}
      ]

      for {input, expected} <- test_cases do
        result = PromptBuilder.format_param_type(input)
        assert result == expected, "Failed for input #{inspect(input)}"
      end
    end

    test "recursive processing maintains correctness at all levels" do
      # Complex nested structure
      complex_type =
        {:list,
         {:map,
          %{
            id: :integer,
            metadata:
              {:map,
               %{
                 created_at: :string,
                 tags: {:list, :string},
                 status: {:enum, [:draft, :published]}
               }}
          }}}

      result = PromptBuilder.format_param_type(complex_type)

      # Verify structure at each level
      assert result["type"] == "array"
      assert result["items"]["type"] == "object"
      assert result["items"]["properties"]["id"] == %{"type" => "integer"}

      metadata = result["items"]["properties"]["metadata"]
      assert metadata["type"] == "object"
      assert metadata["properties"]["created_at"] == %{"type" => "string"}
      assert metadata["properties"]["tags"]["type"] == "array"
      assert metadata["properties"]["status"]["enum"] == ["draft", "published"]
    end
  end

  describe "property-based characteristics" do
    test "all enum values are converted to strings" do
      enums = [
        {:enum, [:a, :b, :c]},
        {:enum, [:get, :post]},
        {:enum, [:todo, :pending, :done]}
      ]

      for enum_type <- enums do
        result = PromptBuilder.format_param_type(enum_type)
        assert Enum.all?(result["enum"], &is_binary/1)
      end
    end

    test "all nested map property keys become strings" do
      nested_maps = [
        {:map, %{name: :string}},
        {:map, %{user_id: :integer, is_active: :boolean}},
        {:map, %{deeply_nested_key: {:map, %{inner: :string}}}}
      ]

      for map_type <- nested_maps do
        result = PromptBuilder.format_param_type(map_type)
        assert Enum.all?(Map.keys(result["properties"]), &is_binary/1)
      end
    end

    test "required arrays are always sorted" do
      # This ensures consistent ordering
      map_type = {:map, %{z: :string, a: :integer, m: :boolean}}
      result = PromptBuilder.format_param_type(map_type)

      assert result["required"] == ["a", "m", "z"]
    end
  end
end
