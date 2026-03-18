# lib/quoracle/groves/

## Modules

**Loader** (353 lines, v5.0) + **Loader.Sanitizer** (230 lines, v6.0, extracted REFACTOR):
- `list_groves/1` - Lists grove metadata from groves directory, non-raising `File.ls/1`, sorted alphabetically
- `load_grove/2` - Full grove struct parse (bootstrap, topology, governance, schemas, workspace, confinement, skills_path)
- `get_bootstrap/2` - Convenience: load_grove + extract bootstrap section
- `groves_dir/1` - 3-tier fallback: opts > ConfigModelSettings DB > `~/.quoracle/groves`
- `get_safe_file_ref/1` - Path sanitization: strips `..` components and leading `/` (SEC-1e/f defense layer 1)
- `extract_frontmatter/1` - YAML between `---` delimiters via YamlElixir
- `build_grove/2` - YAML map to typed grove struct
- v5.0: Parses `confinement:` section (per-skill filesystem boundaries with tilde expansion)
- v5.0: Validates `hard_rules` as typed list entries (filters invalid entries missing required fields)
- v7.0: Parses `confinement_mode:` from frontmatter (default nil = permissive, "strict" = deny unlisted skills)
- **Loader.Sanitizer** (extracted for 500-line limit): `sanitize_confinement/1`, `sanitize_hard_rules/1`, `sanitize_schema_definitions/1`, `sanitize_governance_sources/2`, `parse_workspace/1`

**PathSecurity** (128 lines, v1.0) — NEW (wip-20260228-spawn-contracts):
- `path_traversal?/1` - Rejects `..` components and absolute paths (layer 2 defense)
- `symlink_outside_grove?/2` - Final file symlink detection + intermediate directory symlink detection
- `safe_read_file/3` - Combined security + file read: (source_path, source_for_validation, grove_path)
- `intermediate_symlink_outside_grove?/3` (private) - Walks path segments via Enum.reduce_while
- Shared by BootstrapResolver, GovernanceResolver, SpawnContractResolver, SchemaValidator
- Extracted from previously-duplicated private functions in BootstrapResolver + GovernanceResolver

**GovernanceResolver** (188 lines, v5.0):
- `resolve_all/1` - grove struct → `[governance_injection()]` list (reads source files)
- `build_agent_governance/3` - injections + active_skill_names + hard_rules → formatted `governance_rules` string
- `filter_for_skills/2` - Filter injections by skill name intersection (used by ACTION_Spawn for child filtering)
- `resolve_source_file/3` (private) - Delegates to `PathSecurity.safe_read_file/3` (v3.0: was duplicated private functions)
- Uses `__unsafe_original_source` sentinel from Loader for validation; sanitized source used for File.read
- v4.0: `format_hard_rules/2` handles typed list format `[%{"type" => "shell_pattern_block", ...}]` (was broken with nested map format)
- v4.0: `typed_rule_applies?/2` for scope filtering by skill name; token-efficient "SYSTEM RULES" format
- v5.0: `format_typed_rule_line/1` handles `action_block` entries: `"- BLOCKED ACTION: action1, action2 -- message"`
- v5.0: `typed_rule_applies?/2` extended with `action_block` clause (mirrors `shell_pattern_block`)

**BootstrapResolver** (118 lines, v3.0):
- `resolve/2` - Main entry: grove_name → form_fields map (13 fields)
- `resolve_from_grove/1` - Resolve from pre-loaded grove struct (avoids duplicate load_grove)
- `resolve_fields/2` - `with` chain over 4 file refs + inline values
- `resolve_file_field/3` (private) - Delegates to `PathSecurity.safe_read_file/3` (v3.0: was duplicated private functions)
- `format_skills/1` - List → comma-separated string
- `format_budget/1` - Number → string

**SchemaValidator** (~318 lines, v1.0) — NEW (wip-20260301-grove-schema-validation):
- `validate_file_write/5` - Main entry: validates file content against grove JSON Schema before write
- `find_matching_schema/3` - Finds most-specific schema entry matching file path (public for testability)
- `path_matches_pattern?/2` - Glob-style pattern matching with `*` and `**` wildcards (public for testability)
- Early returns: nil/empty schemas → `:ok`, nil workspace → `:ok` + Logger.warning, outside workspace → `:ok`, no match → `:ok`, non-file_write validate_on → `:ok`
- Validation pipeline: load schema via PathSecurity → parse content JSON → build JSV root → validate → format errors
- Returns `{:error, {:schema_validation_failed, %{path:, schema:, errors:}}}` with field-level messages
- Uses segment-based matching (not regex) for glob patterns; `glob_match?/2` with starts_with/ends_with optimization
- Called by ACTION_FileWrite.validate_schema/3 for both `:write` and `:edit` modes

**LogHelper** (33 lines, v1.0, extracted REFACTOR):
- `log_warning/1` - Logs at :warning level, mirrors at :error in test env for capture_log observability
- Shared by HardRuleEnforcer and SpawnContractResolver (was duplicated private function)

**HardRuleEnforcer** (349 lines, v3.0):
- `check_shell_command/3` - command + hard_rules + skill_name → `:ok` | `{:error, {:hard_rule_violation, details}}`
- `check_shell_working_dir/4` - working_dir + confinement + skill_name + confinement_mode → `:ok` | `{:error, {:confinement_violation, details}}` (v3.0: strict mode denies unlisted skills)
- `check_file_access/5` - path + access_type + confinement + skill_name + confinement_mode → `:ok` | `{:error, {:confinement_violation, details}}` (v3.0: strict mode denies unlisted skills)
- `check_action/3` - action_type + hard_rules + skill_name → `:ok` | `{:error, {:hard_rule_violation, action_hard_rule_violation()}}` (v2.0)
- Pure functions — never raises, returns structured errors with actionable context
- Delegates glob matching to `SchemaValidator.path_matches_pattern?/2`
- Delegates `log_warning/1` to `Groves.LogHelper` (v3.0 REFACTOR)
- `rule_applies?/2` (private) - scope "all" matches everything, list scope checks membership
- `rule_message/1` (private) - extracts message or fallback "Action blocked by grove hard rule"
- `confinement_entry/3` (private) - returns `{:ok, entry}` | `{:error, :unlisted_skill}` | `:allow_unlisted` (v3.0: strict mode support)
- Unlisted skills: Default mode warns + allows. Strict mode (`confinement_mode: "strict"`) denies with actionable error message (v3.0)
- Called by ACTION_Shell (hard rules + working dir + confinement_mode), ACTION_FileRead (file access + confinement_mode), ACTION_FileWrite (file access + confinement_mode), ACTION_Router ClientAPI (action blocking v2.0)

**SpawnContractResolver** (231 lines, v2.0):
- `find_edge/3` - Match topology edge by parent+child skill names; warns on multiple matches
- `resolve_auto_inject/3` - edge + grove_path + existing_params → `{:ok, auto_inject_result}` | `{:error, _}`
- `validate_required_context/3` - edge + grove_vars + log_prefix → `:ok` (v2.0: warns on missing required context keys, graceful degradation)
- `extract_section/2` - Case-insensitive `## heading` extraction from markdown content
- `choose_profile/2` (private) - LLM-explicit profile wins; edge profile is fallback
- `resolve_constraints/2` (private) - Reads constraint file, extracts section if anchor, graceful nil on missing
- `merge_skills/2` (private) - Union + dedup of edge skills and LLM skills

## Key Types

```elixir
# Loader
@type grove_metadata :: %{name: String.t(), description: String.t(), version: String.t(), path: String.t()}
@type grove_bootstrap :: %{global_context_file: String.t() | nil, ..., skills: [String.t()] | nil, budget_limit: number() | nil}
@type grove :: %{name:, description:, version:, path:, bootstrap:, topology:, governance:, schemas:, workspace:, confinement:, confinement_mode:, skills_path:}

# SchemaValidator
@type schema_entry :: %{String.t() => any()}  # raw map with string keys: name, definition, validate_on, path_pattern
@type validation_error :: %{path: String.t(), errors: [String.t()]}

# BootstrapResolver
@type form_fields :: %{global_context: String.t() | nil, ..., budget_limit: String.t() | nil}  # 13 fields
@type resolve_error :: {:error, :grove_not_found | :parse_error | {:file_not_found, _} | {:path_traversal, _} | {:symlink_not_allowed, _}}

# GovernanceResolver
@type governance_injection :: %{scope: String.t(), content: String.t(), source: String.t()}

# PathSecurity
@type security_error :: {:error, {:path_traversal, String.t()} | {:symlink_not_allowed, String.t()} | {:file_not_found, String.t()}}

# SpawnContractResolver
@type topology_edge :: %{String.t() => any()}  # raw YAML map, string keys
@type auto_inject_result :: %{skills: [String.t()], profile: String.t() | nil, constraints: String.t() | nil}
```

## Security (Defense-in-Depth)

Three-layer path protection (all resolvers use PathSecurity as layer 2+):
1. **Loader.get_safe_file_ref/1**: Sanitizes `..` and `/` at parse time (before resolvers see them)
2. **PathSecurity.path_traversal?/1**: Catches any that slip through (shared across all 3 resolvers)
3. **PathSecurity.symlink_outside_grove?/2**: Final + intermediate symlink detection

Symlink protection via PathSecurity:
- Final file symlink detection via File.lstat/1 + File.read_link/1
- Intermediate directory symlink detection via path segment walking
- Trailing `/` on canonical grove path prevents prefix-match attacks

**v3.0 change:** Security functions previously duplicated in BootstrapResolver and GovernanceResolver are now centralized in PathSecurity. SpawnContractResolver uses PathSecurity directly.

## Spawn Contracts (wip-20260228-spawn-contracts, wip-20260313-052349)

Auto-inject skills/profile/constraints from topology edges at spawn time:
- `SpawnContractResolver.find_edge/3`: Match parent+child skill names against topology edges
- `SpawnContractResolver.resolve_auto_inject/3`: Skills union, profile precedence (LLM wins), constraint file read
- `SpawnContractResolver.validate_required_context/3`: Check grove_vars map for required_context keys (v2.0)
- **Profile precedence:** LLM-explicit `profile` param wins; edge `auto_inject.profile` is fallback when LLM omits it
- `choose_profile/2`: `when is_binary(existing) and existing != ""` → existing wins; else edge fallback
- Constraint files: relative paths with `#section-name` anchor support; PathSecurity for security
- Unmatched spawns: `Logger.info` when topology exists + child skills non-empty + no edge matches (non-blocking)
- **grove_vars** (v2.0): Template variable map (`{:grove_vars, :map}` in spawn_child schema) resolved at spawn time by ConfigBuilder for confinement path templates like `{venture_id}`

## Grove Governance (wip-20260226-grove-governance)

- Governance injections filter by `scope: "all"` or matching active skill
- `build_agent_governance/3`: Filters injections → reads source files → concatenates text → adds hard_rules
- v4.0: Hard rules format: list of typed entries `[%{"type" => "shell_pattern_block", "pattern" => "...", "message" => "...", "scope" => "all"}]`
- v4.0: Token-efficient format: "SYSTEM RULES (mechanically enforced — violations are blocked):\n- BLOCKED PATTERN: /pattern/ — message"
- Governance content flows: GovernanceResolver → EventHandlers → TaskManager → ConfigManager → ConsensusHandler → PromptBuilder → system prompt
- `governance_rules`: pre-formatted string passed in `:governance_rules` opt to PromptBuilder
- `governance_config`: raw grove struct for child propagation via ACTION_Spawn → ConfigBuilder
- `grove_hard_rules`: raw typed list for child hard rules filtering via ACTION_Spawn → ConfigBuilder

## Hard Enforcement (wip-20260302-grove-hard-enforcement, feat-20260304-action-block-hard-rules)

Mechanical enforcement of action-level rules — compliance backstop, not just prompt guidance:
- **HardRuleEnforcer**: Pure-function module checking commands/paths/actions before execution
- **Shell enforcement**: Pattern blocking (`^pkill`, etc.) + working directory confinement
- **File enforcement**: Read/write confinement per skill (paths + read_only_paths)
- **Action enforcement** (v2.0): Grove-level action blocking — `check_action/3` called by Router ClientAPI
- **Confinement is opt-in per skill by default**: Unlisted skills warn but allow (same precedent as spawn contracts)
- **Strict confinement mode** (`confinement_mode: "strict"` in GROVE.md frontmatter): Unlisted skills are DENIED instead of warned-and-allowed (v3.0)
- Config flow: Loader (parse confinement_mode) → EventHandlers (extract) → TaskManager → ConfigManager → Core.State (`grove_confinement_mode`) → ActionExecutor (build_parent_config) → Action modules (extract from opts[:parent_config]) → HardRuleEnforcer
- `grove_hard_rules`: Threaded through full pipeline for shell pattern blocking + action blocking
- `grove_confinement`: Threaded through full pipeline for filesystem boundaries
- Child agents inherit both via ConfigBuilder `inheritable_keys` whitelist (`:grove_confinement` added v23.0)
- **Dual-layer action blocking**: Runtime layer (ClientAPI → HardRuleEnforcer.check_action/3) + Prompt layer (ConsensusHandler → extract_forbidden_actions → PromptBuilder `:forbidden_actions`)

## Dependencies

- YamlElixir: YAML parsing
- ConfigModelSettings: groves_path DB config
- File/Path: filesystem operations, symlink detection

## Schema Validation (wip-20260301-grove-schema-validation)

JSON Schema validation for file writes within grove scope:
- SchemaValidator validates content against JSON Schema (Draft 2020-12) via JSV library
- Loader v4.0 sanitizes schema `definition` paths and parses `workspace` at load time
- FileWrite v2.0 calls `SchemaValidator.validate_file_write/5` before filesystem write
- Schema config flows: Loader → EventHandlers → TaskManager → ConfigManager → Core.State → ActionExecutor → FileWrite → SchemaValidator
- Child agents inherit `grove_schemas` + `grove_workspace` via ConfigBuilder inheritable_keys whitelist

## Dependencies

- YamlElixir: YAML parsing
- JSV: JSON Schema validation (Draft 2020-12, transitive via req_llm)
- ConfigModelSettings: groves_path DB config
- File/Path: filesystem operations, symlink detection

## Test Coverage

- 44 GovernanceResolver tests (36 spec R1-R17 + 5 audit remediation + R37-R39 typed hard_rules + R40-R42 action_block, async: true)
- 16 BootstrapResolver tests (11 spec + 6 security: SEC-1a/b/c/d/g/h, async: true)
- 23+ Loader tests (13 spec + security + edge cases + R22-R26 confinement/hard_rules + R31-R33 confinement_mode, async: true)
- 11 PathSecurity tests (R1-R11, async: true, temp directories + real symlinks)
- 27 SpawnContractResolver tests (R1-R22 + R23-R27 validate_required_context, async: true, temp directories + constraint files)
- 21 SchemaValidator tests (R1-R21, async: true, temp grove dirs + real JSV validation)
- 10 FileWrite schema integration tests (R1-R9 + acceptance, async: true)
- 37 HardRuleEnforcer tests (R1-R21 + R22-R31 action_block + R32-R37 strict confinement mode, async: true, pure function tests)
- 25 HardEnforcementIntegration tests (R1-R12 + R3b + R13-R18 action_block + R19-R22 strict mode + confinement_mode threading, async: true, spawns real agents via ActionPipeline)
- All tests use temp directories with unique paths per test
