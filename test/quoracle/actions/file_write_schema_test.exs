defmodule Quoracle.Actions.FileWriteSchemaTest do
  @moduledoc """
  Integration tests for schema validation in ACTION_FileWrite.

  WorkGroupID: wip-20260301-grove-schema-validation
  Packet: 2 (integration)
  ARC: R1-R9 from TEST_GroveSchemaValidation_Integration
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.FileWrite

  @moduletag :file_actions
  @moduletag :feat_grove_system
  @moduletag :packet_2

  setup do
    base_name = "file_write_schema_test/#{System.unique_integer([:positive])}"

    base = Path.join([System.tmp_dir!(), base_name])
    grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])
    workspace = Path.join([System.tmp_dir!(), base_name, "workspace"])
    data_dir = Path.join([System.tmp_dir!(), base_name, "workspace", "data/item_1"])

    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "schemas"]))
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "workspace", "data/item_1"]))

    schema_content =
      Jason.encode!(%{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["id", "name"],
        "properties" => %{
          "id" => %{"type" => "string"},
          "name" => %{"type" => "string"},
          "value" => %{"type" => "integer"}
        },
        "additionalProperties" => false
      })

    schema_path =
      Path.join([System.tmp_dir!(), base_name, "grove", "schemas", "item.schema.json"])

    File.write!(schema_path, schema_content)

    schemas = [
      %{
        "name" => "item.json",
        "definition" => "schemas/item.schema.json",
        "validate_on" => "file_write",
        "path_pattern" => "data/*/item.json"
      }
    ]

    parent_config = %{
      grove_schemas: schemas,
      grove_workspace: workspace,
      grove_path: grove_path
    }

    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      base_name: base_name,
      workspace: workspace,
      data_dir: data_dir,
      opts: [parent_config: parent_config]
    }
  end

  @tag :acceptance
  test "file_write rejected when content violates grove schema", %{data_dir: data_dir, opts: opts} do
    path = Path.join(data_dir, "item.json")
    invalid_content = Jason.encode!(%{"id" => "item_1"})

    assert {:error,
            {:schema_validation_failed, %{path: ^path, schema: "item.json", errors: errors}}} =
             FileWrite.execute(
               %{path: path, mode: :write, content: invalid_content},
               "agent-1",
               opts
             )

    assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "name") end)
    refute File.exists?(path)
    refute Enum.empty?(errors)
  end

  test "write mode creates file when content passes schema validation", %{
    data_dir: data_dir,
    opts: opts
  } do
    path = Path.join(data_dir, "item.json")
    valid_content = Jason.encode!(%{"id" => "item_1", "name" => "Widget", "value" => 42})

    assert {:ok, %{action: "file_write", mode: :write, created: true}} =
             FileWrite.execute(
               %{path: path, mode: :write, content: valid_content},
               "agent-1",
               opts
             )

    assert File.read!(path) == valid_content
  end

  test "write mode rejects file when content fails schema validation", %{
    data_dir: data_dir,
    opts: opts
  } do
    path = Path.join(data_dir, "item.json")
    invalid_content = Jason.encode!(%{"id" => "item_1"})

    assert {:error,
            {:schema_validation_failed, %{path: ^path, schema: "item.json", errors: errors}}} =
             FileWrite.execute(
               %{path: path, mode: :write, content: invalid_content},
               "agent-1",
               opts
             )

    assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "name") end)
    refute File.exists?(path)
  end

  test "write mode rejects non-JSON content for schema-matched path", %{
    data_dir: data_dir,
    opts: opts
  } do
    path = Path.join(data_dir, "item.json")

    assert {:error, {:invalid_json, %{path: ^path, reason: reason}}} =
             FileWrite.execute(%{path: path, mode: :write, content: "not-json"}, "agent-1", opts)

    assert is_binary(reason)
    refute File.exists?(path)
  end

  test "edit mode succeeds when edited content passes schema validation", %{
    data_dir: data_dir,
    opts: opts
  } do
    path = Path.join(data_dir, "item.json")
    File.write!(path, Jason.encode!(%{"id" => "item_1", "name" => "Original", "value" => 7}))

    assert {:ok, %{action: "file_write", mode: :edit, replacements: 1}} =
             FileWrite.execute(
               %{path: path, mode: :edit, old_string: "Original", new_string: "Updated"},
               "agent-1",
               opts
             )

    assert File.read!(path) =~ "Updated"
  end

  test "edit mode rejects edit that would violate schema", %{data_dir: data_dir, opts: opts} do
    path = Path.join(data_dir, "item.json")

    original = Jason.encode!(%{"id" => "item_1", "name" => "Original", "value" => 7})
    File.write!(path, original)

    assert {:error,
            {:schema_validation_failed, %{path: ^path, schema: "item.json", errors: errors}}} =
             FileWrite.execute(
               %{
                 path: path,
                 mode: :edit,
                 old_string: "\"name\":\"Original\"",
                 new_string: "\"title\":\"Original\""
               },
               "agent-1",
               opts
             )

    assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "name") end)
    assert File.read!(path) == original
  end

  test "file_write without grove schemas proceeds normally", %{
    data_dir: data_dir,
    workspace: workspace
  } do
    path = Path.join(data_dir, "item.json")
    content = "not-json"

    opts = [parent_config: %{grove_workspace: workspace}]

    assert {:ok, %{action: "file_write", mode: :write, created: true}} =
             FileWrite.execute(%{path: path, mode: :write, content: content}, "agent-1", opts)

    assert File.read!(path) == content
  end

  test "file_write to non-matching path proceeds without validation", %{
    workspace: workspace,
    opts: opts
  } do
    path = Path.join(workspace, "data/item_1/other.json")
    content = "not-json"

    assert {:ok, %{action: "file_write", mode: :write, created: true}} =
             FileWrite.execute(%{path: path, mode: :write, content: content}, "agent-1", opts)

    assert File.read!(path) == content
  end

  test "file_write outside workspace proceeds without validation", %{base: base, opts: opts} do
    path = Path.join([base, "outside", "item.json"])
    content = "not-json"

    assert {:ok, %{action: "file_write", mode: :write, created: true}} =
             FileWrite.execute(%{path: path, mode: :write, content: content}, "agent-1", opts)

    assert File.read!(path) == content
  end

  test "schema validation errors include field-level details", %{data_dir: data_dir, opts: opts} do
    path = Path.join(data_dir, "item.json")

    invalid_content = Jason.encode!(%{"id" => 123, "name" => "Widget", "extra" => true})

    assert {:error,
            {:schema_validation_failed, %{path: ^path, schema: "item.json", errors: errors}}} =
             FileWrite.execute(
               %{path: path, mode: :write, content: invalid_content},
               "agent-1",
               opts
             )

    assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "id") end)
    assert Enum.any?(errors, fn error -> String.contains?(String.downcase(error), "string") end)

    assert Enum.any?(errors, fn error ->
             String.contains?(String.downcase(error), "additional")
           end)

    refute File.exists?(path)
  end
end
