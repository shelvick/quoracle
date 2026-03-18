# test/quoracle/groves/

## Test Files
- governance_resolver_test.exs: 41 tests (R1-R17 spec + AUDIT remediation) - ExUnit.Case, async: true
- bootstrap_resolver_test.exs: 16 tests (R1-R11 spec + SEC-1a/b/c/d/g/h security) - ExUnit.Case, async: true
- loader_test.exs: 23+ tests (R1-R13 spec + SEC-1e/f/SEC-4a/b security + edge cases + R31-R33 confinement_mode) - DataCase, async: true
- path_security_test.exs: 11 tests (R1-R11) - ExUnit.Case, async: true (NEW: wip-20260228-spawn-contracts)
- spawn_contract_resolver_test.exs: 27 tests (R1-R22 + R23-R27 validate_required_context) - ExUnit.Case, async: true
- spawn_contract_integration_test.exs: integration + acceptance tests for full spawn pipeline - DataCase, async: true (NEW: wip-20260228-spawn-contracts)
- governance_integration_test.exs: integration tests for governance propagation - DataCase, async: true
- hard_rule_enforcer_test.exs: 37 tests (R1-R21 + R22-R31 action_block + R32-R37 strict confinement mode) - ExUnit.Case, async: true
- hard_enforcement_integration_test.exs: 25 tests (R1-R12 + R3b + R13-R18 action_block + R19-R22 strict mode + confinement_mode threading) - DataCase, async: true
- groves_path_config_test.exs: DB config path fallback tests - DataCase, async: true

## Test Patterns
- Temp directories with `System.unique_integer` for isolation
- `create_bootstrap_grove/3` helper for grove setup
- `on_exit` cleanup for temp dirs
- `System.tmp_dir!()` inline in all File operations (git hook requirement)
- `File.ln_s!` for symlink attack tests (SEC-1g/1h)
- `spawn_complete_notify` for async spawn synchronization (spawn_contract_integration_test)

## Coverage

**PathSecurity** (path_security_test.exs):
- path_traversal?: `..` components, absolute paths, valid relative paths
- symlink_outside_grove?: final symlink detection, symlinks inside grove allowed
- safe_read_file/3: path traversal rejection, symlink rejection, missing file error, successful read
- Intermediate symlinks: nested directory symlink outside grove

**SpawnContractResolver** (spawn_contract_resolver_test.exs):
- find_edge/3: exact match, partial match, no match, multiple matches (warns)
- resolve_auto_inject/3: skills union, profile precedence (LLM wins), edge fallback, constraint file read
- extract_section/2: case-insensitive heading match, no heading match
- choose_profile/2: LLM-explicit wins, edge fallback when LLM omits, empty string treated as absent
- resolve_constraints/2: file read, section extraction, path security, missing file graceful nil
- merge_skills/2: deduplication, ordering
- validate_required_context/3: R23-R27 — nil edge, nil grove_vars, all keys present, missing keys warning, empty required_context

**SpawnContractIntegration** (spawn_contract_integration_test.exs):
- R25-R65: Full pipeline from grove loading through spawn to child state
- LLM profile wins regression test
- R30: Profile optional when topology edge provides fallback
- grove_topology/grove_path threading through TaskManager → Core.State
- R64-R66: Template variable resolution tests (grove_vars → ConfigBuilder path template resolution)

**GovernanceResolver** (governance_resolver_test.exs):
- resolve_all: basic injection, unknown scope skip, skill-scoped filtering, all-scope always-included
- build_agent_governance: empty injections nil, grove_hard_rules inclusion, skill filtering
- Security: path traversal rejection, symlink detection, source file not found error
- Loader sanitization: governance source paths sanitized at parse time (R18)
- Audit remediation: grove_hard_rules field exists in Core.State, ConfigManager, ACTION_Spawn, TaskManager

**BootstrapResolver** (bootstrap_resolver_test.exs):
- File reference resolution (4 file ref fields)
- Inline value pass-through (role, constraints, enum fields)
- Missing field nil behavior
- Error cases (file not found, grove not found)
- Skills list formatting, budget number formatting
- Path traversal protection (../absolute/nested)
- Symlink detection (final file, intermediate directory)

**Loader** (loader_test.exs):
- Unreadable GROVE.md crash protection
- DB config fallback chain (tagged :packet_3)
- Tilde expansion, skills_path computation
- R22-R26: Confinement parsing, tilde expansion, hard_rules typed validation (wip-20260302-grove-hard-enforcement)

**HardRuleEnforcer** (hard_rule_enforcer_test.exs):
- R1-R7: Shell pattern blocking (match, no-match, scope all/list, nil/empty rules, invalid regex)
- R8-R11: Working directory confinement (within/outside paths, nil confinement, unlisted skill)
- R12-R21: File access confinement (write within/outside/read-only, read within/read-only/outside, nil, unlisted, glob, error details)
- R22-R31: Action blocking (match, no-match, scope filtering, nil/empty rules)
- R32-R37: Strict confinement mode (unlisted skill denied for file_access and working_dir, with actionable error messages)

**HardEnforcementIntegration** (hard_enforcement_integration_test.exs):
- R1-R2: Shell blocked/allowed through full pipeline (spawns real agents)
- R3/R3b: Working dir blocked/allowed through full pipeline
- R4-R6: File write blocked/allowed/read-only-rejected through full pipeline
- R7-R9: File read blocked/from-write-path/from-read-only through full pipeline
- R10-R11: No grove passthrough (shell + files)
- R12: Confinement inheritance to children
- R13-R18: Action blocking through full pipeline
- R19-R22: Strict confinement mode through full pipeline + confinement_mode threading from Loader to HardRuleEnforcer

**Loader** (loader_test.exs):
- R31-R33: confinement_mode parsing (strict, absent defaults nil, non-string ignored)
