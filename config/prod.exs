import Config

# Note: runtime configuration (DATABASE_URL, SECRET_KEY_BASE, etc.)
# is handled in config/runtime.exs, which is evaluated at boot.

# Do not print debug messages in production
config :logger, level: :info
