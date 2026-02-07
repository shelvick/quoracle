# test/quoracle/audit/

## Test Files
- secret_usage_test.exs: 21 tests (CRUD operations, queries, cleanup)

## Coverage
- log_usage/4 and log_usage/5 variations
- Query by secret name, agent ID, action ID
- Recent usage queries with limits
- Cleanup of old entries based on threshold
- Timestamp validation
- Multiple secret logging
- Empty result handling

## Patterns
- async: true for all tests
- Ecto.Sandbox for DB isolation
- Test fixtures for secret usage data
- DateTime manipulation for retention testing
