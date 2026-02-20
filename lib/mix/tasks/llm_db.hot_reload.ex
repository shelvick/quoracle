defmodule Mix.Tasks.LlmDb.HotReload do
  @moduledoc """
  Hot-reload llm_db modules and data on the running Quoracle server.

  Pushes recompiled llm_db beam files to the running server node and
  calls `LLMDB.load/0` to refresh the in-memory model database from
  the updated packaged snapshot.

  Run this after `scripts/update_llm_db.sh` or `mix deps.compile llm_db --force`.

  ## Usage

      mix llm_db.hot_reload

  ## Prerequisites

  The server must be started as a named node:

      elixir --sname quoracle -S mix phx.server

  ## Options

    * `--node` - Target node short name (default: `quoracle`)
  """

  @shortdoc "Hot-reload llm_db on running server"

  use Mix.Task

  @default_node "quoracle"

  @doc "Pushes recompiled llm_db beams to the running server and refreshes LLMDB data."
  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [node: :string])
    node_name = Keyword.get(opts, :node, @default_node)

    ensure_distributed!()
    target = resolve_target(node_name)

    unless Node.connect(target) do
      Mix.shell().error("Cannot connect to #{target}")
      Mix.shell().error("")
      Mix.shell().error("Is the server running with:")
      Mix.shell().error("  elixir --sname #{node_name} -S mix phx.server")
      exit({:shutdown, 1})
    end

    beam_dir = Path.join([Mix.Project.build_path(), "lib", "llm_db", "ebin"])

    beams =
      beam_dir
      |> Path.join("*.beam")
      |> Path.wildcard()

    if beams == [] do
      Mix.shell().error("No llm_db beam files found in #{beam_dir}")
      exit({:shutdown, 1})
    end

    {pushed, failed} =
      Enum.reduce(beams, {0, 0}, fn path, {ok, err} ->
        module =
          path
          |> Path.basename(".beam")
          |> String.to_atom()

        binary = File.read!(path)
        :rpc.call(target, :code, :soft_purge, [module])

        case :rpc.call(target, :code, :load_binary, [module, to_charlist(path), binary]) do
          {:module, ^module} -> {ok + 1, err}
          _ -> {ok, err + 1}
        end
      end)

    Mix.shell().info("Pushed #{pushed}/#{pushed + failed} llm_db modules to #{target}.")

    case :rpc.call(target, LLMDB, :load, [[]]) do
      {:ok, _snapshot} ->
        Mix.shell().info("LLMDB data refreshed.")

      other ->
        Mix.shell().error("LLMDB.load/0 failed: #{inspect(other)}")
        exit({:shutdown, 1})
    end

    :ok
  end

  @spec resolve_target(String.t()) :: node()
  defp resolve_target(node_name) do
    [_, hostname] = Node.self() |> Atom.to_string() |> String.split("@")
    :"#{node_name}@#{hostname}"
  end

  @spec ensure_distributed!() :: :ok
  defp ensure_distributed! do
    if Node.alive?() do
      :ok
    else
      name = :"llmdb_reload_#{System.unique_integer([:positive])}"

      case Node.start(name, :shortnames) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Mix.shell().error("Cannot start distributed node: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end
  end
end
