# lib/quoracle/skills/

## Overview

File-based knowledge management system. Skills are markdown files stored in `~/.quoracle/skills/` that agents can load and create. Available skills are listed in agents' system prompts.

## Modules

**Loader** (234 lines, v3.0):
- `skills_dir/1` - Returns skills directory with 3-tier fallback: opts > ConfigModelSettings DB > hardcoded default (v2.0)
  - Tilde expansion via Path.expand/1 on DB-configured paths
- `list_skills/1` - Lists all skills (metadata only, no content), grove-first with global fallback (v3.0)
- `load_skill/2` - Loads single skill by name with full content, searches [grove_dir, global_dir] in order (v3.0)
- `load_skills/2` - Loads multiple skills, returns `{:error, _}` if any fail (not crash)
- `parse_skill_file/2` - Parses SKILL.md content into structured data
- `resolve_skill_dirs/1` - Returns [grove_dir, global_dir] based on `:grove_skills_path` and `:skills_path` opts (v3.0)
- `list_skills_in_dir/1` - Non-raising `File.ls/1` for single directory listing (v3.0)
- `load_skill_from_dir/2` - Non-raising `File.read/1` for single skill load (v3.0)
- All bang operations (`File.ls!/1`, `File.read!/1`) replaced with non-raising equivalents (v3.0)

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
