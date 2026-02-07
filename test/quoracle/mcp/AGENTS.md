# test/quoracle/mcp/

## Test Files

- **error_context_test.exs**: 16 tests (ErrorContext lifecycle, telemetry, Logger capture)
  - R1-R11: Unit/integration tests for telemetry and Logger handlers
  - Concurrent collector isolation tests
  - async: true, uses real :telemetry.execute and Logger

- **client_test.exs**: 37 tests (MCP Client GenServer)
  - Connection lifecycle, deduplication, cleanup
  - R15-R20: Error context integration tests
  - async: true, Hammox mocks for anubis_mcp
  - @moduletag capture_log: true (anubis transport termination logs)

- **anubis_wrapper_test.exs**: AnubisWrapper integration tests
  - async: true, capture_log: true

- **server_config_test.exs**: 7 tests (MCP server configuration)
  - async: true

## Patterns

- Hammox mocks for anubis_mcp behavior (AnubisMock)
- Real :telemetry.execute for ErrorContext testing
- capture_log for GenServer termination log noise
- All tests async: true for parallel execution

## Dependencies

- Hammox for behaviour mocking
- test/support/mocks.ex defines Quoracle.MCP.AnubisMock
