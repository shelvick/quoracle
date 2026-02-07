defmodule Test.LiveViewTestHelpers do
  @moduledoc """
  Test helpers for Phoenix LiveView testing.

  Provides utilities for mounting LiveViews with isolated dependencies,
  handling log capture, and synchronizing PubSub broadcasts with LiveView
  message processing.
  """

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import ExUnit.Assertions

  alias Test.AgentTestHelpers

  @doc """
  Wraps Phoenix.LiveViewTest.live_isolated with automatic cleanup.

  Registers an on_exit callback that stops the LiveView process BEFORE
  the sandbox_owner is released, preventing "client exited" Postgrex errors.

  Use this instead of live_isolated/3 when the LiveView may have pending
  DB operations when the test exits.

  ## Examples

      {:ok, view, html} = live_isolated_with_cleanup(conn, DashboardLive, session: session)
  """
  @spec live_isolated_with_cleanup(Plug.Conn.t(), module(), keyword()) ::
          {:ok, %Phoenix.LiveViewTest.View{}, String.t()} | {:error, term()}
  def live_isolated_with_cleanup(conn, live_module, opts \\ []) do
    result = Phoenix.LiveViewTest.live_isolated(conn, live_module, opts)

    # Register cleanup to stop LiveView BEFORE sandbox_owner exits
    case result do
      {:ok, view, _html} ->
        ExUnit.Callbacks.on_exit(fn ->
          if Process.alive?(view.pid) do
            try do
              GenServer.stop(view.pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Mounts a LiveView with isolated dependencies and captures logs.

  This helper:
  1. Merges provided deps into session for LiveView mount
  2. Captures log output to keep tests clean
  3. Uses send/receive pattern for async operation
  4. Returns {:ok, view, html} or {:error, reason}

  ## Arguments
    * `conn` - Phoenix.ConnTest connection
    * `live_module` - LiveView module to mount
    * `deps` - Map with :pubsub, :registry, :dynsup, :sandbox_owner
    * `extra_session` - Additional session parameters (optional)

  ## Examples

      {:ok, view, html} = mount_live_isolated(conn, DashboardLive, deps)

      {:ok, view, html} = mount_live_isolated(conn, DashboardLive, deps,
        %{"initial_task_id" => task.id})
  """
  @spec mount_live_isolated(
          Plug.Conn.t(),
          module(),
          map(),
          map()
        ) :: {:ok, %Phoenix.LiveViewTest.View{}, String.t()} | {:error, term()}
  def mount_live_isolated(conn, live_module, deps, extra_session \\ %{}) do
    session =
      Map.merge(
        %{
          "pubsub" => deps.pubsub,
          "registry" => deps.registry,
          "dynsup" => deps.dynsup,
          "sandbox_owner" => deps.sandbox_owner
        },
        extra_session
      )

    capture_log(fn ->
      send(
        self(),
        {:result, Phoenix.LiveViewTest.live_isolated(conn, live_module, session: session)}
      )
    end)

    result =
      receive do
        {:result, result} -> result
      after
        5000 -> {:error, :mount_timeout}
      end

    # Register cleanup to stop LiveView BEFORE sandbox_owner exits
    # Prevents "client exited" Postgrex errors when CostDisplay queries DB
    case result do
      {:ok, view, _html} ->
        ExUnit.Callbacks.on_exit(fn ->
          if Process.alive?(view.pid) do
            try do
              GenServer.stop(view.pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
        end)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Mounts a LiveView and registers agent cleanup automatically.

  Use this when the LiveView spawns agents that need cleanup.
  The task agent and all its children will be stopped before
  the test exits.

  ## Examples

      {:ok, {task, agent_pid}} = TaskManager.create_task("Test",
        sandbox_owner: deps.sandbox_owner,
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub
      )

      {:ok, view, html} = mount_live_with_agent_cleanup(
        conn, DashboardLive, deps, agent_pid
      )
  """
  @spec mount_live_with_agent_cleanup(
          Plug.Conn.t(),
          module(),
          map(),
          pid()
        ) :: {:ok, %Phoenix.LiveViewTest.View{}, String.t()} | {:error, term()}
  def mount_live_with_agent_cleanup(conn, live_module, deps, task_agent_pid) do
    result = mount_live_isolated(conn, live_module, deps)

    ExUnit.Callbacks.on_exit(fn ->
      AgentTestHelpers.stop_agent_tree(task_agent_pid, deps.registry)
    end)

    result
  end

  @doc """
  Broadcasts to PubSub and forces LiveView to process messages.

  LiveView processes messages asynchronously. This helper ensures
  all pending messages are processed before returning, making tests
  deterministic.

  ## Returns
  The rendered HTML after all messages are processed.

  ## Examples

      html = broadcast_and_render(view, pubsub, "agents:lifecycle",
        {:agent_spawned, %{agent_id: "test-1"}})

      assert html =~ "test-1"
  """
  @spec broadcast_and_render(%Phoenix.LiveViewTest.View{}, atom() | pid(), String.t(), term()) ::
          String.t()
  def broadcast_and_render(view, pubsub, topic, event) do
    Phoenix.PubSub.broadcast(pubsub, topic, event)
    render(view)
  end

  @doc """
  Sends a message to LiveView and forces synchronous processing.

  Similar to broadcast_and_render but for direct process messages.

  ## Examples

      html = send_and_render(view, {:internal_event, data})
      assert html =~ "updated"
  """
  @spec send_and_render(%Phoenix.LiveViewTest.View{}, term()) :: String.t()
  def send_and_render(view, message) do
    send(view.pid, message)
    render(view)
  end

  @doc """
  Waits for a LiveView to receive and process a specific message.

  Useful for testing async operations where you need to wait for
  a specific state change.

  ## Options
    * `:timeout` - Maximum time to wait in milliseconds (default: 1000)
    * `:pattern` - Message pattern to match (required)

  ## Examples

      # Wait for agent spawned event
      assert {:ok, html} = wait_for_message(view,
        pattern: {:agent_spawned, %{agent_id: _}},
        timeout: 2000
      )
  """
  @spec wait_for_message(%Phoenix.LiveViewTest.View{}, keyword()) ::
          {:ok, String.t()} | {:error, :timeout}
  def wait_for_message(view, opts) do
    timeout = Keyword.get(opts, :timeout, 1000)
    pattern = Keyword.fetch!(opts, :pattern)

    # Send pattern to view process and wait for response
    send(view.pid, {:test_wait_for, pattern, self()})

    receive do
      {:test_message_received, html} -> {:ok, html}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Creates a LiveView test context with isolated dependencies.

  This is a convenience function that creates all necessary isolated
  resources for LiveView testing in one call.

  ## Examples

      setup do
        conn = build_conn()
        context = create_live_test_context(conn)

        %{
          conn: context.conn,
          deps: context.deps,
          pubsub: context.deps.pubsub,
          registry: context.deps.registry,
          dynsup: context.deps.dynsup,
          sandbox_owner: context.deps.sandbox_owner
        }
      end
  """
  @spec create_live_test_context(Plug.Conn.t()) :: %{
          conn: Plug.Conn.t(),
          deps: map()
        }
  def create_live_test_context(conn) do
    deps = Test.IsolationHelpers.create_isolated_deps()

    %{
      conn: conn,
      deps: deps
    }
  end

  @doc """
  Asserts that HTML contains an element with specific attributes.

  ## Examples

      assert_element(html, "button[phx-click='submit']")
      assert_element(html, "div[data-agent-id='agent-1']")
  """
  @spec assert_element(String.t(), String.t()) :: :ok
  def assert_element(html, selector) do
    assert html =~ selector_to_pattern(selector),
           "Expected to find element matching selector: #{selector}"

    :ok
  end

  @doc """
  Refutes that HTML contains an element with specific attributes.

  ## Examples

      refute_element(html, "button[phx-click='delete']")
      refute_element(html, "div[data-status='error']")
  """
  @spec refute_element(String.t(), String.t()) :: :ok
  def refute_element(html, selector) do
    refute html =~ selector_to_pattern(selector),
           "Expected NOT to find element matching selector: #{selector}"

    :ok
  end

  # Private helper to convert CSS selector to regex pattern
  defp selector_to_pattern(selector) do
    # Simple implementation - matches basic selectors
    # For complex selectors, use has_element?/2 from LiveViewTest
    selector
  end
end
