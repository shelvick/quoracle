defmodule Quoracle.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Quoracle.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Quoracle.DataCase

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
          wait_for_agent_in_registry: 3,
          create_test_profile: 0,
          create_test_profile: 1
        ]
    end
  end

  setup tags do
    # PostgreSQL must be installed and running for tests
    # Tests will fail without proper database setup

    # Modern pattern - separate owner process that outlives test process
    # This properly handles spawned Tasks, GenServers, and other child processes
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

    # Return sandbox owner for tests that spawn processes needing DB access
    {:ok, sandbox_owner: pid}
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
