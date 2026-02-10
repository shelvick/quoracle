# test/quoracle/

## Test Structure
- models/: Database model tests (credentials, configs)
- providers/: Provider implementation tests
- providers/translators/: Translation layer tests

## Test Coverage Summary
- Provider tests: ~150 tests for Azure providers
- Translation tests: 51 tests for message/request translation
- Model tests: ~50 tests for database operations
- Integration tests: Provider refactoring verification

## Test Patterns
- async: true by default for parallelization
- ExVCR for external API recording
- start_supervised for GenServer testing
- on_exit callbacks for cleanup
- Ecto.Sandbox for database isolation

## Test Infrastructure
- ExUnit with async support
- ExVCR cassettes for API responses
- Hammox for behavior mocking (limited use)
- Logger capture for debug verification
- Database sandbox mode for isolation

## Key Test Utilities
- capture_log/2 for logger assertions
- start_supervised/1 for process management
- use_cassette for VCR recordings
- on_exit for resource cleanup

## Coverage Areas
- Unit: Pure function testing
- Integration: Provider chain testing
- Database: Model CRUD operations
- External: API interaction via cassettes

## Persistence Resilience Tests (persistence_resilience_test.exs)
- 30 tests: R1-R22 ACE state + R23-R31 model_histories preservation
- Property tests: R3, R4, R20-R22, R26-R27 (StreamData generators)
- Integration: Pause/resume cycles with real processes
- v2.0: model_histories preservation for conversation history survival