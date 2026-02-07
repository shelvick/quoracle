# lib/quoracle/profiles/

## Purpose
Profile system for agent permissions and model pool configuration. Uses selectable capability groups (checkboxes) for fine-grained permission control. Provides two-layer defense: PromptBuilder filters actions from LLM schema + Router blocks at runtime.

## Modules

**CapabilityGroups** (104 lines): Pure module defining 5 selectable capability groups
- Groups: `:file_read`, `:file_write`, `:external_api`, `:hierarchy`, `:local_execution`
- Functions: `groups/0`, `group_actions/1`, `allowed_actions_for_groups/1`, `action_allowed?/2`, `base_actions/0`, `get_group_description/1`
- Base actions (7): always allowed regardless of selected groups

**ActionGate** (109 lines): Runtime permission checker called by Router
- Functions: `check/2`, `check!/2`, `filter_actions/2`
- Accepts `[atom()]` capability_groups list
- Used by PromptBuilder to filter schemas before LLM sees them
- Used by Router to block actions at execution time

**Resolver** (103 lines): Profile lookup service with snapshot semantics
- Functions: `resolve/1`, `resolve!/1`, `exists?/1`, `list_names/0`
- Returns `capability_groups` as atoms (converted from DB strings)

**TableProfiles** (93 lines): Ecto schema for profiles table
- Fields: `name`, `description`, `model_pool`, `capability_groups`
- v2.0: `capability_groups` as `{:array, :string}`, converted to atoms via `capability_groups_as_atoms/1`
- Validations: name format, model_pool min length, capability_groups values

**Error Modules**:
- `ActionNotAllowedError` - raised when action blocked (includes capability_groups in message)
- `ProfileNotFoundError` - raised when profile name not found

## Capability Groups (v2.0)

| Group | Actions | Description |
|-------|---------|-------------|
| `:file_read` | file_read | Read files from filesystem |
| `:file_write` | file_write, search_secrets, generate_secret | Write/edit files |
| `:external_api` | call_api, record_cost, search_secrets, generate_secret | HTTP to external APIs |
| `:hierarchy` | spawn_child, dismiss_child, adjust_budget | Agent hierarchy management |
| `:local_execution` | execute_shell, call_mcp, record_cost, search_secrets, generate_secret | Local system access |

**Base Actions** (always allowed): wait, orient, todo, send_message, fetch_web, answer_engine, generate_images

## Integration Points

- **ACTION_Router.ClientAPI**: Calls `ActionGate.check/2` with `capability_groups` from opts
- **CONSENSUS_PromptBuilder**: Calls `ActionGate.filter_actions/2` to filter schemas
- **ACTION_Spawn**: Calls `Resolver.resolve/1` to get profile data for child
- **AGENT_ConfigManager**: Stores resolved profile (with capability_groups) in agent state

## Test Coverage

- `capability_groups_test.exs` - 31 unit tests (R1-R11)
- `action_gate_test.exs` - 7 unit tests
- `resolver_test.exs` - 14 integration tests
- `table_profiles_test.exs` - 14 unit tests
- `capability_groups_integration_test.exs` - 20 tests (R1-R8, 4 acceptance)
- `spawn_integration_test.exs` - 20 tests (7 acceptance for capability_groups)
- `file_autonomy_test.exs` - 26 tests (R12-R18)
- `migrations_test.exs` - 16 tests

Total: 236 tests, all async: true
