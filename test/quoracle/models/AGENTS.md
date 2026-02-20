# test/quoracle/models/

## Test Files
- model_query_test.exs: 38 core tests
- model_query_fixes_test.exs: 6 duplicate handling tests
- model_query_reasoning_test.exs: 6 reasoning_effort tests (R14-R18, v9.0)
- model_query_local_model_test.exs: 9 local model tests (R50-R58, v19.0) — NEW
- model_query_embedding_test.exs: 57 embedding tests (multi-provider + chunking + local model R33-R38)
- local_model_integration_test.exs: 3 cross-cutting tests (R1-R3) — NEW
- integration_audit_findings_test.exs: 14 integration audit tests (F1-F5) — NEW
- config_model_settings_test.exs: 10 tests (business logic: configured?/0, get_all/0, validate_model_pool/1, set_image_generation_models/1)
- model_query/message_builder_compression_test.exs: 10 tests (R39-R44, v13.0 ImageCompressor integration)
- 9 provider integration tests (@tag :provider_integration)

## Coverage
Parallel execution, duplicate handling (no dedup), partial failures, timeouts, message validation, embedding filtering, error aggregation, usage metrics, local model LLMDB bypass, cloud provider guards, integration audit findings

## Test Strategy (req_llm Migration - 2025-12)
- All tests use Hammox mocks for provider isolation
- No ExVCR dependency (removed during migration)
- "mock_" prefix models in test seeds
- async: true for all tests

## Local Model Test Strategy (2026-02)
- Stub plugs for HTTP mocking (no real network calls)
- Real DB operations for credential tests (DataCase)
- Real LiveView rendering for UI tests (ConnCase)
- Capturing plug pattern for system tests (verifies request routing)

## Critical Lessons
- Hammox enforces behaviour type contracts
- Mock provider returns must match @type specs exactly
- "mock_" prefix keeps test models separate from real ones

## Test Patterns
async: true, Hammox mocks for all provider calls, no network access required
