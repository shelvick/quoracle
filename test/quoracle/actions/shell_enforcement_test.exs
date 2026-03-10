defmodule Quoracle.Actions.ShellEnforcementTest do
  @moduledoc """
  Regression tests for ACTION_Shell grove hard-rule enforcement behavior.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Shell

  setup do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    agent_id = "agent-shell-enforcement-#{System.unique_integer([:positive])}"
    action_id = "action-#{System.unique_integer([:positive])}"

    {:ok, router} =
      Quoracle.Actions.Router.start_link(
        action_type: :execute_shell,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        sandbox_owner: nil
      )

    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    opts = [
      agent_pid: self(),
      pubsub: pubsub,
      router_pid: router,
      action_id: action_id,
      smart_threshold: 1000
    ]

    %{opts: opts}
  end

  describe "hard rule enforcement" do
    test "shell command matching blocked pattern returns hard_rule_violation", %{opts: opts} do
      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "^echo\\s",
          "message" => "echo is blocked by grove policy",
          "scope" => "all"
        }
      ]

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_hard_rules: hard_rules,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "echo blocked-command"}, "agent-1", opts)

      assert {:error, {:hard_rule_violation, details}} = result
      assert details.type == "shell_pattern_block"
      assert details.pattern == "^echo\\s"
      assert details.command == "echo blocked-command"
    end

    test "shell command not matching any pattern executes normally", %{opts: opts} do
      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "^pkill",
          "message" => "pkill is blocked",
          "scope" => "all"
        }
      ]

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_hard_rules: hard_rules,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "echo allowed"}, "agent-1", opts)

      assert {:ok, %{stdout: "allowed\n", exit_code: 0}} = result
    end

    test "command allowed when skill not in rule scope", %{opts: opts} do
      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "^echo",
          "message" => "echo is blocked for other skill",
          "scope" => ["other-skill"]
        }
      ]

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_hard_rules: hard_rules,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "echo scoped-allowed"}, "agent-1", opts)

      assert {:ok, %{stdout: "scoped-allowed\n", exit_code: 0}} = result
    end

    test "multiple rules checked until first match", %{opts: opts} do
      hard_rules = [
        %{
          "type" => "shell_pattern_block",
          "pattern" => "^rm\\s",
          "message" => "rm blocked",
          "scope" => "all"
        },
        %{
          "type" => "shell_pattern_block",
          "pattern" => "^echo\\s",
          "message" => "echo blocked",
          "scope" => "all"
        }
      ]

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_hard_rules: hard_rules,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "echo blocked-by-second-rule"}, "agent-1", opts)

      assert {:error, {:hard_rule_violation, details}} = result
      assert details.pattern == "^echo\\s"
    end
  end

  describe "working directory confinement" do
    test "working dir outside confinement returns error", %{opts: opts} do
      confinement = %{
        "agentic-coding" => %{
          "paths" => ["/home/sandbox/allowed/**"],
          "read_only_paths" => []
        }
      }

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_confinement: confinement,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "pwd", working_dir: System.tmp_dir!()}, "agent-1", opts)

      assert {:error, {:confinement_violation, details}} = result
      assert details.working_dir == System.tmp_dir!()
      assert details.skill == "agentic-coding"
    end

    test "working dir within confinement passes", %{opts: opts} do
      confinement = %{
        "agentic-coding" => %{
          "paths" => ["/tmp/**"],
          "read_only_paths" => []
        }
      }

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_confinement: confinement,
          skill_name: "agentic-coding"
        })

      result = Shell.execute(%{command: "pwd", working_dir: System.tmp_dir!()}, "agent-1", opts)

      assert {:ok, %{stdout: stdout, exit_code: 0}} = result
      assert String.trim(stdout) == System.tmp_dir!()
    end

    @tag :capture_log
    test "unlisted skill in confinement allowed", %{opts: opts} do
      confinement = %{
        "different-skill" => %{
          "paths" => ["/tmp/**"],
          "read_only_paths" => []
        }
      }

      opts =
        Keyword.put(opts, :parent_config, %{
          grove_confinement: confinement,
          skill_name: "agentic-coding"
        })

      assert {:ok, %{stdout: "unlisted\n", exit_code: 0}} =
               Shell.execute(
                 %{command: "echo unlisted", working_dir: System.tmp_dir!()},
                 "agent-1",
                 opts
               )
    end
  end

  describe "passthrough without grove config" do
    test "no hard rules means all commands pass", %{opts: opts} do
      opts = Keyword.put(opts, :parent_config, %{skill_name: "agentic-coding"})

      result = Shell.execute(%{command: "echo no-hard-rules"}, "agent-1", opts)

      assert {:ok, %{stdout: "no-hard-rules\n", exit_code: 0}} = result
    end

    test "no confinement means all working dirs pass", %{opts: opts} do
      opts = Keyword.put(opts, :parent_config, %{skill_name: "agentic-coding"})

      result = Shell.execute(%{command: "pwd", working_dir: System.tmp_dir!()}, "agent-1", opts)

      assert {:ok, %{stdout: stdout, exit_code: 0}} = result
      assert String.trim(stdout) == System.tmp_dir!()
    end
  end

  describe "status checks" do
    test "status check bypasses enforcement", %{opts: opts} do
      restrictive_config = %{
        skill_name: "agentic-coding",
        grove_hard_rules: [
          %{
            "type" => "shell_pattern_block",
            "pattern" => ".*",
            "message" => "everything blocked",
            "scope" => "all"
          }
        ],
        grove_confinement: %{
          "agentic-coding" => %{
            "paths" => ["/definitely/not/allowed/**"],
            "read_only_paths" => []
          }
        }
      }

      opts = Keyword.put(opts, :parent_config, restrictive_config)

      result = Shell.execute(%{check_id: "non-existent-command-id"}, "agent-1", opts)

      assert {:error, :command_not_found} = result
    end
  end
end
