# test/quoracle/fields/

## Test Files
- prompt_field_manager_test.exs: 31 tests (extraction, transformation, prompt building, XML formatting, with_log for expected warnings)
- field_validator_test.exs: 22 tests (required/optional validation, enum checking, error tuples)
- field_transformer_test.exs: 19 tests (narrative summarization, LLM integration, length limits)
- cognitive_styles_test.exs: 11 tests (5 style templates + error cases)
- global_context_injector_test.exs: 26 tests (DB injection, sandbox errors, constraint merging, malformed data)
- constraint_accumulator_test.exs: 15 tests (merging, deduplication, type validation)
- schemas_test.exs: 17 tests (field queries, categorization, single source of truth)

## Test Coverage

**PromptFieldManager (31 tests)**
- Field extraction: valid params, missing required, optional handling
- Transformation: parent inheritance, injected field propagation
- Prompt building: system/user prompts, XML tags, empty field omission
- Cognitive style: atom conversion, safe rescue for invalid styles
- Integration: all transformers coordinated correctly

**FieldValidator (22 tests)**
- Required fields: task_description presence check
- Optional fields: all 8 optional fields accepted
- Enum validation: cognitive_style (5 values)
- Error tuples: {:error, {:missing_required_fields, [atoms]}}
- Unknown fields: silently ignored

**FieldTransformer (19 tests)**
- Narrative combination: parent + child contexts
- LLM summarization: >500 chars triggers Gemini call
- Length enforcement: max 500 chars even after summarization
- Empty handling: "", nil, missing contexts
- Fallback: Truncation if LLM fails

**CognitiveStyles (11 tests)**
- 5 templates: systematic, analytical, creative, adaptive, exploratory
- Template structure: XML-wrapped prose with mode name
- Error handling: unknown styles return {:error, :unknown_style}
- Case sensitivity: atom keys only

**GlobalContextInjector (26 tests)**
- DB injection: Queries Task table for global_context, initial_constraints
- Error handling: :db_access_required (ownership), :db_error (connection), :invalid_task_id (cast), :malformed_data (argument)
- Constraint merging: Global + parent constraints deduplicated
- Empty defaults: Returns empty strings/lists on error
- Sandbox compatibility: Handles all DB error scenarios

**ConstraintAccumulator (15 tests)**
- Merging: Global + downstream constraints combined
- Deduplication: Identical constraints removed
- Type filtering: Only binary strings kept
- Empty arrays: Handled gracefully
- Order preservation: Deterministic output

**Schemas (17 tests)**
- Field lists: 2 injected, 9 provided, 2 transformed
- Categorization: get_fields_by_category/1
- Required vs optional: 1 required (task_description), 12 optional
- Single source of truth: All modules query Schemas

## Integration Tests
- spawn_field_consensus_test.exs: 3 system tests (E2E spawn→fields→consensus)
- spawn_field_integration_test.exs: Field propagation through spawn hierarchy
- context_manager_prompt_integration_test.exs: ContextManager uses field prompts
- field_prompt_integration_test.exs: Consensus receives field-based prompts
- agent_prompt_fields_test.exs: Agent state stores prompt_fields correctly

## Patterns
- async: true for all unit tests
- Isolated deps: PubSub, Registry, DynSup per test
- DB sandbox: start_owner! pattern for spawned processes
- ExVCR: Mock LLM calls in FieldTransformer tests
- Property-based: N/A (discrete field values)

## Coverage Metrics
- 141 total field system tests
- 100% function coverage
- Integration coverage: Spawn, Consensus, ContextManager
- E2E coverage: Field extraction → transformation → prompt building → consensus
