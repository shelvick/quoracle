# lib/quoracle/utils/

## Modules
- InjectionProtection: NO_EXECUTE XML tag security wrapper (147 lines)
- JSONNormalizer: Elixir-to-JSON normalizer for LLM communication (137 lines)
- ImageCompressor: Dimension-based image resizing for LLM provider limits (118 lines)
- ContentStringifier: Multimodal content to string conversion (68 lines)

## InjectionProtection

### Key Functions
- generate_tag_id/0: 8-char hex ID via :crypto.strong_rand_bytes(4)
- untrusted_action?/1: Guards 5 untrusted actions (execute_shell, fetch_web, call_api, call_mcp, answer_engine)
- wrap_if_untrusted/2: Conditional wrapping + security logging
- wrap_content/1: Unconditional wrapping with random ID
- detect_existing_tags/1: Case-insensitive tag detection

### Action Classification
- Untrusted (5): execute_shell, fetch_web, call_api, call_mcp, answer_engine
- Trusted (5): send_message, spawn_child, wait, orient, todo

### Security Pattern
- Random IDs prevent spoofing attacks
- Tags wrap OUTSIDE other XML for composability
- Logs warnings when tags detected in input
- Property tests verify classification invariants

## JSONNormalizer

### Purpose
Converts Elixir data structures to pretty-printed JSON for LLM consumption, handling non-JSON-serializable types (PIDs, refs, atoms, tuples).

### Key Function
- normalize/1: Converts any Elixir term to pretty-printed JSON string

### Type Conversions
- Tuples: `{:ok, val}` → `{"type": "ok", "value": val}`
- Atoms: `:atom` → `"atom"` (except nil, true, false)
- PIDs/refs/functions/ports: → inspect() string representation
- Maps: Atom keys → string keys, recursive normalization
- Binaries: UTF-8 validation, invalid bytes → inspect()
- Lists: Recursive normalization, handles improper lists
- Structs: Converted to maps before normalization

### Edge Cases Handled
- Invalid UTF-8 in binaries (values and map keys)
- Improper lists
- Empty maps/lists
- Deeply nested structures
- Mixed key types in maps

### Dependencies
- Jason (JSON encoding with pretty: true)

## ImageCompressor

### Purpose
Resizes images exceeding LLM provider size limits (Bedrock 5MB). Uses progressive dimension-based resizing to preserve fidelity.

### Key Function
- maybe_compress/2: `(binary, media_type) → {:ok, binary, media_type}` - always succeeds (optimistic pass-through)

### Configuration
- @max_size: 4,500,000 (4.5MB buffer below 5MB limit)
- @target_dimensions: [1920, 1280, 1024, 768, 512, 384, 256]

### Algorithm
1. If ≤4.5MB → pass through unchanged
2. Progressive resize through target dimensions until fits
3. On any error → log warning, return original (never blocks LLM query)

### Dependencies
- Image library (~> 0.54) with bundled libvips
- Called by MessageBuilder.to_content_part/1 for :image types

## ContentStringifier

### Purpose
Converts multimodal content (from MCP) to human-readable strings. Shared utility eliminating duplication across Reflector, PerModelQuery.Helpers, and LogEntry.Helpers.

### Key Functions
- stringify/2: `(term, keyword) → String.t()` - Main entry point, handles binary/list/map/nil
- stringify_part/2: `(term, keyword) → String.t()` - Single content part conversion

### Content Types Handled
- `%{type: :text, text: "..."}` → extracts text
- `%{type: :image}` → "[Image]"
- `%{type: :image_url, url: "..."}` → "[Image: url]"
- String keys supported: `%{"type" => "text", "text" => "..."}`

### Options
- `:map_fallback` - Function for unknown map types (default: `&inspect/1`)
  - PerModelQuery.Helpers uses `&JSONNormalizer.normalize/1`
  - Reflector uses default `&inspect/1`

### Used By
- Reflector.build_reflection_prompt/1
- PerModelQuery.Helpers.format_content_for_reflection/1
- LogEntry.Helpers (UI display)

## Test Coverage
- InjectionProtection: 300 lines (10 unit + 3 property tests)
- JSONNormalizer: 431 lines (27 tests + 3 property tests)
- ImageCompressor: ~200 lines (12 tests, setup_all for performance)
- ContentStringifier: Tested via reflector_multimodal_test.exs and helpers_multimodal_test.exs
