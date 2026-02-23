# lib/quoracle/mcp/

## Modules

- **Client**: Per-agent MCP connection manager (434 lines)
  - GenServer managing connections to MCP servers (stdio/HTTP)
  - Connection deduplication by command/url
  - Agent lifecycle monitoring with automatic cleanup
  - Dependency injection for anubis_module (testability)
  - **v2.0**: Error context capture on initialization timeout
  - **v3.0**: Crash reason propagation via DOWN message capture
  - **v4.0**: Reconnect API, connection dead status, timeout 120s, crash protection in call_tool
  - **v5.0**: Reason-aware logging in terminate/2 (info for normal/shutdown, warning for abnormal)

- **ConnectionManager**: Connection lifecycle extracted from Client (~316 lines)
  - start_and_list_tools/4: Spawn anubis client, poll capabilities, list tools
  - wait_for_initialization/4: Polling with DOWN message capture
  - poll_for_capabilities/4: receive...after for proper synchronization
  - resolve_client_pid/1: Registered name to PID resolution

- **ErrorContext**: Per-connection error context collector (297 lines)
  - Captures telemetry events ([:anubis_mcp, :transport, :error], [:anubis_mcp, :client, :error])
  - Captures Logger output from anubis_mcp domain
  - Process-owned ETS for test isolation (async: true compatible)
  - max_errors/0, max_message_length/0 accessors for DRY constant sharing
  - extract_crash_reason/1: Human-readable message from crash reason tuples (v2.0)

- **ServerConfig**: Application configuration access (46 lines)
  - Runtime access to configured MCP servers
  - Transport types: :stdio, :http
  - Secret template support via SecretResolver

- **AnubisBehaviour**: Behaviour for anubis_mcp mocking (52 lines)
- **AnubisWrapper**: Production wrapper for Anubis.Client (106 lines), default timeout 120_000

## Key Functions

Client:
- start_link/1: Start per-agent MCP client (opts: agent_id, agent_pid, anubis_module)
- connect/2: Connect to MCP server, returns connection_id and tools
- call_tool/5: Execute tool on existing connection, returns {:error, :connection_dead} for dead connections
- reconnect/2: Re-establish dead connection using saved connect_params (v4.0)
- terminate_connection/2: Close specific connection
- list_connections/1: List all active connections

ErrorContext:
- start_link/1: Start collector (opts: connection_ref)
- get_context/1: Retrieve captured errors sorted by timestamp
- stop/1: Detach handlers and cleanup
- extract_crash_reason/1: Crash tuple → human-readable string

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
**Connection Dead Status (v4.0)**: Dead connections retain config (status: :dead, connect_params preserved), reconnect/2 re-establishes using saved params
**Crash Protection (v4.0)**: call_tool wraps anubis call in try/catch :exit, marks connection dead on crash instead of crashing GenServer

## Dependencies

- anubis_mcp library (~> 0.17.0): MCP protocol implementation
- Quoracle.Security.SecretResolver: Auth token resolution
- Ecto.Adapters.SQL.Sandbox: Test isolation
- :telemetry, :logger (OTP): Error capture

## Test Coverage

- error_context_test.exs: 29 tests (lifecycle, telemetry, Logger, concurrent isolation, crash reason extraction)
- client_test.exs: 63 tests (connection lifecycle, deduplication, cleanup, error context, reconnect, dead status, crash protection)
- server_config_test.exs: 7 tests (config access)
- All tests use Hammox mocks for anubis_mcp, async: true

## Recent Changes

**Feb 20, 2026 - MCP Reliability Fix (WorkGroupID: fix-20260219-mcp-reliability)**:
- Client v4.0: Reconnect API, connection dead status, timeout increase 30s→120s, call_tool crash protection
- AnubisWrapper: Default timeout raised to 120_000
- Logger levels fixed: diagnostic traces → Logger.debug, connection_not_found → Logger.warning (REFACTOR)

**Dec 19, 2025 - Flaky Test Fix (WorkGroupID: fix-ui-restore-20251219-064003)**:
- ErrorContext: Changed timestamp precision from millisecond to microsecond

**Dec 16, 2025 - Error Context Capture (WorkGroupID: feat-mcp-error-context-20251216)**:
- ErrorContext v1.0: Per-connection telemetry and Logger capture
- Client v2.0: Error context integration on initialization timeout

**Nov 26, 2025 - Initial Implementation (WorkGroupID: feat-20251126-023746)**:
- Client v1.1: Extracted start_and_list_tools/4 and map_to_keyword/1 helpers
- ServerConfig v1.1: Minimal config access module
