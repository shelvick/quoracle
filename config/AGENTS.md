# config/

## Files
- config.exs: Base configuration (DB, Ecto, Cloak structure)
- runtime.exs: Runtime config loading (encryption keys from env)
- dev.exs: Development environment settings
- test.exs: Test environment settings with ExVCR config

## Key Settings
- Cloak.Vault: AES-256-GCM encryption, CLOAK_ENCRYPTION_KEY env var (runtime.exs), fixed test key
- ExVCR: Filters api-key, Authorization, X-goog-api-key, x-api-key headers
- Production: CLOAK_ENCRYPTION_KEY required