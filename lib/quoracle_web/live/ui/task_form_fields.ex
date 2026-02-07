defmodule QuoracleWeb.UI.TaskFormFields do
  @moduledoc """
  Reusable form field components for hierarchical prompt fields.
  Wraps FormComponents with character counters and specialized field types.
  """
  use Phoenix.Component
  import QuoracleWeb.FormComponents

  @doc """
  Renders a text input field with optional character counter.
  """
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:maxlength, :integer, default: nil)
  attr(:placeholder, :string, default: nil)
  attr(:required, :boolean, default: false)
  attr(:help_text, :string, default: nil)

  @spec text_field(map()) :: Phoenix.LiveView.Rendered.t()
  def text_field(assigns) do
    ~H"""
    <div class="mb-4">
      <.input
        type="text"
        name={@name}
        id={@name}
        label={@label}
        value={@value}
        maxlength={@maxlength}
        placeholder={@placeholder}
        required={@required}
      />
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
      <%= if @maxlength do %>
        <%= Phoenix.HTML.raw(format_character_count(String.length(@value), @maxlength)) %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a textarea field with character counter.
  """
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:maxlength, :integer, default: nil)
  attr(:rows, :integer, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:required, :boolean, default: false)
  attr(:help_text, :string, default: nil)

  @spec textarea_field(map()) :: Phoenix.LiveView.Rendered.t()
  def textarea_field(assigns) do
    ~H"""
    <div class="mb-4">
      <.input
        type="textarea"
        name={@name}
        id={@name}
        label={@label}
        value={@value}
        maxlength={@maxlength}
        rows={@rows}
        placeholder={@placeholder}
        required={@required}
      />
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
      <%= if @maxlength do %>
        <%= Phoenix.HTML.raw(format_character_count(String.length(@value), @maxlength)) %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an enum dropdown field.
  """
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)
  attr(:prompt, :string, default: "Select...")
  attr(:required, :boolean, default: false)
  attr(:help_text, :string, default: nil)

  @spec enum_dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  def enum_dropdown(assigns) do
    ~H"""
    <div class="mb-4">
      <.input
        type="select"
        name={@name}
        id={@name}
        label={@label}
        value={@value}
        options={@options}
        prompt={@prompt}
        required={@required}
      />
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a list input field (comma-separated values).
  """
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:help_text, :string, default: nil)

  @spec list_input(map()) :: Phoenix.LiveView.Rendered.t()
  def list_input(assigns) do
    # Convert list to comma-separated string
    assigns = assign(assigns, :display_value, list_to_string(assigns.value))

    ~H"""
    <div class="mb-4">
      <.input
        type="text"
        name={@name}
        id={@name}
        label={@label}
        value={@display_value}
        placeholder={@placeholder}
      />
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
      <p class="text-xs text-gray-500 mt-1">Separate multiple items with commas</p>
    </div>
    """
  end

  @doc """
  Returns cognitive style enum options.
  """
  @spec cognitive_style_options() :: [{String.t(), String.t()}]
  def cognitive_style_options do
    [
      {"Efficient", "efficient"},
      {"Exploratory", "exploratory"},
      {"Problem Solving", "problem_solving"},
      {"Creative", "creative"},
      {"Systematic", "systematic"}
    ]
  end

  @doc """
  Returns output style enum options.
  """
  @spec output_style_options() :: [{String.t(), String.t()}]
  def output_style_options do
    [
      {"Detailed", "detailed"},
      {"Concise", "concise"},
      {"Technical", "technical"},
      {"Narrative", "narrative"}
    ]
  end

  @doc """
  Returns delegation strategy enum options.
  """
  @spec delegation_strategy_options() :: [{String.t(), String.t()}]
  def delegation_strategy_options do
    [
      {"Sequential", "sequential"},
      {"Parallel", "parallel"},
      {"None", "none"}
    ]
  end

  @doc """
  Formats character count with warning color at 90% threshold.
  """
  @spec format_character_count(integer(), integer()) :: String.t()
  def format_character_count(current, max) do
    percentage = current / max * 100
    color_class = if percentage >= 90, do: "text-yellow-600", else: "text-gray-500"
    ~s(<span class="text-sm #{color_class}">#{current}/#{max}</span>)
  end

  @doc """
  Renders a budget input field with dollar prefix and decimal validation.
  """
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:help_text, :string, default: nil)

  @spec budget_input(map()) :: Phoenix.LiveView.Rendered.t()
  def budget_input(assigns) do
    ~H"""
    <div class="mb-4">
      <label for={@name} class="block text-sm font-medium text-gray-700 mb-1">
        <%= @label %>
      </label>
      <div class="flex items-center">
        <span class="mr-1 text-gray-500">$</span>
        <input
          type="text"
          name={@name}
          id={@name}
          value={@value}
          pattern="^\d*\.?\d{0,2}$"
          inputmode="decimal"
          placeholder={@placeholder}
          class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
        />
      </div>
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a profile selector dropdown.

  Displays profiles with capability groups: "name (capabilities)"
  """
  attr(:profiles, :list, required: true)
  attr(:selected_profile, :string, default: nil)
  attr(:help_text, :string, default: nil)

  @spec profile_selector(map()) :: Phoenix.LiveView.Rendered.t()
  def profile_selector(assigns) do
    ~H"""
    <div class="mb-4">
      <label for="profile" class="block text-sm font-medium text-gray-700 mb-1">
        Profile <span class="text-red-500">*</span>
      </label>
      <select
        id="profile"
        name="profile"
        required
        class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
      >
        <option value="">Select a profile...</option>
        <%= for profile <- @profiles do %>
          <option value={profile.name} selected={@selected_profile == profile.name}>
            <%= profile.name %> (<%= format_capability_groups(profile.capability_groups) %>)
          </option>
        <% end %>
      </select>
      <%= if @help_text do %>
        <p class="text-xs text-gray-500 mt-1"><%= @help_text %></p>
      <% end %>
    </div>
    """
  end

  @all_capability_groups ~w(file_read file_write external_api hierarchy local_execution)

  defp format_capability_groups([]), do: "base only"

  defp format_capability_groups(groups) when is_list(groups) do
    string_groups = Enum.map(groups, &to_string/1)

    if Enum.sort(string_groups) == Enum.sort(@all_capability_groups) do
      "all capabilities"
    else
      Enum.join(string_groups, ", ")
    end
  end

  defp format_capability_groups(_), do: "base only"

  # Helper function to convert list/string to display string
  defp list_to_string(value) when is_list(value) do
    Enum.join(value, ", ")
  end

  defp list_to_string(value) when is_binary(value), do: value
  defp list_to_string(_), do: ""
end
