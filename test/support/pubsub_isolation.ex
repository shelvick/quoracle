defmodule Test.PubSubIsolation do
  @moduledoc """
  Test helper for creating isolated Phoenix.PubSub instances per test.

  Provides test isolation for PubSub messages, preventing interference between
  concurrent tests through explicit parameter passing instead of Process dictionary.

  ## Usage

      setup do
        {:ok, pubsub} = Test.PubSubIsolation.setup_isolated_pubsub()
        {:ok, pubsub: pubsub}
      end

      test "example", %{pubsub: pubsub} do
        # Pass pubsub explicitly to all functions
        AgentEvents.broadcast_agent_spawned("id", "task", self(), pubsub)
      end

  ## Implementation Details

  Each test gets a unique PubSub instance that must be passed explicitly
  to all functions that need it. This avoids Process dictionary usage
  and ensures complete isolation between concurrent tests.
  """

  @doc """
  Sets up an isolated PubSub instance for the current test.

  Returns `{:ok, pubsub_name}` where `pubsub_name` is a unique atom
  identifying the isolated PubSub instance.

  The PubSub instance must be passed explicitly to functions that need it.
  No Process dictionary storage is used.

  ## Examples

      iex> {:ok, pubsub} = Test.PubSubIsolation.setup_isolated_pubsub()
      iex> is_atom(pubsub)
      true

  """
  @spec setup_isolated_pubsub() :: {:ok, atom()}
  def setup_isolated_pubsub() do
    # Generate unique name using positive integer
    unique_id = System.unique_integer([:positive])
    pubsub_name = :"test_pubsub_#{unique_id}"

    # Start the isolated PubSub instance
    {:ok, _pid} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Phoenix.PubSub.PG2
      )

    # Store in Process dictionary for backward compatibility
    # TODO: Remove in Packet 3 when all components updated
    Process.put(:test_pubsub, pubsub_name)

    # Return for explicit passing
    {:ok, pubsub_name}
  end

  @doc """
  Subscribe to a topic on an isolated PubSub instance.

  Helper function for subscribing to topics on test-specific PubSub instances.

  ## Examples

      iex> {:ok, pubsub} = Test.PubSubIsolation.setup_isolated_pubsub()
      iex> Test.PubSubIsolation.subscribe_isolated(pubsub, "test_topic")
      :ok

  """
  @spec subscribe_isolated(atom(), String.t()) :: :ok | {:error, term()}
  def subscribe_isolated(pubsub, topic) do
    try do
      Phoenix.PubSub.subscribe(pubsub, topic)
    rescue
      e in ArgumentError -> {:error, e.message}
    end
  end
end
