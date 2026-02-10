defmodule QuoracleWeb.UI.LogView do
  @moduledoc """
  Live component for displaying agent logs with filtering and auto-scroll.
  Supports severity filtering, agent filtering, and metadata expansion.
  """

  use QuoracleWeb, :live_component

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok,
     assign(socket,
       logs: [],
       expanded_logs: MapSet.new(),
       auto_scroll: true,
       min_level: :debug,
       agent_id: nil
     )}
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    # Simple pure component - just assign the data from parent
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:min_level, fn -> :info end)
      |> assign_new(:auto_scroll, fn -> true end)
      |> assign_new(:expanded_logs, fn -> MapSet.new() end)

    {:ok, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="logs" data-agent-id={@agent_id} class="log-view h-full flex flex-col">
      <div class="log-controls mb-4 flex justify-between items-center">
        <div class="level-filters flex gap-2">
          <button
            phx-click="set_min_level"
            phx-value-level="debug"
            phx-target={@myself}
            class={"px-2 py-1 rounded text-sm #{if @min_level == :debug, do: "bg-blue-500 text-white", else: "bg-gray-200"}"}
          >
            Debug
          </button>
          <button
            phx-click="set_min_level"
            phx-value-level="info"
            phx-target={@myself}
            class={"px-2 py-1 rounded text-sm #{if @min_level == :info, do: "bg-blue-500 text-white", else: "bg-gray-200"}"}
          >
            Info
          </button>
          <button
            phx-click="set_min_level"
            phx-value-level="warn"
            phx-target={@myself}
            class={"px-2 py-1 rounded text-sm #{if @min_level == :warn, do: "bg-yellow-500 text-white", else: "bg-gray-200"}"}
          >
            Warn
          </button>
          <button
            phx-click="set_min_level"
            phx-value-level="error"
            phx-target={@myself}
            class={"px-2 py-1 rounded text-sm #{if @min_level == :error, do: "bg-red-500 text-white", else: "bg-gray-200"}"}
          >
            Error
          </button>
        </div>
        
        <div class="log-actions flex gap-2">
          <button
            phx-click="toggle_auto_scroll"
            phx-target={@myself}
            class={"px-2 py-1 rounded text-sm #{if @auto_scroll, do: "bg-green-500 text-white", else: "bg-gray-200"}"}
          >
            Auto-scroll
          </button>
          <button
            phx-click="clear_logs"
            phx-target={@myself}
            class="px-2 py-1 bg-red-500 text-white rounded text-sm"
          >
            Clear
          </button>
        </div>
      </div>
      
      <div class="log-container overflow-y-auto flex-1" data-virtualized={length(@logs) > 100}>
        <%= if @logs == [] do %>
          <p class="text-gray-500">No logs</p>
        <% else %>
          <%= for log <- filtered_logs(@logs, @min_level, @agent_id) |> Enum.take(-100) do %>
            <% log_id = log_identifier(log) %>
            <.live_component
              module={QuoracleWeb.UI.LogEntry}
              id={"log-#{log_id}"}
              log={Map.put(log, :id, log_id)}
              expanded={MapSet.member?(@expanded_logs, log_id)}
              target={@myself}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Sets the minimum log level to display.
  """
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("set_min_level", %{"level" => level}, socket) do
    level_atom =
      case level do
        "debug" -> :debug
        "info" -> :info
        "warn" -> :warn
        "error" -> :error
        _ -> :debug
      end

    {:noreply, assign(socket, min_level: level_atom)}
  end

  @impl true
  def handle_event("toggle_level", %{"level" => _level}, socket) do
    # Toggle visibility of specific level
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_auto_scroll", _params, socket) do
    {:noreply, assign(socket, auto_scroll: !socket.assigns.auto_scroll)}
  end

  @impl true
  def handle_event("clear_logs", _params, socket) do
    {:noreply, assign(socket, logs: [])}
  end

  @impl true
  def handle_event("toggle_metadata", %{"log-id" => log_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_logs, log_id) do
        MapSet.delete(socket.assigns.expanded_logs, log_id)
      else
        MapSet.put(socket.assigns.expanded_logs, log_id)
      end

    {:noreply, assign(socket, expanded_logs: expanded)}
  end

  @impl true
  def handle_event("copy_log", %{"log-id" => log_id}, socket) do
    case find_log_by_id(socket.assigns.logs, log_id) do
      nil ->
        {:noreply, socket}

      log ->
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: log[:message]})}
    end
  end

  @impl true
  def handle_event("copy_full", %{"log-id" => log_id}, socket) do
    case find_log_by_id(socket.assigns.logs, log_id) do
      nil ->
        {:noreply, socket}

      log ->
        text = "#{log[:level]}: #{log[:message]}\nMetadata: #{inspect(log[:metadata])}"
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
    end
  end

  # Private functions

  defp filtered_logs(logs, min_level, _agent_id) do
    # Only filter by level - agent filtering is done by parent Dashboard
    filter_by_level(logs, min_level)
  end

  defp filter_by_level(logs, min_level) do
    level_order = %{debug: 0, info: 1, warn: 2, error: 3}
    min_order = Map.get(level_order, min_level, 0)

    Enum.filter(logs, fn log ->
      log_order = Map.get(level_order, log[:level], 0)
      log_order >= min_order
    end)
  end

  # Generate a stable identifier for a log entry.
  # Uses existing :id if present, otherwise creates hash from timestamp + message.
  defp log_identifier(log) do
    case log[:id] do
      nil ->
        # Create stable ID from timestamp and message
        ts = log[:timestamp] |> to_string()
        msg = log[:message] |> to_string() |> String.slice(0, 50)
        :erlang.phash2({ts, msg}) |> to_string()

      id ->
        to_string(id)
    end
  end

  # Find a log by its generated identifier
  defp find_log_by_id(logs, target_id) do
    Enum.find(logs, fn log -> log_identifier(log) == target_id end)
  end
end
