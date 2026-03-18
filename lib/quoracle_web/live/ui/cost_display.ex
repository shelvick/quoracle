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
    {:ok, assign(socket, expanded: false, costs_loaded: false, breakdown_loaded: false)}
  end

  @impl true
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket) do
    old_total = socket.assigns[:total_cost]

    socket =
      socket
      |> assign(assigns)
      |> assign(
        :precomputed_total_cost?,
        Map.get(assigns, :precomputed_total_cost?, Map.has_key?(assigns, :total_cost))
      )
      |> assign_new(:mode, fn -> :badge end)
      |> assign_new(:expanded, fn -> false end)
      |> assign_new(:total_cost, fn -> nil end)
      |> assign_new(:children_cost, fn -> nil end)
      |> assign_new(:by_type, fn -> %{} end)
      |> assign_new(:by_model, fn -> [] end)
      |> maybe_invalidate_breakdown(old_total)
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
    socket = assign(socket, expanded: not socket.assigns.expanded)

    socket =
      if socket.assigns.expanded do
        maybe_load_costs(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # ============================================================
  # Private Functions
  # ============================================================

  defp maybe_invalidate_breakdown(socket, old_total) do
    new_total = socket.assigns[:total_cost]

    if old_total != new_total do
      assign(socket, breakdown_loaded: false)
    else
      socket
    end
  end

  defp maybe_load_costs(socket) do
    socket
    |> maybe_load_base_costs()
    |> maybe_load_breakdown()
  end

  defp maybe_load_base_costs(socket) do
    if socket.assigns[:costs_loaded] do
      socket
    else
      load_base_costs(socket)
    end
  end

  defp maybe_load_breakdown(%{assigns: %{expanded: false}} = socket), do: socket
  defp maybe_load_breakdown(%{assigns: %{breakdown_loaded: true}} = socket), do: socket
  defp maybe_load_breakdown(socket), do: load_breakdown(socket)

  defp load_base_costs(socket) do
    case socket.assigns[:mode] do
      :badge ->
        load_badge_costs(socket)

      :summary ->
        load_summary_base_costs(socket)

      :detail ->
        load_detail_base_costs(socket)

      :request ->
        assign(socket, :costs_loaded, true)
    end
  end

  defp load_breakdown(socket) do
    case socket.assigns[:mode] do
      :summary -> load_summary_breakdown(socket)
      :detail -> load_detail_breakdown(socket)
      _ -> socket
    end
  end

  defp load_badge_costs(%{assigns: %{precomputed_total_cost?: true}} = socket) do
    assign(socket, :costs_loaded, true)
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

  defp load_summary_base_costs(%{assigns: %{precomputed_total_cost?: true}} = socket) do
    socket
    |> assign(:children_cost, nil)
    |> assign(:by_type, %{})
    |> assign(:costs_loaded, true)
  end

  defp load_summary_base_costs(%{assigns: %{agent_id: agent_id}} = socket)
       when not is_nil(agent_id) do
    own = Aggregator.by_agent(agent_id)
    children = Aggregator.by_agent_children(agent_id)

    socket
    |> assign(:total_cost, own.total_cost)
    |> assign(:children_cost, children.total_cost)
    |> assign(:by_type, own.by_type)
    |> assign(:costs_loaded, true)
  end

  defp load_summary_base_costs(socket) do
    socket
    |> assign(:total_cost, nil)
    |> assign(:children_cost, nil)
    |> assign(:by_type, %{})
    |> assign(:costs_loaded, true)
    |> assign(:breakdown_loaded, true)
  end

  defp load_summary_breakdown(socket) do
    agent_id = socket.assigns[:agent_id]

    if agent_id do
      own = Aggregator.by_agent(agent_id)
      children = Aggregator.by_agent_children(agent_id)

      socket
      |> maybe_assign_total_cost(own.total_cost)
      |> assign(:children_cost, children.total_cost)
      |> assign(:by_type, merge_cost_types(own.by_type, children.by_type))
      |> assign(:breakdown_loaded, true)
    else
      socket
      |> assign(:children_cost, nil)
      |> assign(:by_type, %{})
      |> assign(:breakdown_loaded, true)
    end
  end

  defp load_detail_base_costs(%{assigns: %{precomputed_total_cost?: true}} = socket) do
    socket
    |> assign(:by_model, [])
    |> assign(:costs_loaded, true)
  end

  defp load_detail_base_costs(%{assigns: %{agent_id: agent_id}} = socket)
       when not is_nil(agent_id) do
    %{total_cost: total} = Aggregator.by_agent(agent_id)
    assign(socket, total_cost: total, costs_loaded: true)
  end

  defp load_detail_base_costs(%{assigns: %{task_id: task_id}} = socket)
       when not is_nil(task_id) do
    if valid_uuid?(task_id) do
      %{total_cost: total} = Aggregator.by_task(task_id)
      assign(socket, total_cost: total, costs_loaded: true)
    else
      assign(socket, total_cost: nil, by_model: [], costs_loaded: true, breakdown_loaded: true)
    end
  end

  defp load_detail_base_costs(socket) do
    assign(socket, total_cost: nil, by_model: [], costs_loaded: true, breakdown_loaded: true)
  end

  defp load_detail_breakdown(socket) do
    case socket.assigns do
      %{agent_id: agent_id} when not is_nil(agent_id) ->
        by_model = Aggregator.by_agent_and_model_detailed(agent_id)
        %{total_cost: total} = Aggregator.by_agent(agent_id)

        socket
        |> maybe_assign_total_cost(total)
        |> assign(:by_model, by_model)
        |> assign(:breakdown_loaded, true)

      %{task_id: task_id} when not is_nil(task_id) ->
        if valid_uuid?(task_id) do
          by_model = Aggregator.by_task_and_model_detailed(task_id)
          %{total_cost: total} = Aggregator.by_task(task_id)

          socket
          |> maybe_assign_total_cost(total)
          |> assign(:by_model, by_model)
          |> assign(:breakdown_loaded, true)
        else
          socket
          |> assign(:by_model, [])
          |> assign(:breakdown_loaded, true)
        end

      _ ->
        socket
        |> assign(:by_model, [])
        |> assign(:breakdown_loaded, true)
    end
  end

  defp maybe_assign_total_cost(
         %{assigns: %{precomputed_total_cost?: true, total_cost: total_cost}} = socket,
         _total
       )
       when not is_nil(total_cost),
       do: socket

  defp maybe_assign_total_cost(socket, total), do: assign(socket, :total_cost, total)

  defp merge_cost_types(own_by_type, children_by_type) do
    Map.merge(own_by_type, children_by_type, fn _type, own_cost, child_cost ->
      Decimal.add(own_cost || Decimal.new(0), child_cost || Decimal.new(0))
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
