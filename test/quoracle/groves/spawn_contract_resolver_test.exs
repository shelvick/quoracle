defmodule Quoracle.Groves.SpawnContractResolverTest do
  @moduledoc """
  Unit tests for GROVE_SpawnContractResolver packet 1.

  ARC Criteria: R42-R63 from TEST_GroveSpawnContracts (packet 1)
  """
  use ExUnit.Case, async: true

  @moduletag :feat_grove_system
  @moduletag :packet_1

  alias Quoracle.Groves.SpawnContractResolver

  setup do
    base_name = "test_spawn_contract_groves/#{System.unique_integer([:positive])}"
    temp_dir = Path.join([System.tmp_dir!(), base_name])

    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name]))

    on_exit(fn -> File.rm_rf!(Path.join([System.tmp_dir!(), base_name])) end)

    %{grove_path: temp_dir, base_name: base_name}
  end

  defp write_constraint_file(base_name, relative_path, content) do
    File.mkdir_p!(Path.dirname(Path.join([System.tmp_dir!(), base_name, relative_path])))
    File.write!(Path.join([System.tmp_dir!(), base_name, relative_path]), content)
    Path.join([System.tmp_dir!(), base_name, relative_path])
  end

  describe "find_edge/3" do
    @tag :r42
    test "R42: find_edge matches parent and child skill names" do
      topology = %{
        "edges" => [
          %{"parent" => "factory-oversight", "child" => "venture-management"}
        ]
      }

      assert %{"parent" => "factory-oversight", "child" => "venture-management"} =
               SpawnContractResolver.find_edge(
                 topology,
                 ["factory-oversight"],
                 ["venture-management"]
               )
    end

    @tag :r43
    test "R43: find_edge returns nil when no edge matches" do
      topology = %{"edges" => [%{"parent" => "a", "child" => "b"}]}

      assert is_nil(SpawnContractResolver.find_edge(topology, ["x"], ["y"]))
    end

    @tag :r44
    test "R44: find_edge returns first match when multiple edges match" do
      first = %{"parent" => "factory", "child" => "venture", "name" => "first"}
      second = %{"parent" => "factory", "child" => "venture", "name" => "second"}
      topology = %{"edges" => [first, second]}

      assert ^first = SpawnContractResolver.find_edge(topology, ["factory"], ["venture"])
    end

    @tag :r45
    test "R45: find_edge returns nil for empty child skills" do
      topology = %{"edges" => [%{"parent" => "factory", "child" => "venture"}]}

      assert is_nil(SpawnContractResolver.find_edge(topology, ["factory"], []))
    end

    @tag :r46
    test "R46: find_edge returns nil for nil topology" do
      assert is_nil(SpawnContractResolver.find_edge(nil, ["factory"], ["venture"]))
    end

    @tag :r47
    test "R47: find_edge matches when parent has multiple skills" do
      topology = %{"edges" => [%{"parent" => "factory", "child" => "venture"}]}

      assert %{"parent" => "factory", "child" => "venture"} =
               SpawnContractResolver.find_edge(
                 topology,
                 ["other", "factory", "observer"],
                 ["venture"]
               )
    end

    @tag :r48
    test "R48: find_edge matches when child has multiple skills" do
      topology = %{"edges" => [%{"parent" => "factory", "child" => "venture"}]}

      assert %{"parent" => "factory", "child" => "venture"} =
               SpawnContractResolver.find_edge(
                 topology,
                 ["factory"],
                 ["other", "venture", "observer"]
               )
    end
  end

  describe "resolve_auto_inject/3" do
    @tag :r49
    test "R49: resolve_auto_inject unions skills from edge and LLM params", %{
      grove_path: grove_path
    } do
      edge = %{"auto_inject" => %{"skills" => ["venture-management"]}}
      existing_params = %{skills: ["risk-analysis"]}

      assert {:ok, result} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, existing_params)

      assert result.skills == ["venture-management", "risk-analysis"]
    end

    @tag :r50
    test "R50: resolve_auto_inject deduplicates overlapping skills", %{grove_path: grove_path} do
      edge = %{"auto_inject" => %{"skills" => ["venture-management", "risk-analysis"]}}
      existing_params = %{skills: ["risk-analysis"]}

      assert {:ok, result} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, existing_params)

      assert result.skills == ["venture-management", "risk-analysis"]
    end

    @tag :r51
    test "R51: resolve_auto_inject uses LLM profile over edge profile", %{grove_path: grove_path} do
      edge = %{"auto_inject" => %{"profile" => "quality"}}
      existing_params = %{profile: "speed"}

      assert {:ok, result} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, existing_params)

      assert result.profile == "speed"
    end

    @tag :r52
    test "R52: resolve_auto_inject uses edge profile when LLM omits profile", %{
      grove_path: grove_path
    } do
      edge = %{"auto_inject" => %{"profile" => "quality"}}
      existing_params = %{}

      assert {:ok, result} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, existing_params)

      assert result.profile == "quality"
    end

    @tag :r53
    test "R53: resolve_auto_inject reads constraint file content", %{
      grove_path: grove_path,
      base_name: base_name
    } do
      write_constraint_file(
        base_name,
        "governance/filesystem-confinement.md",
        "Constraint policy"
      )

      edge = %{"auto_inject" => %{"constraints" => "governance/filesystem-confinement.md"}}

      assert {:ok, result} = SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
      assert result.constraints == "Constraint policy"
    end

    @tag :r54
    test "R54: resolve_auto_inject extracts section from constraint file", %{
      grove_path: grove_path,
      base_name: base_name
    } do
      write_constraint_file(
        base_name,
        "governance/filesystem-confinement.md",
        """
        ## venture-management
        Venture policy text.

        ## finance
        Finance policy text.
        """
      )

      edge =
        %{
          "auto_inject" => %{
            "constraints" => "governance/filesystem-confinement.md#venture-management"
          }
        }

      assert {:ok, result} = SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
      assert result.constraints =~ "## venture-management"
      assert result.constraints =~ "Venture policy text."
      refute result.constraints =~ "## finance"
    end

    @tag :r55
    test "R55: resolve_auto_inject falls back to full file when section not found", %{
      grove_path: grove_path,
      base_name: base_name
    } do
      write_constraint_file(
        base_name,
        "governance/filesystem-confinement.md",
        """
        ## venture-management
        Venture policy text.

        ## finance
        Finance policy text.
        """
      )

      edge =
        %{
          "auto_inject" => %{
            "constraints" => "governance/filesystem-confinement.md#missing-section"
          }
        }

      assert {:ok, result} = SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
      assert result.constraints =~ "## venture-management"
      assert result.constraints =~ "## finance"
    end

    @tag :r56
    test "R56: resolve_auto_inject returns nil constraints when file missing", %{
      grove_path: grove_path
    } do
      edge = %{"auto_inject" => %{"constraints" => "governance/missing.md"}}

      assert {:ok, result} = SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
      assert is_nil(result.constraints)
    end

    @tag :r57
    test "R57: resolve_auto_inject concatenates topology and LLM constraints", %{
      grove_path: grove_path,
      base_name: base_name
    } do
      write_constraint_file(
        base_name,
        "governance/filesystem-confinement.md",
        "Topology constraints"
      )

      edge = %{"auto_inject" => %{"constraints" => "governance/filesystem-confinement.md"}}
      existing_params = %{downstream_constraints: "LLM constraints"}

      assert {:ok, result} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, existing_params)

      assert result.constraints == "Topology constraints\n\nLLM constraints"
    end

    @tag :r58
    test "R58: resolve_auto_inject rejects constraint path traversal", %{grove_path: grove_path} do
      edge = %{"auto_inject" => %{"constraints" => "../secret.md"}}

      assert {:error, {:path_traversal, "../secret.md"}} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
    end

    @tag :r59
    test "R59: resolve_auto_inject rejects constraint symlink outside grove", %{
      grove_path: grove_path,
      base_name: base_name
    } do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "governance"]))

      # Create target file truly OUTSIDE the grove directory
      outside_dir =
        Path.join([System.tmp_dir!(), "outside_grove_#{System.unique_integer([:positive])}"])

      File.mkdir_p!(outside_dir)
      outside_file = Path.join(outside_dir, "secret.md")
      File.write!(outside_file, "outside")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      symlink_path = Path.join([System.tmp_dir!(), base_name, "governance", "constraint.md"])
      File.ln_s!(outside_file, symlink_path)

      edge = %{"auto_inject" => %{"constraints" => "governance/constraint.md"}}

      assert {:error, {:symlink_not_allowed, "governance/constraint.md"}} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{})
    end

    @tag :r63
    test "R63: resolve_auto_inject returns defaults when edge has no auto_inject", %{
      grove_path: grove_path
    } do
      edge = %{"parent" => "factory", "child" => "venture"}

      assert {:ok, %{skills: [], profile: nil, constraints: nil}} =
               SpawnContractResolver.resolve_auto_inject(edge, grove_path, %{skills: ["ignored"]})
    end
  end

  describe "extract_section/2" do
    @tag :r60
    test "R60: extract_section returns content between matching headings" do
      content = """
      ## venture-management
      Venture policy text.

      ## finance
      Finance policy text.
      """

      assert {:ok, section} = SpawnContractResolver.extract_section(content, "venture-management")
      assert section =~ "## venture-management"
      assert section =~ "Venture policy text."
      refute section =~ "## finance"
    end

    @tag :r61
    test "R61: extract_section matches headings case-insensitively" do
      content = """
      ## Venture-Management
      Venture policy text.

      ## Finance
      Finance policy text.
      """

      assert {:ok, section} = SpawnContractResolver.extract_section(content, "venture-management")
      assert section =~ "## Venture-Management"
      assert section =~ "Venture policy text."
    end

    @tag :r62
    test "R62: extract_section returns not_found for missing section" do
      content = """
      ## venture-management
      Venture policy text.
      """

      assert :not_found = SpawnContractResolver.extract_section(content, "finance")
    end
  end
end
