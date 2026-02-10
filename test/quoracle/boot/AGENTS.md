# test/quoracle/boot/

## Test Files
- agent_revival_test.exs: Boot-time agent revival tests (10 tests, R1-R10)

## Test Patterns
- async: true (tests behavior not Logger output)
- @moduletag capture_log: true (suppresses Logger output)
- IsolationHelpers.create_isolated_deps/0 for Registry/DynSup/PubSub
- create_task_with_cleanup/2 for test data with cleanup

## Coverage
| Req | Test | Type |
|-----|------|------|
| R1 | Empty database | Unit |
| R2 | Single task restore | Integration |
| R3 | Multiple tasks | Integration |
| R4 | Failure isolation | Integration |
| R5 | Status unchanged | Integration |
| R8 | Dependency injection | Unit |
| R9 | Exception safety | Unit |
| R10 | Always returns ok | Unit |

Note: R6/R7 (logging tests) removed - tested implementation details rather than behavior
