# lib/quoracle/fields/

## Purpose
Hierarchical prompt field system for agent spawning - 13 fields across 3 categories (injected/provided/transformed)

## Modules
- PromptFieldManager: Central orchestrator (253 lines), field extraction/transformation/prompt building
- FieldValidator: Schema validation (183 lines), 13 field types, required/optional checking
- FieldTransformer: Narrative summarization (85 lines), LLM-based compression via Gemini
- CognitiveStyles: 5 metacognitive templates (80 lines), efficient/exploratory/problem_solving/creative/systematic
- GlobalContextInjector: DB-based global field injection (83 lines), task-level context/constraints
- ConstraintAccumulator: Constraint merging (48 lines), deduplication across hierarchy
- Schemas: Field type definitions (201 lines), single source of truth

## Field Categories

**Injected (1):** System-managed, DB-sourced
- global_context: Task-level narrative

**Provided (9):** User-supplied per spawn
- role: Agent identity
- task_description: Work directive
- success_criteria: Completion definition
- immediate_context: Local situation
- approach_guidance: Methodology hints
- cognitive_style: Thinking mode (enum)
- output_style: Communication format
- delegation_strategy: Subtask coordination
- sibling_context: Peer awareness

**Transformed (2):** Auto-generated during propagation
- accumulated_narrative: Parent narrative + immediate_context (LLM-summarized if >500 chars)
- constraints: Accumulated constraints (task initial + parent accumulated + new provided)

## Key Functions
- PromptFieldManager.extract_fields_from_params/1: params→{:ok,%{provided:map}}|{:error,reason}
- PromptFieldManager.transform_for_child/3: parent×provided×task_id→%{injected:,provided:,transformed:}
- PromptFieldManager.build_prompts_from_fields/1: fields→{system_prompt,user_prompt}
- FieldValidator.validate_fields/1: map→{:ok,validated}|{:error,{:missing_required_fields,[atoms]}}
- FieldTransformer.summarize_narrative/2: Combines parent+child narrative, LLM if >500 chars
- CognitiveStyles.get_style_prompt/1: atom→{:ok,prose_template}|{:error,:unknown_style}
- GlobalContextInjector.inject/1: task_id→%{global_context:,constraints:}
- ConstraintAccumulator.accumulate/2: Deduplicates and validates constraints
- Schemas.get_required_fields/0, get_optional_fields/0, get_fields_by_category/1

## Prompt Structure
```
SYSTEM:
<role>Security Specialist</role>
<cognitive_style>SYSTEMATIC mode: ...</cognitive_style>
<constraints>
- Use only approved cloud services
- Focus on security best practices
- Document all findings
</constraints>
<output_style>technical</output_style>
<delegation_strategy>parallel</delegation_strategy>
<global_context>Building microservices platform</global_context>

USER:
<task>Analyze security vulnerabilities</task>
<success_criteria>Identify all OWASP Top 10</success_criteria>
<immediate_context>Production web app</immediate_context>
<approach_guidance>Focus on auth first</approach_guidance>
<sibling_context>
Agent agent-123: Handle frontend
</sibling_context>
<accumulated_narrative>Parent work summary...</accumulated_narrative>
```

## Patterns
- Single source of truth: Schemas module defines all 13 fields
- Inheritance: Injected fields propagate unchanged through hierarchy
- Transformation: Narrative compression, constraint accumulation
- Validation: Required fields checked, enums validated
- Safe atom conversion: try-rescue for cognitive_style (TD-2 fix)
- Specific error handling: DBConnection/Ecto errors (TD-3 fix)

## Integration Points
- ACTION_Spawn: Calls extract_fields_from_params, transform_for_child
- AGENT_Core: Stores prompt_fields in state, passes to ContextManager
- AGENT_ContextManager: Calls build_prompts_from_fields for consensus
- TABLE_Tasks: Stores global_context, initial_constraints (JSONB)
- TABLE_Agents: Stores system_prompt, user_prompt (TEXT)

## Dependencies
- Quoracle.Tasks.Task: DB schema for global fields
- Quoracle.Repo: Database access
- Quoracle.Models.ModelQuery: LLM summarization (Gemini 2.5 Pro)

## Test Coverage
- PromptFieldManager: 31 tests (extraction, transformation, prompt building)
- FieldValidator: 22 tests (required/optional, enum validation)
- FieldTransformer: 19 tests (narrative summarization, LLM mocking)
- CognitiveStyles: 11 tests (5 styles + error cases)
- GlobalContextInjector: 26 tests (DB injection, error handling, constraint merging)
- ConstraintAccumulator: 15 tests (merging, deduplication)
- Schemas: 17 tests (field queries, categorization)
- Integration: 34 tests (spawn consensus E2E, LiveView integration)

## Technical Debt Resolved
- TD-2: Safe atom conversion with try-rescue (PromptFieldManager.ex:104-109)
- TD-3: Narrowed error handling to specific exceptions (GlobalContextInjector.ex:63-75)
