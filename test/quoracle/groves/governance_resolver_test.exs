defmodule Quoracle.Groves.GovernanceResolverTest do
  @moduledoc """
  Unit tests for GROVE_GovernanceResolver packet 1.

  ARC Criteria: R1-R18 from TEST_GroveGovernance (packet 1)
  """
  use ExUnit.Case, async: true

  @moduletag :feat_grove_system
  @moduletag :packet_1

  alias Quoracle.Groves.GovernanceResolver
  alias Quoracle.Groves.Loader

  setup do
    base_name = "test_governance_groves/#{System.unique_integer([:positive])}"
    temp_dir = Path.join([System.tmp_dir!(), base_name])

    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name]))

    on_exit(fn -> File.rm_rf!(Path.join([System.tmp_dir!(), base_name])) end)

    %{groves_path: temp_dir, base_name: base_name}
  end

  defp create_governance_grove(base_name, name, opts \\ []) do
    grove_dir = Path.join([System.tmp_dir!(), base_name, name])
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))

    files = Keyword.get(opts, :files, %{})

    for {filename, content} <- files do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name, Path.dirname(filename)]))
      File.write!(Path.join([System.tmp_dir!(), base_name, name, filename]), content)
    end

    governance_yaml = Keyword.get(opts, :governance_yaml)

    grove_md_content =
      if is_binary(governance_yaml) do
        """
        ---
        name: #{name}
        description: Test grove
        version: "1.0"
        governance:
        #{governance_yaml}
        ---

        # #{name}
        """
      else
        """
        ---
        name: #{name}
        description: Test grove
        version: "1.0"
        ---

        # #{name}
        """
      end

    File.write!(Path.join([System.tmp_dir!(), base_name, name, "GROVE.md"]), grove_md_content)
    grove_dir
  end

  describe "resolve_all/1" do
    @tag :r1
    test "R1: reads governance source files and returns injections", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "gov-grove",
        governance_yaml: """
          injections:
            - source: governance/doctrine.md
              inject_into:
                - factory-oversight
              priority: high
        """,
        files: %{"governance/doctrine.md" => "Operational doctrine content"}
      )

      {:ok, grove} = Loader.load_grove("gov-grove", groves_path: path)

      assert {:ok, [injection]} = GovernanceResolver.resolve_all(grove)
      assert injection.content == "Operational doctrine content"
      assert injection.priority == :high
      assert injection.inject_into == ["factory-oversight"]
    end

    @tag :r2
    test "R2: returns empty list for nil governance", %{groves_path: path, base_name: base_name} do
      create_governance_grove(base_name, "no-gov")

      {:ok, grove} = Loader.load_grove("no-gov", groves_path: path)
      assert {:ok, []} = GovernanceResolver.resolve_all(grove)
    end

    @tag :r3
    test "R3: returns error for missing governance source file", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "missing-file",
        governance_yaml: """
          injections:
            - source: governance/missing.md
              inject_into:
                - test-skill
        """
      )

      {:ok, grove} = Loader.load_grove("missing-file", groves_path: path)

      assert {:error, {:file_not_found, full_path}} = GovernanceResolver.resolve_all(grove)
      assert full_path =~ "governance/missing.md"
    end

    @tag :r7
    test "R7: injection priority defaults to normal when not specified", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "default-priority",
        governance_yaml: """
          injections:
            - source: governance/rules.md
              inject_into:
                - some-skill
        """,
        files: %{"governance/rules.md" => "Some rules"}
      )

      {:ok, grove} = Loader.load_grove("default-priority", groves_path: path)

      assert {:ok, [injection]} = GovernanceResolver.resolve_all(grove)
      assert injection.priority == :normal
    end

    @tag :r14
    test "R14: multiple injections resolved in declaration order", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "multi-inject",
        governance_yaml: """
          injections:
            - source: governance/first.md
              inject_into:
                - skill-a
              priority: high
            - source: governance/second.md
              inject_into:
                - skill-b
              priority: normal
        """,
        files: %{
          "governance/first.md" => "First rule",
          "governance/second.md" => "Second rule"
        }
      )

      {:ok, grove} = Loader.load_grove("multi-inject", groves_path: path)

      assert {:ok, [first, second]} = GovernanceResolver.resolve_all(grove)
      assert first.content == "First rule"
      assert second.content == "Second rule"
    end

    @tag :r16
    test "R16: reads governance from valid subdirectory path", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "subdir-grove",
        governance_yaml: """
          injections:
            - source: governance/deep/nested/rule.md
              inject_into:
                - test-skill
        """,
        files: %{"governance/deep/nested/rule.md" => "Nested rule content"}
      )

      {:ok, grove} = Loader.load_grove("subdir-grove", groves_path: path)

      assert {:ok, [injection]} = GovernanceResolver.resolve_all(grove)
      assert injection.content == "Nested rule content"
    end
  end

  describe "security checks" do
    @tag :r4
    test "R4: rejects governance source with path traversal", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "traversal-grove",
        governance_yaml: """
          injections:
            - source: ../../../etc/passwd
              inject_into:
                - test-skill
        """
      )

      {:ok, grove} = Loader.load_grove("traversal-grove", groves_path: path)
      assert {:error, {:path_traversal, _}} = GovernanceResolver.resolve_all(grove)
    end

    @tag :r15
    test "R15: rejects absolute path in governance source", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "absolute-grove",
        governance_yaml: """
          injections:
            - source: /etc/passwd
              inject_into:
                - test-skill
        """
      )

      {:ok, grove} = Loader.load_grove("absolute-grove", groves_path: path)
      assert {:error, {:path_traversal, _}} = GovernanceResolver.resolve_all(grove)
    end

    @tag :r5
    test "R5: rejects governance source symlink outside grove", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "symlink-grove",
        governance_yaml: """
          injections:
            - source: governance/evil.md
              inject_into:
                - test-skill
        """
      )

      outside_file_path = Path.join([System.tmp_dir!(), base_name, "outside_file.md"])
      File.write!(outside_file_path, "external content")

      symlink_governance_dir_path =
        Path.join([System.tmp_dir!(), "#{base_name}/symlink-grove/governance"])

      File.mkdir_p!(symlink_governance_dir_path)

      symlink_outside_file_path =
        Path.join([System.tmp_dir!(), "#{base_name}/outside_file.md"])

      symlink_evil_file_path =
        Path.join([System.tmp_dir!(), "#{base_name}/symlink-grove/governance/evil.md"])

      File.ln_s!(symlink_outside_file_path, symlink_evil_file_path)

      {:ok, grove} = Loader.load_grove("symlink-grove", groves_path: path)
      assert {:error, {:symlink_not_allowed, _}} = GovernanceResolver.resolve_all(grove)
    end

    @tag :r6
    test "R6: rejects intermediate directory symlink outside grove", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "intermediate-grove",
        governance_yaml: """
          injections:
            - source: governance/subdir/rule.md
              inject_into:
                - test-skill
        """
      )

      outside_intermediate_dir_path =
        Path.join([System.tmp_dir!(), "#{base_name}/outside_intermediate"])

      File.mkdir_p!(outside_intermediate_dir_path)

      intermediate_rule_path =
        Path.join([System.tmp_dir!(), base_name, "outside_intermediate", "rule.md"])

      File.write!(intermediate_rule_path, "external via intermediate symlink")

      intermediate_grove_governance_dir_path =
        Path.join([System.tmp_dir!(), "#{base_name}/intermediate-grove/governance"])

      File.mkdir_p!(intermediate_grove_governance_dir_path)

      outside_intermediate_symlink_source_path =
        Path.join([System.tmp_dir!(), "#{base_name}/outside_intermediate"])

      intermediate_grove_subdir_symlink_target_path =
        Path.join([System.tmp_dir!(), "#{base_name}/intermediate-grove/governance/subdir"])

      File.ln_s!(
        outside_intermediate_symlink_source_path,
        intermediate_grove_subdir_symlink_target_path
      )

      {:ok, grove} = Loader.load_grove("intermediate-grove", groves_path: path)
      assert {:error, {:symlink_not_allowed, _}} = GovernanceResolver.resolve_all(grove)
    end
  end

  describe "build_agent_governance/3" do
    @tag :r8
    test "R8: filters injections by active skill names" do
      injections = [
        %{content: "Factory policy", priority: :normal, inject_into: ["factory-oversight"]},
        %{content: "Unrelated policy", priority: :normal, inject_into: ["finance"]}
      ]

      governance =
        GovernanceResolver.build_agent_governance(injections, ["factory-oversight"], nil)

      assert governance =~ "Factory policy"
      refute governance =~ "Unrelated policy"
    end

    @tag :r9
    test "R9: returns nil when no governance matches" do
      injections = [
        %{content: "Finance only", priority: :normal, inject_into: ["finance"]}
      ]

      assert is_nil(GovernanceResolver.build_agent_governance(injections, ["engineering"], nil))
    end

    @tag :r10
    test "R10: high-priority governance content appears before normal-priority" do
      injections = [
        %{content: "Normal priority rule", priority: :normal, inject_into: ["skill-a"]},
        %{content: "High priority rule", priority: :high, inject_into: ["skill-a"]}
      ]

      governance = GovernanceResolver.build_agent_governance(injections, ["skill-a"], nil)

      assert governance =~ "High priority rule"
      assert governance =~ "Normal priority rule"

      {high_index, _} = :binary.match(governance, "High priority rule")
      {normal_index, _} = :binary.match(governance, "Normal priority rule")

      assert high_index < normal_index
    end

    @tag :r11
    test "R11: hard_rules with scope all included as system rule text" do
      injections = []

      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "pkill|killall",
          "message" => "Never bypass safety checks",
          "scope" => "all"
        }
      ]

      governance =
        GovernanceResolver.build_agent_governance(injections, ["any-skill"], hard_rules)

      assert governance =~ "## Governance Rules"
      assert governance =~ "SYSTEM RULES"
      assert governance =~ "BLOCKED PATTERN: /pkill|killall/"
      assert governance =~ "Never bypass safety checks"
    end

    @tag :r12
    test "R12: nil hard_rules excluded from governance text" do
      injections = [
        %{content: "Applicable rule", priority: :normal, inject_into: ["skill-a"]}
      ]

      governance = GovernanceResolver.build_agent_governance(injections, ["skill-a"], nil)

      assert governance =~ "Applicable rule"
      refute governance =~ "SYSTEM RULES"
      refute governance =~ "BLOCKED PATTERN:"
    end

    @tag :r37
    test "R37: formats typed hard rules as token-efficient system rules text" do
      injections = []

      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "pkill|killall",
          "message" => "Use kill -PID instead",
          "scope" => "all"
        },
        %{
          "type" => "shell_pattern_block",
          "pattern" => "rm\\s+-rf\\s+/",
          "message" => "Never remove root",
          "scope" => "all"
        }
      ]

      governance =
        GovernanceResolver.build_agent_governance(injections, ["any-skill"], hard_rules)

      assert governance =~ "SYSTEM RULES"
      assert governance =~ "BLOCKED PATTERN: /pkill|killall/"
      assert governance =~ "BLOCKED PATTERN: /rm\\s+-rf\\s+//"
      refute governance =~ "mechanically enforced"
    end

    @tag :r38
    test "R38: filters hard rules by skill name when scope is list" do
      injections = []

      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "pkill",
          "message" => "global",
          "scope" => "all"
        },
        %{
          "type" => "shell_pattern_block",
          "pattern" => "killall",
          "message" => "only for venture-management",
          "scope" => ["venture-management"]
        }
      ]

      governance =
        GovernanceResolver.build_agent_governance(injections, ["factory-oversight"], hard_rules)

      assert governance =~ "BLOCKED PATTERN: /pkill/"
      refute governance =~ "BLOCKED PATTERN: /killall/"
    end

    @tag :r39
    test "R39: nil hard_rules produces no system rules section" do
      injections = []

      assert is_nil(GovernanceResolver.build_agent_governance(injections, ["skill-a"], nil))
    end

    @tag :r40
    test "R40: formats action_block hard rules as blocked action text" do
      hard_rules = [
        %{
          "type" => "action_block",
          "actions" => ["answer_engine", "fetch_web", "generate_images"],
          "message" => "Benchmark grove: external queries not permitted.",
          "scope" => "all"
        }
      ]

      governance = GovernanceResolver.build_agent_governance([], ["any-skill"], hard_rules)

      assert governance =~ "SYSTEM RULES"
      assert governance =~ "BLOCKED ACTION: answer_engine, fetch_web, generate_images"
      assert governance =~ "Benchmark grove"
    end

    @tag :r41
    test "R41: filters action_block rules by skill name scope" do
      hard_rules = [
        %{
          "type" => "action_block",
          "actions" => ["answer_engine"],
          "message" => "Scoped block",
          "scope" => ["benchmark-runner"]
        }
      ]

      matching = GovernanceResolver.build_agent_governance([], ["benchmark-runner"], hard_rules)
      assert matching =~ "BLOCKED ACTION"

      non_matching = GovernanceResolver.build_agent_governance([], ["other-skill"], hard_rules)
      assert is_nil(non_matching)
    end

    @tag :r42
    test "R42: formats mixed shell_pattern_block and action_block rules" do
      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "pkill",
          "message" => "No pkill",
          "scope" => "all"
        },
        %{
          "type" => "action_block",
          "actions" => ["answer_engine"],
          "message" => "No answer engine",
          "scope" => "all"
        }
      ]

      governance = GovernanceResolver.build_agent_governance([], ["any-skill"], hard_rules)

      assert governance =~ "BLOCKED PATTERN: /pkill/"
      assert governance =~ "BLOCKED ACTION: answer_engine"
    end

    @tag :r17
    test "R17: empty inject_into list matches no agents" do
      injections = [
        %{content: "No target rule", priority: :normal, inject_into: []}
      ]

      assert is_nil(GovernanceResolver.build_agent_governance(injections, ["skill-a"], nil))
    end
  end

  describe "filter_for_skills/2" do
    @tag :r13
    test "R13: returns injections matching given skill names" do
      matching = %{content: "Match", priority: :normal, inject_into: ["skill-a"]}
      non_matching = %{content: "No match", priority: :normal, inject_into: ["skill-b"]}

      assert [^matching] =
               GovernanceResolver.filter_for_skills([matching, non_matching], ["skill-a"])
    end
  end

  describe "loader governance sanitization" do
    @tag :r18
    test "R18: Loader sanitizes governance source paths at parse time", %{
      groves_path: path,
      base_name: base_name
    } do
      create_governance_grove(base_name, "sanitized-source-grove",
        governance_yaml: """
          injections:
            - source: ../../../governance/rules.md
              inject_into:
                - skill-a
        """
      )

      assert {:ok, grove} = Loader.load_grove("sanitized-source-grove", groves_path: path)
      assert %{"injections" => [%{"source" => source}]} = grove.governance
      assert source == "governance/rules.md"
    end
  end
end
