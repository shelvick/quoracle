import Config

# Configure your database
config :quoracle, Quoracle.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "quoracle_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  log: false

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :quoracle, QuoracleWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "F2N3WxZ9k8hNp7xL4mQ6vB5sT1yC9jG3kM2nR8wE5tU7aP4dX6cS9bV1mL3qY8f5",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:quoracle, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:quoracle, ~w(--watch)]}
  ]

# Watch static and templates for browser reloading.
config :quoracle, QuoracleWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/quoracle_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :quoracle, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Suppress noisy LiveView handle_event debug logs (keystrokes, UI toggles)
config :phoenix_live_view, log: :warning

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Use non-blocking local mailer in development to avoid auth/registration hangs
config :quoracle, Quoracle.Mailer, adapter: Swoosh.Adapters.Local
