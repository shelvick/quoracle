# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-02-11

### Added

- **DeepSeek reasoning support** — OptionsBuilder now configures thinking/reasoning
  parameters for DeepSeek models alongside existing Claude support.
- **llm_db update script** for refreshing the local LLM database from upstream
  sources.

### Fixed

- **Dynamic max_tokens calculation** — Prevents context window overflow by
  computing available output tokens from the model's context limit minus input
  token count, capped at the model's output limit. Includes proactive history
  condensation when output space falls below a safety floor.

### Removed

- Outdated PostgreSQL setup script (superseded by standard Ecto workflows).

## [0.1.1] - 2026-02-10

### Added

- **Per-profile max refinement rounds** — Profiles can now set the maximum
  number of consensus refinement rounds (0–9). Temperature descent adapts
  automatically to the configured round count. Defaults to 4 (matching
  previous hardcoded behavior).
- **Configurable skills path** — The skills directory is now configurable via
  Settings > System. Defaults to `~/.quoracle/skills/`.

### Fixed

- Docker startup crash when `CLOAK_ENCRYPTION_KEY` is missing — now shows an
  actionable error message ([#2](https://github.com/shelvick/quoracle/issues/2)).
- Improved Reflector prompt quality for more useful lesson extraction.

## [0.1.0] - 2026-02-07

Initial open-source release. Recursive Mixture-of-Agents orchestration with
multi-LLM consensus, 21 action types, three-panel LiveView dashboard, task
persistence with pause/resume, hierarchical budget system, cost tracking,
profile-based agent permissions, and file-based skills system.
