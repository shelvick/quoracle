# lib/quoracle/budget/

## Modules
- Schema: Budget data types, serialization, committed management
- Tracker: Budget calculations (available = allocated - spent - committed)
- Escrow: Parent-child allocation lock/release
- Enforcer: Pre-action budget gating

## Key Functions

### Schema
- `new_root/1`: Decimal|nil → budget_data (:root or :na mode)
- `new_allocated/1`: Decimal → budget_data (:allocated mode)
- `serialize/1`, `deserialize/1`: JSONB round-trip
- `add_committed/2`, `release_committed/2`: Escrow management

### Tracker
- `get_spent/1`: agent_id → Decimal (queries agent_costs table)
- `calculate_available/2`: budget_data × spent → Decimal|nil
- `get_status/2`: budget_data × spent → :ok|:warning|:over_budget|:na
- `over_budget?/2`: budget_data × spent → boolean
- `has_available?/3`: budget_data × spent × required → boolean
- `validate_budget_decrease/3`: budget_data × spent × new_allocated → :ok|{:error, map} (v2.0)

### Escrow
- `validate_allocation/3`: budget_data × spent × amount → :ok|{:error, :insufficient_budget}
- `lock_allocation/3`: budget_data × spent × amount → {:ok, budget_data}|{:error, ...}
- `release_allocation/3`: budget_data × child_allocated × child_spent → {:ok, budget_data, unspent}
- `adjust_child_allocation/4`: parent_budget × current × new × spent → {:ok, budget_data}|{:error, term} (v2.0)

### Enforcer
- `check_action/4`: action × params × budget_data × spent → :allowed|{:blocked, :over_budget}
- `costly_action?/2`: action × params → boolean
- `classify_action/2`: action × params → :costly|:free

## Patterns
- Spent NOT stored in state - always queried from agent_costs (single source of truth)
- Available = allocated - spent - committed (computed, not stored)
- N/A mode: allocated=nil means unlimited budget
- Decimal for all money values (precision)
- Pure functional modules (no GenServer state)

## Dependencies
- Quoracle.Costs.Aggregator: Spent queries
- Decimal: All calculations
- AGENT_Core: Stores budget_data in state

## Tests
- test/quoracle/budget/schema_test.exs: 8 unit tests
- test/quoracle/budget/tracker_test.exs: 11 unit + 2 property tests
- test/quoracle/budget/escrow_test.exs: 9 unit + 1 property test
- test/quoracle/budget/enforcer_test.exs: All action classification
- test/quoracle/budget/budget_acceptance_test.exs: E2E lifecycle (361 lines)
