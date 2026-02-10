# lib/quoracle/consensus/prompt_builder/

## Content Source Map

**Use this map to find where specific system prompt text lives.**

### Final Prompt Section Order (v16.0)

```
1. IDENTITY          → sections.ex:152-165, field_prompts.system_prompt
2. SKILLS            → sections.ex:174-182 [conditional: active_skills non-empty] (v16.0)
3. PROFILE           → sections.ex:167-207 [conditional: profile_name provided]
4. OPERATING GUIDELINES → sections.ex:238-289 + guidelines.ex (includes profile selection after decomposition)
5. CAPABILITIES      → sections.ex:335-381
6. FORMAT            → response_format.ex (delegated via sections.ex:383-385)
```

### Section 1: Identity (sections.ex:165-178)
| Content | Location |
|---------|----------|
| Base identity text | sections.ex:167-168 |
| Field system_prompt (role, cognitive_style, etc.) | From agent state via field_prompts |

### Section 2: Profile (sections.ex:180-220) [CONDITIONAL]
| Content | Location | Condition |
|---------|----------|-----------|
| "## Operating Profile" header | sections.ex:212 | profile_name provided |
| Permission text (capability_groups) | sections.ex:223-230 | |
| Permission text (nil fallback) | sections.ex:232-241 | |
| Blocked actions list | sections.ex:192-202 | has restrictions |

### Section 3: Operating Guidelines (sections.ex:267-277 + guidelines.ex)
| Content | Location | Condition |
|---------|----------|-----------|
| "## Operating Guidelines" header | sections.ex:271 | always |
| **Signaling Task Completion** | guidelines.ex:9-15 | always |
| **When to Consider Skills** | guidelines.ex:39-59 | spawn_child in allowed_actions |
| **When to Escalate to Your Parent** | guidelines.ex:20-34 | always |
| **Task Decomposition for Parallel Work** | guidelines.ex:64-95 | :spawn_child in allowed_actions |
| **Selecting a Profile for Child Agents** | guidelines.ex:98-112 | :spawn_child in allowed_actions |
| **Terminating Commands You Started** | guidelines.ex:114-127 | :execute_shell in allowed_actions |
| **Appropriate Check-In Intervals** | guidelines.ex:130-141 | :spawn_child in allowed_actions |

### Section 4: Capabilities (sections.ex:314-321)
| Content | Location |
|---------|----------|
| "## Available Actions" header | sections.ex:330 |
| Action schemas (per-action) | schema_formatter.ex:document_action_with_schema/2 |
| Action descriptions | schema/metadata.ex (via Schema.get_action_description/1) |
| **API Protocol guidance** | action_guidance.ex:15-58 |
| **MCP Usage guidance** | action_guidance.ex:67-93 |
| **Secrets documentation** | prompt_builder.ex:28-78 |
| "## NO_EXECUTE Tags" header | sections.ex:343 |
| NO_EXECUTE explanation | sections.ex:343-364 |
| Untrusted action list | sections.ex:96-123 (generated from @untrusted_actions) |
| Trusted action list | sections.ex:126-151 (generated from @trusted_actions) |

### Section 5: Format (response_format.ex)
| Content | Location |
|---------|----------|
| "## Response Format" header | response_format.ex:26 |
| Response JSON Schema | response_format.ex:49-91 |
| **Grounding Verification** docs | response_format.ex:146-167 (Pythea-inspired self-check) |
| Action examples | examples.ex:build_action_examples/1 |
| **Wait Parameter** docs | response_format.ex:93-112 |
| **Auto-Complete TODO** docs | response_format.ex:114-124 |
| **Bug Report Field** docs | response_format.ex:126-144 |
| **Condense Parameter** docs | response_format.ex:169-180 |
| Important notes | response_format.ex:182-195 |

### Dynamic Content Sources (Database)
| Content | Source Module | DB Table |
|---------|--------------|----------|
| Profile names (spawn_child enum) | prompt_builder.ex:352-363 | profiles |
| Profile descriptions | prompt_builder.ex:368-378 | profiles |
| Capability group descriptions | profiles/capability_groups.ex | (hardcoded) |

### Conditional Logic Summary
| Condition | Affects |
|-----------|---------|
| `profile_name != nil` | Section 2 (Profile) appears |
| `:spawn_child in allowed_actions` | Profile selection, decomposition, monitoring guidance in Section 4 |
| `:execute_shell in allowed_actions` | Process termination guidance in Section 4 |

---

## Modules (Extracted from PromptBuilder.ex for <500 line requirement)

- SchemaFormatter: JSON schema generation (426 lines, pure functions, no side effects)
- Sections: Content assembly (382 lines), section builders, action categorization, skill injection (v16.0)
- SkillLoader: Skill content loading (52 lines, v16.0), loads SKILL.md files, graceful degradation
- Examples: Action example templates (215 lines), extracted from Sections for 500-line limit
- ActionGuidance: API/MCP usage guidance (95 lines, delegated from Sections)
- Guidelines: Operating guidelines content (127 lines, v1.0), extracted from Sections for <500 line limit
- ResponseFormat: Response format documentation (195 lines, v1.1), extracted from Sections for <500 line limit
- Context: Parameter grouping structs (89 lines, v1.0), reduces build_integrated_prompt from 10 params to 4

## Functions

SchemaFormatter:
- action_to_json_schema/1: atom → JSON Schema - Converts Elixir schemas to JSON with param_descriptions
- format_param_type/1: Type conversion (string, enum, list, nested map)
- XOR handling: Detects xor_params, generates oneOf structures
- Special handling: send_message 'to' parameter (array or atom conversion)

Sections:
- build_integrated_prompt/4: Orchestrates optimal section ordering (v16.0: 4th param opts for skill injection)
- prepare_action_docs/1: Categorizes untrusted/trusted actions
- build_action_examples/1: Delegated to Examples module
- Section builders: add_identity_section/2, add_skill_section/2 (v16.0), add_profile_section/2, add_guidelines_section/4, add_capabilities_section/5, add_format_section/2
- Profile formatting: format_profiles_for_guidelines/2, do_format_profiles/1 (v2.0: moved from standalone section into guidelines)

SkillLoader (v16.0):
- load_skill_content/2: list(skill_metadata)×keyword→String.t, loads and joins skill content
- load_single_skill/2: skill_metadata×keyword→String.t|nil, loads single skill file
- extract_body/1: String.t→String.t, removes YAML frontmatter from skill content

Context (v1.0):
- Context.Action: Groups action-related params (schemas, untrusted_docs, trusted_docs, allowed_actions, format_secrets_fn)
- Context.Profile: Groups profile params (name, description, permission_check, blocked_actions, available_profiles)
- Context.Profile.has_profile?/1: Returns true if profile_name is set

ResponseFormat (v1.1):
- build_format_section/1: Response format documentation with JSON schema, grounding verification, wait/condense/bug_report docs
- grounding_verification_docs/0: Pythea-inspired self-check guidance (know your basis, be specific, exploration is fine)

Examples:
- build_action_examples/0: JSON example templates for all action types (wait, send_message, spawn_child, call_api, call_mcp)

Guidelines (v2.0):
- completion_guidance/0: Task completion signaling text
- escalation_guidance/0: Parent escalation guidance
- skills_guidance/1: Skills consultation guidance (conditional on :spawn_child)
- decomposition_guidance/1: Task decomposition for parallel work (conditional on :spawn_child)
- profile_selection_guidance/2: Profile selection for child agents (conditional on :spawn_child, v2.0)
- process_guidance/1: Shell command termination guidance (conditional on :execute_shell)
- child_monitoring_guidance/1: Check-in interval guidance (conditional on :spawn_child)

## Patterns

**Pure transformation** (SchemaFormatter): No DB, no side effects, testable
**Content assembly** (Sections): Optimal ordering, context-aware building
**XOR parameter handling**: oneOf structures for execute_shell
**Parameter grouping** (Context): Structs reduce function arity, improve readability
**Extracted documentation** (ResponseFormat): Response format docs in dedicated module

## Dependencies

SchemaFormatter → ACTION_Schema (for schema definitions)
Sections → ACTION_Schema (for action metadata), Context structs, ResponseFormat, Guidelines
Context → (none - pure data structs)
ResponseFormat → Examples (for action examples)

## Test Patterns

- SchemaFormatter: Pure function tests, no DB
- Sections: Content verification tests
