# lib/quoracle/

## Application Structure
- application.ex: OTP application supervision tree
- repo.ex: Ecto repository definition

## Subdirectories
- agent/: Core agent system with MessageHandler extraction (7 modules)
- action/: Action routing and execution system
- models/: LLM model configuration and management
- providers/: Provider-specific API implementations
- security/: Secret resolution and output scrubbing (added 2025-10-24)
- audit/: Secret usage tracking (added 2025-10-24)
- mcp/: Model Context Protocol client and configuration (added 2025-11-26)
- costs/: Agent cost tracking - AgentCost schema, Recorder, Aggregator (added 2025-12-13)

## Supervision Tree
```
Quoracle.Supervisor
├── Quoracle.Vault (Cloak encryption)
├── Quoracle.Repo (PostgreSQL connection)
├── QuoracleWeb.Telemetry (metrics)
├── Phoenix.PubSub (inter-process messaging)
├── Registry (agent discovery, unique keys)
├── Quoracle.Models.EmbeddingCache (ETS owner)
├── Quoracle.Agent.DynSup (dynamic supervisor)
└── QuoracleWeb.Endpoint (Phoenix HTTP/WebSocket)
```

## Key Patterns
- OTP supervision with one_for_one strategy
- Ecto for database operations
- GenServer for stateful components
- Behaviour-based abstractions

## Configuration
- Database: PostgreSQL via Ecto
- Environment: dev/test/prod configs
- Credentials: Environment variables

## Dependencies
- Phoenix framework (future LiveView)
- Ecto + PostgreSQL
- HTTPoison for HTTP
- Jason for JSON
- ExVCR for test mocking