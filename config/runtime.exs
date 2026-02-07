import Config

# =============================================================================
# Production Configuration
# =============================================================================
#
# All production config is read from environment variables at runtime.
# This file is evaluated at boot (not compile time), so changes to env vars
# take effect on restart without rebuilding the release.

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      Environment variable DATABASE_URL is missing.

      Example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :quoracle, Quoracle.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      Environment variable SECRET_KEY_BASE is missing.

      You can generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  bind_ip =
    case System.get_env("PHX_BIND_ADDRESS") do
      "0.0.0.0" -> {0, 0, 0, 0}
      "::" -> {0, 0, 0, 0, 0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end

  config :quoracle, QuoracleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: bind_ip,
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  cloak_key =
    System.get_env("CLOAK_ENCRYPTION_KEY") ||
      raise """
      Environment variable CLOAK_ENCRYPTION_KEY is missing.

      You can generate a proper 256-bit Base64-encoded key with:
        elixir -e "32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()"

      Then set it in your environment:
        export CLOAK_ENCRYPTION_KEY="your-generated-key"
      """

  config :quoracle, Quoracle.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
      }
    ]
end

# =============================================================================
# Dev Configuration (runtime overrides)
# =============================================================================

if config_env() == :dev do
  # Database: override with DATABASE_URL, or fall back to dev.exs defaults
  if database_url = System.get_env("DATABASE_URL") do
    config :quoracle, Quoracle.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  end

  # Endpoint: override host/port/bind address if env vars are set
  if port = System.get_env("PORT") do
    host = System.get_env("PHX_HOST") || "localhost"

    bind_ip =
      case System.get_env("PHX_BIND_ADDRESS") do
        "0.0.0.0" -> {0, 0, 0, 0}
        "::" -> {0, 0, 0, 0, 0, 0, 0, 0}
        _ -> {127, 0, 0, 1}
      end

    config :quoracle, QuoracleWeb.Endpoint,
      http: [ip: bind_ip, port: String.to_integer(port)],
      url: [host: host, port: String.to_integer(port)]
  end

  # Secret key base: override if set
  if secret_key_base = System.get_env("SECRET_KEY_BASE") do
    config :quoracle, QuoracleWeb.Endpoint, secret_key_base: secret_key_base
  end

  # Cloak encryption: optional in dev
  case System.get_env("CLOAK_ENCRYPTION_KEY") do
    nil ->
      # Vault won't start — encryption features unavailable until key is set
      :ok

    cloak_key ->
      config :quoracle, Quoracle.Vault,
        ciphers: [
          default: {
            Cloak.Ciphers.AES.GCM,
            tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
          }
        ]
  end
end

# =============================================================================
# Test Configuration
# =============================================================================

if config_env() == :test do
  config :quoracle, Quoracle.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1",
        key: Base.decode64!("7Xn3r9SAIw4kANl91jiMqsNSyLJD/5vBfLKqsZH0P2I="),
        iv_length: 12
      }
    ]
end
