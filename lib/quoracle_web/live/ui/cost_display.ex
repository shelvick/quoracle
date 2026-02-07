defmodule QuoracleWeb.Live.UI.CostDisplay do
  @moduledoc """
  LiveView component for displaying costs.

  Renders in multiple modes:
  - :badge - Compact cost display (e.g., "$0.05")
  - :summary - Cost summary with breakdown by type
  - :detail - Full cost details with model breakdown
  - :request - Single request cost (for LogEntry)
  """

  use QuoracleWeb, :live_component

  alias Quoracle.Costs.Aggregator
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket) do
    {:ok, assign(socket, expanded: false, costs_loaded: false)}
  end

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket) do
    # R17-R18: Check if costs_updated_at changed - only force reload when it changes
    old_timestamp = socket.assigns[:costs_updated_at]
    new_timestamp = assigns[:costs_updated_at]
    force_reload = old_timestamp != new_timestamp and new_timestamp != nil

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:mode, fn -> :badge end)
      |> then(fn s ->
        if force_reload, do: assign(s, :costs_loaded, false), else: s
      end)
      |> maybe_load_costs()

    {:ok, socket}
  end

  # ============================================================
  # Rendering
  # ============================================================

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id={assigns[:id]} class={"cost-display cost-display--#{@mode}"}>
      <%= case @mode do %>
        <% :badge -> %>
          <.cost_badge cost={@total_cost} />

        <% :summary -> %>
          <.cost_summary
            total_cost={@total_cost}
            children_cost={@children_cost}
            by_type={@by_type}
            expanded={@expanded}
            myself={@myself}
          />

        <% :detail -> %>
          <.cost_detail
            total_cost={@total_cost}
            by_model={@by_model}
            expanded={@expanded}
            myself={@myself}
          />

        <% :request -> %>
          <.cost_request cost={@cost} metadata={@metadata} />
      <% end %>
    </div>
    """
  end

  # Badge: Compact "$0.05" display
  defp cost_badge(assigns) do
    ~H"""
    <span class="cost-badge text-xs text-gray-500" title="Total cost">
      <%= format_cost(@cost) %>
    </span>
    """
  end

  # Summary: Expandable with type breakdown
  defp cost_summary(assigns) do
    ~H"""
    <div class="cost-summary">
      <div
        class="flex items-center gap-2 cursor-pointer hover:bg-gray-50 p-1 rounded"
        phx-click="toggle_expand"
        phx-target={@myself}
      >
        <span class="cost-total font-medium"><%= format_cost(@total_cost) %></span>
        <%= if @children_cost do %>
          <span class="cost-children text-xs text-gray-400">
            (children: <%= format_cost(@children_cost) %>)
          </span>
        <% end %>
        <span class="expand-icon text-gray-400"><%= if @expanded, do: "▼", else: "▶" %></span>
      </div>

      <%= if @expanded do %>
        <div class="cost-breakdown mt-2 pl-4 text-sm">
          <%= for {type, cost} <- @by_type do %>
            <div class="flex justify-between">
              <span class="text-gray-600"><%= format_type(type) %></span>
              <span><%= format_cost(cost) %></span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Detail: Full breakdown with models (v2.0 - Token Breakdown Table)
  defp cost_detail(assigns) do
    ~H"""
    <div class="cost-detail">
      <div
        class="flex items-center gap-2 cursor-pointer hover:bg-gray-50 p-1 rounded"
        phx-click="toggle_expand"
        phx-target={@myself}
      >
        <span class="font-medium">Cost Details</span>
        <span class="cost-total"><%= format_cost(@total_cost) %></span>
        <span class="expand-icon text-gray-400"><%= if @expanded, do: "▼", else: "▶" %></span>
      </div>

      <%= if @expanded do %>
        <div class="overflow-x-auto mt-2">
          <table class="min-w-full text-sm">
            <thead class="bg-gray-100">
              <tr>
                <th class="px-2 py-1 text-left font-medium text-gray-600">Model</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Req</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Input</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Output</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Reason</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Cache R</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Cache W</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">In$</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Out$</th>
                <th class="px-2 py-1 text-right font-medium text-gray-600">Total$</th>
              </tr>
            </thead>
            <tbody>
              <%= for model <- @by_model do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-2 py-1 text-gray-700 truncate max-w-32" title={model.model_spec}>
                    <%= truncate_model(model.model_spec) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= model.request_count %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_tokens(model.input_tokens) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_tokens(model.output_tokens) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_token_or_dash(model[:reasoning_tokens]) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_token_or_dash(model[:cached_tokens]) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_token_or_dash(model[:cache_creation_tokens]) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_cost_compact(model[:input_cost]) %>
                  </td>
                  <td class="px-2 py-1 text-right text-gray-600">
                    <%= format_cost_compact(model[:output_cost]) %>
                  </td>
                  <td class="px-2 py-1 text-right font-medium text-gray-800">
                    <%= format_cost(model.total_cost) %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # Request: Single cost for LogEntry
  defp cost_request(assigns) do
    ~H"""
    <div class="cost-request inline-flex items-center gap-2 text-xs">
      <span class="cost-amount"><%= format_cost(@cost) %></span>
      <%= if @metadata && @metadata["model_spec"] do %>
        <span class="model-spec text-gray-400" title={@metadata["model_spec"]}>
          (<%= truncate_model(@metadata["model_spec"]) %>)
        </span>
      <% end %>
    </div>
    """
  end

  # ============================================================
  # Event Handlers
  # ============================================================

  @impl true
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("toggle_expand", _params, socket) do
    {:noreply, assign(socket, expanded: not socket.assigns.expanded)}
  end

  # ============================================================
  # Private Functions
  # ============================================================

  defp maybe_load_costs(socket) do
    if socket.assigns[:costs_loaded] do
      socket
    else
      load_costs(socket)
    end
  end

  defp load_costs(socket) do
    case socket.assigns[:mode] do
      :badge ->
        load_badge_costs(socket)

      :summary ->
        load_summary_costs(socket)

      :detail ->
        load_detail_costs(socket)

      :request ->
        # Request mode uses passed-in cost, no loading needed
        socket
        |> assign(:costs_loaded, true)
    end
  end

  defp load_badge_costs(socket) do
    case socket.assigns do
      %{agent_id: agent_id} when not is_nil(agent_id) ->
        summary = Aggregator.by_agent(agent_id)
        assign(socket, total_cost: summary.total_cost, costs_loaded: true)

      %{task_id: task_id} when not is_nil(task_id) ->
        if valid_uuid?(task_id) do
          summary = Aggregator.by_task(task_id)
          assign(socket, total_cost: summary.total_cost, costs_loaded: true)
        else
          assign(socket, total_cost: nil, costs_loaded: true)
        end

      _ ->
        assign(socket, total_cost: nil, costs_loaded: true)
    end
  end

  defp load_summary_costs(socket) do
    agent_id = socket.assigns[:agent_id]

    if agent_id do
      own = Aggregator.by_agent(agent_id)
      children = Aggregator.by_agent_children(agent_id)

      socket
      |> assign(:total_cost, own.total_cost)
      |> assign(:children_cost, children.total_cost)
      |> assign(:by_type, own.by_type)
      |> assign(:costs_loaded, true)
    else
      assign(socket, total_cost: nil, children_cost: nil, by_type: %{}, costs_loaded: true)
    end
  end

  defp load_detail_costs(socket) do
    case socket.assigns do
      %{agent_id: agent_id} when not is_nil(agent_id) ->
        by_model = Aggregator.by_agent_and_model_detailed(agent_id)
        assign_detail_costs(socket, by_model)

      %{task_id: task_id} when not is_nil(task_id) ->
        if valid_uuid?(task_id) do
          by_model = Aggregator.by_task_and_model_detailed(task_id)
          assign_detail_costs(socket, by_model)
        else
          assign(socket, total_cost: nil, by_model: [], costs_loaded: true)
        end

      _ ->
        assign(socket, total_cost: nil, by_model: [], costs_loaded: true)
    end
  end

  defp assign_detail_costs(socket, by_model) do
    total = sum_model_costs(by_model)

    socket
    |> assign(:total_cost, total)
    |> assign(:by_model, by_model)
    |> assign(:costs_loaded, true)
  end

  @spec sum_model_costs([map()]) :: Decimal.t()
  defp sum_model_costs(by_model) do
    Enum.reduce(by_model, Decimal.new(0), fn m, acc ->
      if m.total_cost, do: Decimal.add(acc, m.total_cost), else: acc
    end)
  end

  # ============================================================
  # Formatting Helpers
  # ============================================================

  defp format_cost(nil), do: "N/A"

  defp format_cost(%Decimal{} = cost) do
    rounded = Decimal.round(cost, 2)
    "$#{Decimal.to_string(rounded)}"
  end

  defp format_cost(cost) when is_float(cost), do: format_cost(Decimal.from_float(cost))
  defp format_cost(_), do: "N/A"

  defp format_type("llm_consensus"), do: "Consensus"
  defp format_type("llm_embedding"), do: "Embeddings"
  defp format_type("llm_answer"), do: "Answer Engine"
  defp format_type("llm_summarization"), do: "Summarization"
  defp format_type(type), do: type

  defp format_tokens(nil), do: "0"
  defp format_tokens(tokens) when tokens >= 1_000_000, do: "#{div(tokens, 1_000_000)}M"
  defp format_tokens(tokens) when tokens >= 1_000, do: "#{div(tokens, 1_000)}K"
  defp format_tokens(tokens), do: to_string(tokens)

  # Formats token count or returns "—" for nil/0 (historical data)
  @spec format_token_or_dash(integer() | nil) :: String.t()
  defp format_token_or_dash(nil), do: "—"
  defp format_token_or_dash(0), do: "—"
  defp format_token_or_dash(tokens), do: format_tokens(tokens)

  # Formats cost compactly for table cells (dash for nil/zero)
  @spec format_cost_compact(Decimal.t() | nil) :: String.t()
  defp format_cost_compact(nil), do: "—"

  defp format_cost_compact(%Decimal{} = cost) do
    if Decimal.compare(cost, Decimal.new(0)) == :eq do
      "—"
    else
      rounded = Decimal.round(cost, 2)
      "$#{Decimal.to_string(rounded)}"
    end
  end

  defp format_cost_compact(_), do: "—"

  defp truncate_model(nil), do: "unknown"

  defp truncate_model(spec) do
    case String.split(spec, "/") do
      [_provider, model] -> model
      _ -> spec
    end
    |> String.slice(0, 20)
  end

  # UUID validation to prevent Ecto.Query.CastError
  # Must match UUID format: 8-4-4-4-12 hex characters
  @uuid_regex ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  defp valid_uuid?(value) when is_binary(value) do
    Regex.match?(@uuid_regex, value)
  end

  defp valid_uuid?(_), do: false
end
