# lib/quoracle/audit/

## Modules
- SecretUsage: Audit trail for secret access tracking

## Key Functions
- log_usage/4: Record secret access (secret_names, agent_id, action_id, module)
- log_usage/5: Record with explicit context
- get_usage_for_secret/1: Query all usage of specific secret
- get_usage_by_agent/1: Query all secrets accessed by agent
- get_usage_by_action/1: Query secrets used in specific action
- get_recent_usage/1: Query recent usage (default 100 entries)
- cleanup_old_entries/1: Delete entries older than threshold

## Data Structure
```elixir
%SecretUsage{
  secret_name: String.t(),
  agent_id: String.t(),
  action_id: String.t(),
  context: String.t(),
  accessed_at: DateTime.t()
}
```

## Patterns
- Automatic timestamping with DateTime.utc_now()
- Batch logging for multiple secrets
- Flexible querying by secret/agent/action
- Retention policy support via cleanup_old_entries/1
- DB-backed persistence for compliance

## Dependencies
- Quoracle.Models.TableSecretUsage schema
- Integrated into ACTION_Router.Execution

Test coverage: 21 secret_usage tests (CRUD, queries, cleanup)
