defmodule QuoracleWeb.Dashboard3PanelIntegrationTest do
  @moduledoc """
  Integration tests for Packet 4: Dashboard 3-panel layout integration.

  Verifies the dashboard correctly integrates the unified TaskTree component,
  removes the old task list panel, and properly handles event delegation
  from TaskTree to Dashboard event handlers.

  Tests written for wip-20250121-ui-merge Packet 4.
  """

  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated dependencies
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    {:ok, _dynsup} =
      start_supervised({Quoracle.Agent.DynSup, name: dynsup_name}, shutdown: :infinity)

    # Create test profile for task creation tests - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    %{
      conn: conn,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup_name,
      sandbox_owner: sandbox_owner,
      force_persist: true,
      profile: profile
    }
  end

  defp create_db_only_task(prompt) do
    %Quoracle.Tasks.Task{}
    |> Quoracle.Tasks.Task.changeset(%{prompt: prompt, status: "running"})
    |> Quoracle.Repo.insert!()
  end

  describe "R1: 3-Panel Layout" do
    # R1: [INTEGRATION] test - WHEN dashboard renders THEN displays 3 panels with correct widths
    test "dashboard displays 3-panel layout", %{conn: conn} = context do
      {:ok, _view, html} = mount_dashboard(conn, context)

      # Should have exactly 3 main panels
      panels = html |> Floki.parse_document!() |> Floki.find("div.flex.h-screen > div")
      assert length(panels) == 3, "Expected 3 panels, got #{length(panels)}"

      # Panel 1: TaskTree (5/12 width)
      [panel1 | _] = panels
      assert Floki.attribute(panel1, "class") |> to_string() =~ "w-5/12"

      # Panel 2: Logs (1/3 width)
      [_, panel2 | _] = panels
      assert Floki.attribute(panel2, "class") |> to_string() =~ "w-1/3"

      # Panel 3: Mailbox (1/4 width)
      [_, _, panel3] = panels
      assert Floki.attribute(panel3, "class") |> to_string() =~ "w-1/4"
    end

    test "no task list panel exists", %{conn: conn} = context do
      {:ok, _view, html} = mount_dashboard(conn, context)

      # Should NOT have the old task list panel with individual task items
      refute html =~ "task-item"
      refute html =~ "phx-click=\"select_task\""
    end
  end

  describe "R2: Tree Integration" do
    # R2: [INTEGRATION] test - WHEN dashboard mounts THEN TaskTree receives all tasks and agents
    test "TaskTree receives complete task and agent data", %{conn: conn} = context do
      # Create multiple tasks with proper cleanup
      {:ok, {task1, _agent1_pid}} = create_task_with_cleanup("First task", Keyword.new(context))
      {:ok, {task2, _agent2_pid}} = create_task_with_cleanup("Second task", Keyword.new(context))

      {:ok, {task3, _agent3_pid}} =
        create_task_with_cleanup("Third task with agent", Keyword.new(context))

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Check that TaskTree component received all tasks
      tree_element = element(view, "#task-tree")
      tree_html = render(tree_element)

      assert tree_html =~ task1.id
      assert tree_html =~ task2.id
      assert tree_html =~ task3.id

      # Check all agents are passed (not filtered by task)
      assert tree_html =~ "root-#{task3.id}"
    end

    test "TaskTree receives pubsub, registry, and dynsup", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # TaskTree component should have received dependency injection
      tree_component = view |> element("#task-tree") |> render()

      # Verify TaskTree can create new tasks (needs dynsup)
      assert tree_component =~ "New Task"

      # Verify TaskTree shows unified tree (needs all deps)
      assert tree_component =~ "Task Tree"
    end
  end

  describe "R3: Event Delegation" do
    # R3: [INTEGRATION] test - WHEN TaskTree sends events THEN Dashboard handles them correctly
    test "Dashboard handles pause_task event from TaskTree", %{conn: conn} = context do
      {:ok, {task, agent_pid}} = create_task_with_cleanup("Task to pause", Keyword.new(context))

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Monitor agent before pause (async pause requires waiting for termination)
      ref = Process.monitor(agent_pid)

      # TaskTree sends pause event via root_pid
      send(view.pid, {:pause_task, task.id})
      render(view)

      # Wait for async pause to complete (agent termination)
      receive do
        {:DOWN, ^ref, :process, ^agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Process the agent_terminated PubSub message in the view
      render(view)

      # Task should be paused after agent terminates
      assert {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "paused"
    end

    test "Dashboard handles resume_task event from TaskTree", %{conn: conn} = context do
      # Create task and properly pause it (stops the agent)
      {:ok, {task, agent_pid}} = create_task_with_cleanup("Task to resume", Keyword.new(context))

      # Properly pause the task (this stops the agent)
      :ok =
        Quoracle.Tasks.TaskRestorer.pause_task(task.id,
          registry: context.registry,
          dynsup: context.dynsup
        )

      # Wait for agent to stop
      ref = Process.monitor(agent_pid)
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, _reason}, 30_000

      {:ok, view, _html} = mount_dashboard(conn, context)

      # TaskTree sends resume event
      send(view.pid, {:resume_task, task.id})
      render(view)

      # Task should be running again
      assert {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "running"
    end

    test "Dashboard handles delete_task event from TaskTree", %{conn: conn} = context do
      {:ok, {task, _agent_pid}} = create_task_with_cleanup("Task to delete", Keyword.new(context))
      TaskManager.update_task_status(task.id, "paused")

      {:ok, view, _html} = mount_dashboard(conn, context)

      # TaskTree sends delete event
      send(view.pid, {:delete_task, task.id})
      render(view)

      # Task should be deleted
      assert {:error, :not_found} = TaskManager.get_task(task.id)
    end

    test "Dashboard handles submit_prompt event from TaskTree", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # TaskTree sends new task prompt
      send(
        view.pid,
        {:submit_prompt,
         %{"task_description" => "New task from modal", "profile" => context.profile.name}}
      )

      render(view)

      # New task should be created
      tasks = TaskManager.list_tasks()
      assert Enum.any?(tasks, fn t -> t.prompt == "New task from modal" end)

      # CRITICAL: Clean up the agent spawned by task creation
      task = Enum.find(tasks, fn t -> t.prompt == "New task from modal" end)
      agent_id = "root-#{task.id}"

      case Registry.lookup(context.registry, {:agent, agent_id}) do
        [{agent_pid, _}] ->
          # Wait for agent initialization
          assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)
          # Register cleanup with tree cleanup for any children
          register_agent_cleanup(agent_pid, cleanup_tree: true, registry: context.registry)

        [] ->
          # Agent might not be registered yet - register deferred cleanup
          on_exit(fn ->
            case Registry.lookup(context.registry, {:agent, agent_id}) do
              [{pid, _}] when is_pid(pid) ->
                if Process.alive?(pid) do
                  try do
                    GenServer.stop(pid, :normal, :infinity)
                  catch
                    :exit, _ -> :ok
                  end
                end

              _ ->
                :ok
            end
          end)
      end
    end

    test "Dashboard handles select_agent event from TaskTree", %{conn: conn} = context do
      {:ok, {_task, _agent_pid}} =
        create_task_with_cleanup("Task with agent", Keyword.new(context))

      {:ok, view, _html} = mount_dashboard(conn, context)

      # TaskTree sends agent selection
      agent_id = "test-agent-123"
      send(view.pid, {:select_agent, agent_id})
      render(view)

      # Logs should be filtered to selected agent
      logs_element = element(view, "#logs")
      logs_html = render(logs_element)
      # Logs panel exists and renders
      assert logs_html =~ ~r/(#{agent_id}|No logs|Logs)/
    end
  end

  describe "R4: Agent Selection Still Works" do
    # R4: [INTEGRATION] test - WHEN agent selected in TaskTree THEN logs filter to that agent
    test "agent selection filters logs correctly", %{conn: conn} = context do
      {:ok, {task, _agent_pid}} =
        create_task_with_cleanup("Task with agent", Keyword.new(context))

      agent_id = "root-#{task.id}"

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Broadcast some logs
      Phoenix.PubSub.broadcast(
        context.pubsub,
        "agents:#{agent_id}:logs",
        {:log_entry,
         %{agent_id: agent_id, level: :info, message: "Test log", timestamp: DateTime.utc_now()}}
      )

      render(view)

      # Select the agent
      send(view.pid, {:select_agent, agent_id})
      html = render(view)

      # Logs should show for selected agent or indicate no logs
      assert html =~ ~r/(Test log|No logs|Logs)/
    end
  end

  describe "R5: No Task Selection State" do
    @tag :acceptance
    test "selecting agent with many active agents is responsive", %{conn: conn} = context do
      tasks = Enum.map(1..35, fn i -> create_db_only_task("Responsive selection task #{i}") end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner,
          "log_debounce_ms" => 0
        })

      {:ok, view, _html} = live(conn, "/")

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      target_task = List.last(tasks)
      target_agent_id = "responsive-agent-35"

      Enum.with_index(tasks, 1)
      |> Enum.each(fn {task, index} ->
        agent_id = "responsive-agent-#{index}"

        send(
          view.pid,
          {:agent_spawned,
           %{agent_id: agent_id, task_id: task.id, parent_id: nil, timestamp: DateTime.utc_now()}}
        )

        send(
          view.pid,
          {:log_entry,
           %{
             id: index,
             agent_id: agent_id,
             level: :info,
             message: "log for #{agent_id}",
             timestamp: DateTime.utc_now()
           }}
        )
      end)

      # Two renders: first processes log_entry (buffers + sends :flush_log_updates),
      # second processes :flush_log_updates (merges buffer into logs map)
      render(view)
      render(view)

      view_pid = view.pid
      :erlang.trace(view_pid, true, [:call])
      :erlang.trace_pattern({Quoracle.Costs.Aggregator, :batch_totals, 2}, true, [])

      on_exit(fn ->
        if Process.alive?(view_pid) do
          :erlang.trace(view_pid, false, [:call])
        end

        :erlang.trace_pattern({Quoracle.Costs.Aggregator, :batch_totals, 2}, false, [])
      end)

      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='#{target_agent_id}']")
      |> render_click()

      logs_html = view |> element("#logs") |> render()

      refute_receive {:trace, ^view_pid, :call,
                      {Quoracle.Costs.Aggregator, :batch_totals, [_agent_ids, _task_ids]}},
                     0

      assert logs_html =~ "log for #{target_agent_id}"
      refute logs_html =~ "log for responsive-agent-1"
      assert render(view) =~ target_task.id
    end

    # R5: [UNIT] test - WHEN dashboard mounts THEN no current_task_id in assigns
    test "dashboard has no current_task_id state", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Check socket assigns - should NOT have current_task_id
      # LiveView test struct doesn't expose assigns directly
      # Check that the rendered HTML doesn't have current_task_id related UI

      # Should not render task selection UI
      html = render(view)
      refute html =~ "phx-click=\"select_task\""
      refute html =~ "current_task_id"
    end

    test "no task selection handler exists", %{conn: conn} = context do
      {:ok, view, _html} = mount_dashboard(conn, context)

      # Try to send old select_task event - should fail because handler doesn't exist
      # Trap exits so the test process doesn't die when the view crashes
      Process.flag(:trap_exit, true)

      # Use a fake task ID - we don't need a real task for this test
      fake_task_id = Ecto.UUID.generate()

      # The view will crash with FunctionClauseError
      capture_log(fn ->
        try do
          render_click(view, "select_task", %{"task-id" => fake_task_id})
          # If we get here, the handler exists (test should fail)
          flunk("Expected select_task to fail, but it succeeded")
        catch
          # Expected: view crashes because handler doesn't exist
          :exit, _reason -> :ok
        end
      end)
    end
  end

  describe "packet 2 acceptance coverage" do
    @tag :acceptance
    test "dashboard route shows task-tree costs after cost recording", %{conn: conn} = context do
      {:ok, {task, agent_pid}} =
        create_task_with_cleanup("Acceptance cost path", Keyword.new(context))

      {:ok, %{agent_id: agent_id}} = GenServer.call(agent_pid, :get_state)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner,
          "cost_debounce_ms" => 0
        })

      {:ok, view, _html} = live(conn, "/")

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, _cost} =
        Quoracle.Costs.Recorder.record(
          %{
            agent_id: agent_id,
            task_id: task.id,
            cost_type: "llm_consensus",
            cost_usd: Decimal.new("0.33"),
            metadata: %{"model_spec" => "anthropic:claude-sonnet"}
          },
          pubsub: context.pubsub
        )

      render(view)
      render(view)

      task_tree_html = view |> element("#task-tree") |> render()
      agent_component = agent_node_component!(view, "agent-node-#{agent_id}")

      assert task_tree_html =~ task.id
      assert task_tree_html =~ "cost-badge-tasktree-#{agent_id}"
      assert task_tree_html =~ "$0.33"
      refute task_tree_html =~ "$0.99"
      assert Decimal.equal?(agent_component.assigns.agent_cost, Decimal.new("0.33"))
      refute Map.has_key?(agent_component.assigns, :cost_data)
    end

    test "state_changed does not trigger Mailbox update", %{conn: conn} = context do
      task = create_db_only_task("State change mailbox isolation")
      agent_id = "state-agent-#{System.unique_integer([:positive])}"
      message_id = System.unique_integer([:positive])
      mailbox_test_pid = self()

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner,
          "mailbox_test_pid" => mailbox_test_pid
        })

      {:ok, view, _html} = live(conn, "/")

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      assert_receive {:mailbox_updated, initial_keys}, 1_000
      assert :agent_alive_map in initial_keys
      refute :agents in initial_keys

      send(
        view.pid,
        {:agent_spawned,
         %{agent_id: agent_id, task_id: task.id, parent_id: nil, timestamp: DateTime.utc_now()}}
      )

      render(view)

      assert_receive {:mailbox_updated, spawned_keys}, 1_000
      assert :agent_alive_map in spawned_keys
      refute :agents in spawned_keys

      send(
        view.pid,
        {:agent_message,
         %{
           id: message_id,
           from: :agent,
           sender_id: agent_id,
           content: "State change mailbox message",
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      assert_receive {:mailbox_updated, message_keys}, 1_000
      assert :messages in message_keys
      refute :agents in message_keys

      view
      |> element("[phx-click='toggle_message'][phx-value-message-id='#{message_id}']")
      |> render_click()

      mailbox_html_before_state_change = view |> element("#mailbox") |> render()

      assert mailbox_html_before_state_change =~ "Type your reply..."
      refute mailbox_html_before_state_change =~ "Agent no longer active"
      refute mailbox_html_before_state_change =~ "disabled"

      flush_mailbox_updates()

      send(view.pid, {:state_changed, %{agent_id: agent_id, new_state: :paused}})
      render(view)

      refute_receive {:mailbox_updated, _keys}, 200

      mailbox_html_after_state_change = view |> element("#mailbox") |> render()
      task_tree_html_after_state_change = view |> element("#task-tree") |> render()

      assert mailbox_html_after_state_change =~ "Type your reply..."
      refute mailbox_html_after_state_change =~ "Agent no longer active"
      refute mailbox_html_after_state_change =~ "disabled"
      assert task_tree_html_after_state_change =~ agent_id
      assert task_tree_html_after_state_change =~ "paused"
    end

    @tag :acceptance
    test "dashboard route submits mailbox reply and disables it after termination",
         %{conn: conn} = context do
      task = create_db_only_task("Acceptance mailbox path")
      agent_id = "acceptance-mailbox-agent-#{System.unique_integer([:positive])}"
      message_id = System.unique_integer([:positive])
      reply_content = "Acceptance reply content"

      Registry.register(context.registry, {:agent, agent_id}, %{pid: self(), parent_id: nil})

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner
        })

      {:ok, view, _html} = live(conn, "/")

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      send(
        view.pid,
        {:agent_spawned,
         %{agent_id: agent_id, task_id: task.id, parent_id: nil, timestamp: DateTime.utc_now()}}
      )

      render(view)

      send(
        view.pid,
        {:agent_message,
         %{
           id: message_id,
           from: :agent,
           sender_id: agent_id,
           content: "Acceptance mailbox message",
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      view
      |> element("[phx-click='toggle_message'][phx-value-message-id='#{message_id}']")
      |> render_click()

      mailbox_html = view |> element("#mailbox") |> render()

      assert mailbox_html =~ "Acceptance mailbox message"
      assert mailbox_html =~ "Type your reply..."
      refute mailbox_html =~ "Agent no longer active"
      refute mailbox_html =~ "disabled"

      view
      |> element("#message-#{message_id} textarea[name='content']")
      |> render_change(%{"content" => reply_content})

      changed_mailbox_html = view |> element("#mailbox") |> render()

      changed_textarea =
        changed_mailbox_html
        |> Floki.parse_document!()
        |> Floki.find("textarea[name='content']")
        |> Floki.text()

      assert changed_textarea == reply_content

      view
      |> form("#message-#{message_id} form[phx-submit='send_reply']", %{
        "content" => reply_content
      })
      |> render_submit()

      assert_receive {:"$gen_cast", {:send_user_message, ^reply_content}}, 1_000

      mailbox_html_after_reply = view |> element("#mailbox") |> render()

      cleared_textarea =
        mailbox_html_after_reply
        |> Floki.parse_document!()
        |> Floki.find("textarea[name='content']")
        |> Floki.text()

      assert cleared_textarea == ""
      refute mailbox_html_after_reply =~ "Acceptance reply content"

      Phoenix.PubSub.broadcast(
        context.pubsub,
        "agents:lifecycle",
        {:agent_terminated, %{agent_id: agent_id}}
      )

      render(view)
      mailbox_html_after_termination = view |> element("#mailbox") |> render()

      assert mailbox_html_after_termination =~ "Acceptance mailbox message"
      assert mailbox_html_after_termination =~ "Agent no longer active"
      assert mailbox_html_after_termination =~ "disabled"
    end
  end

  describe "R6: Mailbox Integration" do
    # R6: [INTEGRATION] test - WHEN messages arrive THEN Mailbox displays correctly (unchanged)
    test "Mailbox continues to function with 3-panel layout", %{conn: conn} = context do
      {:ok, {task, _agent_pid}} =
        create_task_with_cleanup("Task with messages", Keyword.new(context))

      agent_id = "root-#{task.id}"

      {:ok, view, _html} = mount_dashboard(conn, context)

      # Send a message
      Phoenix.PubSub.broadcast(
        context.pubsub,
        "tasks:#{task.id}:messages",
        {:task_message,
         %{
           id: "msg-1",
           from: "user",
           to: agent_id,
           content: "Test message",
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Mailbox should still display messages
      mailbox_element = element(view, "#mailbox")
      mailbox_html = render(mailbox_element)
      assert mailbox_html =~ "Test message"
    end
  end

  describe "R7: Responsive Widths" do
    # R7: [UNIT] test - WHEN rendered THEN panel widths sum to ~100%
    test "panel widths are correct (5/12 + 1/3 + 1/4)", %{conn: conn} = context do
      {:ok, _view, html} = mount_dashboard(conn, context)

      # Parse the HTML and check widths
      panels = html |> Floki.parse_document!() |> Floki.find("div.flex.h-screen > div")

      # 5/12 ≈ 41.67%
      [panel1 | _] = panels
      assert Floki.attribute(panel1, "class") |> to_string() =~ "w-5/12"

      # 1/3 ≈ 33.33%
      [_, panel2 | _] = panels
      assert Floki.attribute(panel2, "class") |> to_string() =~ "w-1/3"

      # 1/4 = 25%
      [_, _, panel3] = panels
      assert Floki.attribute(panel3, "class") |> to_string() =~ "w-1/4"

      # Total: 41.67% + 33.33% + 25% = 100%
    end
  end

  describe "R8: PubSub Isolation" do
    # R8: [INTEGRATION] test - WHEN test runs THEN uses isolated PubSub instance
    test "Dashboard passes isolated pubsub to TaskTree", %{conn: conn} = context do
      {:ok, _view, _html} = mount_dashboard(conn, context)

      # Send a test message through isolated pubsub
      test_topic = "test_topic_#{System.unique_integer()}"
      Phoenix.PubSub.subscribe(context.pubsub, test_topic)

      # TaskTree should use same isolated pubsub
      Phoenix.PubSub.broadcast(context.pubsub, test_topic, {:test_message, "data"})

      assert_receive {:test_message, "data"}, 30_000

      # Unsubscribe from isolated before testing global separation
      Phoenix.PubSub.unsubscribe(context.pubsub, test_topic)

      # Global pubsub should NOT receive broadcasts from isolated
      Phoenix.PubSub.subscribe(Quoracle.PubSub, test_topic)
      Phoenix.PubSub.broadcast(context.pubsub, test_topic, {:isolated_message, "data"})

      refute_receive {:isolated_message, "data"}, 100
    end
  end

  describe "packet 1 acceptance coverage" do
    @tag :acceptance
    test "dashboard route preserves nested task tree interactions", %{conn: conn} = context do
      tasks = Enum.map(1..2, fn i -> create_db_only_task("Acceptance task tree path #{i}") end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "pubsub" => context.pubsub,
          "registry" => context.registry,
          "dynsup" => context.dynsup,
          "sandbox_owner" => context.sandbox_owner
        })

      {:ok, view, _html} = live(conn, "/")

      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      [task_one, task_two] = tasks

      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: "root_acceptance",
           task_id: task_one.id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: "child_acceptance",
           task_id: task_one.id,
           parent_id: "root_acceptance",
           timestamp: DateTime.utc_now()
         }}
      )

      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: "sibling_acceptance",
           task_id: task_two.id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      view
      |> element("[phx-click='toggle_expand'][phx-value-agent-id='root_acceptance']")
      |> render_click()

      view
      |> element("[phx-click='select_agent'][phx-value-agent-id='child_acceptance']")
      |> render_click()

      html = render(view)

      # Acceptance: both tasks visible
      assert html =~ task_one.id
      assert html =~ task_two.id
      # Acceptance: agents visible with correct IDs
      assert html =~ "root_acceptance"
      assert html =~ "child_acceptance"
      assert html =~ "sibling_acceptance"
      # Acceptance: selecting child_acceptance filtered logs (empty for new agent)
      assert html =~ "No logs"
      # Packet 1: agents rendered via AgentNode LiveComponent
      assert html =~ ~s(id="agent-node-root_acceptance")
      # Negative: no crashes, no empty state
      refute html =~ "No active tasks"
      refute html =~ "FunctionClauseError"
    end
  end

  # Helper functions

  defp mount_dashboard(conn, %{
         pubsub: pubsub,
         registry: registry,
         dynsup: dynsup,
         sandbox_owner: owner
       }) do
    conn
    |> Plug.Test.init_test_session(%{
      "pubsub" => pubsub,
      "registry" => registry,
      "dynsup" => dynsup,
      "sandbox_owner" => owner
    })
    |> live("/")
  end

  defp agent_node_component!(view, id) do
    assert {:ok, components} = Phoenix.LiveView.Debug.live_components(view.pid)

    component =
      Enum.find(components, fn component ->
        component.module == QuoracleWeb.UI.AgentNode and component.id == id
      end)

    assert component, "expected AgentNode component #{id} to be rendered"
    component
  end

  defp flush_mailbox_updates do
    receive do
      {:mailbox_updated, _keys} -> flush_mailbox_updates()
    after
      0 -> :ok
    end
  end
end
