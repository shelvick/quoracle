# test/quoracle/costs/

## Test Files
- agent_cost_test.exs: 29 tests (schema validation, Decimal precision, JSONB)
- recorder_test.exs: 28 tests (recording, PubSub broadcast, safe_broadcast)
- aggregator_test.exs: 36 tests (agent/task/model queries, recursive CTE)

## Coverage
- Schema: Required fields, cost_type enum, nil cost_usd, foreign key constraint
- Recorder: Insert, broadcast to both topics, silent mode, PubSub cleanup handling
- Aggregator: by_agent, by_agent_children, by_task, by_model, recursive descendants

## Test Patterns
- async: true for all tests
- Isolated PubSub per test (start_supervised!)
- start_owner! for DB sandbox
- Property tests for aggregation consistency

## Key Test Assertions
- Decimal precision preserved to 10 places
- Children costs exclude self
- Task total equals sum of agent totals
- Nil costs excluded from sums but counted in requests
