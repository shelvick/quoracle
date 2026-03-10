# lib/quoracle/actions/

## Modules

**Schema System** (6-module architecture, 888 lines):
- Schema: Public API (get_schema/1, list_actions/0, validate_action_type/1, get_action_description/1, get_action_priority/1, wait_required?/1)
- Schema.ActionList: Action registry (26 actions, v30.0 added batch_async)
- Schema.Definitions: Public API layer (52 lines, delegates to SchemaDefinitions)
- Schema.SchemaDefinitions: Aggregator (18 lines, merges AgentSchemas + ApiSchemas)
- Schema.AgentSchemas: Agent actions (199 lines: spawn_child, wait, send_message, orient, todo)
- Schema.ApiSchemas: API/integration actions (395 lines: answer_engine, execute_shell, fetch_web, call_api, call_mcp, generate_secret, search_secrets, file_read, file_write)
- Schema.Metadata: LLM descriptions with WHEN/HOW guidance, priorities

**Validator** (270 lines, v12.0): Parameter validation, XOR enforcement, enum validation, boolean type support, default_fields nested map with :all_optional, `spawn_profile_optional?/2` for topology-based profile optionality, `validate_params/3` with opts for grove_topology threading

**Action Implementations**:
- Orient: 12-field strategic reflection (144 lines)
- Spawn: Child agent spawning with grove spawn contracts (471 lines, v21.0), ConfigBuilder 273 lines, Helpers 82 lines, BudgetValidation 113 lines, TopologyResolver 137 lines (NEW, extracted for 500-line limit), dismissing flag check (v11.0), profile parameter (v14.0), budget enforcement (v17.0), TopologyResolver.apply_spawn_contract/2 consults grove topology edges at spawn time
- Wait: Unified wait parameter (142 lines, true/false/number support, interruptible)
- SendMessage: Parent/child messaging (3-arity)
- DismissChild: Recursive child termination (378 lines, v6.0), async background dispatch to TreeTerminator, child_dismissed notification, budget reconciliation with atomic batch absorption (Recorder.record_batch/2), sentinel "(external)" model_spec for non-model costs, escrow-first release ordering, absorption_ctx map for clean parameter passing
- Answer (263 lines): Gemini grounding search
  - Model from ConfigModelSettings.get_answer_engine_model!() (config-driven)
  - Raises RuntimeError if answer engine model not configured
- Web: HTML fetch with html2markdown
- Shell: Command execution with status checking (366 lines, 4 sub-modules: Execution, StatusCheck, Termination, ShellHandlers)
  - StatusCheck: Split API - execute/2 (external) vs execute_with_state/3 (Router deadlock prevention)
  - Termination: wait_for_port_death after SIGKILL prevents Task hang (v29.0)
  - v4.0: `enforce_grove_policies/3` pre-execution checks (hard rules + working dir confinement)
  - v4.0: Extracts `grove_hard_rules`, `grove_confinement`, `skill_name` from `opts[:parent_config]`
- Todo: Task list management
- GenerateSecret: Random password generation
- SearchSecrets: Search secret names by terms (48 lines, no access control)
- API: External API calls (289 lines, REST/GraphQL/JSON-RPC, see api/AGENTS.md for sub-components)
- MCP: Model Context Protocol tool calling (203 lines, 3 modes: connect/call/terminate), v3.0 retry with exponential backoff, v3.1 action field + response truncation
- FileRead: File reading with line numbers (162 lines, v2.0), offset/limit support, binary detection, v2.0 confinement check via `HardRuleEnforcer.check_file_access(path, :read, confinement, skill_name)` in with-chain
- FileWrite: File creation and editing (224 lines, v3.0), Claude Code edit semantics, exact string matching, grove schema validation hook via `validate_schema/3` delegates to `SchemaValidator.validate_file_write/5`, v3.0 `validate_confinement/3` checks before schema validation and filesystem write
- BatchSync: Batched action execution (87 lines), delegates batchable_actions() to ActionList, sequential with early termination
- BatchAsync: Parallel batch execution (127 lines), fire-and-forget with wait:false, per-action Router spawning

**Shared Modules**:
- Shared.BatchValidation: DRY validation for batch_sync and batch_async (110 lines)

**Validator Sub-modules** (extracted for 500-line limit):
- Validator.TypeValidation: All type validation logic (262 lines, NEW — wip-20260228-spawn-contracts), validate_param_types/2, validate_type/2, nested map, enum, union types
- Validator.BatchSync: batch_sync validation (98 lines) - nested action list validation
- Validator.BatchAsync: batch_async validation (delegates to Shared.BatchValidation)

**Spawn Sub-modules**:
- Spawn.ConfigBuilder: Agent config construction (324 lines), build_config/6, inheritable_keys whitelist includes grove_topology + grove_path + grove_schemas + grove_workspace (v22.0), accumulated_narrative de-duplication regex, stores :initial_message in config (v24.0)
- Spawn.BudgetValidation: Budget enforcement (113 lines)
- Spawn.Helpers: Shared helpers (82 lines)
- Spawn.TopologyResolver: Grove topology consultation (137 lines, NEW — wip-20260228-spawn-contracts), apply_spawn_contract/2, resolve_profile_data/2, resolve_grove_skills_path/1
- Spawn.ConfigBuilder v23.0: Added `:grove_confinement` to `inheritable_keys` whitelist (child agents inherit confinement)

**Router**: Action dispatch with access control (480 lines, ClientAPI 139 lines), autonomy permission check via ActionGate (v23.0)
- terminate/2: 30s safety timeout for shell_task cleanup (v29.0), prevents indefinite hang
- ShellHandlers: Extracted shell lifecycle (267 lines) - handle_get_status/1, handle_terminate_shell/1, kill_os_process/1

## Key Functions

Schema system:
- get_schema/1: {:ok, schema} | {:error, :unknown_action}
- list_actions/0: [atom()] (26 actions)
- validate_action_type/1: {:ok, atom} | {:error, :unknown_action}
- get_action_description/1: String.t() - WHEN/HOW guidance
- get_action_priority/1: integer() - 1-19 for tiebreaking
- wait_required?/1: boolean() - only :wait returns false

Validator:
- validate/2: map × atom → {:ok, map} | {:error, reasons}
- Handles XOR params (execute_shell)
- Enum validation (cognitive_style, output_style, delegation_strategy, method, format)
- Nested map validation (default_fields with :all_optional)

Router:
- execute/3: agent_pid × action_map × opts → {:ok, result} | {:error, reason}
- Generic dispatch pattern

## Patterns

**Module extraction**: Large modules split for <500 line requirement
**XOR parameters**: Mutually exclusive params (execute_shell: command ⊻ check_id)
**Enum types**: Type-safe parameter values (cognitive_style: 5 values, output_style: 4, delegation_strategy: 3)
**param_descriptions**: LLM-facing parameter explanations for all actions
**downstream_constraints**: Spawn parameter accumulates through hierarchy
**Compile-time atoms**: @send_message_targets, orient parameter atoms

## Dependencies

Schema → Definitions → ActionList/Metadata
Validator → Schema
Router → All action implementations
Actions → Schema for parameter definitions

## Test Coverage

- schema_test.exs: Core schema validation
- validator_test.exs: Parameter validation, XOR, enums, default_fields
- Action-specific tests: orient_test.exs, spawn_test.exs, etc.
- router_test.exs: 1318 tests, access control, dispatch

## Recent Changes

**Mar 4, 2026 - Grove Action Block Enforcement (WorkGroupID: feat-20260304-action-block-hard-rules)**:
- **Router.ClientAPI v33.0 (173 lines)**: Grove-level action blocking in execution pipeline
  - `validate_action_hard_rules/2`: Extracts grove_hard_rules + skill_name from opts[:parent_config], delegates to HardRuleEnforcer.check_action/3
  - `parent_config_value/2`: Dual atom/string key lookup helper (shared pattern with Shell, FileRead, FileWrite)
  - Check ordering: AFTER Schema.validate_action_type + ActionGate.check, BEFORE execute_with_validation
  - Merged `do_execute_with_access_and_autonomy` into `execute_with_access_and_autonomy` (REFACTOR)

**Mar 4, 2026 - Fix Child Initial Message (WorkGroupID: fix-20260304-initial-message-fields)**:
- **Spawn v24.0 (471 lines)**: Uses `config[:initial_message]` for `Core.send_user_message` (was bare `task_string`)
  - `initial_message = Map.get(config, :initial_message, task_string)` — fallback preserves backward compat
  - Broadcast at line 269 still uses `task_string` (UI display unchanged)
- **Spawn.ConfigBuilder v24.0 (324 lines)**: Captures and stores XML-tagged initial message
  - `user_prompt` no longer discarded (was `_user_prompt`)
  - Stores `:initial_message` in config map alongside `:system_prompt`
  - Accumulated_narrative de-duplication: regex strips child's `<accumulated_narrative>` tag, re-injects parent's authoritative version
  - REFACTOR: 14-line block comment documenting the regex logic

**Mar 3, 2026 - Grove Hard Enforcement (WorkGroupID: wip-20260302-grove-hard-enforcement)**:
- **Shell v4.0 (366 lines)**: Pre-execution hard rule enforcement + working dir confinement
  - `enforce_grove_policies/3`: Checks hard_rules then confinement before execute_command
  - Extracts `grove_hard_rules`, `grove_confinement`, `skill_name` from `opts[:parent_config]`
  - Status checks (check_id path) bypass enforcement
- **FileRead v2.0 (162 lines)**: Filesystem confinement enforcement
  - `HardRuleEnforcer.check_file_access(path, :read, confinement, skill_name)` in with-chain
  - Extracts confinement/skill_name from `opts[:parent_config]`
- **FileWrite v3.0 (224 lines)**: Filesystem confinement enforcement
  - `validate_confinement/3`: Checks before schema validation and filesystem write
  - `HardRuleEnforcer.check_file_access(path, :write, confinement, skill_name)`
- **Spawn.ConfigBuilder v23.0 (290 lines)**: Added `:grove_confinement` to `inheritable_keys` whitelist

**Mar 2, 2026 - Grove Schema Validation (WorkGroupID: wip-20260301-grove-schema-validation)**:
- **FileWrite v2.0 (204 lines)**: Grove schema validation hook for file writes
  - `validate_schema/3`: Extracts grove config from opts, delegates to `SchemaValidator.validate_file_write/5`
  - `execute_mode/4`: Now accepts opts (was 3-arity), calls schema validation before write
  - `build_edited_content/3`: Extracted edit logic to separate content computation from writing
  - Schema validation runs after content computation, before filesystem write, for both `:write` and `:edit` modes
- **Spawn v22.0**: Added `:grove_schemas` + `:grove_workspace` to ConfigBuilder inheritable_keys whitelist

**Mar 1, 2026 - Grove Spawn Contracts (WorkGroupID: wip-20260228-spawn-contracts)**:
- **Spawn v21.0 (471 lines)**: Grove topology auto-injection at spawn time
  - TopologyResolver extracted to `spawn/topology_resolver.ex` (137 lines, 500-line limit)
  - Profile precedence fix: removed `Map.delete(params, :profile)` — LLM-explicit now wins via `SpawnContractResolver.choose_profile/2`
  - Unmatched-edge `Logger.info` for observability (non-blocking)
  - Inheritable keys whitelist now includes `:grove_topology` + `:grove_path`
- **Validator v12.0 (270 lines)**: Spawn profile optionality + TypeValidation extraction
  - `spawn_profile_optional?/2`: Returns true when topology edge provides `auto_inject.profile`
  - `validate_params/3`: Added `opts \\ []` for grove_topology threading
  - TypeValidation extracted to `validator/type_validation.ex` (262 lines, 500-line limit)
- **Validator.TypeValidation v1.0 (262 lines)**: All type validation logic extracted from Validator
- **Spawn.TopologyResolver v1.0 (137 lines)**: Grove topology consultation extracted from Spawn

**Feb 12, 2026 - Action Deadlock Fix (WorkGroupID: fix-20260212-action-deadlock)**:
- **Spawn v19.0 (475 lines)**: Removed `Core.update_budget_committed(parent_pid, budget_result.escrow_amount)` call from background task (deadlock cause). Budget committed now updated by Core via ActionResultHandler when processing spawn result.
- **AdjustBudget v2.0 (179 lines)**: `get_parent_state/3` checks `opts[:parent_config]` first with agent_id pin match, falls back to Registry. New `do_adjust/4` dispatcher and `adjust_child_directly/3` for direct calls outside ActionExecutor.

**Feb 11, 2026 - Budget Enforcement (WorkGroupID: fix-20260211-budget-enforcement)**:
- **Spawn v17.0**: BudgetValidation nil branch now checks parent mode — budgeted parents (:root/:allocated) MUST specify budget for children, returns {:error, :budget_required} with LLM-guiding error message
- **DismissChild v4.0 (249 lines)**: Budget reconciliation on dismissal
  - Extracted `do_background_dismissal/7` from anonymous fn (REFACTOR)
  - `query_child_tree_spent/1`: Queries Aggregator before TreeTerminator deletes records
  - `reconcile_child_budget/5`: Creates `child_budget_absorbed` cost record under parent, calls `Core.release_child_budget/3`
  - `decimal_to_string/1`: Metadata formatting helper

**Jan 26, 2026 - Batch Async (WorkGroupID: feat-20260126-batch-async)**:
- **BatchAsync v1.0 (127 lines)**: Parallel batch action execution
  - Fire-and-forget with wait:false (agent continues immediately)
  - Per-action Router spawning (secrets, permissions, metrics per sub-action)
  - Exclusion list: [:wait, :batch_sync, :batch_async]
  - Task.async_many for parallel execution
  - :batch_completed notification to Core on completion
- **Shared.BatchValidation v1.0 (110 lines)**: DRY validation
  - Shared by batch_sync and batch_async
  - validate_batch_size/1, validate_actions_eligible/2, validate_action_params/1
  - Dual atom/string key support for LLM compatibility
- **Schema v30.0**: Added batch_async action (26 actions total)
- **Router v30.0**: Added batch_async routing via ActionMapper, extracted ShellHandlers
- **Aggregator v6.0**: Sorted fingerprinting for order-independent clustering
- **Result v5.0**: batch_async priority calculation (max of sub-actions)

**Jan 7, 2026 - File Actions (WorkGroupID: feat-20260107-file-actions)**:
- **FileRead v1.0 (152 lines)**: File reading with line-based output
  - Absolute path enforcement, binary file detection
  - Default 2000-line limit, offset/limit pagination
  - Line truncation at 2000 chars with indicator
- **FileWrite v1.0 (196 lines)**: File creation and editing
  - Two modes: :write (create new) and :edit (Claude Code semantics)
  - Exact string matching with uniqueness validation
  - replace_all option for multiple occurrences
- **Schema v27.0**: Added file_read, file_write actions (21 actions total)
- **Router**: Added file_read, file_write routing via ActionMapper
- **CapabilityGroups**: file_read, file_write groups (allowed for all except restricted)

**Mar 2, 2026 - Fix Cost Decrease on Dismiss (WorkGroupID: fix-20260301-cost-decrease-on-dismiss)**:
- **DismissChild v6.0 (378 lines)**: Atomic batch absorption + sentinel model_spec
  - `create_absorption_records/3`: Accepts `absorption_ctx` map (child_id, task_id, tree_spent, per_model, pubsub), filters zero-cost rows, validates task_id, dispatches to `record_absorption_batch/2`
  - `reconcile_child_budget/4`: Simplified from 8 params using absorption_ctx
  - `build_absorption_metadata/4`: Always includes sentinel `"(external)"` for nil model_spec (makes external costs visible in Aggregator IS NOT NULL filter)
  - `record_absorption_batch/2`: Routes to `Recorder.record_batch/2` (with pubsub) or `Recorder.record_silent_batch/1` (nil pubsub)
  - `validate_absorption_batch/1`: Pre-check ensures all records have binary task_id before DB insert
  - `log_absorption_batch_warning/3`: Dual warn+error logging (test env logger level is :error)
- **ActionExecutor**: `task_id: Map.get(state, :task_id)` — removed fallback to agent_id (prevents non-UUID task_id poisoning cost records)

**Feb 23, 2026 - Cost Display & Budget Timeout Fix (WorkGroupID: fix-20260223-cost-display-budget-timeout)**:
- **DismissChild v5.0 (374 lines)**: Per-model absorption records + escrow-first ordering
  - `create_absorption_records/7`: Creates one `child_budget_absorbed` record per model_spec (preserves model attribution)
  - `reconcile_child_budget/8`: Escrow release BEFORE absorption records (prevents budget leak on parent crash)
  - `build_absorption_metadata/4`: Includes model_spec, token counts, costs for LLM models; omits for external costs
  - `query_child_tree_by_model/1`: Snapshots per-model tree costs before TreeTerminator deletes records
  - `decimal_to_string/1`: Metadata formatting helper
- **ActionExecutor**: `case action_atom` timeout override — `:adjust_budget` → `:infinity` (prevents 5s Task.yield killing slow budget ops)
- **Router v32.0**: @always_sync_actions canonical 13-action list + timeout override mechanism

**Feb 17, 2026 - Adjust Budget Timeout Fix (WorkGroupID: fix-20260217-adjust-budget-timeout)**:
- **AdjustBudget v3.0 (75 lines)**: Cast-based budget update, unified code path
  - Deleted Path A (adjust_child_directly, do_adjust, validate_adjustment)
  - Always routes through Core.adjust_child_budget (no branching on parent_config)
  - No GenServer.call to child (eliminates timeout when child mid-consensus)
  - Decrease validation: spent-only from DB (committed check removed)
  - Error map values use Decimal.to_string (String.t() contract)
- **Router.Execution v31.0 (264 lines)**: Logger.warning on explicit timeout path

**Dec 31, 2025 - Budget UI (WorkGroupID: feat-20251231-191717)**:
- **AdjustBudget v1.0→v2.0**: Agent→child budget modification with atomic escrow
  - Validates parent has available funds for increases
  - Validates child can accommodate decreases (spent+committed)
  - Uses BUDGET_Escrow.adjust_child_allocation/4 for atomic updates
  - Notifies child agent of budget change via cast
  - **v2.0 (179 lines)**: Uses opts[:parent_config] instead of Core.get_state(parent_pid) to avoid deadlock; falls back to Registry lookup for direct calls outside ActionExecutor
  - **v3.0 (75 lines)**: See Feb 17, 2026 entry above
- **Schema v23.0**: Added adjust_budget action (17 actions total)
- **Router v20.0**: Added adjust_budget routing via ActionMapper

**Dec 27, 2025 - Children Tracking (WorkGroupID: feat-20251227-children-inject)**:
- **Spawn v12.0**: Casts `{:child_spawned, %{agent_id, spawned_at}}` to parent after successful spawn
- **DismissChild v2.0**: Casts `{:child_dismissed, child_id}` to parent after dispatch
- UUID generation condensed (501→487 lines) using string interpolation

**Dec 24, 2025 - dismiss_child Action (WorkGroupID: feat-20251224-dismiss-child)**:
- **DismissChild v1.0 (141 lines)**: Recursive child agent termination
  - Async dispatch to TreeTerminator via Task.Supervisor
  - Parent authorization via Registry lookup
  - Idempotent (success if child already gone)
  - Sets parent's dismissing flag before dispatch
- **Spawn v11.0**: Added dismissing flag check to prevent race conditions
- **Schema v22.0**: Added dismiss_child action (16 actions total)
- **Router v19.0**: Added dismiss_child routing via ActionMapper

**Nov 26, 2025 - MCP Action (WorkGroupID: feat-20251126-023746)**:
- **MCP v1.0 (121 lines)**: Model Context Protocol tool calling action
  - 3 modes: connect (stdio/HTTP), call tool, terminate connection
  - XOR validation: transport ⊻ connection_id
  - Extracted do_connect/2 helper for code reuse
  - Transport uses atoms (:stdio, :http)
  - Depends on MCP.Client via opts injection

**Nov 18, 2025 - REFACTOR (commit 6bf7abe)**:
- **Schema split for 500-line limit**:
  - Created AgentSchemas (199 lines): spawn_child, wait, send_message, orient, todo
  - Created ApiSchemas (317 lines): answer_engine, execute_shell, fetch_web, call_api, call_mcp, generate_secret
  - Created SchemaDefinitions (18 lines): Merges sub-modules
  - Updated Definitions (52 lines, down from 546): Now delegates to SchemaDefinitions
  - All modules now under 500 lines
- **Router v16.0 (499 lines)**:
  - Fixed "echo: write error: Broken pipe" - Router.terminate now waits for shell_tasks
  - Fixed "Postgrex client exited" - Changed logic from `if agent_alive` to `if !agent_died`
  - Handles three cases: live agent (cleanup), dead agent (skip), standalone (cleanup)
  - Condensed comments in terminate/2
- **Flaky test fix**: router_api_test.exs changed from httpbin.org to localhost:1 (instant connection refused, deterministic)

**Nov 14, 2025 - Wait Parameter Unification (WorkGroupID: wait-20251114-203234)**:
- **Schema v18.0**: Wait parameter added to all actions as `{:union, [:boolean, :number]}` type, wait_required?/1 function
- **Validator v7.0**: Boolean type support for wait parameter validation
- **Wait v7.0**: Unified with wait parameter - duration→wait (breaking change), supports true/false/number, 142 lines
- **MessageHandler v7.0**: Timer cancellation on all consensus-triggering messages (464 lines, condensed from 511)
- **ConsensusHandler v4.0**: Timer storage for wait parameter
- **PromptBuilder v7.0**: Schema propagation for wait parameter

**Schema v17.0**: Module extraction (4 modules), param_descriptions for all actions, enum types, XOR formalization
**Validator v17.0**: default_fields validation (:all_optional), enum type checking, enhanced XOR
**Spawn v17.0**: downstream_constraints parameter added
**Orient v17.0**: Removed redundant fields (status_update, delegation_patterns), fixed naming (delegation_plan)
