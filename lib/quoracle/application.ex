defmodule Quoracle.Application do
  @moduledoc """
  The Quoracle Application.

  This module starts the application supervision tree with the following children:
  - Vault: Cloak encryption
  - Repo: PostgreSQL connection
  - Telemetry: Metrics collection
  - PubSub: Inter-process messaging
  - AgentRegistry: Agent discovery (unique agent IDs)
  - EmbeddingCache: ETS table owner for embedding cache
  - DynSup: Dynamic supervisor for agents
  - EventHistory: UI persistence buffer for logs/messages
  - Endpoint: Phoenix HTTP/WebSocket server
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    verify_system_dependencies!()

    vault_children =
      if Quoracle.Vault.configured?() do
        [Quoracle.Vault]
      else
        Logger.warning("""
        CLOAK_ENCRYPTION_KEY not set — vault disabled.
        Encryption features (credentials, secrets) will not work.
        Generate a key with: elixir -e "32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()"
        """)

        []
      end

    children =
      vault_children ++
        [
          # Start the Ecto repository
          Quoracle.Repo,
          # Start the Telemetry supervisor
          QuoracleWeb.Telemetry,
          # Start the PubSub system
          {Phoenix.PubSub, name: Quoracle.PubSub},
          # Start the Registry for agent discovery (unique keys for single agent per ID)
          {Registry, keys: :unique, name: Quoracle.AgentRegistry},
          # Start the Registry for MCP error context collectors (duplicate keys for routing)
          {Registry, keys: :duplicate, name: Quoracle.MCP.ErrorContext.Registry},
          # Start the EmbeddingCache to manage ETS table
          Quoracle.Models.EmbeddingCache,
          # Start Task.Supervisor for background spawn tasks
          {Task.Supervisor, name: Quoracle.SpawnTaskSupervisor},
          # Start the DynamicSupervisor for agents
          Quoracle.Agent.DynSup,
          # Start the EventHistory buffer for UI persistence (must be after PubSub)
          {Quoracle.UI.EventHistory, pubsub: Quoracle.PubSub, name: Quoracle.UI.EventHistory},
          # Start the Endpoint (http/https)
          QuoracleWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Quoracle.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Register the MCP error context Logger handler after Registry is ready
        # This must happen after supervisor starts (Registry must be running)
        Quoracle.MCP.ErrorContext.ensure_handler_registered()

        # Restore running tasks from database at boot
        Quoracle.Boot.AgentRevival.restore_running_tasks()

        {:ok, pid}

      error ->
        error
    end
  end

  # Verify required system libraries are installed
  # Crashes at startup with helpful message if missing
  defp verify_system_dependencies! do
    verify_libvips!()
  end

  defp verify_libvips! do
    # The 'image' library compiles without libvips but fails at runtime.
    # Check immediately at startup so we don't get cryptic errors later.
    try do
      version = Vix.Vips.version()
      Logger.debug("libvips #{version} available for image compression")
    rescue
      _ ->
        raise """

        =====================================================
        MISSING SYSTEM DEPENDENCY: libvips
        =====================================================

        The 'image' library requires libvips to be installed
        on your system. Image compression will not work.

        Install with:
          Fedora/RHEL:   sudo dnf install vips vips-devel
          Debian/Ubuntu: sudo apt install libvips libvips-dev
          macOS:         brew install vips
          Arch:          sudo pacman -S libvips

        Then restart the application.
        =====================================================
        """
    end
  end
end
