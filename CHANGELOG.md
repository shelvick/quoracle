# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.7] - 2026-02-13

### Added

- **Multi-provider embedding support** — Agents can now use different embedding
  providers and models via configurable opts, with token-based chunking for
  inputs exceeding provider token limits.

### Fixed

- **Action executor deadlock** — Actions are now dispatched via Task.Supervisor
  instead of inline callbacks, eliminating a deadlock where synchronous action
  execution blocked the agent's message loop.
- **Race condition in message handling** — Extracted ActionResultHandler from
  MessageHandler to fix an R64 race condition where action results could be
  processed before the agent was ready.
- **FunctionClauseError in Aggregator** — `extract_action_type/1` now handles
  unexpected input shapes gracefully instead of crashing.
- **Batch validator crash on non-map entries** — Guard added to prevent crashes
  when batch actions contain malformed entries.

### Changed

- Replaced manual `on_exit` cleanup across test files with
  `register_agent_cleanup` helper for consistency.
- Added dynamic `max_tokens` to Reflector query path to prevent context window
  overflow.

## [0.1.6] - 2026-02-12

### Fixed

- **batch_sync stall with wait:true** — `batch_sync` actions with `wait:true`
  stalled indefinitely when all sub-actions were self-contained (e.g.,
  `file_read`, `orient`). Now dynamically inspects sub-actions and auto-corrects
  `wait:true` to `false` when no sub-action can trigger an external response.
  Mixed batches preserve `wait:true` as expected.

## [0.1.5] - 2026-02-12

### Fixed

- **Orphaned agents on task deletion** — Deleting a task now force-kills its
  agents instead of sending a graceful stop request. Agents stuck in retry
  loops could not process `:stop_requested` messages, leaving them running
  indefinitely.
- **Send message target cleanup** — Stripped bracket artifacts from LLM-generated
  targets (e.g., `[parent]` → `parent`). Removed dead `all_children` and `user`
  target types; added error logging for invalid targets.
- **Announcement guardrails** — Tightened send_message schema and prompt guidance
  to prevent LLMs from misusing `announcement` for status updates. Announcement
  is now explicitly documented as broadcast-only for directives and corrections.

## [0.1.4] - 2026-02-11

### Changed

- Release workflow now triggers on tag push and creates the GitHub release
  automatically with changelog notes and tarball.

_Note: v0.1.3 was skipped due to a GitHub ghost-ref bug that blocked tag
re-creation._

## [0.1.3] - 2026-02-11

### Fixed

- **Budget enforcement for spawn** — Budgeted parent agents now correctly
  require a `:budget` parameter when spawning children. Budget data and spent
  amounts propagate through ActionExecutor to child agents, and budgets are
  reconciled when children are dismissed.

### Changed

- Replaced dev-centric role names with research/business examples in SVG
  diagrams.
- DRY refactor of wait coercion, pipeline opts, and background dismissal
  extraction in Core.

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
