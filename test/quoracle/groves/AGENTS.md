# test/quoracle/groves/

## Test Files
- governance_resolver_test.exs: 41 tests (R1-R17 spec + AUDIT remediation) - ExUnit.Case, async: true
- bootstrap_resolver_test.exs: 16 tests (R1-R11 spec + SEC-1a/b/c/d/g/h security) - ExUnit.Case, async: true
- loader_test.exs: 20+ tests (R1-R13 spec + SEC-1e/f/SEC-4a/b security + edge cases) - DataCase, async: true
- path_security_test.exs: 11 tests (R1-R11) - ExUnit.Case, async: true (NEW: wip-20260228-spawn-contracts)
- spawn_contract_resolver_test.exs: 22 tests (R1-R22) - ExUnit.Case, async: true (NEW: wip-20260228-spawn-contracts)
- spawn_contract_integration_test.exs: integration + acceptance tests for full spawn pipeline - DataCase, async: true (NEW: wip-20260228-spawn-contracts)
- governance_integration_test.exs: integration tests for governance propagation - DataCase, async: true
- hard_rule_enforcer_test.exs: 21 tests (R1-R21) - ExUnit.Case, async: true (NEW: wip-20260302-grove-hard-enforcement)
- hard_enforcement_integration_test.exs: 13 tests (R1-R12 + R3b) - DataCase, async: true (NEW: wip-20260302-grove-hard-enforcement)
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

**SpawnContractIntegration** (spawn_contract_integration_test.exs):
- R25-R65: Full pipeline from grove loading through spawn to child state
- LLM profile wins regression test
- R30: Profile optional when topology edge provides fallback
- grove_topology/grove_path threading through TaskManager → Core.State

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

**HardEnforcementIntegration** (hard_enforcement_integration_test.exs):
- R1-R2: Shell blocked/allowed through full pipeline (spawns real agents)
- R3/R3b: Working dir blocked/allowed through full pipeline
- R4-R6: File write blocked/allowed/read-only-rejected through full pipeline
- R7-R9: File read blocked/from-write-path/from-read-only through full pipeline
- R10-R11: No grove passthrough (shell + files)
- R12: Confinement inheritance to children
