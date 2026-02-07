defmodule QuoracleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use QuoracleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint QuoracleWeb.Endpoint

      use QuoracleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      # Exclude live_isolated - we define our own wrapper below with auto-cleanup
      import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
      import QuoracleWeb.ConnCase

      # Import test helpers for common patterns
      import Test.IsolationHelpers,
        only: [
          create_isolated_deps: 0,
          stop_and_wait_for_unregister: 3,
          stop_and_wait_for_unregister: 4
        ]

      import Test.AgentTestHelpers,
        only: [
          spawn_agent_with_cleanup: 3,
          stop_agent_gracefully: 1,
          stop_agent_tree: 2,
          spawn_agents_concurrently: 3,
          create_task_with_cleanup: 2,
          assert_agent_in_registry: 2,
          refute_agent_in_registry: 2,
          wait_for_agent_in_registry: 3
        ]

      import Test.LiveViewTestHelpers,
        only: [
          mount_live_isolated: 3,
          mount_live_isolated: 4,
          mount_live_with_agent_cleanup: 4,
          broadcast_and_render: 4,
          send_and_render: 2
        ]

      # Override live_isolated to auto-register cleanup
      # This prevents "client exited" Postgrex errors when LiveView has pending
      # DB operations at test exit. Defined here so @endpoint is available.
      def live_isolated(conn, module, opts \\ []) do
        result = Phoenix.LiveViewTest.live_isolated(conn, module, opts)

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
    end
  end

  setup tags do
    # Set up database sandbox for tests that need it

    # Modern pattern - separate owner process that outlives test process
    # This properly handles LiveView proxy processes that are spawned under ExUnit supervisor
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Quoracle.Repo,
        # Only share when async: false is explicitly needed
        shared: not tags[:async]
      )

    # Ensure proper cleanup when test exits
    # CRITICAL: Use :infinity timeout to allow all DB operations to complete
    # Sandbox.stop_owner/1 uses 5000ms default which causes premature kills
    on_exit(fn ->
      try do
        GenServer.stop(pid, :normal, :infinity)
      catch
        :exit, _ -> :ok
      end
    end)

    # Create connection with secret_key_base for LiveView tests
    # Must be at least 64 bytes for Plug.Session.COOKIE validation
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:secret_key_base, String.duplicate("a", 64))

    {:ok, conn: conn, sandbox_owner: pid}
  end
end
