defmodule Quoracle.Actions.FileReadConfinementTest do
  @moduledoc """
  Tests for ACTION_FileRead filesystem confinement enforcement.

  WorkGroupID: wip-20260302-grove-hard-enforcement
  Packet: 3 (File Confinement)
  ARC: R16-R20 from TEST_ACTION_FileRead v2.0
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Actions.FileRead

  @moduletag :file_actions
  @moduletag :feat_grove_system
  @moduletag :packet_3

  setup do
    base_name = "file_read_confinement/#{System.unique_integer([:positive])}"

    allowed_dir = Path.join([System.tmp_dir!(), base_name, "allowed"])
    read_only_dir = Path.join([System.tmp_dir!(), base_name, "read_only"])
    outside_dir = Path.join([System.tmp_dir!(), base_name, "outside"])

    File.mkdir_p!(allowed_dir)
    File.mkdir_p!(read_only_dir)
    File.mkdir_p!(outside_dir)

    on_exit(fn ->
      File.rm_rf!(Path.join([System.tmp_dir!(), base_name]))
    end)

    confinement = %{
      "agentic-coding" => %{
        "paths" => [Path.join(allowed_dir, "**")],
        "read_only_paths" => [Path.join(read_only_dir, "**")]
      }
    }

    {:ok,
     allowed_dir: allowed_dir,
     read_only_dir: read_only_dir,
     outside_dir: outside_dir,
     confinement: confinement}
  end

  test "file_read outside confinement returns error", %{
    outside_dir: outside_dir,
    confinement: confinement
  } do
    path = Path.join(outside_dir, "blocked.txt")
    File.write!(path, "blocked")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:error, {:confinement_violation, %{path: ^path, access_type: :read}}} =
             FileRead.execute(%{path: path}, "agent-1", opts)
  end

  test "file_read within write-capable paths succeeds", %{
    allowed_dir: allowed_dir,
    confinement: confinement
  } do
    path = Path.join(allowed_dir, "allowed.txt")
    File.write!(path, "line one")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:ok, %{action: "file_read", path: ^path, content: content}} =
             FileRead.execute(%{path: path}, "agent-1", opts)

    assert content =~ "1\tline one"
  end

  test "file_read within read-only paths succeeds", %{
    read_only_dir: read_only_dir,
    confinement: confinement
  } do
    path = Path.join(read_only_dir, "read_only.txt")
    File.write!(path, "read only")

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    assert {:ok, %{action: "file_read", path: ^path, content: content}} =
             FileRead.execute(%{path: path}, "agent-1", opts)

    assert content =~ "1\tread only"
  end

  test "file_read with strict confinement blocks unlisted skill", %{outside_dir: outside_dir} do
    path = Path.join(outside_dir, "strict-blocked.txt")
    File.write!(path, "strict blocked")

    confinement = %{
      "different-skill" => %{
        "paths" => [Path.join(outside_dir, "**")],
        "read_only_paths" => []
      }
    }

    opts = [
      parent_config: %{
        grove_confinement: confinement,
        grove_confinement_mode: "strict",
        skill_name: "agentic-coding"
      }
    ]

    assert {:error, {:confinement_violation, %{path: ^path, access_type: :read} = details}} =
             FileRead.execute(%{path: path}, "agent-1", opts)

    assert details.skill == "agentic-coding"
  end

  test "file_read without confinement passes through", %{outside_dir: outside_dir} do
    path = Path.join(outside_dir, "passthrough.txt")
    File.write!(path, "passthrough")

    opts = [parent_config: %{skill_name: "agentic-coding"}]

    assert {:ok, %{action: "file_read", path: ^path, content: content}} =
             FileRead.execute(%{path: path}, "agent-1", opts)

    assert content =~ "1\tpassthrough"
  end

  test "unlisted skill reads with warning", %{outside_dir: outside_dir} do
    path = Path.join(outside_dir, "unlisted.txt")
    File.write!(path, "unlisted")

    confinement = %{
      "different-skill" => %{
        "paths" => [Path.join(outside_dir, "**")],
        "read_only_paths" => []
      }
    }

    opts = [parent_config: %{grove_confinement: confinement, skill_name: "agentic-coding"}]

    log =
      capture_log(fn ->
        assert {:ok, %{action: "file_read", path: ^path, content: content}} =
                 FileRead.execute(%{path: path}, "agent-1", opts)

        assert content =~ "1\tunlisted"
      end)

    assert log =~ "No confinement entry for skill"
  end
end
