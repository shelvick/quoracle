defmodule QuoracleWeb.DashboardLive.EventHandlers do
  @moduledoc """
  Handles user events for the Dashboard LiveView.
  Extracted from DashboardLive to reduce module size below 500 lines.
  """

  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket
  alias QuoracleWeb.DashboardLive.Subscriptions

  @doc """
  Handles prompt submission to spawn a new root agent for a task.
  Accepts hierarchical prompt fields (task_description is primary field).
  Uses TASK_Manager to create task and spawn root agent.
  """
  @spec handle_submit_prompt(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_submit_prompt(params, socket) do
    # Process and validate form params using FieldProcessor
    case Quoracle.Tasks.FieldProcessor.process_form_params(params) do
      {:ok, %{task_fields: task_fields, agent_fields: agent_fields}} ->
        # Use TASK_Manager to create task and spawn root agent
        # Pass all dependencies for test isolation
        opts =
          []
          |> maybe_add_opt(:sandbox_owner, socket.assigns[:sandbox_owner])
          |> maybe_add_opt(:dynsup, socket.assigns[:dynsup])
          |> maybe_add_opt(:registry, socket.assigns[:registry])
          |> maybe_add_opt(:pubsub, socket.assigns[:pubsub])

        case Quoracle.Tasks.TaskManager.create_task(task_fields, agent_fields, opts) do
          {:ok, {task, root_pid}} ->
            # Task saved to DB, root agent spawned and persisting
            # Will receive agent_spawned event for UI update

            # Add task to local state (root_agent_id follows pattern: root-{task.id})
            root_agent_id = "root-#{task.id}"

            task_entry = %{
              id: task.id,
              prompt: task.prompt,
              status: "running",
              live: true,
              result: nil,
              error_message: nil,
              inserted_at: task.inserted_at,
              updated_at: task.updated_at,
              budget_limit: task.budget_limit,
              root_agent_id: root_agent_id
            }

            updated_tasks = Map.put(socket.assigns.tasks, task.id, task_entry)

            # Subscribe to task messages and costs
            socket = Subscriptions.safe_subscribe(socket, "tasks:#{task.id}:messages")
            socket = Subscriptions.safe_subscribe(socket, "tasks:#{task.id}:costs")

            # Send explicit message to agent (use task_description)
            prompt = Map.get(agent_fields, :task_description, "")
            Quoracle.Agent.Core.send_user_message(root_pid, prompt)

            {:noreply, Phoenix.Component.assign(socket, tasks: updated_tasks)}

          {:error, :profile_required} ->
            {:noreply, LiveView.put_flash(socket, :error, "Missing required field: profile")}

          {:error, :profile_not_found} ->
            {:noreply, LiveView.put_flash(socket, :error, "Profile not found")}

          {:error, {:skill_not_found, name}} ->
            {:noreply, LiveView.put_flash(socket, :error, "Skill '#{name}' not found")}

          {:error, reason} ->
            {:noreply,
             LiveView.put_flash(socket, :error, "Failed to create task: #{inspect(reason)}")}
        end

      {:error, {:missing_required, fields}} ->
        field_names = Enum.map(fields, &Atom.to_string/1)
        error_msg = "Missing required field: #{Enum.join(field_names, ", ")}"
        {:noreply, LiveView.put_flash(socket, :error, error_msg)}

      {:error, {:invalid_enum, field, _value, allowed}} ->
        field_str = Atom.to_string(field)
        allowed_str = Enum.join(allowed, ", ")
        error_msg = "Invalid value for #{field_str}. Valid options: #{allowed_str}"
        {:noreply, LiveView.put_flash(socket, :error, error_msg)}

      {:error, :invalid_budget_format} ->
        {:noreply, LiveView.put_flash(socket, :error, "Invalid budget format")}

      {:error, reason} ->
        {:noreply, LiveView.put_flash(socket, :error, "Validation failed: #{inspect(reason)}")}
    end
  end

  @doc """
  Handles agent selection from the UI.
  """
  @spec handle_select_agent(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_select_agent(%{"agent-id" => agent_id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, selected_agent_id: agent_id)}
  end

  @doc """
  Handles delete agent request.
  """
  @spec handle_delete_agent(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_delete_agent(%{"agent-id" => agent_id}, socket) do
    # Handle delete agent button click
    send(self(), {:delete_agent, agent_id})
    {:noreply, socket}
  end

  @doc """
  Handles pause task request.
  Delegates to TASK_Restorer to terminate all agents for this task.
  TaskRestorer sets status to "pausing" immediately (async pause).
  MessageHandlers will update to "paused" when all agents terminate.
  """
  @spec handle_pause_task(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_pause_task(%{"task-id" => task_id}, socket) do
    # Delegate to TASK_Restorer to terminate all agents for this task
    # TaskRestorer sets status to "pausing" immediately and spawns async terminations
    case Quoracle.Tasks.TaskRestorer.pause_task(task_id,
           registry: socket.assigns.registry,
           dynsup: socket.assigns.dynsup
         ) do
      :ok ->
        # Update local state to "pausing" (not "paused" - that happens after terminations)
        # TaskRestorer already set DB to "pausing"
        updated_tasks =
          if Map.has_key?(socket.assigns.tasks, task_id) do
            Map.update!(socket.assigns.tasks, task_id, fn task ->
              %{task | status: "pausing"}
            end)
          else
            socket.assigns.tasks
          end

        {:noreply, Phoenix.Component.assign(socket, tasks: updated_tasks)}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to pause task #{task_id}: #{inspect(reason)}")
        {:noreply, LiveView.put_flash(socket, :error, "Failed to pause task: #{inspect(reason)}")}
    end
  end

  @doc """
  Handles resume task request.
  Delegates to TASK_Restorer to restore agent tree from database.
  """
  @spec handle_resume_task(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_resume_task(%{"task-id" => task_id}, socket) do
    # Delegate to TASK_Restorer to restore agent tree from database
    case Quoracle.Tasks.TaskRestorer.restore_task(
           task_id,
           socket.assigns.registry,
           socket.assigns.pubsub,
           dynsup: socket.assigns.dynsup,
           sandbox_owner: socket.assigns[:sandbox_owner]
         ) do
      {:ok, _root_pid} ->
        # TaskRestorer.handle_restore_result already sets task status to "running" in DB
        # Update local state if task exists (agents will be added via spawn events)
        updated_tasks =
          if Map.has_key?(socket.assigns.tasks, task_id) do
            Map.update!(socket.assigns.tasks, task_id, fn task ->
              %{task | status: "running", live: true}
            end)
          else
            socket.assigns.tasks
          end

        {:noreply, Phoenix.Component.assign(socket, tasks: updated_tasks)}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to resume task #{task_id}: #{inspect(reason)}")

        {:noreply,
         LiveView.put_flash(socket, :error, "Failed to resume task: #{inspect(reason)}")}
    end
  end

  @doc """
  Handles delete task request.
  Delegates to TaskManager.delete_task which auto-pauses if running, then deletes.
  """
  @spec handle_delete_task(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_delete_task(%{"task-id" => task_id}, socket) do
    opts = [
      registry: socket.assigns.registry,
      dynsup: socket.assigns.dynsup
    ]

    case Quoracle.Tasks.TaskManager.delete_task(task_id, opts) do
      {:ok, _deleted_task} ->
        # Remove task from local state
        updated_socket = Phoenix.Component.update(socket, :tasks, &Map.delete(&1, task_id))

        {:noreply, LiveView.put_flash(updated_socket, :info, "Task deleted successfully")}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to delete task #{task_id}: #{inspect(reason)}")
        {:noreply, LiveView.put_flash(socket, :error, "Failed to delete task")}
    end
  end

  @doc """
  Handles show_budget_editor message from TaskTree (R45).
  Populates budget editor state with task data.
  Falls back to DB lookup if task not in local state.
  """
  @spec handle_show_budget_editor(String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_show_budget_editor(task_id, socket) do
    # Look up task in local state, or fetch from DB if not present
    task =
      case Map.get(socket.assigns.tasks, task_id) do
        nil ->
          case Quoracle.Tasks.TaskManager.get_task(task_id) do
            {:ok, db_task} -> %{budget_limit: db_task.budget_limit}
            _ -> nil
          end

        t ->
          t
      end

    current_budget = task && task[:budget_limit]
    cost_summary = Quoracle.Costs.Aggregator.by_task(task_id)
    current_spent = cost_summary.total_cost || Decimal.new(0)

    {:noreply,
     Phoenix.Component.assign(socket,
       budget_editor_visible: true,
       budget_editor_task_id: task_id,
       budget_editor_current: current_budget,
       budget_editor_spent: current_spent
     )}
  end

  @doc """
  Handles budget edit submission (R46, R47, R48).
  Validates budget >= spent, updates task, notifies agent.
  """
  @spec handle_submit_budget_edit(map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_submit_budget_edit(params, socket) do
    task_id = params["task_id"]
    new_budget_str = params["new_budget"]

    case parse_and_validate_budget(new_budget_str, socket.assigns.budget_editor_spent) do
      {:ok, new_budget} ->
        case Quoracle.Tasks.TaskManager.update_task_budget(task_id, new_budget) do
          {:ok, _task} ->
            # Update local state
            updated_tasks =
              Map.update!(socket.assigns.tasks, task_id, fn task ->
                Map.put(task, :budget_limit, new_budget)
              end)

            # Notify root agent (R48)
            notify_root_agent_budget_change(task_id, new_budget, socket.assigns)

            {:noreply,
             socket
             |> Phoenix.Component.assign(tasks: updated_tasks, budget_editor_visible: false)
             |> LiveView.put_flash(:info, "Budget updated")}

          {:error, reason} ->
            {:noreply, LiveView.put_flash(socket, :error, "Failed: #{inspect(reason)}")}
        end

      {:error, :below_spent} ->
        {:noreply, LiveView.put_flash(socket, :error, "Budget cannot be less than spent amount")}

      {:error, :invalid_format} ->
        {:noreply, LiveView.put_flash(socket, :error, "Invalid budget format")}
    end
  end

  @doc """
  Handles cancel budget edit (R49).
  Hides editor without changes.
  """
  @spec handle_cancel_budget_edit(Socket.t()) :: {:noreply, Socket.t()}
  def handle_cancel_budget_edit(socket) do
    {:noreply, Phoenix.Component.assign(socket, budget_editor_visible: false)}
  end

  @doc """
  Catch-all for events that should be handled by child components.
  These are here to prevent crashes if events bubble up unexpectedly.
  """
  @spec handle_child_component_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_child_component_event(event, _params, socket)
      when event in [
             "toggle_metadata",
             "copy_log",
             "copy_full",
             "send_message",
             "toggle_expand",
             "set_min_level",
             "toggle_autoscroll",
             "clear_logs"
           ] do
    # These events should be handled by their respective child components
    # (LogEntry, LogView, Mailbox, TaskTree) via phx-target={@myself}
    {:noreply, socket}
  end

  # Private helper for building opts list
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Budget editor helpers
  defp parse_and_validate_budget(budget_str, spent) do
    case Decimal.parse(budget_str) do
      {budget, ""} ->
        if Decimal.compare(budget, spent) == :lt do
          {:error, :below_spent}
        else
          {:ok, budget}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp notify_root_agent_budget_change(task_id, new_budget, assigns) do
    alias Quoracle.Agent.Core

    registry = assigns[:registry] || Quoracle.AgentRegistry

    # Get root_agent_id from socket assigns (Task schema doesn't have this field)
    task_data = Map.get(assigns[:tasks] || %{}, task_id, %{})
    root_agent_id = task_data[:root_agent_id]

    with root_agent_id when not is_nil(root_agent_id) <- root_agent_id,
         [{pid, _}] <- Registry.lookup(registry, {:agent, root_agent_id}),
         {:ok, state} <- Core.get_state(pid) do
      # Update budget_data with new allocated amount, preserving committed
      new_budget_data = %{
        state.budget_data
        | allocated: new_budget
      }

      Core.update_budget_data(pid, new_budget_data)
    end
  end
end
