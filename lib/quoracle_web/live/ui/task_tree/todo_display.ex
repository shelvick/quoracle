defmodule QuoracleWeb.UI.TaskTree.TodoDisplay do
  @moduledoc """
  TODO list display component for TaskTree.
  Extracted to keep TaskTree module under 500 lines.
  """

  use Phoenix.Component
  import QuoracleWeb.UI.TaskTree.Helpers, only: [state_icon: 1, todo_state_class: 1]

  @doc """
  Renders agent TODO list with state icons and styling.
  """
  attr(:agent, :map, required: true)

  def render(assigns) do
    ~H"""
    <%= if @agent[:todos] do %>
      <div class="todos-section ml-4 mt-2 p-2 bg-gray-50 rounded">
        <h4 class="text-xs font-semibold text-gray-600 mb-1">TODOs</h4>
        <%= if Enum.empty?(@agent[:todos]) do %>
          <p class="text-xs text-gray-400">No current tasks</p>
        <% else %>
          <ul class="space-y-1">
            <%= for todo <- @agent[:todos] do %>
              <li class={"todo-item text-xs flex items-start gap-2 #{todo_state_class(todo[:state])}"}>
                <span class="state-badge"><%= state_icon(todo[:state]) %></span>
                <span class="flex-1"><%= todo[:content] %></span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    <% end %>
    """
  end
end
