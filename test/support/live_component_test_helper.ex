defmodule QuoracleWeb.LiveComponentTestHelper do
  @moduledoc """
  Helper module for testing LiveView components in isolation.
  Creates a minimal LiveView wrapper for component testing.
  """

  use Phoenix.LiveView

  @doc """
  Mounts a LiveView that renders only the specified component.

  CRITICAL: When testing components that make DB queries (like CostDisplay),
  pass "sandbox_owner" in session to grant sandbox access to this LiveView process.
  Without this, DB queries will fail with "client exited" errors.
  """
  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, %{"component" => component, "assigns" => assigns} = session, socket) do
    # Grant sandbox access for components that make DB queries (e.g., CostDisplay)
    # Matches DashboardLive pattern - prevents "client exited" errors
    sandbox_owner = session["sandbox_owner"] || session[:sandbox_owner]

    if sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    {:ok,
     socket
     |> assign(:component, component)
     |> assign(:component_assigns, assigns)
     |> assign(Map.merge(%{}, assigns))}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id="test-wrapper">
      <.live_component
        module={@component}
        id={@component_assigns[:id] || "test-component"}
        {@component_assigns}
      />
    </div>
    """
  end

  @impl true
  @spec handle_info(any(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:render_log_entry, log}, socket) do
    {:noreply, assign(socket, :logs, [log])}
  end

  def handle_info({:render_message, message}, socket) do
    {:noreply, assign(socket, :messages, [message])}
  end

  def handle_info({:render_agent_node, agent}, socket) do
    agent_id = agent[:agent_id] || agent[:id]
    {:noreply, assign(socket, :agents, %{agent_id => agent})}
  end

  def handle_info({:set_logs, logs}, socket) do
    {:noreply, assign(socket, :logs, logs)}
  end

  def handle_info({:set_messages, messages}, socket) do
    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:set_agents, agents}, socket) do
    {:noreply, assign(socket, :agents, agents)}
  end

  def handle_info({:update_component, new_assigns}, socket) do
    # Merge new assigns into component_assigns to trigger component re-render
    updated_assigns = Map.merge(socket.assigns.component_assigns, new_assigns)

    {:noreply,
     socket
     |> assign(:component_assigns, updated_assigns)
     |> assign(Map.merge(%{}, new_assigns))}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(_event, _params, socket) do
    # Pass through all events - components handle their own
    {:noreply, socket}
  end
end
