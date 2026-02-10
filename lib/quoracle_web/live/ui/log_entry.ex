defmodule QuoracleWeb.UI.LogEntry do
  @moduledoc """
  Live component for rendering individual log entries.
  Supports metadata expansion, severity styling, and copy actions.
  """

  use QuoracleWeb, :live_component

  import QuoracleWeb.UI.LogEntry.Helpers

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    # Check if metadata exists for conditional click handler
    assigns =
      assign(
        assigns,
        :has_metadata,
        assigns.log[:metadata] && map_size(assigns.log[:metadata]) > 0
      )

    ~H"""
    <div
      id={"log-entry-#{@log[:id] || System.unique_integer([:positive])}"}
      class={"log-entry border-b py-2 hover:bg-gray-50 level-#{@log[:level]} #{if @has_metadata, do: "cursor-pointer", else: ""}"}
      phx-hook="LogEntry"
      {if @has_metadata, do: [{"phx-click", "toggle_metadata"}, {"phx-value-log-id", @log[:id]}, {"phx-target", @target}], else: []}
    >
      <div class="flex items-start">
        <!-- Chevron (only when metadata exists) -->
        <%= if @log[:metadata] && map_size(@log[:metadata]) > 0 do %>
          <span class="mr-2 text-gray-400 flex-shrink-0">
            <%= if @expanded, do: "▼", else: "▶" %>
          </span>
        <% else %>
          <span class="mr-2 flex-shrink-0 w-4"></span>
        <% end %>

        <!-- Timestamp -->
        <span class={"timestamp text-xs text-gray-500 mr-2 #{level_time_class(@log[:level])}"}>">
          <%= format_timestamp(@log[:timestamp], @log[:level]) %>
        </span>
        
        <!-- Level Badge -->
        <span class={"level-badge px-2 py-1 text-xs rounded mr-2 level-#{@log[:level]} #{level_color_class(@log[:level])}"}>
          <%= String.upcase(to_string(@log[:level])) %>
        </span>
        
        <!-- Agent ID -->
        <span class="agent-id text-xs text-gray-600 mr-2">
          <%= @log[:agent_id] %>
        </span>
        
        <!-- Message (with word-wrap) -->
        <span class="message flex-1 break-words whitespace-normal">
          <%= highlight_message(@log[:message]) %>
        </span>

        <!-- Per-request cost (if present in metadata) -->
        <%= if has_cost_data?(@log[:metadata]) do %>
          <.live_component
            module={QuoracleWeb.Live.UI.CostDisplay}
            id={"log-cost-#{@log[:id] || System.unique_integer([:positive])}"}
            mode={:request}
            cost={get_cost_from_metadata(@log[:metadata])}
            metadata={@log[:metadata]}
          />
        <% end %>

        <!-- Actions (always visible, prevent expansion on click) -->
        <div class="log-actions ml-2 flex gap-1" phx-click="stop_propagation">
          <button
            phx-click="copy_log"
            phx-value-log-id={@log[:id]}
            phx-target={@myself}
            class="text-xs text-blue-500 hover:text-blue-700"
          >
            Copy
          </button>

          <button
            phx-click="copy_full"
            phx-value-log-id={@log[:id]}
            phx-target={@myself}
            class="text-xs text-blue-500 hover:text-blue-700"
          >
            Full
          </button>
        </div>
      </div>
      
      <!-- Metadata (expandable, with word-wrap) -->
      <%= if @expanded && @log[:metadata] && map_size(@log[:metadata]) > 0 do %>
        <div class="metadata mt-2 ml-8 p-2 bg-gray-100 rounded text-sm">
          <%= if has_sent_messages?(@log[:metadata]) do %>
            <!-- Sent Messages Sub-Accordions (outgoing to LLMs) -->
            <div class="sent-messages space-y-2">
              <div class="text-xs text-gray-600 font-medium mb-1">Messages sent to models:</div>
              <%= for {model_entry, index} <- Enum.with_index(@log[:metadata][:sent_messages] || @log[:metadata]["sent_messages"] || []) do %>
                <div class="sent-message border border-blue-200 rounded bg-white">
                  <div
                    class="flex items-center justify-between p-2 cursor-pointer hover:bg-blue-50"
                    phx-click="toggle_sent_message"
                    phx-value-index={index}
                    phx-target={@myself}
                  >
                    <div class="flex items-center gap-2">
                      <span class="text-blue-400">
                        <%= if MapSet.member?(@expanded_sent_messages, index), do: "▼", else: "▶" %>
                      </span>
                      <span class="font-medium text-sm text-blue-700"><%= format_model_id_for_sent(model_entry) %></span>
                      <span class="text-xs text-gray-500">(<%= get_sent_message_count(model_entry) %> messages)</span>
                    </div>
                    <button
                      phx-click="copy_sent_message"
                      phx-value-index={index}
                      phx-target={@myself}
                      class="text-xs text-blue-500 hover:text-blue-700 px-2 py-1"
                      onclick="event.stopPropagation()"
                    >
                      Copy
                    </button>
                  </div>
                  <%= if MapSet.member?(@expanded_sent_messages, index) do %>
                    <div class="p-2 border-t border-blue-200 bg-blue-50 space-y-1">
                      <!-- Nested message accordions -->
                      <% messages = get_messages_from_entry(model_entry) %>
                      <%= for {msg, msg_index} <- Enum.with_index(messages) do %>
                        <% msg_key = {index, msg_index} %>
                        <% is_expanded = MapSet.member?(@expanded_sent_message_items, msg_key) %>
                        <% role = get_message_role(msg) %>
                        <% content = get_message_content(msg) %>
                        <div class={"message-item border rounded #{role_border_class(role)}"}>
                          <div
                            class={"flex items-center gap-2 p-1.5 cursor-pointer text-xs #{role_hover_class(role)}"}
                            phx-click="toggle_sent_message_item"
                            phx-value-model-index={index}
                            phx-value-msg-index={msg_index}
                            phx-target={@myself}
                          >
                            <span class={role_text_class(role)}>
                              <%= if is_expanded, do: "▼", else: "▶" %>
                            </span>
                            <span class={"font-medium px-1.5 py-0.5 rounded text-xs #{role_badge_class(role)}"}><%= role %></span>
                            <%= unless is_expanded do %>
                              <span class="text-gray-600 truncate flex-1"><%= truncate_content(content, 80) %></span>
                            <% end %>
                          </div>
                          <%= if is_expanded do %>
                            <div class={"p-2 border-t text-xs #{role_content_bg(role)}"}>
                              <pre class="break-words whitespace-pre-wrap overflow-wrap-anywhere select-text"><%= content %></pre>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
            <!-- Other metadata (excluding sent_messages) -->
            <% other_metadata = Map.drop(@log[:metadata], [:sent_messages, "sent_messages"]) %>
            <%= if map_size(other_metadata) > 0 do %>
              <div class="mt-2 pt-2 border-t border-gray-200">
                <pre class="text-xs break-words whitespace-pre-wrap overflow-wrap-anywhere select-text"><%= format_metadata(other_metadata) %></pre>
              </div>
            <% end %>
          <% else %>
            <%= if has_llm_responses?(@log[:metadata]) do %>
              <!-- LLM Response Sub-Accordions -->
              <div class="llm-responses space-y-2">
                <%= for {response, index} <- Enum.with_index(@log[:metadata][:raw_responses] || @log[:metadata]["raw_responses"] || []) do %>
                  <div class="llm-response border border-gray-200 rounded bg-white">
                    <div
                      class="flex items-center justify-between p-2 cursor-pointer hover:bg-gray-50"
                      phx-click="toggle_response"
                      phx-value-index={index}
                      phx-target={@myself}
                    >
                      <div class="flex items-center gap-2">
                        <span class="text-gray-400">
                          <%= if MapSet.member?(@expanded_responses, index), do: "▼", else: "▶" %>
                        </span>
                        <span class="font-medium text-sm"><%= format_model_name(response) %></span>
                        <span class="text-xs text-gray-500"><%= format_response_stats(response) %></span>
                      </div>
                      <button
                        phx-click="copy_response"
                        phx-value-index={index}
                        phx-target={@myself}
                        class="text-xs text-blue-500 hover:text-blue-700 px-2 py-1"
                        onclick="event.stopPropagation()"
                      >
                        Copy
                      </button>
                    </div>
                    <%= if MapSet.member?(@expanded_responses, index) do %>
                      <div class="p-2 border-t border-gray-200 bg-gray-50">
                        <pre class="text-xs break-words whitespace-pre-wrap overflow-wrap-anywhere select-text"><%= format_response_content(response) %></pre>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
              <!-- Other metadata (excluding raw_responses) -->
              <% other_metadata = Map.drop(@log[:metadata], [:raw_responses, "raw_responses"]) %>
              <%= if map_size(other_metadata) > 0 do %>
                <div class="mt-2 pt-2 border-t border-gray-200">
                  <pre class="text-xs break-words whitespace-pre-wrap overflow-wrap-anywhere select-text"><%= format_metadata(other_metadata) %></pre>
                </div>
              <% end %>
            <% else %>
              <pre class="text-xs break-words whitespace-pre-wrap overflow-wrap-anywhere select-text"><%= format_metadata(@log[:metadata]) %></pre>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    # Filter out reserved assigns
    safe_assigns = Map.drop(assigns, [:myself])

    socket =
      socket
      |> assign(safe_assigns)
      |> assign_new(:expanded, fn -> false end)
      |> assign_new(:expanded_responses, fn -> MapSet.new() end)
      |> assign_new(:expanded_sent_messages, fn -> MapSet.new() end)
      |> assign_new(:expanded_sent_message_items, fn -> MapSet.new() end)
      |> assign_new(:highlight, fn -> nil end)

    # Default target to myself if not provided by parent
    # (allows routing toggle events to parent LogView when used in context)
    socket =
      if socket.assigns[:target] do
        socket
      else
        assign(socket, :target, socket.assigns.myself)
      end

    {:ok, socket}
  end

  @doc """
  Handles main accordion toggle when target is self (isolated component tests).
  In production context, this event routes to parent LogView instead.
  """
  @impl true
  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_metadata", _params, socket) do
    # Fallback for when target is self (isolated tests or no parent)
    {:noreply, assign(socket, expanded: !socket.assigns.expanded)}
  end

  # Handles sub-accordion toggle for individual LLM responses.
  @impl true
  def handle_event("toggle_response", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    expanded = socket.assigns.expanded_responses

    new_expanded =
      if MapSet.member?(expanded, index) do
        MapSet.delete(expanded, index)
      else
        MapSet.put(expanded, index)
      end

    {:noreply, assign(socket, expanded_responses: new_expanded)}
  end

  # Handles sub-accordion toggle for sent messages per model.
  @impl true
  def handle_event("toggle_sent_message", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    expanded = socket.assigns.expanded_sent_messages

    new_expanded =
      if MapSet.member?(expanded, index) do
        MapSet.delete(expanded, index)
      else
        MapSet.put(expanded, index)
      end

    {:noreply, assign(socket, expanded_sent_messages: new_expanded)}
  end

  # Handles sub-sub-accordion toggle for individual messages within a model.
  @impl true
  def handle_event(
        "toggle_sent_message_item",
        %{"model-index" => model_idx_str, "msg-index" => msg_idx_str},
        socket
      ) do
    key = {String.to_integer(model_idx_str), String.to_integer(msg_idx_str)}
    expanded = socket.assigns.expanded_sent_message_items

    new_expanded =
      if MapSet.member?(expanded, key) do
        MapSet.delete(expanded, key)
      else
        MapSet.put(expanded, key)
      end

    {:noreply, assign(socket, expanded_sent_message_items: new_expanded)}
  end

  @impl true
  def handle_event("copy_log", _params, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: socket.assigns.log[:message]})}
  end

  @impl true
  def handle_event("copy_full", _params, socket) do
    log = socket.assigns.log
    text = "#{log[:level]}: #{log[:message]}\nMetadata: #{inspect(log[:metadata])}"
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
  end

  @impl true
  def handle_event("copy_response", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    responses =
      socket.assigns.log[:metadata][:raw_responses] ||
        socket.assigns.log[:metadata]["raw_responses"] || []

    case Enum.at(responses, index) do
      nil ->
        {:noreply, socket}

      response ->
        text = format_response_content(response)
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
    end
  end

  @impl true
  def handle_event("copy_sent_message", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    sent_messages =
      socket.assigns.log[:metadata][:sent_messages] ||
        socket.assigns.log[:metadata]["sent_messages"] || []

    case Enum.at(sent_messages, index) do
      nil ->
        {:noreply, socket}

      model_entry ->
        text = format_sent_messages(model_entry)
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
    end
  end

  # Helpers imported from QuoracleWeb.UI.LogEntry.Helpers
end
