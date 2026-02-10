# lib/quoracle/actions/api/

## Modules (API Action Sub-Components)

**Core Orchestrator**:
- API: Main action module (289 lines, 3-arity execute/3, protocol orchestration)

**HTTP Layer**:
- RequestBuilder: Request construction for REST/GraphQL/JSON-RPC (139 lines)
- ResponseParser: Protocol-specific response parsing (178 lines)

**Authentication**:
- AuthHandler: Auth strategy application (139 lines, Bearer/Basic/API Key/OAuth2)

**Protocol Adapters**:
- GraphQLAdapter: GraphQL query/mutation formatting (87 lines, oneOf for variables)
- JSONRPCAdapter: JSON-RPC 2.0 request/response handling (94 lines, UUID generation)

## Key Functions

API.execute/3:
- resolve_secrets → flatten_auth_params → build → apply_auth → execute_request → parse → scrub_output
- Returns {:ok, %{action: "call_api", status_code:, data:, errors:, headers:, response_size:, execution_time_ms:, api_type:, url:}}

flatten_auth_params/1:
- Transforms nested Schema format %{auth: %{type:, token:}} → flattened %{auth_type:, auth_token:}
- Bridges Schema API and AuthHandler interfaces

RequestBuilder.build/1:
- REST: method, url, headers, query_params, body
- GraphQL: POST with {query:, variables:} body
- JSON-RPC: POST with {jsonrpc: "2.0", method:, params:, id:}
- Returns Req.Request.t()

ResponseParser.parse/2:
- REST: Status code → semantic errors, JSON/text parsing
- GraphQL: Partial success support (data + errors both present returns {:ok})
- JSON-RPC: result vs error field extraction

AuthHandler.apply_auth/2:
- Map-based headers (Map.put pattern, not list prepending)
- Bearer: Authorization header
- Basic: Base64 encoding
- API Key: Custom header or query param
- OAuth2: Client credentials exchange for access token

## Patterns

**Orchestration**: API.execute/3 delegates to specialized modules
**Adapter pattern**: Protocol-specific logic isolated (GraphQL/JSON-RPC adapters)
**Parameter transformation**: flatten_auth_params bridges format mismatch
**Map-based headers**: Elixir idiomatic Map.put vs list prepending
**Error tuples**: Consistent {:ok, result} | {:error, atom()} throughout
**Security integration**: SecretResolver for {{SECRET:name}} templates, OutputScrubber for response sanitization

## Dependencies

API → RequestBuilder, ResponseParser, AuthHandler, SecretResolver, OutputScrubber
AuthHandler → (independent, no HTTP calls)
RequestBuilder → Req library
ResponseParser → Jason (JSON parsing)
GraphQLAdapter → Jason
JSONRPCAdapter → Jason, UUID

External: Req (HTTP client), Jason (JSON), UUID

## Test Coverage

- api_test.exs: VCR cassettes with Finch adapter (async: false)
- auth_handler_test.exs: Map-based header fixtures (23 tests)
- auth_handler_secret_integration_test.exs: Secret resolution integration (11 tests)
- request_builder_test.exs: Protocol-specific request construction
- response_parser_test.exs: Protocol-specific parsing, status code mapping
- graphql_adapter_test.exs: Query formatting, partial success
- jsonrpc_adapter_test.exs: 2.0 format validation, ID matching

## Recent Changes (Nov 18, 2025)

**REFACTOR - AuthHandler Integration**:
- API.ex: Added flatten_auth_params/2 (lines 60-87) to transform Schema nested auth → AuthHandler flattened params
- Removed 13 lines of duplicate inline authentication code
- 289 lines (down from 302)

**REFACTOR - Map-based Headers**:
- AuthHandler: Changed from list prepending `[{key, value} | headers]` to `Map.put(headers, key, value)`
- All auth methods updated: apply_bearer_auth/2, apply_basic_auth/2, apply_api_key_auth/2, apply_oauth2_auth/2
- Better Elixir idioms and pattern matching
- Test fixtures updated in auth_handler_test.exs and auth_handler_secret_integration_test.exs

**Implementation Note**: flatten_auth_params is architectural adapter, not "legacy code" - intentional bridge between Schema API format (nested for LLM clarity) and AuthHandler internal format (flattened for processing)
