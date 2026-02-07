defmodule Quoracle.Release do
  @moduledoc """
  Release tasks that run without Mix installed.

  Used by rel/overlays/bin/migrate and rel/overlays/bin/server.

      bin/migrate        # create database (if needed) and run pending migrations
      bin/migrate undo   # rollback last migration
  """

  @app :quoracle

  @doc "Create the database if it doesn't exist."
  @spec create() :: :ok
  def create do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, term} -> raise "Could not create database: #{inspect(term)}"
      end
    end

    :ok
  end

  @doc "Run all pending migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rollback the last migration."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
