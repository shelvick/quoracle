# lib/quoracle/tasks/

## Modules
- TaskManager: Task CRUD with hierarchical prompt fields, delegates to AGENT_DynSup
- TaskRestorer: Pause/resume orchestration, agent tree restoration, async pause (v3.0), rebuild_children_lists/2 (v4.0)
- FieldProcessor: Form validation, task/agent field splitting, enum conversion

## Key Functions
- create_task/3: task_fields×agent_fields×opts→{:ok,{task,pid}}|{:error,reason}, hierarchical fields
- delete_task/2: task_id×opts→{:ok,task}|{:error,reason}, auto-pause then cascade delete
- list_tasks/1: opts→[tasks], ordered by inserted_at desc
- get_task/1: id→{:ok,task}|{:error,:not_found}
- update_task_status/2: id×status→{:ok,task}|{:error,reason}
- save_agent/1: attrs→{:ok,agent}|{:error,reason}, called by Core.persist_agent
- get_agents_for_task/1: task_id→[agents], for restoration
- FieldProcessor.process_form_params/1: params→{:ok,%{task_fields,agent_fields}}|{:error,reason}
- pause_task/2: task_id×opts→:ok, sets "pausing" immediately, spawns async terminations via Task.start
- restore_task/4: task_id×registry×pubsub×opts→{:ok,root_pid}, topological sort, v4.0 calls rebuild_children_lists/2

## Patterns
- Transaction wrapping for atomicity (create_task, delete_task)
- Delegation to TaskRestorer for pause logic (no reimplementation)
- Sandbox.allow in create_task for test isolation
- Core.get_state sync wait after transaction to prevent sandbox race

## Field System Integration (2025-11)
- Task table: global_context (TEXT), initial_constraints (JSONB array)
- FieldProcessor: 11-field validation, task/agent split, enum conversion (207 lines)
- create_task/3: task_fields + agent_fields → DB + agent with prompt_fields
- GlobalContextInjector queries task by ID to retrieve fields

## Patterns
- Transaction wrapping for atomicity (create_task, delete_task)
- Delegation to TaskRestorer for pause logic
- Sandbox.allow in create_task for test isolation
- Core.get_state sync wait after transaction (prevents sandbox race)
- FieldProcessor: empty string → nil, comma-separated → list, enum validation

## Dependencies
- AGENT_DynSup: Agent spawning with prompt_fields
- TaskRestorer: Pause/resume orchestration
- Repo: Database operations
- RegistryQueries: Live agent discovery
- FIELDS_GlobalContextInjector: Global field injection
- FIELDS_PromptFieldManager: Prompt building from fields

## Recent Changes

**Feb 5, 2026 - Root Skills Feature (feat-20260205-root-skills)**:
- **FieldProcessor v3.0**: Added skills field to task_fields, parses comma-separated skill names
- **TaskManager v7.0**: Added resolve_skills/2 for skill resolution via SkillLoader before spawn
- Skills flow: form → FieldProcessor → task_fields.skills → TaskManager → active_skills → agent

**Jan 6, 2026 - user_prompt Removal (fix-20260106-user-prompt-removal)**:
- **TaskManager**: Removed user_prompt from agent_config in create_task/3
- Initial messages now flow through model_histories instead of separate user_prompt field

## Test Coverage
- TaskManager: 85 tests (77 + 8 new for skills R29-R35)
- FieldProcessor: 32 tests (27 + 5 new for skills R15-R19)
- Edge cases: empty fields, invalid enums, transaction rollbacks, concurrent operations, skill resolution
- Full async: true with isolated dependencies
