# test/quoracle/agent/consensus_handler/

## Test Files
- ace_injector_test.exs: 65 tests (R1-R15, A1, R61-R73), ACE context injection with newest-first fix
- action_executor_budget_test.exs: R59-R64 (4 tests), ActionExecutor budget_data/spent propagation
- action_executor_http_timeout_test.exs: R78-R82 (5 tests), HTTP action timeout overrides
- action_executor_timeout_test.exs: ActionExecutor timeout tests
- budget_injector_test.exs: Budget context injection tests
- children_injector_test.exs: 26 tests (R1-R28 v2.0 + R30-R36 v3.0), children context injection with message enrichment and Registry fallback
- context_injector_test.exs: 22 tests (R1-R11 + edge cases), context token injection

## v3.0 Children Injector Tests (fix-20260311-211553)
- R30-R36: Registry fallback when state.children empty/partial, graceful degradation, message enrichment of Registry-discovered children
- Uses `register_child_with_parent/3` and `make_parent_registry_with_children/2` helpers for composite Registry value registration
- All async: true with isolated Registry per test
