defmodule Quoracle.MixProject do
  use Mix.Project

  def project do
    [
      app: :quoracle,
      version: "0.1.9",
      elixir: "~> 1.18",
      listeners: [Phoenix.CodeReloader],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [
        summary: [threshold: 70]
      ],
      cli: cli(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Quoracle.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # CLI configuration
  defp cli do
    [
      preferred_envs: [
        "test.live": :test
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: [
        "deps.get",
        "deps.compile llm_db --force",
        "ecto.setup",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind quoracle", "esbuild quoracle"],
      "assets.deploy": [
        "tailwind quoracle --minify",
        "esbuild quoracle --minify",
        "phx.digest"
      ]
    ]
  end

  defp releases do
    [
      quoracle: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, &tar_with_prefix/1]
      ]
    ]
  end

  # Custom release step: tar with a top-level directory (quoracle-VERSION/)
  defp tar_with_prefix(%Mix.Release{} = release) do
    name = "#{release.name}-#{release.version}"
    rel_parent = Path.dirname(release.path)
    build_dir = Path.dirname(rel_parent)
    dir = Path.basename(release.path)

    {_, 0} =
      System.cmd(
        "tar",
        [
          "czf",
          Path.join(build_dir, "#{name}.tar.gz"),
          "--transform",
          "s/^#{dir}/#{name}/",
          dir
        ],
        cd: rel_parent
      )

    release
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Development and test dependencies
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},

      # Phoenix and LiveView
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:floki, "~> 0.38.0"},
      {:req, "~> 0.5.15"},
      {:htmd, "~> 0.2.0"},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.5",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:plug_cowboy, "~> 2.5"},

      # Database
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:cloak_ecto, "~> 1.3"},

      # JSON
      {:jason, "~> 1.4"},

      # YAML (for skills system)
      {:yaml_elixir, "~> 2.11"},

      # Token counting
      {:tiktoken, "~> 0.4"},

      # MCP (Model Context Protocol)
      {:anubis_mcp, "~> 0.17.0"},

      # LLM client
      {:req_llm, "~> 1.5"},
      {:llm_db, "~> 2026.2", override: true},
      {:req_cassette, "~> 0.5", only: :test},

      # Image resizing
      {:image, "~> 0.54"}
    ]
  end
end
