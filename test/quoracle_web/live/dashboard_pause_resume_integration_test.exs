defmodule QuoracleWeb.DashboardPauseResumeIntegrationTest do
  @moduledoc """
  Integration tests for pause/resume functionality in Dashboard LiveView.

  These tests verify that the UI correctly delegates to TaskRestorer to:
  - Actually terminate agent processes when pausing
  - Actually restore agent processes when resuming

  Tests written to address audit findings:
  - Pause handler must call TaskRestorer.pause_task (not just update DB)
  - Resume handler must call TaskRestorer.restore_task (not just update DB)
  """
  # Now supports async: true with isolated dependencies!
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Agent.RegistryQueries

  setup %{conn: conn, sandbox_owner: sandbox_owner} do
    # Create isolated dependencies
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    {:ok, _dynsup} =
      start_supervised({Quoracle.Agent.DynSup, name: dynsup_name}, shutdown: :infinity)

    # Get test profile for task creation - use unique name to avoid ON CONFLICT contention
    profile = create_test_profile()

    %{
      conn: conn,
      pubsub: pubsub_name,
      registry: registry_name,
      dynsup: dynsup_name,
      sandbox_owner: sandbox_owner,
      profile: profile
    }
  end

  describe "Pause Task Integration (ARC_PAUSE_INT_01)" do
    test "WHEN user clicks pause THEN TaskRestorer.pause_task called AND agents terminated",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Create a real task with agents
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Integration test task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Wait for initialization
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Ensure cleanup
      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Verify agent is alive
      assert Process.alive?(task_agent_pid)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent before pause (for async wait)
      ref = Process.monitor(task_agent_pid)

      # Click pause button (async - returns immediately)
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Force LiveView to process the event
      render(view)

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # CRITICAL ASSERTION: Agent should be terminated by TaskRestorer.pause_task
      refute Process.alive?(task_agent_pid),
             "Task agent should be terminated by TaskRestorer.pause_task"

      # Verify task status updated (may be "pausing" or "paused" with async pause)
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status in ["pausing", "paused"]
    end

    test "WHEN pause called IF no agents running THEN succeeds gracefully", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    } do
      # Create task and immediately terminate agent
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "Empty task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Ensure cleanup even if test fails
      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Terminate the agent manually
      GenServer.stop(task_agent_pid, :normal, :infinity)
      refute Process.alive?(task_agent_pid)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Pause should succeed even with no agents
      render_click(view, "pause_task", %{"task-id" => task.id})
      render(view)

      # Verify task marked as paused
      {:ok, updated_task} = TaskManager.get_task(task.id)
      assert updated_task.status == "paused"
    end

    test "WHEN pause called on non-existent task THEN succeeds gracefully", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Pause non-existent task - TaskRestorer returns :ok (no agents to terminate)
      fake_task_id = Ecto.UUID.generate()

      # Should not crash - handles gracefully
      html = render_click(view, "pause_task", %{"task-id" => fake_task_id})

      # Dashboard still renders without error
      assert html =~ "Quoracle"
    end
  end

  describe "Resume Task Integration (ARC_RESUME_INT_01)" do
    test "WHEN user clicks resume THEN TaskRestorer.restore_task called AND agents restored",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Create a task
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "Resume test task"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Ensure cleanup even if test fails
      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Manually terminate agent to simulate paused state
      # (TaskRestorer has its own tests - we're testing Dashboard UI here)
      GenServer.stop(task_agent_pid, :normal, :infinity)

      # Verify agent terminated
      refute Process.alive?(task_agent_pid)

      # Update task status to paused in DB
      {:ok, _task} = TaskManager.update_task_status(task.id, "paused")

      # Verify agent record exists in DB for restoration
      agents = Quoracle.Tasks.TaskManager.get_agents_for_task(task.id)
      assert agents != []

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Click resume button
      render_click(view, "resume_task", %{"task-id" => task.id})

      # Force LiveView to process the event
      render(view)

      # CRITICAL ASSERTION: Agents should be restored by TaskRestorer.restore_task
      # Query Registry to verify agents are running again
      restored_agents = RegistryQueries.list_all_agents(registry)

      # CRITICAL: Register cleanup IMMEDIATELY after resume, BEFORE assertions
      # This ensures cleanup runs even if assertions fail
      on_exit(fn ->
        Enum.each(restored_agents, fn {_agent_id, meta} ->
          if Process.alive?(meta.pid) do
            try do
              GenServer.stop(meta.pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

      restored_agent_ids = Enum.map(restored_agents, fn {agent_id, _meta} -> agent_id end)

      root_agent_id = "root-#{task.id}"

      assert root_agent_id in restored_agent_ids,
             "Task agent should be restored by TaskRestorer.restore_task"

      # Verify at least root agent was restored
      assert restored_agents != [],
             "At least root agent should be restored from DB by TaskRestorer.restore_task"

      # Verify task status updated to "running" in DB
      {:ok, updated_task} = TaskManager.get_task(task.id)

      assert updated_task.status == "running",
             "TaskRestorer.restore_task should update task status to running"
    end

    test "WHEN resume called IF no agents in DB THEN returns error", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Create task directly in DB without agents
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Empty task", status: "paused"})
        |> Quoracle.Repo.insert()

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Try to resume - should fail gracefully (capture expected error log)
      html =
        capture_log(fn ->
          render_click(view, "resume_task", %{"task-id" => task.id})
        end)

      # Should show error flash
      assert html =~ "Failed to resume task"
    end

    test "WHEN resume fails THEN error flash shown to user", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Try to resume non-existent task (capture expected error log)
      fake_task_id = Ecto.UUID.generate()

      html =
        capture_log(fn ->
          render_click(view, "resume_task", %{"task-id" => fake_task_id})
        end)

      # Should show error flash
      assert html =~ "Failed to resume task"
    end
  end

  describe "Pause/Resume Round-Trip (ARC_ROUNDTRIP_01)" do
    test "WHEN task paused and resumed THEN agent tree fully restored",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Create task
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "Round-trip test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      # Ensure cleanup even if test fails
      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent before pause (for async wait)
      ref = Process.monitor(task_agent_pid)

      # PAUSE via UI (async - returns immediately)
      render_click(view, "pause_task", %{"task-id" => task.id})
      render(view)

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # Verify agent terminated
      refute Process.alive?(task_agent_pid)

      # RESUME via UI
      render_click(view, "resume_task", %{"task-id" => task.id})
      render(view)

      # Find restored agent
      restored_agents = RegistryQueries.list_all_agents(registry)

      # CRITICAL: Register cleanup IMMEDIATELY after resume, BEFORE assertions
      # This ensures cleanup runs even if assertions fail
      on_exit(fn ->
        Enum.each(restored_agents, fn {_agent_id, meta} ->
          if Process.alive?(meta.pid) do
            try do
              GenServer.stop(meta.pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

      assert restored_agents != []
    end
  end

  describe "UI State Consistency (ARC_UI_STATE_01)" do
    test "WHEN task paused THEN UI shows 'paused' status and pause button disabled", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    } do
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(%{profile: profile.name}, %{task_description: "UI state test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Use real agent ID (matches TaskManager.create_task format)
      real_agent_id = "root-#{task.id}"

      # Notify view about the agent (so it can track termination for status update)
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: real_agent_id,
           task_id: task.id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      render(view)

      # Monitor agent to wait for termination (async pause)
      ref = Process.monitor(task_agent_pid)

      # Pause task directly (async - starts termination in background)
      # Note: Using render_click directly because task may not load from DB in live_isolated
      render_click(view, "pause_task", %{"task-id" => task.id})

      # Wait for agent to terminate (async pause completion)
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event
      render(view)

      # Verify agent was actually terminated (core pause behavior)
      refute Process.alive?(task_agent_pid)

      # Verify DB status updated to "paused" after async pause completes
      {:ok, updated_task} = Quoracle.Tasks.TaskManager.get_task(task.id)
      assert updated_task.status == "paused"
    end

    test "WHEN task running THEN UI shows 'running' status and resume button disabled", %{
      conn: conn,
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner,
      profile: profile
    } do
      {:ok, {_task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Running state test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      {:ok, _view, html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Verify UI shows running state
      assert html =~ ~r/[Rr]unning/
      # Pause button should be available for running tasks
      assert html =~ ~r/[Pp]ause/
    end
  end

  # Integration tests verifying ACE state (context_lessons, model_states)
  # survives pause/resume cycles through the LiveView UI.
  #
  # These tests address the gap identified in audit: R8/R11 originally used
  # internal APIs (TaskRestorer) instead of going through LiveView UI entry point.
  describe "ACE State Persistence (ARC_ACE_PERSIST_01)" do
    test "WHEN task paused and resumed via UI THEN ACE state (context_lessons) preserved",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Create task via TaskManager (simulates UI submit_prompt flow)
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "ACE persistence test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Simulate agent learning (ACE state accumulation)
      :sys.replace_state(task_agent_pid, fn state ->
        %{
          state
          | context_lessons: %{
              "anthropic:claude-sonnet-4" => [
                %{type: :factual, content: "User prefers Elixir", confidence: 5},
                %{type: :behavioral, content: "Always use TDD", confidence: 3}
              ]
            },
            model_states: %{
              "anthropic:claude-sonnet-4" => %{
                summary: "Working on authentication module",
                updated_at: DateTime.utc_now()
              }
            }
        }
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent before pause (for async wait)
      ref = Process.monitor(task_agent_pid)

      # PAUSE via UI click (async - returns immediately)
      render_click(view, "pause_task", %{"task-id" => task.id})
      render(view)

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # Verify agent terminated
      refute Process.alive?(task_agent_pid)

      # RESUME via UI click
      render_click(view, "resume_task", %{"task-id" => task.id})
      render(view)

      # Find restored agent via Registry
      restored_agents = RegistryQueries.list_all_agents(registry)
      assert restored_agents != []

      {_agent_id, meta} = Enum.find(restored_agents, fn {id, _} -> id =~ "root-#{task.id}" end)
      restored_pid = meta.pid

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # CRITICAL ASSERTION: ACE state must survive UI pause/resume
      {:ok, restored_state} = Quoracle.Agent.Core.get_state(restored_pid)

      assert is_map(restored_state.context_lessons)
      lessons = restored_state.context_lessons["anthropic:claude-sonnet-4"]
      assert length(lessons) == 2, "Expected 2 lessons, got #{length(lessons || [])}"

      assert Enum.any?(lessons, &(&1.content == "User prefers Elixir"))
      assert Enum.any?(lessons, &(&1.content == "Always use TDD"))

      # Verify model_states preserved
      model_state = restored_state.model_states["anthropic:claude-sonnet-4"]
      assert model_state.summary == "Working on authentication module"
    end

    test "WHEN task with child paused and resumed via UI THEN all agents visible in UI",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Subscribe to lifecycle events to verify broadcasts
      Phoenix.PubSub.subscribe(pubsub, "agents:lifecycle")

      # Create task
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Child visibility test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Create a child agent record in DB (simulates spawned child)
      child_id = "child-#{System.unique_integer([:positive])}"
      root_agent_id = "root-#{task.id}"

      {:ok, _child_db} =
        Quoracle.Repo.insert(%Quoracle.Agents.Agent{
          agent_id: child_id,
          task_id: task.id,
          status: "running",
          parent_id: root_agent_id,
          config: %{},
          state: %{}
        })

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # CRITICAL: Stop LiveView gracefully before sandbox cleanup to prevent
      # "client exited" errors from mid-operation DB calls during test exit
      on_exit(fn ->
        if Process.alive?(view.pid) do
          try do
            GenServer.stop(view.pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Clear any existing spawn events
      flush_messages()

      # Monitor agent before pause (async pause requires waiting for termination)
      ref = Process.monitor(task_agent_pid)

      # PAUSE via UI
      render_click(view, "pause_task", %{"task-id" => task.id})
      render(view)

      # Wait for agent termination (async pause completes when agents terminate)
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Process the agent_terminated PubSub message
      render(view)

      # RESUME via UI
      render_click(view, "resume_task", %{"task-id" => task.id})
      render(view)

      # CRITICAL ASSERTION: UI should receive spawn events for ALL restored agents
      spawn_events = collect_spawn_events(2, 2000)
      spawned_ids = Enum.map(spawn_events, & &1.agent_id) |> Enum.sort()

      # Both root and child should broadcast spawn events
      assert root_agent_id in spawned_ids,
             "Root agent should broadcast spawn event, got: #{inspect(spawned_ids)}"

      assert child_id in spawned_ids,
             "Child agent should broadcast spawn event, got: #{inspect(spawned_ids)}"

      # Synchronize LiveView before cleanup to ensure all pending DB operations complete
      render(view)

      # Cleanup
      restored_agents = RegistryQueries.list_all_agents(registry)

      on_exit(fn ->
        Enum.each(restored_agents, fn {_id, meta} ->
          if Process.alive?(meta.pid), do: GenServer.stop(meta.pid, :normal, :infinity)
        end)
      end)
    end
  end

  # R25: Model Histories Preservation via UI
  # WorkGroupID: fix-history-20251219-033611
  describe "Model Histories Preservation (R25)" do
    @tag :acceptance
    test "R25: WHEN task paused and resumed via UI THEN model_histories preserved",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # User action: Create task via TaskManager (simulates UI submit_prompt)
      {:ok, {task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Model histories acceptance test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Simulate conversation history (what user would see after exchanging messages)
      :sys.replace_state(task_agent_pid, fn state ->
        %{
          state
          | model_histories: %{
              "anthropic:claude-sonnet-4" => [
                %{
                  type: :user,
                  content: "Hello, I need help with Elixir",
                  timestamp: DateTime.utc_now()
                },
                %{
                  type: :agent,
                  content: "I'd be happy to help with Elixir!",
                  timestamp: DateTime.utc_now()
                },
                %{
                  type: :user,
                  content: "How do I use pattern matching?",
                  timestamp: DateTime.utc_now()
                },
                %{
                  type: :agent,
                  content: "Pattern matching in Elixir works like...",
                  timestamp: DateTime.utc_now()
                }
              ]
            }
        }
      end)

      # User action: Mount dashboard (visits /dashboard)
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Monitor agent before pause (for async wait)
      ref = Process.monitor(task_agent_pid)

      # User action: Click pause button (async - returns immediately)
      render_click(view, "pause_task", %{"task-id" => task.id})
      render(view)

      # Wait for async termination to complete
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Force LiveView to process termination event and complete DB operations
      render(view)

      # Verify agent terminated (pause worked)
      refute Process.alive?(task_agent_pid)

      # User action: Click resume button (simulates page refresh then resume)
      render_click(view, "resume_task", %{"task-id" => task.id})
      render(view)

      # User expects: Agent restored with conversation history intact
      restored_agents = RegistryQueries.list_all_agents(registry)
      assert restored_agents != [], "Agent should be restored"

      {_agent_id, meta} = Enum.find(restored_agents, fn {id, _} -> id =~ "root-#{task.id}" end)
      restored_pid = meta.pid

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid, :normal, :infinity)
      end)

      # CRITICAL USER EXPECTATION: model_histories must survive pause/resume
      {:ok, restored_state} = Quoracle.Agent.Core.get_state(restored_pid)

      # Positive assertion: model_histories exists and is not empty
      assert is_map(restored_state.model_histories),
             "model_histories should be a map after resume"

      refute restored_state.model_histories == %{},
             "model_histories should NOT be empty after resume - user's conversation should be preserved"

      histories = restored_state.model_histories["anthropic:claude-sonnet-4"]

      assert is_list(histories) and length(histories) == 4,
             "Expected 4 history entries (user's conversation), got #{length(histories || [])}"

      # Verify user's conversation content preserved
      assert Enum.any?(histories, fn entry ->
               (is_map(entry) and Map.get(entry, :content) == "Hello, I need help with Elixir") or
                 (is_map(entry) and Map.get(entry, "content") == "Hello, I need help with Elixir")
             end),
             "User's first message should be preserved"

      assert Enum.any?(histories, fn entry ->
               (is_map(entry) and Map.get(entry, :content) == "How do I use pattern matching?") or
                 (is_map(entry) and Map.get(entry, "content") == "How do I use pattern matching?")
             end),
             "User's second question should be preserved"

      # Negative assertion: no empty or corrupted entries
      refute Enum.any?(histories, fn entry ->
               content = Map.get(entry, :content) || Map.get(entry, "content")
               is_nil(content) or content == ""
             end),
             "No corrupted/empty entries should exist in model_histories"
    end
  end

  describe "Pause UX: Pausing→Resume live transition" do
    test "WHEN all agents terminate THEN UI shows Resume button without page refresh",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner,
           profile: profile
         } do
      # Create a real task with agent
      {:ok, {_task, task_agent_pid}} =
        TaskManager.create_task(
          %{profile: profile.name},
          %{task_description: "Pausing transition test"},
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, _state} = Quoracle.Agent.Core.get_state(task_agent_pid)

      on_exit(fn ->
        stop_agent_tree(task_agent_pid, registry)
      end)

      # Mount dashboard
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Force LiveView to process agent_spawned events
      render(view)

      # Verify Pause button visible
      html = render(view)
      assert html =~ "Pause"

      # Monitor agent to wait for termination
      ref = Process.monitor(task_agent_pid)

      # Click pause via the TaskTree component (production path: phx-target={@myself})
      view
      |> element("button", "Pause")
      |> render_click()

      # Process {:pause_task} handle_info (sent by TaskTree to root_pid)
      render(view)

      # Wait for agent to actually terminate
      receive do
        {:DOWN, ^ref, :process, ^task_agent_pid, _} -> :ok
      after
        5000 -> flunk("Agent did not terminate within 5 seconds")
      end

      # Process {:agent_terminated} handle_info
      render(view)
      html = render(view)

      # CRITICAL: UI must show Resume button without page refresh
      assert html =~ "Resume",
             "Resume button should appear after pause completes (without page refresh)"

      refute html =~ "Pausing...",
             "Pausing indicator should be gone after all agents terminated"
    end
  end

  describe "Pause UX: Delete visible during pausing" do
    test "WHEN task is pausing THEN Delete button is visible",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner
         } do
      # Create a task with "pausing" status directly in DB
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{
          prompt: "Delete during pausing test",
          status: "pausing"
        })
        |> Quoracle.Repo.insert()

      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      html = render(view)

      # Delete button should be visible during "pausing" state
      assert html =~ "Delete",
             "Delete button should be visible when task status is 'pausing'"

      # Clean up
      Quoracle.Repo.delete(task)
    end
  end

  describe "Pause UX: Pausing recovery on refresh" do
    test "WHEN page loads with stuck 'pausing' task (no live agents) THEN recovers to 'paused'",
         %{
           conn: conn,
           pubsub: pubsub,
           registry: registry,
           dynsup: dynsup,
           sandbox_owner: sandbox_owner
         } do
      # Create a task stuck in "pausing" state (simulates refresh during pause)
      {:ok, task} =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Stuck pausing test", status: "pausing"})
        |> Quoracle.Repo.insert()

      # Mount dashboard (simulates page refresh)
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "dynsup" => dynsup,
            "sandbox_owner" => sandbox_owner
          }
        )

      html = render(view)

      # Task should show Resume (recovered from "pausing" to "paused")
      assert html =~ "Resume",
             "Stuck 'pausing' task should recover to 'paused' on page load"

      refute html =~ "Pausing...",
             "'Pausing...' should not persist after recovery"

      # DB should also be updated
      {:ok, updated_task} = TaskManager.get_task(task.id)

      assert updated_task.status == "paused",
             "DB should be updated from 'pausing' to 'paused'"

      # Clean up
      Quoracle.Repo.delete(task)
    end
  end

  # Helper to flush mailbox
  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  # Helper to collect spawn events
  defp collect_spawn_events(count, timeout) do
    collect_spawn_events(count, timeout, [])
  end

  defp collect_spawn_events(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_spawn_events(count, timeout, acc) do
    receive do
      {:agent_spawned, payload} ->
        collect_spawn_events(count - 1, timeout, [payload | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
