# lib/quoracle/actions/schema/

## Modules (Extracted for <500 line requirement)

**Public API Layer**:
- Definitions: Public API (52 lines, delegates to SchemaDefinitions)

**Schema Aggregation**:
- SchemaDefinitions: Aggregator (18 lines, merges AgentSchemas + ApiSchemas)

**Schema Data** (split by action category):
- AgentSchemas: Agent actions (199 lines: spawn_child, wait, send_message, orient, todo)
- ApiSchemas: API/integration actions (295 lines: answer_engine, execute_shell, fetch_web, call_api, call_mcp, generate_secret, search_secrets, file_read, file_write)

**Supporting Modules**:
- ActionList: Action registry (44 lines, 14 actions, compile-time atom creation)
- Metadata: LLM guidance (81 lines, action_descriptions with WHEN/HOW, priorities 1-14)

## Functions

SchemaDefinitions:
- schemas/0: %{action → schema} - Merges AgentSchemas + ApiSchemas

AgentSchemas & ApiSchemas:
- schemas/0: %{action → schema} - Action-specific parameter definitions
- Contains param_types, consensus_rules, param_descriptions

ActionList:
- actions/0: [atom()] - Single source of truth for available actions

Metadata:
- descriptions/0: %{action → description} - WHEN/HOW guidance for LLMs
- priorities/0: %{action → integer} - Consensus tiebreaking (1-14)

## Patterns

**Module extraction**: Split Definitions (546 lines) → 6 modules (all <500 lines)
**Separation of concerns**: Validation (SchemaDefinitions) vs LLM guidance (Metadata), Agent vs API actions
**Compile-time safety**: ActionList creates atoms at compile time (orient params, send_message targets)
**Type definitions**: Nested map types with :all_optional flag (default_fields)
**Enum types**: Type-safe values (cognitive_style, output_style, delegation_strategy, method, format)

## Dependencies

ActionList → none (foundational)
AgentSchemas → ActionList
ApiSchemas → ActionList
SchemaDefinitions → AgentSchemas, ApiSchemas
Definitions (public API) → SchemaDefinitions
Metadata → none (pure data)

Parent module (Schema.ex) delegates to Definitions and Metadata

## Recent Changes (Nov 18, 2025 - REFACTOR)

**Schema split for 500-line limit** (commit 6bf7abe):
- Created AgentSchemas (199 lines): spawn_child, wait, send_message, orient, todo
- Created ApiSchemas (317 lines): answer_engine, execute_shell, fetch_web, call_api, call_mcp, generate_secret
- Created SchemaDefinitions (18 lines): Merges sub-modules via Map.merge
- Updated Definitions (52 lines, down from 546): Now delegates to SchemaDefinitions
- Public API unchanged - transparent refactoring
