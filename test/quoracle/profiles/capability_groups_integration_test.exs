defmodule Quoracle.Profiles.CapabilityGroupsIntegrationTest do
  @moduledoc """
  Integration tests for TEST_ProfileAutonomy v2.0 - capability groups enforcement.

  Tests the complete permission system from profile resolution through
  Router enforcement and PromptBuilder filtering using capability groups.

  WorkGroupID: feat-20260107-capability-groups
  Packet: 3 (Permission Enforcement)

  ARC Requirements:
  - R1: Router Blocks Without Group
  - R2: Router Allows With Group
  - R3: Base Actions Always Allowed
  - R4: Group Combinations Tested
  - R5: Prompt Filters by Groups
  - R6: Acceptance - Blocked Action Error
  - R7: Acceptance - Allowed Action Success
  - R8: Acceptance - Prompt Shows Only Allowed
  """
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router
  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Profiles.ActionGate

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub instance
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    # Per-action Router (v28.0): Don't spawn shared Router - each test spawns its own
    {:ok, pubsub: pubsub_name, registry: registry_name, sandbox_owner: sandbox_owner}
  end

  # Helper to spawn per-action Router
  defp spawn_router(action_type, opts) do
    action_id = "action-#{System.unique_integer([:positive])}"
    agent_id = Keyword.get(opts, :agent_id, "test-agent")

    {:ok, router} =
      Router.start_link(
        action_type: action_type,
        action_id: action_id,
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: Keyword.fetch!(opts, :pubsub),
        sandbox_owner: Keyword.get(opts, :sandbox_owner)
      )

    router
  end

  # ==========================================================================
  # R1: Router Blocks Without Group
  # ==========================================================================

  describe "R1: Router blocks without group" do
    @tag :r1_integration
    test "router blocks execute_shell without local_execution group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:execute_shell, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: [:file_read, :hierarchy]]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{command: "ls"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :action_not_allowed}}
    end

    @tag :r1_integration
    test "router blocks spawn_child without hierarchy group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:spawn_child, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: [:local_execution, :file_read]]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :spawn_child,
            %{prompt: "test", profile: "test-default"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :action_not_allowed}}
    end

    @tag :r1_integration
    test "router blocks file_write without file_write group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:file_write, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: [:file_read]]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :file_write,
            %{path: "/tmp/test.txt", content: "test"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :action_not_allowed}}
    end

    @tag :r1_integration
    test "router blocks call_api without external_api group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:call_api, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: [:hierarchy, :local_execution]]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :call_api,
            %{endpoint: "http://test.com", method: "GET"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :action_not_allowed}}
    end
  end

  # ==========================================================================
  # R2: Router Allows With Group
  # ==========================================================================

  describe "R2: Router allows with group" do
    @tag :r2_integration
    test "router allows execute_shell with local_execution group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:execute_shell, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Per-action Router (v28.0): Shell requires agent_pid and pubsub in opts
      opts = [capability_groups: [:local_execution], agent_pid: self(), pubsub: pubsub]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{command: "echo hello"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # May fail for other reasons, but not capability group
      refute match?({:error, :action_not_allowed}, result)
    end

    @tag :r2_integration
    test "router allows spawn_child with hierarchy group", %{
      registry: registry,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:spawn_child, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [
        capability_groups: [:hierarchy],
        registry: registry,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner
      ]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :spawn_child,
            %{prompt: "test", profile: "test-default"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      # May fail for other reasons (e.g., profile not found), but not capability group
      refute match?({:error, :action_not_allowed}, result)
    end

    @tag :r2_integration
    test "router allows file_read with file_read group", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:file_read, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: [:file_read]]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :file_read,
            %{path: "/tmp/test-read.txt"},
            "test-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      refute match?({:error, :action_not_allowed}, result)
    end
  end

  # ==========================================================================
  # R3: Base Actions Always Allowed
  # ==========================================================================

  describe "R3: Base actions always allowed" do
    @tag :r3_integration
    test "router allows wait with empty capability groups", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:wait, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: []]

      capture_log(fn ->
        result = Router.execute(router, :wait, %{wait: 0.01}, "test-agent", opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      assert match?({:ok, _}, result)
    end

    @tag :r3_integration
    test "router allows orient with empty capability groups", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:orient, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      opts = [capability_groups: []]

      params = %{
        current_situation: "Testing",
        goal_clarity: "Clear",
        available_resources: "All",
        key_challenges: "None",
        delegation_consideration: "None"
      }

      capture_log(fn ->
        result = Router.execute(router, :orient, params, "test-agent", opts)
        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      assert match?({:ok, _}, result)
    end

    @tag :r3_integration
    test "all base actions allowed via ActionGate with empty groups" do
      # 7 base actions per PROFILE_CapabilityGroups spec
      # Note: search_secrets, generate_secret, record_cost are NOT base - they require groups
      base_actions = [
        :wait,
        :orient,
        :todo,
        :send_message,
        :fetch_web,
        :answer_engine,
        :generate_images
      ]

      for action <- base_actions do
        assert ActionGate.check(action, []) == :ok,
               "Base action #{action} should be allowed with empty groups"
      end
    end
  end

  # ==========================================================================
  # R4: Group Combinations Tested
  # ==========================================================================

  describe "R4: Group combinations tested" do
    @tag :r4_integration
    test "various group combinations enforce correct actions", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v28.0): Each action needs its own Router
      group_tests = [
        {[:hierarchy], :spawn_child, :allowed},
        {[:hierarchy], :execute_shell, :blocked},
        {[:local_execution], :execute_shell, :allowed},
        {[:local_execution], :spawn_child, :blocked},
        {[:file_read], :file_read, :allowed},
        {[:file_read], :file_write, :blocked},
        {[:file_write], :file_write, :allowed},
        {[:external_api], :call_api, :allowed},
        {[], :wait, :allowed},
        {[], :execute_shell, :blocked}
      ]

      for {groups, action, expected} <- group_tests do
        # Spawn a fresh Router for each action
        router = spawn_router(action, pubsub: pubsub, sandbox_owner: sandbox_owner)

        # Per-action Router (v28.0): Shell requires agent_pid and pubsub in opts
        opts = [capability_groups: groups, agent_pid: self(), pubsub: pubsub]
        params = minimal_params(action)

        capture_log(fn ->
          result = Router.execute(router, action, params, "test-agent", opts)
          send(self(), {:result, groups, action, expected, result})
        end)

        assert_receive {:result, ^groups, ^action, ^expected, result}, 1000

        # Cleanup router (may have terminated on success)
        # Per-action Router (v28.0): Router self-terminates after action completion
        # Use try/catch to handle race between alive? check and stop
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end

        case expected do
          :allowed ->
            refute match?({:error, :action_not_allowed}, result),
                   "#{action} should be allowed with groups #{inspect(groups)}"

          :blocked ->
            assert {:error, :action_not_allowed} = result,
                   "#{action} should be blocked with groups #{inspect(groups)}"
        end
      end
    end

    @tag :r4_integration
    test "multiple groups combine permissions", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # With both hierarchy and local_execution, both types should be allowed
      # Per-action Router (v28.0): Shell requires agent_pid and pubsub in opts
      opts = [
        capability_groups: [:hierarchy, :local_execution],
        agent_pid: self(),
        pubsub: pubsub
      ]

      # Per-action Router (v28.0): Each action needs its own Router

      # Test spawn_child (needs hierarchy)
      spawn_router_pid = spawn_router(:spawn_child, pubsub: pubsub, sandbox_owner: sandbox_owner)

      capture_log(fn ->
        result =
          Router.execute(
            spawn_router_pid,
            :spawn_child,
            %{prompt: "test", profile: "test-default"},
            "test-agent",
            opts
          )

        send(self(), {:result, :spawn, result})
      end)

      assert_receive {:result, :spawn, spawn_result}
      refute match?({:error, :action_not_allowed}, spawn_result)

      # Per-action Router may terminate after action completes - handle race condition
      if Process.alive?(spawn_router_pid) do
        try do
          GenServer.stop(spawn_router_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end

      # Test execute_shell (needs local_execution)
      shell_router_pid =
        spawn_router(:execute_shell, pubsub: pubsub, sandbox_owner: sandbox_owner)

      capture_log(fn ->
        result =
          Router.execute(
            shell_router_pid,
            :execute_shell,
            %{command: "echo test"},
            "test-agent",
            opts
          )

        send(self(), {:result, :shell, result})
      end)

      assert_receive {:result, :shell, shell_result}
      refute match?({:error, :action_not_allowed}, shell_result)

      # Per-action Router may terminate after action completes - handle race condition
      if Process.alive?(shell_router_pid) do
        try do
          GenServer.stop(shell_router_pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  # ==========================================================================
  # R5: Prompt Filters by Groups
  # ==========================================================================

  describe "R5: Prompt filters by groups" do
    @tag :r5_integration
    test "empty groups shows only base actions in prompt" do
      opts = [capability_groups: []]
      prompt = PromptBuilder.build_system_prompt(opts)

      # Base actions should be present
      assert prompt =~ "wait"
      assert prompt =~ "orient"
      assert prompt =~ "send_message"

      # Group-specific actions should NOT have schema documentation
      # Match schema heading format "action_name: description" not JSON examples
      refute prompt =~ ~r/^execute_shell: /m
      refute prompt =~ ~r/^spawn_child: /m
      refute prompt =~ ~r/^file_read: /m
      refute prompt =~ ~r/^file_write: /m
      refute prompt =~ ~r/^call_api: /m
    end

    @tag :r5_integration
    test "all groups shows all actions except role-gated" do
      opts = [
        capability_groups: [:hierarchy, :local_execution, :file_read, :file_write, :external_api]
      ]

      prompt = PromptBuilder.build_system_prompt(opts)

      # Should contain all non-role-gated actions
      assert prompt =~ "execute_shell"
      assert prompt =~ "spawn_child"
      assert prompt =~ "call_api"
      assert prompt =~ "file_read"
      assert prompt =~ "file_write"
    end

    @tag :r5_integration
    test "file_read only shows file_read action" do
      opts = [capability_groups: [:file_read]]
      prompt = PromptBuilder.build_system_prompt(opts)

      assert prompt =~ "file_read"
      refute prompt =~ ~r/^file_write: /m
      refute prompt =~ ~r/^execute_shell: /m
      refute prompt =~ ~r/^spawn_child: /m
    end

    @tag :r5_integration
    test "hierarchy only shows hierarchy actions" do
      opts = [capability_groups: [:hierarchy]]
      prompt = PromptBuilder.build_system_prompt(opts)

      assert prompt =~ "spawn_child"
      assert prompt =~ "dismiss_child"
      assert prompt =~ "adjust_budget"
      refute prompt =~ ~r/^execute_shell: /m
      refute prompt =~ ~r/^file_read: /m
    end
  end

  # ==========================================================================
  # R6-R8: Acceptance Tests
  # ==========================================================================

  describe "R6: Acceptance - Blocked action error" do
    @tag :acceptance
    @tag :r6_integration
    test "user task with empty groups, blocked action returns error", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:execute_shell, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Subscribe to action events
      agent_id = "test-empty-groups-agent"
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      opts = [capability_groups: [], pubsub: pubsub]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{command: "ls"},
            agent_id,
            opts
          )

        send(self(), {:result, result})
      end)

      # Error returned to caller
      assert_receive {:result, {:error, :action_not_allowed}}

      # Error broadcast via PubSub
      assert_receive {:action_error, %{error: {:error, :action_not_allowed}}}, 1000
    end
  end

  describe "R7: Acceptance - Allowed action success" do
    @tag :acceptance
    @tag :r7_integration
    test "user task with local_execution group, shell succeeds", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      router = spawn_router(:execute_shell, pubsub: pubsub, sandbox_owner: sandbox_owner)

      on_exit(fn ->
        if Process.alive?(router), do: GenServer.stop(router, :normal, :infinity)
      end)

      # Per-action Router (v28.0): Shell requires agent_pid and pubsub in opts
      opts = [capability_groups: [:local_execution], agent_pid: self(), pubsub: pubsub]

      capture_log(fn ->
        result =
          Router.execute(
            router,
            :execute_shell,
            %{command: "echo hello"},
            "test-shell-agent",
            opts
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, result}
      refute match?({:error, :action_not_allowed}, result)
    end
  end

  describe "R8: Acceptance - Prompt shows only allowed" do
    @tag :acceptance
    @tag :r8_integration
    test "empty groups agent prompt contains only safe action schemas" do
      opts = [
        profile_name: "empty-groups-profile",
        profile_description: "Profile with no capability groups",
        capability_groups: []
      ]

      prompt = PromptBuilder.build_system_prompt(opts)

      # Verify safe (base) actions present
      safe_actions = ~w(wait orient todo send_message fetch_web answer_engine)

      for action <- safe_actions do
        assert prompt =~ action,
               "Safe action #{action} should appear in empty groups prompt"
      end

      # Verify group-specific actions absent from schemas
      blocked = ~w(execute_shell spawn_child dismiss_child call_api call_mcp file_read file_write)

      for action <- blocked do
        refute prompt =~ ~r/^#{action}: /m,
               "Group action #{action} should NOT have schema documentation in empty groups prompt"
      end

      # Verify profile section exists (name/description omitted to avoid spawn bias)
      assert prompt =~ "## Operating Profile"
      refute prompt =~ "empty-groups-profile", "Profile name should not appear"

      refute prompt =~ "Profile with no capability groups",
             "Profile description should not appear"
    end

    @tag :acceptance
    @tag :r8_integration
    test "full groups agent prompt contains all allowed actions" do
      opts = [
        profile_name: "full-groups-profile",
        profile_description: "Profile with all capability groups",
        capability_groups: [:hierarchy, :local_execution, :file_read, :file_write, :external_api]
      ]

      prompt = PromptBuilder.build_system_prompt(opts)

      # All group-specific actions should be present
      group_actions = ~w(execute_shell spawn_child dismiss_child call_api file_read file_write)

      for action <- group_actions do
        assert prompt =~ action,
               "Group action #{action} should appear in full groups prompt"
      end
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp minimal_params(:wait), do: %{wait: 0.01}
  defp minimal_params(:orient), do: %{current_situation: "test", goal_clarity: "test"}
  defp minimal_params(:execute_shell), do: %{command: "echo test"}
  defp minimal_params(:spawn_child), do: %{prompt: "test", profile: "test-default"}
  defp minimal_params(:call_api), do: %{endpoint: "http://test.com", method: "GET"}
  defp minimal_params(:call_mcp), do: %{server: "test", tool: "test", arguments: %{}}
  defp minimal_params(:file_read), do: %{path: "/tmp/test-read.txt"}
  defp minimal_params(:file_write), do: %{path: "/tmp/test-write.txt", content: "test"}
  defp minimal_params(_), do: %{}
end
