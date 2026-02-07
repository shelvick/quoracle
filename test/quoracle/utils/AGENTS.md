# test/quoracle/utils/

## Test Files
- injection_protection_test.exs: 13 tests (10 unit + 3 property tests)
- json_normalizer_test.exs: 27 tests (24 unit + 3 property tests)
- image_compressor_test.exs: 12 tests (R1-R10 ARC requirements)

## InjectionProtection Test Coverage
- Tag ID generation (8-char hex, uniqueness)
- Action classification (untrusted vs trusted)
- Conditional wrapping (wrap_if_untrusted/2)
- Unconditional wrapping (wrap_content/1)
- Existing tag detection (case-insensitive)
- Security logging for detected tags
- Property tests:
  - All untrusted actions wrapped
  - All trusted actions not wrapped
  - Classification consistency

### ARC Verification
- R1-R11: Unit tests for core functionality
- Property-based tests for classification invariants
- 5 untrusted actions: execute_shell, fetch_web, call_api, call_mcp, answer_engine
- 5 trusted actions: send_message, spawn_child, wait, orient, todo

## JSONNormalizer Test Coverage
- Basic types: primitives, strings, numbers, booleans, nil (R1)
- Atoms: conversion to strings (R2)
- Success tuples: `{:ok, val}` → `{"type": "ok", "value": val}` (R3)
- Error tuples: `{:error, reason}` → `{"type": "error", "reason": reason}` (R4)
- Maps: atom/string/mixed keys → string keys (R5-R6)
- Lists: recursive normalization, nested lists (R7)
- PIDs: string representation via inspect() (R8)
- References: string representation via inspect() (R9)
- Nested structures: deep recursion (R10)
- Empty structures: empty maps and lists (R11)
- Pretty printing: newlines and indentation (R12)
- Property tests:
  - Always produces valid JSON (R13)
  - Maintains data structure shape
  - Lists maintain order and length
- Edge cases (R14):
  - Long strings (10k chars)
  - Special characters and Unicode
  - Mixed complex structures
  - Improper lists
  - Keyword lists
  - Structs (DateTime, MapSet)
  - Nested error tuples
  - Invalid UTF-8 in binaries (values and map keys)
  - Port lifecycle race conditions

### ARC Verification
- R1-R14: All requirements covered with unit tests
- Property-based tests for JSON validity and structure preservation
- Comprehensive edge case handling

## ImageCompressor Test Coverage
- Pass-through: images ≤4.5MB unchanged (R1)
- Compression: images >4.5MB resized to fit (R2)
- Progressive resize: tries smaller dimensions until fits (R3)
- Format preservation: PNG→PNG, JPEG→JPEG (R4)
- Media type preservation: returns same media_type (R5)
- Error recovery: corrupted data returns original (R6-R7)
- Edge cases: empty/nil handling (R8)
- Aspect ratio: preserved during resize (R9)
- Minimum dimension: graceful handling at 256px (R10)

### ARC Verification
- R1-R10: All requirements covered with unit tests
- Uses gaussnoise for reliable oversized image generation
- setup_all for performance (immutable read-only fixtures)

## Patterns
- async: true for all tests
- Property testing with ExUnitProperties
- No external dependencies (InjectionProtection)
- Jason dependency (JSONNormalizer)
- Image library dependency (ImageCompressor)
- Pure function testing
- Race condition handling (port cleanup with try/catch)
- setup_all for immutable read-only test fixtures (ImageCompressor)
