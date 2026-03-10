defmodule QuoracleWeb.UI.GroveSelector do
  @moduledoc """
  Phoenix function component that renders a grove selection dropdown.
  When a grove is selected, it triggers a phx-change event that the parent
  TaskTree handles to resolve bootstrap fields and push_event to JS hook.
  """

  use Phoenix.Component

  attr(:groves, :list,
    required: true,
    doc: "List of grove_metadata maps from GROVE_Loader.list_groves/1"
  )

  attr(:selected, :string, default: nil, doc: "Currently selected grove name")
  attr(:name, :string, default: "grove", doc: "Form field name")
  attr(:target, :any, default: nil, doc: "phx-target for the change event")

  @doc """
  Renders a grove selection dropdown with label and help text.
  """
  @spec grove_dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  def grove_dropdown(assigns) do
    ~H"""
    <div class="grove-selector mb-4">
      <label for="grove-select" class="block text-sm font-medium text-gray-700 mb-1">Start from Grove</label>
      <select
        id="grove-select"
        name={@name}
        phx-change="grove_selected"
        phx-target={@target}
        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 text-sm"
      >
        <option value="">No grove (blank form)</option>
        <%= for grove <- @groves do %>
          <option value={grove.name} selected={grove.name == @selected}>
            <%= grove.name %> — <%= grove.description %>
          </option>
        <% end %>
      </select>
      <p class="text-xs text-gray-500 mt-1">
        Select a grove to pre-fill the form with its bootstrap configuration.
      </p>
    </div>
    """
  end
end
