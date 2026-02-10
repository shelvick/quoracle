defmodule Quoracle.UI.EventHistory do
  @moduledoc """
  GenServer maintaining bounded in-memory buffers for UI event history.
  Subscribes to PubSub topics and provides query API for LiveView mount replay.

  Follows established dependency injection patterns:
  - Accepts pubsub via opts for test isolation
  - No named process registration by default (PID discovery via supervisor)
  - Sandbox setup in handle_continue (not init/1)
  """

  use GenServer
  require Logger

  alias Quoracle.UI.RingBuffer
  alias Phoenix.PubSub

  @default_log_buffer_size 100
  @default_message_buffer_size 50

  defstruct [
    :pubsub,
    :registry,
    :sandbox_owner,
    log_buffers: %{},
    message_buffers: %{},
    subscribed_agents: MapSet.new(),
    subscribed_tasks: MapSet.new(),
    log_buffer_size: @default_log_buffer_size,
    message_buffer_size: @default_message_buffer_size
  ]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    _pubsub = Keyword.fetch!(opts, :pubsub)
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Retrieves logs for the specified agent IDs.
  Returns a map of agent_id => [log] with logs in chronological order (oldest first).
  """
  @spec get_logs(pid(), [String.t()]) :: %{String.t() => [map()]}
  def get_logs(pid, agent_ids) when is_list(agent_ids) do
    GenServer.call(pid, {:get_logs, agent_ids})
  end

  @doc """
  Retrieves messages for the specified task IDs.
  Returns a flat list of messages in chronological order (oldest first).
  """
  @spec get_messages(pid(), [String.t()]) :: [map()]
  def get_messages(pid, task_ids) when is_list(task_ids) do
    GenServer.call(pid, {:get_messages, task_ids})
  end

  @doc """
  Returns the PID of the registered EventHistory GenServer.
  Returns nil if not registered.
  """
  @spec get_pid() :: pid() | nil
  def get_pid do
    Process.whereis(__MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    registry = Keyword.get(opts, :registry)
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    log_buffer_size = Keyword.get(opts, :log_buffer_size, @default_log_buffer_size)
    message_buffer_size = Keyword.get(opts, :message_buffer_size, @default_message_buffer_size)

    state = %__MODULE__{
      pubsub: pubsub,
      registry: registry,
      sandbox_owner: sandbox_owner,
      log_buffer_size: log_buffer_size,
      message_buffer_size: message_buffer_size
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    # Setup sandbox access if provided (for tests)
    if state.sandbox_owner do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, state.sandbox_owner, self())
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    # Subscribe to lifecycle topic
    PubSub.subscribe(state.pubsub, "agents:lifecycle")

    # Query registry for existing agents and tasks if provided
    state =
      if state.registry do
        state
        |> subscribe_to_existing_agents()
        |> subscribe_to_existing_tasks()
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_logs, agent_ids}, _from, state) do
    logs =
      Map.new(agent_ids, fn agent_id ->
        case Map.get(state.log_buffers, agent_id) do
          nil -> {agent_id, []}
          buffer -> {agent_id, RingBuffer.to_list(buffer)}
        end
      end)

    {:reply, logs, state}
  end

  @impl true
  def handle_call({:get_messages, task_ids}, _from, state) do
    messages =
      task_ids
      |> Enum.flat_map(fn task_id ->
        case Map.get(state.message_buffers, task_id) do
          nil -> []
          buffer -> RingBuffer.to_list(buffer)
        end
      end)

    {:reply, messages, state}
  end

  @impl true
  def handle_info({:agent_spawned, payload}, state) do
    agent_id = payload[:agent_id] || payload["agent_id"]
    task_id = payload[:task_id] || payload["task_id"]

    # Subscribe to agent's log topic if not already subscribed
    state =
      if agent_id && not MapSet.member?(state.subscribed_agents, agent_id) do
        PubSub.subscribe(state.pubsub, "agents:#{agent_id}:logs")
        %{state | subscribed_agents: MapSet.put(state.subscribed_agents, agent_id)}
      else
        state
      end

    # Subscribe to task's message topic if not already subscribed
    state =
      if task_id && not MapSet.member?(state.subscribed_tasks, task_id) do
        PubSub.subscribe(state.pubsub, "tasks:#{task_id}:messages")
        %{state | subscribed_tasks: MapSet.put(state.subscribed_tasks, task_id)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:log_entry, log}, state) do
    agent_id = log[:agent_id] || log["agent_id"]

    state =
      if agent_id do
        buffer =
          Map.get(state.log_buffers, agent_id) ||
            RingBuffer.new(state.log_buffer_size)

        buffer = RingBuffer.insert(buffer, log)
        %{state | log_buffers: Map.put(state.log_buffers, agent_id, buffer)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_message, message}, state) do
    task_id = message[:task_id] || message["task_id"]

    state =
      if task_id do
        buffer =
          Map.get(state.message_buffers, task_id) ||
            RingBuffer.new(state.message_buffer_size)

        buffer = RingBuffer.insert(buffer, message)
        %{state | message_buffers: Map.put(state.message_buffers, task_id, buffer)}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_terminated, _payload}, state) do
    # Per Q3 (option c): Keep buffer forever until restart
    # No cleanup needed - memory is bounded by ring buffer size
    {:noreply, state}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp subscribe_to_existing_agents(state) do
    # Query registry for all registered agents
    keys = Registry.select(state.registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    Enum.reduce(keys, state, fn
      {:agent, agent_id}, acc ->
        if MapSet.member?(acc.subscribed_agents, agent_id) do
          acc
        else
          PubSub.subscribe(acc.pubsub, "agents:#{agent_id}:logs")
          %{acc | subscribed_agents: MapSet.put(acc.subscribed_agents, agent_id)}
        end

      _other, acc ->
        acc
    end)
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp subscribe_to_existing_tasks(state) do
    # Query registry for all composite values to extract task_ids
    values = Registry.select(state.registry, [{{:_, :_, :"$1"}, [], [:"$1"]}])

    task_ids =
      values
      |> Enum.map(fn value -> Map.get(value, :task_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(task_ids, state, fn task_id, acc ->
      if MapSet.member?(acc.subscribed_tasks, task_id) do
        acc
      else
        PubSub.subscribe(acc.pubsub, "tasks:#{task_id}:messages")
        %{acc | subscribed_tasks: MapSet.put(acc.subscribed_tasks, task_id)}
      end
    end)
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end
end
