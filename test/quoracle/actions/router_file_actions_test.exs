defmodule Quoracle.Actions.RouterFileActionsTest do
  @moduledoc """
  Integration tests for Router dispatching file actions to FileRead/FileWrite modules.

  Packet 1 - R15: Router Integration for file_read
  Packet 2 - R19-R20: Router Integration for file_write
  WorkGroupID: feat-20260107-file-actions
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.Router
  alias Quoracle.Actions.Router.ActionMapper

  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :file_read,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name
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

    # Create unique temp directory for test files
    temp_dir =
      Path.join([
        System.tmp_dir!(),
        "router_file_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok,
     router: router,
     pubsub: pubsub_name,
     agent_id: agent_id,
     temp_dir: temp_dir,
     capability_groups: [:file_read, :file_write]}
  end

  describe "R15: ActionMapper registration" do
    test "file_read is registered in ActionMapper" do
      # [INTEGRATION] - WHEN ActionMapper queried for :file_read THEN returns FileRead module
      assert {:ok, module} = ActionMapper.get_action_module(:file_read)
      assert module == Quoracle.Actions.FileRead
    end
  end

  describe "R15: Router.execute with file_read" do
    test "Router dispatches file_read to FileRead module", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_read action THEN dispatches to FileRead and returns content
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello from router test")

      # Force sync execution (file I/O can exceed smart mode's 100ms threshold)
      result =
        Router.execute(router, :file_read, %{path: path}, agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:ok, %{action: "file_read", content: content}} = result
      assert content =~ "hello from router test"
    end

    test "Router returns error for missing file", %{
      router: router,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_read for missing file THEN returns file_not_found
      missing_path =
        Path.join(System.tmp_dir!(), "missing_#{System.unique_integer([:positive])}.txt")

      result =
        Router.execute(router, :file_read, %{path: missing_path}, agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:error, {:file_not_found, %{path: ^missing_path}}} = result
    end

    test "Router returns error for relative path", %{
      router: router,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_read with relative path THEN returns relative_path error
      result =
        Router.execute(router, :file_read, %{path: "relative.txt"}, agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:error, {:relative_path, %{path: "relative.txt", hint: _}}} = result
    end
  end

  # ===========================================================================
  # Packet 2: R19-R20 - file_write Router Integration
  # ===========================================================================

  describe "R19: ActionMapper registration for file_write" do
    test "file_write is registered in ActionMapper" do
      # [INTEGRATION] - WHEN ActionMapper queried for :file_write THEN returns FileWrite module
      assert {:ok, module} = ActionMapper.get_action_module(:file_write)
      assert module == Quoracle.Actions.FileWrite
    end
  end

  describe "R19: Router.execute with file_write" do
    test "Router dispatches file_write to FileWrite module - write mode", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_write action THEN dispatches to FileWrite
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")

      # Force sync execution (file I/O can exceed smart mode's 100ms threshold)
      result =
        Router.execute(
          router,
          :file_write,
          %{path: path, mode: :write, content: "hello from router"},
          agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:ok, %{action: "file_write", mode: :write, created: true}} = result
      assert File.read!(path) == "hello from router"
    end

    test "Router dispatches file_write to FileWrite module - edit mode", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_write edit action THEN performs replacement
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "old content here")

      # Force sync execution (file I/O can exceed smart mode's 100ms threshold)
      result =
        Router.execute(
          router,
          :file_write,
          %{path: path, mode: :edit, old_string: "old", new_string: "new"},
          agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:ok, %{action: "file_write", mode: :edit, replacements: 1}} = result
      assert File.read!(path) == "new content here"
    end

    test "Router returns error for existing file in write mode", %{
      router: router,
      agent_id: agent_id,
      temp_dir: temp_dir,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_write for existing file THEN returns file_exists
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "existing")

      result =
        Router.execute(
          router,
          :file_write,
          %{path: path, mode: :write, content: "new"},
          agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:error, {:file_exists, %{path: ^path}}} = result
    end

    test "Router returns error for relative path in file_write", %{
      router: router,
      agent_id: agent_id,
      capability_groups: capability_groups
    } do
      # [INTEGRATION] - WHEN Router receives file_write with relative path THEN returns error
      result =
        Router.execute(
          router,
          :file_write,
          %{path: "relative.txt", mode: :write, content: "test"},
          agent_id,
          timeout: 5000,
          capability_groups: capability_groups
        )

      assert {:error, {:relative_path, %{path: "relative.txt"}}} = result
    end
  end
end
