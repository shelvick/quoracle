# lib/quoracle/mcp/

## Modules

- **Client**: Per-agent MCP connection manager (455 lines)
  - GenServer managing connections to MCP servers (stdio/HTTP)
  - Connection deduplication by command/url
  - Agent lifecycle monitoring with automatic cleanup
  - Dependency injection for anubis_module (testability)
  - **v2.0**: Error context capture on initialization timeout

- **ErrorContext**: Per-connection error context collector (297 lines)
  - Captures telemetry events ([:anubis_mcp, :transport, :error], [:anubis_mcp, :client, :error])
  - Captures Logger output from anubis_mcp domain
  - Process-owned ETS for test isolation (async: true compatible)
  - max_errors/0, max_message_length/0 accessors for DRY constant sharing

- **ServerConfig**: Application configuration access (46 lines)
  - Runtime access to configured MCP servers
  - Transport types: :stdio, :http
  - Secret template support via SecretResolver

- **AnubisBehaviour**: Behaviour for anubis_mcp mocking (52 lines)
- **AnubisWrapper**: Production wrapper for Anubis.Client (68 lines)

## Key Functions

Client:
- start_link/1: Start per-agent MCP client (opts: agent_id, agent_pid, anubis_module)
- connect/2: Connect to MCP server, returns connection_id and tools
- call_tool/5: Execute tool on existing connection
- terminate_connection/2: Close specific connection
- list_connections/1: List all active connections

ErrorContext:
- start_link/1: Start collector (opts: connection_ref)
- get_context/1: Retrieve captured errors sorted by timestamp
- stop/1: Detach handlers and cleanup
- max_errors/0: Returns 20 (constant accessor)
- max_message_length/0: Returns 200 (constant accessor)

ServerConfig:
- list_servers/0: Get all configured MCP servers
- get_server/1: Get specific server by name
- server_exists?/1: Check if server is configured

## Patterns

**Error Context Lifecycle**: ErrorContext created per connection attempt, captures errors during init, cleaned up after
**Timeout Error Format**: `{:error, {:initialization_timeout, context: [%{type, message, timestamp, source}]}}`
**Dependency Injection**: anubis_module injectable for testing (default: AnubisWrapper)
**Agent Lifecycle Coupling**: Client monitors agent_pid, auto-terminates on agent death
**Connection Deduplication**: Same command/url returns existing connection_id
**Sandbox Support**: sandbox_owner propagation for test DB access

## Dependencies

- anubis_mcp library (~> 0.16.0): MCP protocol implementation
- Quoracle.Security.SecretResolver: Auth token resolution
- Ecto.Adapters.SQL.Sandbox: Test isolation
- :telemetry, :logger (OTP): Error capture

## Test Coverage

- error_context_test.exs: 16 tests (lifecycle, telemetry, Logger, concurrent isolation)
- client_test.exs: 37 tests (connection lifecycle, deduplication, cleanup, error context)
- server_config_test.exs: 7 tests (config access)
- All tests use Hammox mocks for anubis_mcp, async: true

## Recent Changes

**Dec 19, 2025 - Flaky Test Fix (WorkGroupID: fix-ui-restore-20251219-064003)**:
- ErrorContext: Changed timestamp precision from millisecond to microsecond
- Prevents cross-test contamination when parallel tests start in same millisecond
- Affected lines: 140, 201, 267 (start_time and timestamp comparisons)

**Dec 16, 2025 - Error Context Capture (WorkGroupID: feat-mcp-error-context-20251216)**:
- ErrorContext v1.0: Per-connection telemetry and Logger capture
- Client v2.0: Error context integration on initialization timeout
- Added max_errors/0, max_message_length/0 accessors (REFACTOR - DRY)

**Nov 26, 2025 - Initial Implementation (WorkGroupID: feat-20251126-023746)**:
- Client v1.1: Extracted start_and_list_tools/4 and map_to_keyword/1 helpers
- ServerConfig v1.1: Minimal config access module
