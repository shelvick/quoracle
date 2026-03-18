defmodule Quoracle.Groves.HardEnforcementIntegrationTest do
  @moduledoc """
  Integration and acceptance tests for grove hard-rule and confinement enforcement.

  WorkGroupID: wip-20260302-grove-hard-enforcement
  Packet: 4 (Integration)
  Spec: TEST_GroveHardEnforcement_Integration
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Groves.{GovernanceResolver, Loader}
  alias Quoracle.Tasks.TaskManager

  @moduletag :feat_grove_system
  @moduletag :packet_4

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()
    profile = create_test_profile()

    fixture = create_hard_enforcement_fixture(profile.name)

    on_exit(fn ->
      File.rm_rf!(fixture.base_dir)
    end)

    {:ok, grove} = Loader.load_grove(fixture.grove_name, groves_path: fixture.groves_path)

    {:ok,
     deps: deps,
     profile: profile,
     sandbox_owner: sandbox_owner,
     fixture: fixture,
     grove: grove,
     hard_rules: get_in(grove, [:governance, "hard_rules"]),
     confinement: Map.get(grove, :confinement)}
  end

  describe "shell command enforcement (end-to-end)" do
    @tag :acceptance
    test "blocked shell command returns actionable error through full pipeline", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      result =
        process_action(root_pid, "execute_shell", %{
          command: "echo blocked-shell",
          working_dir: ctx.fixture.allowed_dir
        })

      assert {:error, {:hard_rule_violation, details}} = result
      assert details.pattern =~ "blocked-shell"
      assert details.message =~ "Blocked by grove hard rule"
      refute details.message == ""
    end

    @tag :acceptance
    test "allowed shell command executes normally through pipeline", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      result =
        process_action(root_pid, "execute_shell", %{
          command: "echo allowed-shell",
          working_dir: ctx.fixture.allowed_dir
        })

      assert_shell_success(result)

      case result do
        {:ok, %{stdout: stdout}} -> assert stdout == "allowed-shell\n"
        _ -> :ok
      end

      refute match?({:error, {:hard_rule_violation, _}}, result)
      refute match?({:error, {:confinement_violation, _}}, result)
    end
  end

  describe "working directory enforcement (end-to-end)" do
    @tag :acceptance
    test "shell with confined working dir outside paths returns error", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      result =
        process_action(root_pid, "execute_shell", %{
          command: "pwd",
          working_dir: ctx.fixture.outside_dir
        })

      assert {:error, {:confinement_violation, details}} = result
      assert details.working_dir == ctx.fixture.outside_dir
      assert details.skill == "agentic-coding"
      refute match?({:ok, %{exit_code: 0}}, result)
    end

    @tag :acceptance
    test "shell with working dir within confinement paths executes normally", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      result =
        process_action(root_pid, "execute_shell", %{
          command: "pwd",
          working_dir: ctx.fixture.allowed_dir
        })

      assert_shell_success(result)

      case result do
        {:ok, %{stdout: stdout}} -> assert String.trim(stdout) == ctx.fixture.allowed_dir
        _ -> :ok
      end

      refute match?({:error, {:confinement_violation, _}}, result)
    end

    @tag :capture_log
    @tag :acceptance
    test "strict confinement blocks unlisted skill shell through user message flow", ctx do
      strict_confinement = %{
        "different-skill" => %{
          "paths" => [Path.join(ctx.fixture.allowed_dir, "**")],
          "read_only_paths" => []
        }
      }

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: strict_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:strict-shell"],
          test_mode: false,
          test_opts: [
            model_query_fn:
              mock_query_fn_for_action(
                action_response("execute_shell", %{
                  "command" => "pwd",
                  "working_dir" => ctx.fixture.outside_dir
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      event =
        send_user_message_and_wait_for_action(
          root_pid,
          ctx.deps.pubsub,
          "Attempt strict shell from unlisted skill"
        )

      assert {:action_error, %{error: {:error, {:confinement_violation, details}}}} = event
      assert details.working_dir == ctx.fixture.outside_dir
      assert details.skill == "agentic-coding"
      refute match?({:action_completed, _}, event)
    end
  end

  describe "filesystem confinement - file_write (end-to-end)" do
    @tag :acceptance
    test "file write outside confinement returns error through pipeline", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      blocked_path = Path.join(ctx.fixture.outside_dir, "blocked-write.txt")

      result =
        process_action(root_pid, "file_write", %{
          path: blocked_path,
          mode: "write",
          content: "blocked"
        })

      assert {:error, {:confinement_violation, details}} = result
      assert details.path == blocked_path
      assert details.access_type == :write
      refute File.exists?(blocked_path)
      refute match?({:ok, %{action: "file_write"}}, result)
    end

    @tag :acceptance
    test "file write within confinement paths succeeds", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      allowed_path = Path.join(ctx.fixture.allowed_dir, "allowed-write.txt")

      result =
        process_action(root_pid, "file_write", %{
          path: allowed_path,
          mode: "write",
          content: "allowed"
        })

      assert {:ok, %{action: "file_write", path: ^allowed_path, created: true}} = result
      assert File.read!(allowed_path) == "allowed"
      refute match?({:error, {:confinement_violation, _}}, result)
    end

    @tag :acceptance
    test "file write to read-only path returns error", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      read_only_path = Path.join(ctx.fixture.read_only_dir, "readonly-write.txt")

      result =
        process_action(root_pid, "file_write", %{
          path: read_only_path,
          mode: "write",
          content: "blocked"
        })

      assert {:error, {:confinement_violation, details}} = result
      assert details.path == read_only_path
      assert details.access_type == :write
      refute File.exists?(read_only_path)
      refute match?({:ok, %{action: "file_write"}}, result)
    end

    @tag :capture_log
    @tag :acceptance
    test "strict confinement blocks unlisted skill file_write", ctx do
      strict_confinement = %{
        "different-skill" => %{
          "paths" => [Path.join(ctx.fixture.allowed_dir, "**")],
          "read_only_paths" => []
        }
      }

      blocked_path = Path.join(ctx.fixture.allowed_dir, "strict-blocked-write.txt")

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: strict_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:strict-file-write"],
          test_mode: false,
          test_opts: [
            model_query_fn:
              mock_query_fn_for_action(
                action_response("file_write", %{
                  "path" => blocked_path,
                  "mode" => "write",
                  "content" => "blocked"
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:action_error, %{error: {:error, {:confinement_violation, details}}}} =
               send_user_message_and_wait_for_action(
                 root_pid,
                 ctx.deps.pubsub,
                 "Attempt strict file write from unlisted skill"
               )

      assert details.path == blocked_path
      assert details.access_type == :write
      assert details.skill == "agentic-coding"
      refute File.exists?(blocked_path)
    end

    @tag :acceptance
    test "strict confinement allows listed skill file_write within paths", ctx do
      strict_confinement = %{
        "agentic-coding" => %{
          "paths" => [Path.join(ctx.fixture.allowed_dir, "**")],
          "read_only_paths" => []
        }
      }

      allowed_path = Path.join(ctx.fixture.allowed_dir, "strict-allowed-write.txt")

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: strict_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:strict-file-write-allowed"],
          test_mode: false,
          test_opts: [
            model_query_fn:
              mock_query_fn_for_action(
                action_response("file_write", %{
                  "path" => allowed_path,
                  "mode" => "write",
                  "content" => "strict allowed"
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      event =
        send_user_message_and_wait_for_action(
          root_pid,
          ctx.deps.pubsub,
          "Write within strict confinement for listed skill"
        )

      assert {:action_completed,
              %{result: {:ok, %{action: "file_write", path: ^allowed_path, created: true}}}} =
               event

      assert File.read!(allowed_path) == "strict allowed"
      refute match?({:action_error, _}, event)
    end
  end

  describe "filesystem confinement - file_read (end-to-end)" do
    @tag :acceptance
    test "file read outside all paths returns error through pipeline", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      outside_path = Path.join(ctx.fixture.outside_dir, "outside-read.txt")

      outside_file =
        Path.join(System.tmp_dir!(), Path.relative_to(outside_path, System.tmp_dir!()))

      File.write!(outside_file, "outside")

      result = process_action(root_pid, "file_read", %{path: outside_path})

      assert {:error, {:confinement_violation, details}} = result
      assert details.path == outside_path
      assert details.access_type == :read
      refute match?({:ok, %{action: "file_read"}}, result)
    end

    @tag :acceptance
    test "file read from write-capable path succeeds", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      allowed_path = Path.join(ctx.fixture.allowed_dir, "allowed-read.txt")

      allowed_file =
        Path.join(System.tmp_dir!(), Path.relative_to(allowed_path, System.tmp_dir!()))

      File.write!(allowed_file, "allowed read")

      result = process_action(root_pid, "file_read", %{path: allowed_path})

      assert {:ok, %{action: "file_read", path: ^allowed_path, content: content}} = result
      assert content =~ "1\tallowed read"
      refute match?({:error, {:confinement_violation, _}}, result)
    end

    @tag :acceptance
    test "file read from read-only path succeeds", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      read_only_path = Path.join(ctx.fixture.read_only_dir, "readonly-read.txt")

      read_only_file =
        Path.join(System.tmp_dir!(), Path.relative_to(read_only_path, System.tmp_dir!()))

      File.write!(read_only_file, "readonly read")

      result = process_action(root_pid, "file_read", %{path: read_only_path})

      assert {:ok, %{action: "file_read", path: ^read_only_path, content: content}} = result
      assert content =~ "1\treadonly read"
      refute match?({:error, {:confinement_violation, _}}, result)
    end

    @tag :capture_log
    @tag :acceptance
    test "strict confinement blocks unlisted skill file_read through user message flow", ctx do
      strict_confinement = %{
        "different-skill" => %{
          "paths" => [Path.join(ctx.fixture.allowed_dir, "**")],
          "read_only_paths" => []
        }
      }

      blocked_path = Path.join(ctx.fixture.allowed_dir, "strict-blocked-read.txt")

      blocked_file =
        Path.join(System.tmp_dir!(), Path.relative_to(blocked_path, System.tmp_dir!()))

      File.write!(blocked_file, "strict blocked read")

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: strict_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:strict-file-read"],
          test_mode: false,
          test_opts: [
            model_query_fn:
              mock_query_fn_for_action(
                action_response("file_read", %{
                  "path" => blocked_path
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      event =
        send_user_message_and_wait_for_action(
          root_pid,
          ctx.deps.pubsub,
          "Attempt strict file read from unlisted skill"
        )

      assert {:action_error, %{error: {:error, {:confinement_violation, details}}}} = event
      assert details.path == blocked_path
      assert details.access_type == :read
      assert details.skill == "agentic-coding"
      refute match?({:action_completed, _}, event)
    end
  end

  describe "template var confinement (end-to-end)" do
    @tag :capture_log
    @tag :integration
    @tag :acceptance
    test "child with resolved grove_vars enforces confinement", ctx do
      template_base_name = Path.relative_to(ctx.fixture.base_dir, System.tmp_dir!())

      template_root =
        Path.join(System.tmp_dir!(), Path.join([template_base_name, "template-workspaces"]))

      child_workspace = "child-a"

      child_dir =
        Path.join(
          System.tmp_dir!(),
          Path.join([template_base_name, "template-workspaces", child_workspace])
        )

      sibling_dir =
        Path.join(
          System.tmp_dir!(),
          Path.join([template_base_name, "template-workspaces", "child-b"])
        )

      root_message = "Spawn template child for #{child_workspace}"
      child_message = "Write inside your resolved workspace"
      allowed_path = Path.join(child_dir, "allowed.txt")

      File.mkdir_p!(child_dir)
      File.mkdir_p!(sibling_dir)

      template_confinement = %{
        "agentic-coding" => %{
          "paths" => [Path.join([template_root, "{child_workspace}", "**"])],
          "read_only_paths" => []
        }
      }

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: template_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:template-child-allowed"],
          test_mode: false,
          skip_initial_consultation: true,
          spawn_complete_notify: self(),
          test_opts: [
            model_query_fn:
              template_spawn_query_fn(
                root_message,
                child_message,
                ctx.profile.name,
                child_workspace,
                action_response("file_write", %{
                  "path" => allowed_path,
                  "mode" => "write",
                  "content" => "template allowed"
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)

      {child_pid, child_id} =
        send_user_message_and_wait_for_child_spawn(
          root_pid,
          root_state.agent_id,
          ctx.deps.pubsub,
          root_message
        )

      on_exit(fn -> stop_agent_tree(child_pid, ctx.deps.registry) end)

      event =
        send_user_message_and_wait_for_agent_action(
          child_pid,
          child_id,
          ctx.deps.pubsub,
          child_message,
          "file_write"
        )

      assert {:action_completed,
              %{
                agent_id: ^child_id,
                result: {:ok, %{action: "file_write", path: ^allowed_path, created: true}}
              }} =
               event

      assert File.read!(allowed_path) == "template allowed"
      refute match?({:action_error, _}, event)
    end

    @tag :capture_log
    @tag :integration
    @tag :acceptance
    test "child with resolved grove_vars blocked on sibling path", ctx do
      template_base_name = Path.relative_to(ctx.fixture.base_dir, System.tmp_dir!())

      template_root =
        Path.join(System.tmp_dir!(), Path.join([template_base_name, "template-workspaces"]))

      child_workspace = "child-a"

      child_dir =
        Path.join(
          System.tmp_dir!(),
          Path.join([template_base_name, "template-workspaces", child_workspace])
        )

      sibling_dir =
        Path.join(
          System.tmp_dir!(),
          Path.join([template_base_name, "template-workspaces", "child-b"])
        )

      root_message = "Spawn template child for #{child_workspace}"
      child_message = "Write outside your resolved workspace"
      blocked_path = Path.join(sibling_dir, "blocked.txt")

      File.mkdir_p!(child_dir)
      File.mkdir_p!(sibling_dir)

      template_confinement = %{
        "agentic-coding" => %{
          "paths" => [Path.join([template_root, "{child_workspace}", "**"])],
          "read_only_paths" => []
        }
      }

      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          confinement: template_confinement,
          confinement_mode: "strict",
          model_pool: ["mock:template-child-blocked"],
          test_mode: false,
          skip_initial_consultation: true,
          spawn_complete_notify: self(),
          test_opts: [
            model_query_fn:
              template_spawn_query_fn(
                root_message,
                child_message,
                ctx.profile.name,
                child_workspace,
                action_response("file_write", %{
                  "path" => blocked_path,
                  "mode" => "write",
                  "content" => "template blocked"
                })
              )
          ]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)

      {child_pid, child_id} =
        send_user_message_and_wait_for_child_spawn(
          root_pid,
          root_state.agent_id,
          ctx.deps.pubsub,
          root_message
        )

      on_exit(fn -> stop_agent_tree(child_pid, ctx.deps.registry) end)

      event =
        send_user_message_and_wait_for_agent_action(
          child_pid,
          child_id,
          ctx.deps.pubsub,
          child_message,
          "file_write"
        )

      assert {:action_error,
              %{agent_id: ^child_id, error: {:error, {:confinement_violation, details}}}} = event

      assert details.path == blocked_path
      assert details.access_type == :write
      refute File.exists?(blocked_path)
      refute match?({:action_completed, _}, event)
    end
  end

  describe "no grove - passthrough" do
    @tag :acceptance
    test "shell command without grove config passes through", ctx do
      {:ok, {_task, root_pid}} = create_task_without_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      assert is_nil(Map.get(root_state, :grove_confinement))

      result =
        process_action(root_pid, "execute_shell", %{
          command: "echo no-grove-shell",
          working_dir: ctx.fixture.outside_dir
        })

      assert_shell_success(result)

      case result do
        {:ok, %{stdout: stdout}} -> assert stdout == "no-grove-shell\n"
        _ -> :ok
      end

      refute match?({:error, {:hard_rule_violation, _}}, result)
      refute match?({:error, {:confinement_violation, _}}, result)
    end

    @tag :acceptance
    test "file operations without grove config pass through", ctx do
      {:ok, {_task, root_pid}} = create_task_without_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      assert is_nil(Map.get(root_state, :grove_confinement))

      passthrough_path = Path.join(ctx.fixture.outside_dir, "no-grove-file.txt")

      write_result =
        process_action(root_pid, "file_write", %{
          path: passthrough_path,
          mode: "write",
          content: "passthrough"
        })

      assert {:ok, %{action: "file_write", path: ^passthrough_path, created: true}} = write_result

      read_result = process_action(root_pid, "file_read", %{path: passthrough_path})

      assert {:ok, %{action: "file_read", path: ^passthrough_path, content: content}} =
               read_result

      assert content =~ "1\tpassthrough"
      refute match?({:error, {:confinement_violation, _}}, write_result)
      refute match?({:error, {:confinement_violation, _}}, read_result)
    end
  end

  describe "action block enforcement (end-to-end)" do
    @tag :acceptance
    @tag :r13
    test "R13: blocked action returns hard_rule_violation through full pipeline", ctx do
      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          hard_rules: action_block_hard_rules(),
          confinement: ctx.confinement
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      result = process_action(root_pid, "fetch_web", %{url: "https://example.com"})

      assert {:error, {:hard_rule_violation, details}} = result
      assert details.type == "action_block"
      assert details.action == "fetch_web"
      assert details.message =~ "Benchmark"
      refute match?({:ok, _}, result)
    end

    @tag :acceptance
    @tag :r14
    test "R14: non-blocked action proceeds normally when action_block rules exist", ctx do
      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          hard_rules: action_block_hard_rules(),
          confinement: ctx.confinement
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      result =
        process_action(root_pid, "execute_shell", %{
          command: "echo action-block-allowed",
          working_dir: ctx.fixture.allowed_dir
        })

      assert_shell_success(result)
      refute match?({:error, {:hard_rule_violation, _}}, result)
    end

    @tag :acceptance
    @tag :r15
    test "R15: blocked actions excluded from LLM schema in system prompt", ctx do
      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          hard_rules: action_block_hard_rules(),
          confinement: ctx.confinement,
          governance_rules: action_block_governance_rules(),
          test_opts: [model_query_fn: capturing_model_query_fn(self())]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      {_messages, captured_prompt} = trigger_consensus_and_capture_prompt(root_pid)

      assert captured_prompt =~ "## Available Actions"

      [_before_actions, actions_section] =
        String.split(captured_prompt, "You must respond with **only** a JSON object", parts: 2)

      refute actions_section =~ ~r/\nanswer_engine:/
      refute actions_section =~ ~r/\ngenerate_images:/
      assert actions_section =~ ~r/\norient:/
      assert actions_section =~ ~r/\nexecute_shell:/
    end

    @tag :acceptance
    @tag :r16
    test "R16: action_block governance text appears in system prompt", ctx do
      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          hard_rules: action_block_hard_rules(),
          confinement: ctx.confinement,
          governance_rules: action_block_governance_rules(),
          test_opts: [model_query_fn: capturing_model_query_fn(self())]
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      {_messages, captured_prompt} = trigger_consensus_and_capture_prompt(root_pid)

      assert captured_prompt =~ "BLOCKED ACTION"
      assert captured_prompt =~ "answer_engine"
      assert captured_prompt =~ "Benchmark grove"
      refute captured_prompt =~ "BLOCKED ACTION: totally_unknown_action"
    end

    @tag :capture_log
    @tag :acceptance
    @tag :r17
    test "R17: child agent inherits action blocking from parent grove", ctx do
      {:ok, {_task, root_pid}} =
        create_task_from_grove(ctx,
          hard_rules: action_block_hard_rules(),
          confinement: ctx.confinement
        )

      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      spawn_action = %{
        action: "spawn_child",
        params: %{
          "task_description" => "Action block child task",
          "success_criteria" => "inherits action block",
          "immediate_context" => "integration",
          "approach_guidance" => "follow parent",
          "skills" => ["agentic-coding"],
          "profile" => ctx.profile.name
        }
      }

      spawn_action_id = "spawn-action-block-child-#{System.unique_integer([:positive])}"

      assert {:ok, %{pid: child_pid}} =
               GenServer.call(root_pid, {:process_action, spawn_action, spawn_action_id}, 30_000)

      on_exit(fn -> stop_agent_tree(child_pid, ctx.deps.registry) end)

      result = process_action(child_pid, "fetch_web", %{url: "https://example.com"})

      assert {:error, {:hard_rule_violation, details}} = result
      assert details.type == "action_block"
      assert details.action == "fetch_web"
      refute match?({:ok, _}, result)
    end

    @tag :acceptance
    @tag :r18
    test "R18: no grove config allows all actions through", ctx do
      {:ok, {_task, root_pid}} = create_task_without_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      result =
        process_action(root_pid, "execute_shell", %{
          command: "echo no-grove-action-block",
          working_dir: ctx.fixture.outside_dir
        })

      assert_shell_success(result)
      refute match?({:error, {:hard_rule_violation, _}}, result)
    end
  end

  describe "confinement inheritance" do
    @tag :capture_log
    @tag :acceptance
    test "child agent inherits confinement from parent", ctx do
      {:ok, {_task, root_pid}} = create_task_from_grove(ctx)
      on_exit(fn -> stop_agent_tree(root_pid, ctx.deps.registry) end)

      assert {:ok, root_state} = Core.get_state(root_pid)
      assert Map.has_key?(root_state, :grove_confinement)
      refute is_nil(Map.get(root_state, :grove_confinement))

      spawn_action = %{
        action: "spawn_child",
        params: %{
          "task_description" => "Hard enforcement child task",
          "success_criteria" => "inherits confinement",
          "immediate_context" => "integration",
          "approach_guidance" => "follow parent",
          "skills" => ["agentic-coding"],
          "profile" => ctx.profile.name,
          "grove_vars" => %{"child_workspace" => "inheritance-check"}
        }
      }

      spawn_action_id = "spawn-child-#{System.unique_integer([:positive])}"

      assert {:ok, %{pid: child_pid}} =
               GenServer.call(root_pid, {:process_action, spawn_action, spawn_action_id}, 30_000)

      on_exit(fn -> stop_agent_tree(child_pid, ctx.deps.registry) end)

      assert {:ok, child_state} = Core.get_state(child_pid)
      assert Map.has_key?(child_state, :grove_confinement)
      assert Map.get(child_state, :grove_confinement) == ctx.confinement

      blocked_result =
        process_action(child_pid, "execute_shell", %{
          command: "pwd",
          working_dir: ctx.fixture.outside_dir
        })

      assert {:error, {:confinement_violation, blocked_details}} = blocked_result
      assert blocked_details.working_dir == ctx.fixture.outside_dir
      refute match?({:ok, %{exit_code: 0}}, blocked_result)

      allowed_result =
        process_action(child_pid, "execute_shell", %{
          command: "pwd",
          working_dir: ctx.fixture.allowed_dir
        })

      assert_shell_success(allowed_result)

      case allowed_result do
        {:ok, %{stdout: child_stdout}} ->
          assert String.trim(child_stdout) == ctx.fixture.allowed_dir

        _ ->
          :ok
      end

      refute match?({:error, {:confinement_violation, _}}, allowed_result)
    end
  end

  defp create_task_from_grove(ctx, opts \\ []) do
    task_fields = %{profile: ctx.profile.name, skills: ["agentic-coding"]}
    agent_fields = %{task_description: "Hard enforcement integration task"}

    create_opts = [
      sandbox_owner: ctx.sandbox_owner,
      registry: ctx.deps.registry,
      dynsup: ctx.deps.dynsup,
      pubsub: ctx.deps.pubsub,
      grove_skills_path: ctx.grove.skills_path,
      grove_hard_rules: Keyword.get(opts, :hard_rules, ctx.hard_rules),
      grove_confinement: Keyword.get(opts, :confinement, ctx.confinement),
      grove_topology: Keyword.get(opts, :grove_topology, ctx.grove.topology),
      grove_path: Keyword.get(opts, :grove_path, ctx.grove.path)
    ]

    create_opts =
      maybe_put(create_opts, :test_opts, Keyword.get(opts, :test_opts))
      |> maybe_put(:governance_rules, Keyword.get(opts, :governance_rules))
      |> maybe_put(:grove_confinement_mode, Keyword.get(opts, :confinement_mode))
      |> maybe_put(:model_pool, Keyword.get(opts, :model_pool))
      |> maybe_put(:test_mode, Keyword.get(opts, :test_mode))
      |> maybe_put(:skip_auto_consensus, Keyword.get(opts, :skip_auto_consensus))
      |> maybe_put(:skip_initial_consultation, Keyword.get(opts, :skip_initial_consultation))
      |> maybe_put(:spawn_complete_notify, Keyword.get(opts, :spawn_complete_notify))

    TaskManager.create_task(task_fields, agent_fields, create_opts)
  end

  defp create_task_without_grove(ctx) do
    task_fields = %{profile: ctx.profile.name, skills: ["agentic-coding"]}
    agent_fields = %{task_description: "No grove passthrough task"}

    TaskManager.create_task(task_fields, agent_fields,
      sandbox_owner: ctx.sandbox_owner,
      registry: ctx.deps.registry,
      dynsup: ctx.deps.dynsup,
      pubsub: ctx.deps.pubsub,
      grove_skills_path: ctx.grove.skills_path
    )
  end

  defp process_action(agent_pid, action, params) do
    action_map = %{action: action, params: params}
    action_id = "hard-enforce-#{System.unique_integer([:positive])}"

    GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
  end

  defp send_user_message_and_wait_for_action(agent_pid, pubsub, content) do
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")
    :ok = Core.send_user_message(agent_pid, content)

    receive do
      {:action_completed, event} -> {:action_completed, event}
      {:action_error, event} -> {:action_error, event}
    after
      30_000 -> flunk("Timed out waiting for action event")
    end
  end

  defp send_user_message_and_wait_for_child_spawn(root_pid, root_agent_id, pubsub, content) do
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")
    :ok = Core.send_user_message(root_pid, content)

    wait_for_child_spawn_or_root_failure(root_agent_id)
  end

  defp send_user_message_and_wait_for_agent_action(agent_pid, agent_id, pubsub, content, action) do
    :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")
    :ok = Core.send_user_message(agent_pid, content)

    receive_matching_action_event(agent_id, action)
  end

  defp receive_matching_action_event(agent_id, action) do
    receive do
      {:action_completed, %{agent_id: ^agent_id, result: {:ok, %{action: ^action}}} = event} ->
        {:action_completed, event}

      {:action_error,
       %{agent_id: ^agent_id, error: {:error, {:confinement_violation, _}}} = event} ->
        {:action_error, event}

      {:action_completed, _other_event} ->
        receive_matching_action_event(agent_id, action)

      {:action_error, _other_event} ->
        receive_matching_action_event(agent_id, action)
    after
      30_000 -> flunk("Timed out waiting for matching action event")
    end
  end

  defp wait_for_child_spawn_or_root_failure(root_agent_id) do
    receive do
      {:spawn_complete, child_id, {:ok, child_pid}} ->
        {child_pid, child_id}

      {:spawn_complete, child_id, {:error, reason}} ->
        flunk("Child #{child_id} failed to spawn: #{inspect(reason)}")

      {:action_error, %{agent_id: ^root_agent_id, error: error}} ->
        flunk("Root agent failed before spawning child: #{inspect(error)}")

      {:action_completed,
       %{agent_id: ^root_agent_id, result: {:ok, %{action: "spawn", agent_id: _child_id}}}} ->
        wait_for_child_spawn_or_root_failure(root_agent_id)

      {:action_completed, %{agent_id: ^root_agent_id}} ->
        # Non-spawn action (e.g. orient) completed first — keep waiting for spawn
        wait_for_child_spawn_or_root_failure(root_agent_id)

      {:action_completed, _other_event} ->
        wait_for_child_spawn_or_root_failure(root_agent_id)

      {:action_error, _other_event} ->
        wait_for_child_spawn_or_root_failure(root_agent_id)
    after
      30_000 -> flunk("Timed out waiting for child spawn")
    end
  end

  defp mock_query_fn_for_action(first_response_json) do
    {:ok, counter_pid} = Agent.start_link(fn -> 0 end)

    fn _messages, [model_id], _opts ->
      call_number = Agent.get_and_update(counter_pid, fn n -> {n + 1, n + 1} end)

      response_json =
        if call_number == 1, do: first_response_json, else: orient_response()

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: response_json}],
         failed_models: []
       }}
    end
  end

  defp template_spawn_query_fn(
         root_message,
         child_message,
         profile_name,
         child_workspace,
         child_action_json
       ) do
    {:ok, counter_pid} = Agent.start_link(fn -> 0 end)

    fn messages, [model_id], _opts ->
      call_number = Agent.get_and_update(counter_pid, fn n -> {n + 1, n + 1} end)
      latest_user_message = latest_user_message(messages)

      response_json =
        cond do
          call_number == 1 and String.contains?(latest_user_message, root_message) ->
            action_response("spawn_child", %{
              "task_description" => "Template confinement child task",
              "success_criteria" => "inherits resolved confinement",
              "immediate_context" => "template variable integration",
              "approach_guidance" => "operate within resolved workspace",
              "skills" => ["agentic-coding"],
              "profile" => profile_name,
              "grove_vars" => %{"child_workspace" => child_workspace}
            })

          String.contains?(latest_user_message, child_message) ->
            child_action_json

          true ->
            orient_response()
        end

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: response_json}],
         failed_models: []
       }}
    end
  end

  defp action_response(action, params) do
    Jason.encode!(%{
      "action" => action,
      "params" => params,
      "reasoning" => "Strict confinement acceptance coverage",
      "wait" => true
    })
  end

  defp action_block_hard_rules do
    [
      %{
        "type" => "action_block",
        "actions" => ["answer_engine", "fetch_web", "generate_images"],
        "message" => "Benchmark grove: external queries are blocked.",
        "scope" => "all"
      }
    ]
  end

  defp action_block_governance_rules do
    GovernanceResolver.build_agent_governance([], ["agentic-coding"], action_block_hard_rules())
  end

  defp trigger_consensus_and_capture_prompt(agent_pid) do
    Core.handle_message(agent_pid, "Trigger action-block consensus")

    assert_receive {:query_messages, ^agent_pid, _model_id, messages}, 10_000

    system_prompt =
      messages
      |> Enum.find(&(&1.role == "system"))
      |> case do
        nil -> nil
        message -> message.content
      end

    {messages, system_prompt}
  end

  defp capturing_model_query_fn(test_pid) do
    fn messages, [model_id], _opts ->
      send(test_pid, {:query_messages, self(), model_id, messages})

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: orient_response()}],
         failed_models: []
       }}
    end
  end

  defp orient_response do
    Jason.encode!(%{
      "action" => "orient",
      "params" => %{
        "current_situation" => "capturing system prompt",
        "goal_clarity" => "clear",
        "available_resources" => "test harness",
        "key_challenges" => "none",
        "delegation_consideration" => "not needed"
      },
      "reasoning" => "Action-block prompt capture response",
      "wait" => true
    })
  end

  defp latest_user_message(messages) do
    messages
    |> Enum.filter(&(&1.role == "user"))
    |> List.last()
    |> case do
      nil -> ""
      %{content: content} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Shell commands may complete synchronously ({:ok, %{exit_code: 0, stdout: ...}}) or
  # asynchronously ({:ok, %{command_id: _, status: :running, sync: false}}) depending on
  # system load vs smart_threshold timing. Both indicate the command passed enforcement
  # checks (confinement/hard rules are checked BEFORE shell execution begins).
  defp assert_shell_success(result) do
    case result do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{status: :running, sync: false}} ->
        :ok

      other ->
        flunk("Expected shell success (sync or async), got: #{inspect(other)}")
    end
  end

  defp create_hard_enforcement_fixture(profile_name) do
    base_name = "hard_enforcement_packet4/#{System.unique_integer([:positive])}"
    base_dir = Path.join(System.tmp_dir!(), base_name)
    groves_path = Path.join(System.tmp_dir!(), Path.join([base_name, "groves"]))
    grove_name = "hard-enforce-grove"
    _grove_dir = Path.join(System.tmp_dir!(), Path.join([base_name, "groves", grove_name]))

    allowed_dir = Path.join(System.tmp_dir!(), Path.join([base_name, "allowed"]))
    read_only_dir = Path.join(System.tmp_dir!(), Path.join([base_name, "read_only"]))
    outside_dir = Path.join(System.tmp_dir!(), Path.join([base_name, "outside"]))

    skill_dir =
      Path.join(
        System.tmp_dir!(),
        Path.join([base_name, "groves", grove_name, "skills", "agentic-coding"])
      )

    skill_file =
      Path.join(
        System.tmp_dir!(),
        Path.join([base_name, "groves", grove_name, "skills", "agentic-coding", "SKILL.md"])
      )

    grove_file =
      Path.join(System.tmp_dir!(), Path.join([base_name, "groves", grove_name, "GROVE.md"]))

    File.mkdir_p!(skill_dir)
    File.mkdir_p!(allowed_dir)
    File.mkdir_p!(read_only_dir)
    File.mkdir_p!(outside_dir)

    File.write!(skill_file, """
    ---
    name: agentic-coding
    description: Hard enforcement integration skill
    ---
    # agentic-coding

    Integration skill.
    """)

    File.write!(grove_file, """
    ---
    name: #{grove_name}
    description: Hard enforcement packet 4 fixture
    version: "1.0"
    bootstrap:
      profile: #{profile_name}
      skills:
        - agentic-coding
    governance:
      hard_rules:
        - type: shell_pattern_block
          pattern: '^echo blocked-shell$'
          message: "Blocked by grove hard rule."
          scope:
            - agentic-coding
    topology:
      edges:
        - parent: agentic-coding
          child: agentic-coding
          required_context:
            - child_workspace
    confinement:
      agentic-coding:
        paths:
          - "#{allowed_dir}/**"
        read_only_paths:
          - "#{read_only_dir}/**"
    ---
    """)

    %{
      base_dir: base_dir,
      groves_path: groves_path,
      grove_name: grove_name,
      allowed_dir: allowed_dir,
      read_only_dir: read_only_dir,
      outside_dir: outside_dir
    }
  end
end
