# lib/quoracle/skills/

## Overview

File-based knowledge management system. Skills are markdown files stored in `~/.quoracle/skills/` that agents can load and create. Available skills are listed in agents' system prompts.

## Modules

**Loader** (234 lines):
- `skills_dir/1` - Returns skills directory (injectable for tests)
- `list_skills/1` - Lists all skills (metadata only, no content)
- `load_skill/2` - Loads single skill by name with full content
- `load_skills/2` - Loads multiple skills, fails if any missing
- `parse_skill_file/2` - Parses SKILL.md content into structured data

**Creator** (147 lines):
- `create/2` - Creates new skill directory and SKILL.md file
- `validate_name/1` - Validates skill name format
- Name rules: lowercase alphanumeric, hyphens allowed, no consecutive hyphens, starts with letter, max 64 chars
- Creates attachment subdirectories: scripts/, references/, assets/

## SKILL.md Format

```yaml
---
name: deployment
description: Deploy applications to staging and production...
metadata:
  complexity: medium
  estimated_tokens: 1500
  capability_groups_required: file_read,external_api
---

# Deployment

[Markdown content...]
```

## Directory Structure

```
~/.quoracle/skills/
├── deployment/
│   ├── SKILL.md
│   ├── scripts/       # Optional
│   ├── references/    # Optional
│   └── assets/        # Optional
└── code-review/
    └── SKILL.md
```

## Key Patterns

- **Path injection**: All functions accept `:skills_path` option for test isolation
- **Metadata vs content**: `list_skills` returns metadata only, `load_skill` includes content
- **Error handling**: Missing directory returns empty list, missing skill returns `{:error, :not_found}`

## Actions Using This Module

- `learn_skills` - Uses Loader for content retrieval (temporary or permanent)
- `create_skill` - Uses Creator for new skill files

## Test Coverage

- 40 tests in loader_test.exs
- All tests use temp directories for isolation
- async: true for all tests

## Dependencies

- `YamlElixir` for YAML parsing in frontmatter
- Standard `File` module for filesystem operations
