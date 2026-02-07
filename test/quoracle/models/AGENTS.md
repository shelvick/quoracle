# test/quoracle/models/

## Test Files
- model_query_test.exs: 38 core tests
- model_query_fixes_test.exs: 6 duplicate handling tests
- model_query_reasoning_test.exs: 6 reasoning_effort tests (R14-R18, v9.0)
- config_model_settings_test.exs: 10 tests (business logic: configured?/0, get_all/0, validate_model_pool/1, set_image_generation_models/1)
- model_query/message_builder_compression_test.exs: 10 tests (R39-R44, v13.0 ImageCompressor integration)
- 9 provider integration tests (@tag :provider_integration)

## Coverage
Parallel execution, duplicate handling (no dedup), partial failures, timeouts, message validation, embedding filtering, error aggregation, usage metrics

## Test Strategy (req_llm Migration - 2025-12)
- All tests use Hammox mocks for provider isolation
- No ExVCR dependency (removed during migration)
- "mock_" prefix models in test seeds
- async: true for all tests

## Critical Lessons
- Hammox enforces behaviour type contracts
- Mock provider returns must match @type specs exactly
- "mock_" prefix keeps test models separate from real ones

## Test Patterns
async: true, Hammox mocks for all provider calls, no network access required
