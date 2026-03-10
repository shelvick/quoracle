defmodule Quoracle.Groves.SchemaValidatorTest do
  @moduledoc """
  Unit tests for GROVE_SchemaValidator packet 1.

  ARC Criteria: R1-R21 from TEST_GroveSchemaValidator (packet 1)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Groves.SchemaValidator

  @moduletag :feat_grove_system
  @moduletag :packet_1

  setup do
    base_name = "test_schema_validator_groves/#{System.unique_integer([:positive])}"
    grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])
    workspace = Path.join([System.tmp_dir!(), base_name, "workspace"])
    schemas_dir = Path.join([System.tmp_dir!(), base_name, "grove", "schemas"])

    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "schemas"]))
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "workspace"]))

    valid_schema =
      Jason.encode!(%{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["name", "status"],
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1},
          "status" => %{"type" => "string", "enum" => ["active", "paused", "archived"]},
          "count" => %{"type" => "integer"}
        },
        "additionalProperties" => false
      })

    schema_path =
      Path.join([System.tmp_dir!(), base_name, "grove", "schemas", "test.schema.json"])

    File.write!(schema_path, valid_schema)

    schemas = [
      %{
        "name" => "test.json",
        "definition" => "schemas/test.schema.json",
        "validate_on" => "file_write",
        "path_pattern" => "data/*/test.json"
      }
    ]

    on_exit(fn -> File.rm_rf!(Path.join([System.tmp_dir!(), base_name])) end)

    %{
      base_name: base_name,
      grove_path: grove_path,
      workspace: workspace,
      schemas: schemas,
      schemas_dir: schemas_dir
    }
  end

  defp workspace_file(workspace, path) do
    Path.join(workspace, path)
  end

  describe "schema matching helpers" do
    @tag :r1
    test "R1: find_matching_schema matches single-wildcard pattern", %{
      workspace: workspace,
      schemas: schemas
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert %{"name" => "test.json"} =
               SchemaValidator.find_matching_schema(file_path, schemas, workspace)
    end

    @tag :r2
    test "R2: find_matching_schema returns nil for non-matching path", %{
      workspace: workspace,
      schemas: schemas
    } do
      file_path = workspace_file(workspace, "other/item_1/test.json")

      assert is_nil(SchemaValidator.find_matching_schema(file_path, schemas, workspace))
    end

    @tag :r3
    test "R3: find_matching_schema returns most-specific pattern", %{workspace: workspace} do
      schemas = [
        %{
          "name" => "generic",
          "definition" => "schemas/test.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/*/test.json"
        },
        %{
          "name" => "specific",
          "definition" => "schemas/test.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/item_1/test.json"
        }
      ]

      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert %{"name" => "specific"} =
               SchemaValidator.find_matching_schema(file_path, schemas, workspace)
    end

    @tag :r4
    test "R4: path_matches_pattern handles double-star glob" do
      assert SchemaValidator.path_matches_pattern?("a/test.json", "a/**/test.json")
      assert SchemaValidator.path_matches_pattern?("a/b/c/test.json", "a/**/test.json")
      refute SchemaValidator.path_matches_pattern?("a/b/c/other.json", "a/**/test.json")
    end

    @tag :r6
    test "R6: path_matches_pattern matches extension glob" do
      assert SchemaValidator.path_matches_pattern?(
               "opportunities/eval.json",
               "opportunities/*.json"
             )

      refute SchemaValidator.path_matches_pattern?(
               "opportunities/eval.md",
               "opportunities/*.json"
             )

      refute SchemaValidator.path_matches_pattern?(
               "opportunities/deep/eval.json",
               "opportunities/*.json"
             )
    end
  end

  describe "validate_file_write validation" do
    @tag :r5
    test "R5: validate_file_write skips files outside workspace", %{
      base_name: base_name,
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = Path.join([System.tmp_dir!(), base_name, "outside_workspace", "test.json"])

      assert :ok =
               SchemaValidator.validate_file_write(
                 file_path,
                 "not json",
                 schemas,
                 workspace,
                 grove_path
               )
    end

    @tag :r7
    test "R7: validate_file_write returns ok for valid content", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha", "status" => "active", "count" => 3})

      assert :ok =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )
    end

    @tag :r8
    test "R8: validate_file_write rejects content with missing required fields", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha"})

      assert {:error,
              {:schema_validation_failed,
               %{path: ^file_path, schema: "test.json", errors: errors}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "status") end)
    end

    @tag :r9
    test "R9: validate_file_write rejects wrong field types", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha", "status" => "active", "count" => "three"})

      assert {:error,
              {:schema_validation_failed,
               %{path: ^file_path, schema: "test.json", errors: errors}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "integer") end)

      assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "count") end)
    end

    @tag :r10
    test "R10: validate_file_write rejects invalid enum values", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha", "status" => "invalid", "count" => 3})

      assert {:error,
              {:schema_validation_failed,
               %{path: ^file_path, schema: "test.json", errors: errors}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "one of") end)
      assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "status") end)
    end

    @tag :r11
    test "R11: validate_file_write rejects additional properties", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      content =
        Jason.encode!(%{"name" => "alpha", "status" => "active", "count" => 3, "extra" => true})

      assert {:error,
              {:schema_validation_failed,
               %{path: ^file_path, schema: "test.json", errors: errors}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert Enum.any?(errors, fn error ->
               String.contains?(String.downcase(error), "additional")
             end)
    end

    @tag :r12
    test "R12: validate_file_write returns invalid_json for malformed content", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert {:error, {:invalid_json, %{path: ^file_path, reason: reason}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 "{\"name\": \"alpha\",",
                 schemas,
                 workspace,
                 grove_path
               )

      assert is_binary(reason)
      assert reason != ""
    end

    @tag :r13
    test "R13: validate_file_write returns invalid_json for empty content", %{
      workspace: workspace,
      schemas: schemas,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert {:error, {:invalid_json, %{path: ^file_path, reason: reason}}} =
               SchemaValidator.validate_file_write(file_path, "", schemas, workspace, grove_path)

      assert is_binary(reason)
    end
  end

  describe "validate_file_write early returns" do
    @tag :r14
    test "R14: validate_file_write skips when schemas is nil", %{
      workspace: workspace,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert :ok =
               SchemaValidator.validate_file_write(file_path, "{}", nil, workspace, grove_path)
    end

    @tag :r15
    test "R15: validate_file_write skips when schemas is empty list", %{
      workspace: workspace,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      assert :ok = SchemaValidator.validate_file_write(file_path, "{}", [], workspace, grove_path)
    end

    @tag :r16
    test "R16: validate_file_write skips validation when schemas present but no workspace", %{
      schemas: schemas,
      grove_path: grove_path
    } do
      assert :ok =
               SchemaValidator.validate_file_write(
                 Path.join(System.tmp_dir!(), "somewhere/data/item_1/test.json"),
                 "{}",
                 schemas,
                 nil,
                 grove_path
               )
    end

    @tag :r17
    test "R17: validate_file_write skips when validate_on is not file_write", %{
      workspace: workspace,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      schemas = [
        %{
          "name" => "test.json",
          "definition" => "schemas/test.schema.json",
          "validate_on" => "spawn",
          "path_pattern" => "data/*/test.json"
        }
      ]

      assert :ok =
               SchemaValidator.validate_file_write(
                 file_path,
                 "{not valid json}",
                 schemas,
                 workspace,
                 grove_path
               )
    end
  end

  describe "validate security and schema load" do
    @tag :r18
    test "R18: validate_file_write rejects schema definition path traversal", %{
      workspace: workspace,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      schemas = [
        %{
          "name" => "bad.json",
          "definition" => "../outside.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/*/test.json"
        }
      ]

      content = Jason.encode!(%{"name" => "alpha", "status" => "active"})

      assert {:error, {:path_traversal, "../outside.schema.json"}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )
    end

    @tag :r19
    test "R19: validate_file_write rejects schema definition symlink outside grove", %{
      base_name: base_name,
      workspace: workspace,
      grove_path: grove_path
    } do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "outside"]))

      outside_schema_path =
        Path.join([System.tmp_dir!(), base_name, "outside", "outside.schema.json"])

      outside_schema =
        Jason.encode!(%{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "object"
        })

      File.write!(outside_schema_path, outside_schema)

      File.ln_s!(
        Path.join([System.tmp_dir!(), base_name, "outside", "outside.schema.json"]),
        Path.join([System.tmp_dir!(), base_name, "grove", "schemas", "outside_link.schema.json"])
      )

      schemas = [
        %{
          "name" => "linked.json",
          "definition" => "schemas/outside_link.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/*/test.json"
        }
      ]

      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha", "status" => "active"})

      assert {:error, {:symlink_not_allowed, "schemas/outside_link.schema.json"}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )
    end

    @tag :r20
    test "R20: validate_file_write returns schema_load_failed for missing definition", %{
      workspace: workspace,
      grove_path: grove_path
    } do
      file_path = workspace_file(workspace, "data/item_1/test.json")

      schemas = [
        %{
          "name" => "missing.json",
          "definition" => "schemas/missing.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/*/test.json"
        }
      ]

      content = Jason.encode!(%{"name" => "alpha", "status" => "active"})

      assert {:error,
              {:schema_load_failed, %{definition: "schemas/missing.schema.json", reason: reason}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert reason != nil
    end

    @tag :r21
    test "R21: validate_file_write returns schema_load_failed for malformed schema", %{
      base_name: base_name,
      workspace: workspace,
      grove_path: grove_path
    } do
      malformed_schema_path =
        Path.join([System.tmp_dir!(), base_name, "grove", "schemas", "malformed.schema.json"])

      File.write!(malformed_schema_path, "{\"type\": \"object\"")

      schemas = [
        %{
          "name" => "malformed.json",
          "definition" => "schemas/malformed.schema.json",
          "validate_on" => "file_write",
          "path_pattern" => "data/*/test.json"
        }
      ]

      file_path = workspace_file(workspace, "data/item_1/test.json")
      content = Jason.encode!(%{"name" => "alpha", "status" => "active"})

      assert {:error,
              {:schema_load_failed,
               %{definition: "schemas/malformed.schema.json", reason: reason}}} =
               SchemaValidator.validate_file_write(
                 file_path,
                 content,
                 schemas,
                 workspace,
                 grove_path
               )

      assert reason != nil
    end
  end
end
