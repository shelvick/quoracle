import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :quoracle, QuoracleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "F2N3WxZ9k8hNp7xL4mQ6vB5sT1yC9jG3kM2nR8wE5tU7aP4dX6cS9bV1mL3qY8fZ",
  server: false

# Configure your database
config :quoracle, Quoracle.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "quoracle_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Must exceed max_cases (16) + headroom for spawned processes
  # Increased to 8x to handle heavy parallel test load with 10x determinism runs
  pool_size: System.schedulers_online() * 8,
  # Increase queue timeouts for CI/heavy parallel load scenarios
  queue_target: 5000,
  queue_interval: 30_000

# Set environment for runtime checks
config :quoracle, :env, :test

# Flag to indicate SQL sandbox mode for test database isolation
config :quoracle, :sql_sandbox, true

# Print only errors during test (suppress warnings from expected test failures)
config :logger, level: :error

# Filter out Postgrex/DB infrastructure errors at runtime (expected in defensive tests)
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :domain]

# Suppress Ecto debug logs in tests
config :quoracle, Quoracle.Repo, log: false

# Disable anubis_mcp logging in tests
# Why: anubis_mcp's transport processes log "stdio_down" during cleanup.
# These logs cannot be captured by ExUnit.CaptureLog because they originate
# from separate processes (the transport layer) that are not spawned by
# our test code. The library overrides configured log levels in call sites,
# so logging config alone cannot suppress them.
config :anubis_mcp, :log, false

# Configure MCP test servers
config :quoracle, :mcp_servers, [
  %{
    name: "test_server",
    transport: :stdio,
    command: "echo test",
    timeout: 30_000
  },
  %{
    name: "test_http_server",
    transport: :http,
    url: "http://localhost:9999/mcp",
    timeout: 30_000
  }
]
