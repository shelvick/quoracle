defmodule Quoracle.Groves.HardRuleEnforcerTest do
  @moduledoc """
  Unit tests for GROVE_HardRuleEnforcer packets 1-2.

  ARC Criteria: R1-R37 from TEST_GroveHardRuleEnforcer
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Groves.HardRuleEnforcer

  @moduletag :feat_grove_system
  @moduletag :packet_1

  @shell_rules [
    %{
      "type" => "shell_pattern_block",
      "pattern" => "pkill|killall|pgrep.*xargs.*kill",
      "message" => "Forbidden: use targeted kill with verified PID.",
      "scope" => "all"
    },
    %{
      "type" => "shell_pattern_block",
      "pattern" => "rm\\s+-rf\\s+/",
      "message" => "Forbidden: do not rm -rf root.",
      "scope" => ["agentic-coding-management"]
    }
  ]

  @confinement %{
    "venture-management" => %{
      "paths" => ["/home/user/venture_factory/ventures/**"],
      "read_only_paths" => ["/home/user/venture_factory/shared/**"]
    }
  }

  @action_block_rules [
    %{
      "type" => "action_block",
      "actions" => ["answer_engine", "fetch_web", "generate_images"],
      "message" => "Benchmark grove: external queries not permitted.",
      "scope" => "all"
    },
    %{
      "type" => "action_block",
      "actions" => ["generate_images"],
      "message" => "Image generation not allowed for this skill.",
      "scope" => ["benchmark-runner"]
    }
  ]

  describe "check_shell_command/3" do
    @tag :r1
    test "R1: blocks shell command matching pattern" do
      command = "pkill -f myapp"

      assert {:error, {:hard_rule_violation, details}} =
               HardRuleEnforcer.check_shell_command(command, @shell_rules, "venture-management")

      assert details.type == "shell_pattern_block"
      assert details.pattern == "pkill|killall|pgrep.*xargs.*kill"
      assert details.command == command
      assert details.message =~ "Forbidden"
      refute details.message == ""
    end

    @tag :r2
    test "R2: allows shell command not matching any pattern" do
      assert :ok =
               HardRuleEnforcer.check_shell_command(
                 "echo 'safe command'",
                 @shell_rules,
                 "venture-management"
               )
    end

    @tag :r3
    test "R3: scope all applies to any skill" do
      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_shell_command(
                 "killall myapp",
                 @shell_rules,
                 "unlisted-skill"
               )
    end

    @tag :r4
    test "R4: scope list applies only to listed skills" do
      assert :ok =
               HardRuleEnforcer.check_shell_command(
                 "rm -rf /",
                 @shell_rules,
                 "venture-management"
               )

      assert {:error, {:hard_rule_violation, details}} =
               HardRuleEnforcer.check_shell_command(
                 "rm -rf /",
                 @shell_rules,
                 "agentic-coding-management"
               )

      assert details.pattern == "rm\\s+-rf\\s+/"
    end

    @tag :r5
    test "R5: nil hard_rules returns ok" do
      assert :ok =
               HardRuleEnforcer.check_shell_command("pkill -f myapp", nil, "venture-management")
    end

    @tag :r6
    test "R6: empty hard_rules returns ok" do
      assert :ok =
               HardRuleEnforcer.check_shell_command("pkill -f myapp", [], "venture-management")
    end

    @tag :r7
    test "R7: invalid regex pattern skipped with warning" do
      invalid_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "[",
          "message" => "broken regex",
          "scope" => "all"
        }
      ]

      log =
        capture_log(fn ->
          assert :ok =
                   HardRuleEnforcer.check_shell_command(
                     "echo 'safe command'",
                     invalid_rules,
                     "venture-management"
                   )
        end)

      assert String.downcase(log) =~ "regex"
    end
  end

  describe "check_shell_working_dir/3" do
    @tag :r8
    test "R8: working dir within allowed paths passes" do
      assert :ok =
               HardRuleEnforcer.check_shell_working_dir(
                 "/home/user/venture_factory/ventures/acme",
                 @confinement,
                 "venture-management"
               )
    end

    @tag :r9
    test "R9: working dir outside allowed paths returns confinement error" do
      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_shell_working_dir(
                 "/etc",
                 @confinement,
                 "venture-management"
               )

      assert details.working_dir == "/etc"
      assert details.skill == "venture-management"
      assert is_list(details.allowed_paths)
      assert details.message =~ "outside"
    end

    @tag :r10
    test "R10: nil confinement allows any working dir" do
      assert :ok =
               HardRuleEnforcer.check_shell_working_dir(
                 "/completely/any/path",
                 nil,
                 "venture-management"
               )
    end

    @tag :r11
    test "R11: unlisted skill warns and allows working dir" do
      log =
        capture_log(fn ->
          assert :ok =
                   HardRuleEnforcer.check_shell_working_dir(
                     "/etc",
                     @confinement,
                     "factory-oversight"
                   )
        end)

      assert log =~ "factory-oversight"
    end
  end

  describe "check_file_access/4" do
    @tag :r12
    test "R12: file write within allowed paths passes" do
      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/home/user/venture_factory/ventures/acme/notes.md",
                 :write,
                 @confinement,
                 "venture-management"
               )
    end

    @tag :r13
    test "R13: file write outside allowed paths returns confinement error" do
      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/tmp/outside.txt",
                 :write,
                 @confinement,
                 "venture-management"
               )

      assert details.path == "/tmp/outside.txt"
      assert details.skill == "venture-management"
      assert details.access_type == :write
    end

    @tag :r14
    test "R14: file write to read_only_path is rejected" do
      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/home/user/venture_factory/shared/rules.md",
                 :write,
                 @confinement,
                 "venture-management"
               )

      assert details.access_type == :write
    end

    @tag :r15
    test "R15: file read within write-capable paths passes" do
      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/home/user/venture_factory/ventures/acme/readme.md",
                 :read,
                 @confinement,
                 "venture-management"
               )
    end

    @tag :r16
    test "R16: file read within read-only paths passes" do
      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/home/user/venture_factory/shared/guide.md",
                 :read,
                 @confinement,
                 "venture-management"
               )
    end

    @tag :r17
    test "R17: file read outside all paths returns confinement error" do
      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/etc/passwd",
                 :read,
                 @confinement,
                 "venture-management"
               )

      assert details.path == "/etc/passwd"
      assert details.access_type == :read
    end

    @tag :r18
    test "R18: nil confinement allows any file access" do
      assert :ok = HardRuleEnforcer.check_file_access("/etc/passwd", :read, nil, "skill-a")
      assert :ok = HardRuleEnforcer.check_file_access("/etc/passwd", :write, nil, "skill-a")
    end

    @tag :r19
    test "R19: unlisted skill warns and allows file access" do
      log =
        capture_log(fn ->
          assert :ok =
                   HardRuleEnforcer.check_file_access(
                     "/etc/passwd",
                     :read,
                     @confinement,
                     "factory-oversight"
                   )
        end)

      assert log =~ "factory-oversight"
    end

    @tag :r20
    test "R20: recursive glob pattern matches nested paths" do
      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/home/user/venture_factory/ventures/acme/reports/2026/q1/metrics.json",
                 :read,
                 @confinement,
                 "venture-management"
               )
    end

    @tag :r21
    test "R21: error details include path, skill, and allowed paths" do
      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/outside/root/secret.md",
                 :write,
                 @confinement,
                 "venture-management"
               )

      assert details.path == "/outside/root/secret.md"
      assert details.skill == "venture-management"
      assert is_list(details.allowed_paths)
      assert details.allowed_paths != []
      assert details.message =~ "venture-management"
    end
  end

  describe "strict confinement mode" do
    @tag :r32
    test "R32: strict mode denies unlisted skill for file access" do
      confinement = %{
        "venture-management" => %{
          "paths" => ["/home/user/ventures/**"],
          "read_only_paths" => ["/home/user/shared/**"]
        }
      }

      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/home/user/ventures/project/file.txt",
                 :read,
                 confinement,
                 "unlisted-skill",
                 "strict"
               )

      assert details.path == "/home/user/ventures/project/file.txt"
      assert details.skill == "unlisted-skill"
      assert details.access_type == :read
      assert details.allowed_paths == []
      assert details.message =~ "Strict confinement mode"
      assert details.message =~ "no confinement entry for skill"
      assert details.message =~ "unlisted-skill"
      assert details.message =~ "GROVE.md"
    end

    @tag :r33
    test "R33: strict mode denies unlisted skill for working dir" do
      confinement = %{
        "venture-management" => %{
          "paths" => ["/home/user/ventures/**"]
        }
      }

      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_shell_working_dir(
                 "/home/user/ventures/project",
                 confinement,
                 "unlisted-skill",
                 "strict"
               )

      assert details.working_dir == "/home/user/ventures/project"
      assert details.skill == "unlisted-skill"
      assert details.allowed_paths == []
      assert details.message =~ "Strict confinement mode"
      assert details.message =~ "no confinement entry for skill"
      assert details.message =~ "unlisted-skill"
      assert details.message =~ "GROVE.md"
    end

    @tag :r34
    test "R34: permissive mode warns and allows unlisted skill for file access" do
      confinement = %{
        "venture-management" => %{
          "paths" => ["/home/user/ventures/**"]
        }
      }

      log =
        capture_log(fn ->
          assert :ok =
                   HardRuleEnforcer.check_file_access(
                     "/etc/passwd",
                     :read,
                     confinement,
                     "unlisted-skill",
                     nil
                   )
        end)

      assert log =~ "No confinement entry"
      assert log =~ "unlisted-skill"
    end

    @tag :r35
    test "R35: permissive mode warns and allows unlisted skill for working dir" do
      confinement = %{
        "venture-management" => %{
          "paths" => ["/home/user/ventures/**"]
        }
      }

      log =
        capture_log(fn ->
          assert :ok =
                   HardRuleEnforcer.check_shell_working_dir(
                     "/tmp/work",
                     confinement,
                     "unlisted-skill",
                     nil
                   )
        end)

      assert log =~ "No confinement entry"
      assert log =~ "unlisted-skill"
    end

    @tag :r36
    test "R36: strict mode with nil confinement allows access" do
      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/etc/passwd",
                 :read,
                 nil,
                 "any-skill",
                 "strict"
               )
    end

    @tag :r37
    test "R37: strict mode with listed skill applies normal path matching" do
      confinement = %{
        "venture-management" => %{
          "paths" => ["/home/user/ventures/**"],
          "read_only_paths" => ["/home/user/shared/**"]
        }
      }

      assert :ok =
               HardRuleEnforcer.check_file_access(
                 "/home/user/ventures/project/file.txt",
                 :write,
                 confinement,
                 "venture-management",
                 "strict"
               )

      assert {:error, {:confinement_violation, details}} =
               HardRuleEnforcer.check_file_access(
                 "/etc/passwd",
                 :read,
                 confinement,
                 "venture-management",
                 "strict"
               )

      refute details.message =~ "Strict confinement mode"
      assert details.skill == "venture-management"
    end
  end

  describe "check_action/3" do
    @tag :r22
    test "R22: blocks action matching action_block rule" do
      assert {:error, {:hard_rule_violation, details}} =
               HardRuleEnforcer.check_action(:answer_engine, @action_block_rules, "any-skill")

      assert details.type == "action_block"
      assert details.action == "answer_engine"
      assert details.message =~ "Benchmark grove"
      refute details.message == ""
    end

    @tag :r23
    test "R23: allows action not matching any action_block rule" do
      assert :ok = HardRuleEnforcer.check_action(:execute_shell, @action_block_rules, "any-skill")
    end

    @tag :r24
    test "R24: action_block scope all applies to any skill" do
      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:answer_engine, @action_block_rules, "skill-one")

      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:fetch_web, @action_block_rules, "skill-two")
    end

    @tag :r25
    test "R25: action_block scope list blocks for listed skill" do
      scoped_rules = [
        %{
          "type" => "action_block",
          "actions" => ["generate_images"],
          "message" => "Scoped block",
          "scope" => ["benchmark-runner"]
        }
      ]

      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:generate_images, scoped_rules, "benchmark-runner")
    end

    @tag :r26
    test "R26: action_block scope list allows for unlisted skill" do
      scoped_rules = [
        %{
          "type" => "action_block",
          "actions" => ["generate_images"],
          "message" => "Scoped block",
          "scope" => ["benchmark-runner"]
        }
      ]

      assert :ok = HardRuleEnforcer.check_action(:generate_images, scoped_rules, "other-skill")
    end

    @tag :r27
    test "R27: nil hard_rules allows any action" do
      assert :ok = HardRuleEnforcer.check_action(:answer_engine, nil, "any-skill")
    end

    @tag :r28
    test "R28: empty hard_rules allows any action" do
      assert :ok = HardRuleEnforcer.check_action(:answer_engine, [], "any-skill")
    end

    @tag :r29
    test "R29: action_block with multiple actions blocks each listed action" do
      rules = [
        %{
          "type" => "action_block",
          "actions" => ["answer_engine", "fetch_web", "generate_images"],
          "message" => "All blocked",
          "scope" => "all"
        }
      ]

      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:answer_engine, rules, "s")

      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:fetch_web, rules, "s")

      assert {:error, {:hard_rule_violation, _}} =
               HardRuleEnforcer.check_action(:generate_images, rules, "s")

      assert :ok = HardRuleEnforcer.check_action(:execute_shell, rules, "s")
    end

    @tag :r30
    test "R30: action_block error details include full context" do
      assert {:error, {:hard_rule_violation, details}} =
               HardRuleEnforcer.check_action(:answer_engine, @action_block_rules, "any-skill")

      assert details.type == "action_block"
      assert is_list(details.actions)
      assert "answer_engine" in details.actions
      assert details.action == "answer_engine"
      assert is_binary(details.message)
      refute details.message == ""
    end

    @tag :r31
    test "R31: check_action ignores shell_pattern_block rules" do
      mixed_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "answer_engine",
          "message" => "Shell pattern, not action block",
          "scope" => "all"
        }
      ]

      assert :ok = HardRuleEnforcer.check_action(:answer_engine, mixed_rules, "any-skill")
    end
  end
end
