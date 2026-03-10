defmodule Quoracle.Actions.FileWriteConfinementTest do
  @moduledoc """
  Tests for ACTION_FileWrite filesystem confinement enforcement.

  WorkGroupID: wip-20260302-grove-hard-enforcement
  Packet: 3 (File Confinement)
  ARC: R25-R30 from ACTION_FileWrite v3.0
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.FileWrite

  @moduletag :file_actions
  @moduletag :feat_grove_system
  @moduletag :packet_3

  setup do
    base_name = "file_write_confinement/#{System.unique_integer([:positive])}"

    allowed_dir = Path.join([System.tmp_dir!(), base_name, "allowed"])
    read_only_dir = Path.join([System.tmp_dir!(), base_name, "read_only"])
    blocked_dir = Path.join([System.tmp_dir!(), base_name, "blocked"])
    grove_schemas_dir = Path.join([System.tmp_dir!(), base_name, "grove", "schemas"])
    workspace = Path.join([System.tmp_dir!(), base_name, "workspace"])

    File.mkdir_p!(allowed_dir)
    File.mkdir_p!(read_only_dir)
    File.mkdir_p!(blocked_dir)
    File.mkdir_p!(grove_schemas_dir)
    File.mkdir_p!(workspace)

    schema =
      Jason.encode!(%{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["id", "name"],
        "properties" => %{
          "id" => %{"type" => "string"},
          "name" => %{"type" => "string"}
        },
        "additionalProperties" => false
      })

    schema_path = Path.join(grove_schemas_dir, "item.schema.json")
    File.write!(schema_path, schema)

    schemas = [
      %{
        "name" => "item.json",
        "definition" => "schemas/item.schema.json",
        "validate_on" => "file_write",
        "path_pattern" => "blocked/item.json"
      }
    ]

    confinement = %{
      "agentic-coding" => %{
        "paths" => [Path.join(allowed_dir, "**")],
        "read_only_paths" => [Path.join(read_only_dir, "**")]
      }
    }

    on_exit(fn ->
      File.rm_rf!(Path.join([System.tmp_dir!(), base_name]))
    end)

    {:ok,
     allowed_dir: allowed_dir,
     read_only_dir: read_only_dir,
     blocked_dir: blocked_dir,
     workspace: workspace,
     grove_path: Path.join([System.tmp_dir!(), base_name, "grove"]),
     schemas: schemas,
     confinement: confinement}
  end

  @tag :acceptance
  test "file_write outside confinement returns error", %{
    blocked_dir: blocked_dir,
    confinement: confinement
  } do
    path = Path.join(blocked_dir, "blocked.txt")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:error, {:confinement_violation, %{path: ^path, access_type: :write}}} =
             FileWrite.execute(%{path: path, mode: :write, content: "blocked"}, "agent-1", opts)

    refute File.exists?(path)
  end

  test "file_write within confinement paths succeeds", %{
    allowed_dir: allowed_dir,
    confinement: confinement
  } do
    path = Path.join(allowed_dir, "allowed.txt")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:ok, %{action: "file_write", mode: :write, path: ^path, created: true}} =
             FileWrite.execute(%{path: path, mode: :write, content: "ok"}, "agent-1", opts)

    assert File.read!(path) == "ok"
  end

  test "file_write to read-only path returns confinement error", %{
    read_only_dir: read_only_dir,
    confinement: confinement
  } do
    path = Path.join(read_only_dir, "cannot-write.txt")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:error, {:confinement_violation, %{path: ^path, access_type: :write}}} =
             FileWrite.execute(%{path: path, mode: :write, content: "blocked"}, "agent-1", opts)

    refute File.exists?(path)
  end

  test "edit mode outside confinement blocked before content computation", %{
    blocked_dir: blocked_dir,
    confinement: confinement
  } do
    path = Path.join(blocked_dir, "missing-edit.txt")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:error, {:confinement_violation, %{path: ^path, access_type: :write}}} =
             FileWrite.execute(
               %{path: path, mode: :edit, old_string: "old", new_string: "new"},
               "agent-1",
               opts
             )
  end

  test "confinement checked before schema validation", %{
    workspace: workspace,
    grove_path: grove_path,
    schemas: schemas,
    confinement: confinement
  } do
    blocked_workspace_dir = Path.join(workspace, "blocked")
    blocked_in_workspace = Path.join(blocked_workspace_dir, "item.json")
    File.mkdir_p!(blocked_workspace_dir)

    opts = [
      parent_config: %{
        grove_confinement: confinement,
        skill_name: "agentic-coding",
        grove_schemas: schemas,
        grove_workspace: workspace,
        grove_path: grove_path
      }
    ]

    invalid_content = Jason.encode!(%{"id" => "only-id"})

    assert {:error, {:confinement_violation, %{path: ^blocked_in_workspace, access_type: :write}}} =
             FileWrite.execute(
               %{path: blocked_in_workspace, mode: :write, content: invalid_content},
               "agent-1",
               opts
             )

    refute File.exists?(blocked_in_workspace)
  end

  test "file_write without confinement passes through", %{blocked_dir: blocked_dir} do
    path = Path.join(blocked_dir, "passthrough.txt")

    opts = [parent_config: %{skill_name: "agentic-coding"}]

    assert {:ok, %{action: "file_write", mode: :write, path: ^path, created: true}} =
             FileWrite.execute(
               %{path: path, mode: :write, content: "passthrough"},
               "agent-1",
               opts
             )

    assert File.read!(path) == "passthrough"
  end
end
