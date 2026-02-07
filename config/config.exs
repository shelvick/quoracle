import Config

# Configure Phoenix endpoint
config :quoracle, QuoracleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: QuoracleWeb.ErrorHTML, json: QuoracleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Quoracle.PubSub,
  live_view: [signing_salt: "Ey3Qz8kP"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  quoracle: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  quoracle: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :domain]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure your database
config :quoracle, Quoracle.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "quoracle_#{config_env()}",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Configure Ecto repos
config :quoracle, ecto_repos: [Quoracle.Repo]

# Configure Cloak encryption
# Cipher configuration is set in runtime.exs based on environment
config :quoracle, Quoracle.Vault, []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
