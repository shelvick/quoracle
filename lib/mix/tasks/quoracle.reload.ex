defmodule Mix.Tasks.Quoracle.Reload do
  @moduledoc """
  Hot-reload changed modules on the running Quoracle server.

  Compiles the project, identifies modules that differ from what's currently
  loaded on the running server, and pushes the updated code without restarting.
  Running agents, supervision trees, and all state are preserved.

  ## Usage

      mix quoracle.reload

  ## Prerequisites

  The server must be started as a named node:

      elixir --sname quoracle -S mix phx.server

  ## Options

    * `--node` - Target node short name (default: `quoracle`)
    * `--dry-run` - Show what would be reloaded without pushing code

  ## What's safe to reload

  Most modules are stateless and reload safely:

    * Action modules (execute/3 functions)
    * Validators, parsers, prompt builders
    * Utility modules, Ecto schema modules
    * LiveView modules (clients reconnect automatically)

  GenServer modules reload safely only when the state shape is unchanged.
  The task warns when reloading GenServer modules.

  ## What still needs a restart

    * Changes to GenServer state struct fields
    * Ecto migrations
    * Supervision tree structure changes
    * Application config changes
  """

  @shortdoc "Hot-reload changed modules on running server"

  use Mix.Task

  @default_node "quoracle"

  @doc "Compiles the project and pushes changed modules to the running server node."
  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [node: :string, dry_run: :boolean])
    node_name = Keyword.get(opts, :node, @default_node)
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.shell().info("Compiling...")
    Mix.Task.run("compile")

    ensure_distributed!()
    target = resolve_target(node_name)

    unless Node.connect(target) do
      Mix.shell().error("Cannot connect to #{target}")
      Mix.shell().error("")
      Mix.shell().error("Is the server running with:")
      Mix.shell().error("  elixir --sname #{node_name} -S mix phx.server")
      exit({:shutdown, 1})
    end

    changed = find_changed_modules(target, beam_directory())

    case {changed, dry_run?} do
      {[], _} ->
        Mix.shell().info("All modules match the running server. Nothing to reload.")

      {modules, true} ->
        report_dry_run(modules, target)

      {modules, false} ->
        push_and_report(modules, target)
    end
  end

  @spec beam_directory() :: String.t()
  defp beam_directory do
    Path.join([Mix.Project.build_path(), "lib", "quoracle", "ebin"])
  end

  @spec resolve_target(String.t()) :: node()
  defp resolve_target(node_name) do
    # Extract hostname from our own node name so both nodes use
    # the same Erlang distribution hostname resolution
    [_, hostname] = Node.self() |> Atom.to_string() |> String.split("@")
    :"#{node_name}@#{hostname}"
  end

  @spec ensure_distributed!() :: :ok
  defp ensure_distributed! do
    if Node.alive?() do
      :ok
    else
      name = :"reload_#{System.unique_integer([:positive])}"

      case Node.start(name, :shortnames) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Mix.shell().error("Cannot start distributed node: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end
  end

  @spec find_changed_modules(node(), String.t()) :: [{module(), String.t(), boolean()}]
  defp find_changed_modules(target, beam_dir) do
    beam_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      module = beam_path_to_module(path)
      local_md5 = path |> File.read!() |> :erlang.md5()

      case :rpc.call(target, :code, :get_object_code, [module]) do
        {^module, remote_binary, _filename} ->
          :erlang.md5(remote_binary) != local_md5

        :error ->
          # New module not yet loaded on remote
          true

        {:badrpc, _reason} ->
          false
      end
    end)
    |> Enum.map(fn path ->
      module = beam_path_to_module(path)
      genserver? = genserver_module?(target, module)
      {module, path, genserver?}
    end)
  end

  @spec beam_path_to_module(String.t()) :: module()
  defp beam_path_to_module(path) do
    path
    |> Path.basename(".beam")
    |> String.to_existing_atom()
  end

  @spec genserver_module?(node(), module()) :: boolean()
  defp genserver_module?(target, module) do
    case :rpc.call(target, module, :__info__, [:attributes]) do
      attrs when is_list(attrs) ->
        attrs
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
        |> Enum.member?(GenServer)

      _ ->
        false
    end
  end

  @spec report_dry_run([{module(), String.t(), boolean()}], node()) :: :ok
  defp report_dry_run(changed, target) do
    {genservers, safe} = Enum.split_with(changed, fn {_, _, gs?} -> gs? end)

    Mix.shell().info("")
    Mix.shell().info("Dry run - would reload #{length(changed)} module(s) on #{target}:")

    if safe != [] do
      Mix.shell().info("")
      Mix.shell().info("  Safe modules (#{length(safe)}):")
      for {mod, _, _} <- safe, do: Mix.shell().info("    #{inspect(mod)}")
    end

    if genservers != [] do
      Mix.shell().info("")

      Mix.shell().info(
        "  GenServer modules (#{length(genservers)}) - state shape must be unchanged:"
      )

      for {mod, _, _} <- genservers, do: Mix.shell().info("    #{inspect(mod)}")
    end

    :ok
  end

  @spec push_and_report([{module(), String.t(), boolean()}], node()) :: :ok
  defp push_and_report(changed, target) do
    results =
      Enum.map(changed, fn {module, path, genserver?} ->
        binary = File.read!(path)

        # Soft-purge old code (safe - won't kill processes still running it)
        :rpc.call(target, :code, :soft_purge, [module])

        case :rpc.call(target, :code, :load_binary, [module, to_charlist(path), binary]) do
          {:module, ^module} when genserver? -> {:warn, module}
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, module, reason}
          {:badrpc, reason} -> {:error, module, {:badrpc, reason}}
        end
      end)

    ok = for {:ok, mod} <- results, do: mod
    warn = for {:warn, mod} <- results, do: mod
    err = for {:error, mod, reason} <- results, do: {mod, reason}

    Mix.shell().info("")

    if ok != [] do
      Mix.shell().info("Reloaded #{length(ok)} module(s):")
      for mod <- ok, do: Mix.shell().info("  #{inspect(mod)}")
    end

    if warn != [] do
      Mix.shell().info("")

      Mix.shell().info(
        "Reloaded #{length(warn)} GenServer module(s) (state shape must be unchanged):"
      )

      for mod <- warn, do: Mix.shell().info("  #{inspect(mod)}")
    end

    if err != [] do
      Mix.shell().info("")
      Mix.shell().error("Failed to reload #{length(err)} module(s):")

      for {mod, reason} <- err do
        Mix.shell().error("  #{inspect(mod)}: #{inspect(reason)}")
      end
    end

    total = length(ok) + length(warn) + length(err)
    succeeded = length(ok) + length(warn)
    Mix.shell().info("")
    Mix.shell().info("Done. #{succeeded}/#{total} modules reloaded on #{target}.")
    :ok
  end
end
