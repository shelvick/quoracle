# test/quoracle/security/

## Test Files
- secret_resolver_test.exs: 24 tests (template parsing, recursive resolution, property-based)
- output_scrubber_test.exs: 21 tests (struct handling, recursive scrubbing, integration)

## Coverage
- Template syntax: {{SECRET:name}} recognition
- DB lookups for secret values
- Error handling: missing secrets, invalid syntax
- Recursive resolution: nested maps, lists, mixed structures
- Property-based testing for complex inputs
- Struct preservation during scrubbing
- Case-insensitive secret matching
- Integration with Router.Security

## Patterns
- async: true for all tests
- Property-based testing with StreamData
- Ecto.Sandbox for DB isolation
- Mock secret data via test fixtures
