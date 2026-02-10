# test/quoracle/consensus/

## Test Files
- prompt_builder_test.exs: 38 tests for PromptBuilder module
- prompt_builder_skills_test.exs: 14 tests for skill injection in Sections (R56-R67)
- skill_injection_integration_test.exs: 11 tests for full pipeline (R63, R68-R74, fix-20260113-skill-injection)
- prompt_builder_batch_sync_test.exs: 9 tests for batch_sync documentation (R75-R82) - Added 2026-01-24 (feat-20260123-batch-sync Packet 3)
- batch_consensus_test.exs: 10 tests for batch_sync fingerprinting and action summary (R43-R47) - Added 2026-01-24 (feat-20260123-batch-sync Packet 2)
- batch_async_consensus_test.exs: 19 tests + 3 properties for batch_async consensus (R42-R53) - Added 2026-01-26 (feat-20260126-batch-async)

## Test Coverage
- System prompt generation with all 11 actions
- JSON schema creation and formatting
- Parameter type conversion (nested maps, enums, lists)
- Nested map property schemas with required fields
- Enum type schemas with value constraints
- Recursive type conversion
- Debug logging behavior
- Property-based tests for schema alignment
- Edge cases for invalid actions
- NO_EXECUTE documentation section (R12-R17):
  - Section presence verification
  - Untrusted actions list (6 actions)
  - Trusted actions list (5 actions)
  - Critical warning text
  - Example injection attempt
  - Section placement

## Skill Injection Tests (v16.0, fix-20260113-skill-injection)
- R63: End-to-end skill content in system prompt
- R68: Skills section positioned after identity, before profile
- R69: Multiple skills ordering and content
- R70-R71: Empty/nil active_skills handling
- R72-R73: Skills coexist with profile and capability groups
- R74: UI and LLM receive same skill content (single prompt_opts)
- Temp file isolation with unique base_name per test

## Batch Consensus Tests (feat-20260123-batch-sync Packet 2)
- R43: batch_sync fingerprint uses action type sequence
- R44: Same sequence same fingerprint (different params cluster together)
- R45: Different sequence different fingerprint
- R46: Dual key support (string keys from LLM, mixed keys)
- R47: format_action_summary shows batch_sync action list
- Clustering integration test for batch_sync responses

## Batch Async Consensus Tests (feat-20260126-batch-async)
- R48: batch_async fingerprint uses sorted action type sequence
- R49: Same actions different order cluster together (order-independent)
- R50: Different action sets separate
- R51: Dual key support (string keys from LLM)
- R52: format_action_summary shows batch_async sorted action list
- R53: batch_sync and batch_async with same actions have different fingerprints
- R42: batch_async cluster priority is max of sub-action priorities
- R43: batch_async uses same priority calculation as batch_sync
- Property tests for order-independence and sorted fingerprints

## Patterns
- async: true for all tests
- Property testing with ExUnitProperties
- Direct ACTION_Schema integration (no mocking)
- Comprehensive ARC criteria verification
- Tests for enhanced type system (nested maps, enums)
- Temp file isolation for skill tests (mimic spawn_skills_test.exs)