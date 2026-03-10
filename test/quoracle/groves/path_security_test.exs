defmodule Quoracle.Groves.PathSecurityTest do
  @moduledoc """
  Unit tests for GROVE_PathSecurity packet 1.

  ARC Criteria: R31-R41 from TEST_GroveSpawnContracts (packet 1)
  """
  use ExUnit.Case, async: true

  @moduletag :feat_grove_system
  @moduletag :packet_1

  alias Quoracle.Groves.PathSecurity

  setup do
    base_name = "test_path_security_groves/#{System.unique_integer([:positive])}"
    temp_dir = Path.join([System.tmp_dir!(), base_name])

    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name]))

    on_exit(fn -> File.rm_rf!(Path.join([System.tmp_dir!(), base_name])) end)

    %{grove_path: temp_dir, base_name: base_name}
  end

  describe "path_traversal?/1" do
    @tag :r31
    test "R31: path_traversal? detects .. components" do
      assert PathSecurity.path_traversal?("../secrets.md")
      assert PathSecurity.path_traversal?("governance/../../secrets.md")
    end

    @tag :r32
    test "R32: path_traversal? detects absolute paths" do
      assert PathSecurity.path_traversal?("/etc/passwd")
    end

    @tag :r33
    test "R33: path_traversal? accepts valid relative paths" do
      refute PathSecurity.path_traversal?("governance/filesystem-confinement.md")
      refute PathSecurity.path_traversal?("constraints/policy.md")
    end
  end

  describe "symlink_outside_grove?/2" do
    @tag :r34
    test "R34: symlink_outside_grove? detects symlink escaping grove", %{base_name: base_name} do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "governance"]))
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "outside"]))

      outside_secret_path = Path.join([System.tmp_dir!(), base_name, "outside", "secret.md"])
      File.write!(outside_secret_path, "outside")

      symlink_path = Path.join([System.tmp_dir!(), base_name, "grove", "governance", "policy.md"])

      File.ln_s!(
        outside_secret_path,
        symlink_path
      )

      grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])
      assert PathSecurity.symlink_outside_grove?(symlink_path, grove_path)
    end

    @tag :r35
    test "R35: symlink_outside_grove? allows symlink within grove", %{base_name: base_name} do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "governance"]))
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "constraints"]))

      in_grove_policy_path =
        Path.join([System.tmp_dir!(), base_name, "grove", "constraints", "policy.md"])

      File.write!(in_grove_policy_path, "inside")

      symlink_path = Path.join([System.tmp_dir!(), base_name, "grove", "governance", "policy.md"])

      File.ln_s!(
        in_grove_policy_path,
        symlink_path
      )

      grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])
      refute PathSecurity.symlink_outside_grove?(symlink_path, grove_path)
    end

    @tag :r36
    test "R36: symlink_outside_grove? detects intermediate directory symlink escape", %{
      base_name: base_name
    } do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "outside"]))

      outside_policy_path = Path.join([System.tmp_dir!(), base_name, "outside", "policy.md"])
      File.write!(outside_policy_path, "outside through intermediate")

      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove"]))

      File.ln_s!(
        Path.join([System.tmp_dir!(), base_name, "outside"]),
        Path.join([System.tmp_dir!(), base_name, "grove", "governance"])
      )

      full_path = Path.join([System.tmp_dir!(), base_name, "grove", "governance", "policy.md"])
      grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])

      assert PathSecurity.symlink_outside_grove?(full_path, grove_path)
    end

    @tag :r37
    test "R37: symlink_outside_grove? allows regular files within grove", %{base_name: base_name} do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "grove", "governance"]))

      full_path = Path.join([System.tmp_dir!(), base_name, "grove", "governance", "policy.md"])

      File.write!(full_path, "safe")

      grove_path = Path.join([System.tmp_dir!(), base_name, "grove"])
      refute PathSecurity.symlink_outside_grove?(full_path, grove_path)
    end
  end

  describe "safe_read_file/3" do
    @tag :r38
    test "R38: safe_read_file reads valid file within grove", %{base_name: base_name} do
      grove_path = Path.join([System.tmp_dir!(), base_name])

      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "governance"]))

      policy_path = Path.join([System.tmp_dir!(), base_name, "governance", "policy.md"])
      File.write!(policy_path, "  policy body\n")

      assert {:ok, "policy body"} =
               PathSecurity.safe_read_file(
                 "governance/policy.md",
                 "governance/policy.md",
                 grove_path
               )
    end

    @tag :r39
    test "R39: safe_read_file rejects path traversal", %{grove_path: grove_path} do
      assert {:error, {:path_traversal, "../secrets.md"}} =
               PathSecurity.safe_read_file("secrets.md", "../secrets.md", grove_path)
    end

    @tag :r40
    test "R40: safe_read_file returns error for missing file", %{grove_path: grove_path} do
      assert {:error, {:file_not_found, full_path}} =
               PathSecurity.safe_read_file(
                 "governance/missing.md",
                 "governance/missing.md",
                 grove_path
               )

      assert full_path =~ "governance/missing.md"
    end

    @tag :r41
    test "R41: safe_read_file rejects nil source path", %{grove_path: grove_path} do
      assert {:error, {:path_traversal, ""}} =
               PathSecurity.safe_read_file(nil, nil, grove_path)
    end
  end
end
