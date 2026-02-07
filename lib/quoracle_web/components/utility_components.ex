defmodule QuoracleWeb.UtilityComponents do
  @moduledoc """
  Utility components for the application.

  This module contains helper components and functions for icons,
  JavaScript animations, and error translation.
  """
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr(:name, :string, required: true)
  attr(:class, :string, default: nil)

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Shows an element with a smooth transition animation.

  ## Examples

      <div phx-click={show("#modal")}>Show Modal</div>
  """
  @spec show(Phoenix.LiveView.JS.t() | String.t()) :: Phoenix.LiveView.JS.t()
  @spec show(Phoenix.LiveView.JS.t(), String.t()) :: Phoenix.LiveView.JS.t()
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 100,
      transition:
        {"transition-all transform ease-out duration-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  @doc """
  Hides an element with a smooth transition animation.

  ## Examples

      <div phx-click={hide("#modal")}>Hide Modal</div>
  """
  @spec hide(Phoenix.LiveView.JS.t() | String.t()) :: Phoenix.LiveView.JS.t()
  @spec hide(Phoenix.LiveView.JS.t(), String.t()) :: Phoenix.LiveView.JS.t()
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 100,
      transition:
        {"transition-all transform ease-in duration-100",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext or simple string interpolation.

  ## Examples

      translate_error({"must be at least %{count} characters", count: 5})
      # => "must be at least 5 characters"
  """
  @spec translate_error({String.t(), keyword() | map()}) :: String.t()
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(QuoracleWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(QuoracleWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Renders a confirmation modal dialog.

  ## Examples

      <.modal id="delete-task" on_confirm="delete_task" task_id={task.id}>
        <:title>Confirm Deletion</:title>
        Are you sure you want to delete this task?
      </.modal>
  """
  attr(:id, :string, required: true)
  attr(:on_confirm, :string, required: true)
  attr(:on_cancel, :string, default: "hide_modal")
  attr(:task_id, :string, default: nil)
  attr(:confirm_label, :string, default: "Delete")

  attr(:confirm_class, :string,
    default: "px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded"
  )

  slot(:title, required: true)

  @spec modal(map()) :: Phoenix.LiveView.Rendered.t()
  def modal(assigns) do
    ~H"""
    <div id={@id} class="hidden fixed inset-0 z-50">
      <%!-- Backdrop --%>
      <div
        class="fixed inset-0 bg-gray-500/75"
        phx-click={hide("##{@id}")}
        aria-hidden="true"
      >
      </div>

      <%!-- Modal content --%>
      <div class="fixed inset-0 overflow-y-auto p-4">
        <div class="flex min-h-full items-center justify-center">
          <div
            class="bg-white rounded-lg shadow-xl max-w-md w-full p-6"
            phx-click-away={hide("##{@id}")}
          >
            <h3 class="text-lg font-semibold mb-4">
              <%= render_slot(@title) %>
            </h3>

            <div class="mb-6">
              <%= render_slot(@inner_block) %>
            </div>

            <div class="flex gap-3 justify-end">
              <button
                type="button"
                class="px-4 py-2 bg-gray-200 hover:bg-gray-300 text-gray-800 rounded"
                phx-click={if @on_cancel == "hide_modal", do: hide("##{@id}"), else: @on_cancel}
              >
                Cancel
              </button>
              <button
                type="button"
                class={@confirm_class}
                phx-click={@on_confirm}
                {if @task_id, do: [{"phx-value-task-id", @task_id}], else: []}
              >
                <%= @confirm_label %>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
