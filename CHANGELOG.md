# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.3] - 2026-03-27

### Changed

- Dashboard per-node scalar extraction: AgentNode only reads the fields it needs from agent state, reducing LiveView diff overhead.
- Log detail truncation with lazy-load: long log entries are truncated in the list view and expand on click.
- Removed duplicate agent cost PubSub subscriptions that caused redundant re-renders.
- Upgraded LLMDB to v2026.3 with new snapshot format.

### Fixed

- Livebench coding category scoring issues.
- Benchmark grove adherence improvements for more reliable agent behavior.

## [0.2.2] - 2026-03-18

### Added

- Quoracle logo (SVG) displayed in navigation header, replacing the text link.
- Strict confinement mode for groves with `grove_vars` template variable resolution at spawn time.

### Changed

- AgentNode evolved to recursive LiveComponent for per-node DOM diffing instead of full-tree re-renders.
- Log panel uses debounce timer and pre-computed `display_logs` to reduce render overhead.
- Dashboard cost queries batched with precomputed data flow for lower DB pressure.
- Mailbox panel fully isolated with dedicated PubSub subscriptions.
- CostDisplay breakdown cache invalidated automatically when `total_cost` changes.
- Initial cost data hydrated at mount time instead of lazy-loading.
- Header streamlined: gear icon replaces Settings text link, reduced whitespace.

### Removed

- Dead signals, stale `cost_id_prefix` references, and unused assigns cleaned up from dashboard.

## [0.2.1] - 2026-03-12

### Fixed

- Child tracking race condition: use Registry fallback when injected children lag state updates, and deduplicate spawn_child results to keep tracking consistent under async races.
- Dashboard cost refresh storm: debounce `cost_recorded` PubSub events (2s window) to prevent O(N²) re-query feedback loop that caused UI lockup with 100+ agents.

### Changed

- Removed 20-child injection limit that caused agents to lose visibility of children beyond 20, triggering unbounded respawning.
- Deferred per-agent GenServer calls (todos, budget) in Dashboard to after mount to prevent longpoll timeout with many live agents.

### Removed

- Dead `registry_spawned_at/1` function and unreachable code paths in ChildrenInjector.

## [0.2.0] - 2026-03-10

### Added

- **Groves**: declarative multi-agent orchestration via GROVE.md manifests. Define topology, bootstrap, governance, confinement, schemas, and spawn contracts in a single file — then run it.
  - **Bootstrap**: pre-fill task creation forms from file references or inline values.
  - **Governance**: dual-layer rule enforcement — prompt guidance (LLM reads the rule) AND runtime blocking (code enforces the rule). Supports `shell_pattern_block` and `action_block` hard rules.
  - **Confinement**: per-skill filesystem restrictions enforced at the `file_read`, `file_write`, and `execute_shell` action layer.
  - **Schema validation**: JSON Schema (Draft 2020-12) validation on `file_write` actions matching glob path patterns.
  - **Spawn contracts**: declared parent→child topology edges with auto-injection of skills, profile (with fallback), and constraints.
  - **PathSecurity**: three-layer defense against path traversal and symlink attacks across all grove resolvers.
- Two example groves shipped: **livebench** (6-category benchmark) and **mmlu-pro** (14-subject multiple-choice benchmark).
- Children context enrichment: agents see their children's latest message preview and status directly in the prompt.
- Correction feedback injection: parent feedback is injected into child prompts with lifecycle tracking and root stall notification when children stop progressing.

### Fixed

- Per-model consensus queries now run in parallel instead of sequentially.
- Context window overflow from insufficient token safety margins across multiple providers.
- Correction feedback cleared by queued messages arriving during retry.
- Missing `:id` field in system stall messages crashing the Mailbox UI.
- Empty children signal not injected when no live children exist.
- GPT wait-stall pattern causing agents to idle indefinitely.
- LLM receive timeout too low for slow providers (increased to 300s).

### Changed

- Comprehensive Groves documentation added to README.
- DRY refactors: children tracking, skill metadata construction, single-model persist path, PerModelQuery extraction.

## [0.1.17] - 2026-02-28

### Added

- Profile hot-reload: agents reload profile config at runtime (model pool, max refinement rounds, system prompt) without task restart.
- Forced reflection: single-model agents with `force_reflection` enabled undergo mandatory refinement in round 1.

### Fixed

- Condensation overflow crashing when `to_discard` exceeded model context window.
- GenServer crash when LLM returns unknown sub-action type in `batch_sync` or `batch_async`.
- Reflector response extraction failing for reasoning models with `:object` content parts.

### Changed

- Warning log broadcast on model pool switch failure during hot-reload.
- Non-negative validation for `max_refinement_rounds` in hot-reload handler.

## [0.1.16] - 2026-02-23

### Added

- System prompt caching in the consensus pipeline for improved performance.
- MCP Client lifecycle monitoring with liveness guards and crash-to-error logging.

### Fixed

- Cost display budget timeouts and model attribution loss after child dismissal.
- Infinite continuation loop in fast-path consensus.
- `Decimal.decimal(nil)` crash in `Tracker.over_budget?` for N/A budgets.
- `Response.text()` blindness to pure JSON responses.
- Google Vertex string error body handling in RetryHelper v3.3.
- Silent result loss from HTTP actions missing timeout overrides.

### Changed

- DRY Aggregator SQL with extracted ResponseLogger module.
- Test suite optimization: removed ~230 redundant tests, split heavy modules, migrated 23 files from DataCase to ExUnit.Case.

## [0.1.15] - 2026-02-21

### Fixed

- **Consensus interleaving** — Defer consensus when self-contained actions are
  still pending, preventing premature consensus queries.
- **quoracle.reload change detection** — Fix false positives from non-deterministic
  compilation.
- **RetryHelper v3.2** — Retry HTTP 429/5xx errors from crashed response parsers
  with improved malformed response logging and stacktrace context.
- **Vertex native model compatibility** — Skip response_format for native Vertex
  models (Gemini, Claude) that don't support it.

### Changed

- Apply ResponseTruncator to async shell completion path.

### Removed

- Remove obsolete auto_complete_todo parameter.

## [0.1.14] - 2026-02-21

### Fixed

- **Async shell Phase 2 results discarded** — Shell completion results from
  long-running async commands were silently lost. ActionResultHandler now
  preserves pending_actions entries for Phase 1 acks, and ShellCompletion
  passes action_atom via 4-arity cast for standard continuation.
- **Flaky shell Port crash test** — Condensed core.ex stop_requested handler
  and stabilized the shell Port crash test.

### Added

- **Vertex MaaS JSON mode** — Added response_format support for Vertex Model-
  as-a-Service, fixed ClientAPI timeouts.

## [0.1.13] - 2026-02-20

### Added

- **Local model support** — Connect to locally-hosted LLMs (Ollama, LM Studio, etc.)
  with conditional API key handling, LLMDB bypass for embeddings, custom model_spec
  input, and local model indicators in the UI.

### Fixed

- **MCP reliability** — Guaranteed error delivery on dispatch task crash, added
  MCP_Client reconnection with dead status tracking, retry logic with reconnect
  and timeout increase, sync timeout for system-level actions, and fixed Streamable
  HTTP base_url path doubling.
- **Budget timeout on child dismiss** — Replaced blocking GenServer.call budget
  updates with cast-based approach, eliminating child timeout when parent is busy.
  Fixed Decimal-to-String drift in cost tracking.
- **Cost details total** — Fixed cost details total dropping on child dismiss.

### Changed

- **MCP protocol version** — Set protocol_version per transport in connection manager.

## [0.1.12] - 2026-02-16

### Fixed

- **Hot-reload false positives** — Fixed `quoracle.reload` reporting spurious
  changes due to non-deterministic compilation order and MD5 algorithm mismatch,
  then always reporting no changes after the algorithm fix.
- **Task cost tracking** — Fixed task costs dropping to zero when dismissing
  children with N/A budgets.
- **Agent stall during sync actions** — Fixed agents stalling when user messages
  arrive while an always-sync action is executing.
- **Consensus clustering** — Fixed consensus clustering incorrectly handling
  mergeable params.

### Changed

- **Shell error messages** — Enriched `command_not_found` errors with a list of
  available command IDs for easier debugging.
- **Reflector token budget** — Added 5% safety margin to Reflector max_tokens
  calculation to prevent truncation.

## [0.1.11] - 2026-02-16

### Fixed

- **Dead Router PID crash** — Guard check_id routing against dead Router PIDs,
  preventing crashes when routing to a terminated Router process.
- **Reflector echoing action JSON** — When conversation history was dominated by
  action JSON, the Reflector LLM would pattern-match to action output instead of
  producing lessons and state extraction. Split into system/user message structure
  with XML boundary tags to keep the LLM on task.

### Changed

- **ConfigBuilder simplification** — Extracted `inherit_key/4` helper to reduce
  ConfigBuilder complexity.

## [0.1.10] - 2026-02-14

### Fixed

- **Parent ID lost after pause/resume** — Child agents now correctly persist
  their parent ID when the parent process has exited, preventing nil parent_id
  after restoration.
- **Root agent hijack on restore** — Dashboard now uses first-writer-wins guard
  on root_agent_id, preventing orphaned agents from overwriting the root during
  task restoration.
- **Restore halts on single agent failure** — TaskRestorer now continues past
  individual agent failures instead of aborting the entire restoration.
- **In-flight spawns missed during pause** — Post-pause sweep catches agents
  that register after the initial Registry query, ensuring all agents are
  stopped before persistence.
- **Orphaned agents from previous session** — New cleanup pass terminates
  agents surviving from a prior session that were not part of the restoration
  set.

## [0.1.9] - 2026-02-14

### Fixed

- **Action executor regressions** — Fixed three regressions: error-state stall
  preventing recovery, shell action `check_id` misrouting, and Router process
  leak on action completion.
- **Malformed LLM response handling** — Reflector now retries when LLM responses
  fail to parse, instead of stalling.
- **Flaky deadlock test** — Fixed non-deterministic batch_sync test.

### Changed

- **LLM prompt robustness** — Strengthened JSON output instructions for weaker
  models, clarified batch_sync/batch_async exclusions, added enum constraints
  to action JSON schemas, and improved parent-child timing guidance.
- **Dynamic max_tokens safety margin** — Token estimation now includes a 5%
  safety margin to prevent truncation.
- **Action lifecycle log broadcasts** — Restored action lifecycle events to the
  UI log panel.
- **Reflector refactor** — Extracted `retry_ctx` map to reduce function arity;
  deduplicated `extract_check_or_terminate_id` and removed dead code.
- **Test performance** — Deleted redundant tests, reduced timeouts, and
  simplified setup for faster test suite execution.

## [0.1.8] - 2026-02-13

### Added

- **Hot-reload mix task** — `mix quoracle.reload` enables hot-reloading modules
  on a running node without restart.

### Fixed

- **Hostname resolution in reload task** — Fixed node name lookup for the
  hot-reload mix task.
- **Embedding crash on non-binary input** — `Embeddings.get_embedding/1` no
  longer crashes when receiving non-binary input.
- **Embedding cost context not propagated** — Embedding cost metadata is now
  properly threaded through HistoryTransfer and batch_sequence_merge.

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
