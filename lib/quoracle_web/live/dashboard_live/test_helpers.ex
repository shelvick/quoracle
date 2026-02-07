defmodule QuoracleWeb.DashboardLive.TestHelpers do
  @moduledoc """
  Test support functions for DashboardLive.
  Handles test-specific messages for component rendering.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]

  @spec handle_render_log_entry(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_render_log_entry(log, socket) do
    {:noreply, update(socket, :logs, fn _ -> [log] end)}
  end

  @spec handle_render_message(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_render_message(message, socket) do
    {:noreply, update(socket, :messages, fn _ -> [message] end)}
  end

  @spec handle_render_agent_node(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_render_agent_node(agent, socket) do
    agent_id = agent[:agent_id] || agent[:id]
    {:noreply, assign(socket, agents: %{agent_id => agent})}
  end

  @spec handle_set_messages(list(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_messages(messages, socket) do
    {:noreply, assign(socket, messages: messages)}
  end

  @spec handle_set_logs(map() | list(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_logs(logs, socket) do
    {:noreply, assign(socket, logs: logs)}
  end

  @spec handle_set_agents(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_agents(agents, socket) do
    {:noreply, assign(socket, agents: agents)}
  end

  @spec handle_send_message(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_send_message(message, socket) do
    {:noreply, update(socket, :messages, &(&1 ++ [message]))}
  end
end
