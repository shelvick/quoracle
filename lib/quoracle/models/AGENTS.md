# lib/quoracle/models/

## Architecture (2025-12 ReqLLM Migration)
ModelQuery calls ReqLLM directly with model_spec from credentials.
No provider abstraction layer - ~7,340 lines of provider code deleted.

## Concurrency
EmbeddingCache owns ETS table (process-owned)

## Modules
- **ModelQuery**: Parallel LLM query via Task.async (364 lines)
  - Calls ReqLLM.generate_text directly with credential.model_spec
  - Returns ReqLLM.Response passthrough (no normalization)
  - v9.0: Default `reasoning_effort: :high` for all providers
  - v10.0: Bedrock prompt caching support via `prompt_cache` option
  - v11.0: Multimodal message support via MessageBuilder extraction
  - `build_options/2`: Delegated to OptionsBuilder, public with `@doc false` for testing (R14-R17)
- **ModelQuery.OptionsBuilder** (161 lines): Provider-specific LLM options builder (extracted 2026-01)
  - `build_options/2`: Builds provider-specific options for ReqLLM
  - `get_provider_prefix/1`: Extracts provider prefix from model_spec
  - Handles Azure, Google Vertex, Bedrock, default providers
  - Claude thinking config for Bedrock/Vertex Claude models
- **ModelQuery.MessageBuilder** (164 lines): Message building and validation (extracted v11.0)
  - `validate_messages/1`: Validates message format (role + content)
  - `build_messages/1`: Builds ReqLLM.Message list from string-role messages
  - Supports multimodal content: text, image (base64), image_url
  - Handles atom/string keys and type values (from JSON or Elixir)
  - v13.0: Calls ImageCompressor.maybe_compress for all :image types (6 clauses)
- **ModelQuery.CacheHelper** (55 lines): Anthropic prompt caching for Bedrock
  - `maybe_add_cache_options/2`: Add caching provider_options when prompt_cache present
  - `log_cache_metrics/1`: Debug logging for cache read/write tokens
- **ModelQuery.UsageHelper** (228 lines): Usage/cost calculation helpers (extracted 2025-12-13)
  - v12.0: Captures 5 token types (input, output, reasoning, cached, cache_creation) + aggregate costs (input_cost, output_cost)
  - v16.0: Logger.warning when cost context (agent_id/task_id/pubsub) missing
  - `calculate_aggregate_usage/1`: Sum tokens/costs from responses
  - `maybe_record_costs/2`: Record costs via CostRecorder with sandbox cleanup handling
  - `record_single_request/4`: Record cost for single AI request (embeddings, answer engine, condensation)
  - `extract_usage/1`, `extract_total_cost/1`: Response parsing
  - `extract_cache_creation_tokens/1`: v12.0 - Extract cache_creation_input_tokens from usage
  - `format_cost/1`: v12.0 - Format Decimal cost as string for JSON metadata
- **Embeddings** (445 lines): Text embedding via ReqLLM, caching, chunking at 10K chars
  - Model from ConfigModelSettings.get_embedding_model!() (config-driven)
  - v5.0: `compute_embedding_cost/2` — compute cost_usd from LLMDB pricing (Decimal arithmetic)
- **EmbeddingCache**: GenServer owns :embedding_cache ETS (LRU 100 entries)
- **CredentialManager**: DB credential retrieval, returns model_spec for LLMDB lookup
- **ConfigModelSettings** (319 lines): Runtime config for consensus/embedding/answer models
  - get_consensus_models/0,!/0, set_consensus_models/1
  - get_embedding_model/0,!/0, set_embedding_model/1
  - get_answer_engine_model/0,!/0, set_answer_engine_model/1
  - get_image_generation_models/0,!/0, set_image_generation_models/1 (v3.0)
  - get_skills_path/0, set_skills_path/1 (v5.0): System-wide skills directory path
  - validate_model_pool/1 (v4.0): Validates model IDs against credentials for runtime switching
  - get_all/0 (includes skills_path), configured?/0
- **LLMDBModelLoader** (130 lines): LLMDB model queries for UI dropdowns
  - all_models/0,1, chat_models/0,1, embedding_models/0,1
  - models_by_provider/0,1, available?/0,1, format_model/1
- **TableConsensusConfig** (94 lines): model_settings table key-value JSONB storage
  - get/1, upsert/2, delete/1, list_all/0
- **TableSecrets**: Encrypted secret storage with Cloak
  - v2.0: search_by_terms/1 for case-insensitive substring matching (ILIKE ANY)
- **TableCredentials**: Model credential storage with model_spec column
- **TableSecretUsage**: Audit trail for secret access
- **TableModelConfigs**: Model metadata (retained for ProviderGoogle)

## Deleted Modules
- ~~ModelRegistry~~: Replaced by LLMDB queries via model_spec
- ~~ProviderSetup~~: Provider initialization no longer needed

## Key Flow
```
CredentialManager.get_credentials(model_id)
  → credential.model_spec (e.g., "openai:gpt-4o")
    → ReqLLM.generate_text(model_spec, messages, opts)
      → ReqLLM.Response passthrough
```

## Patterns
- Parallel execution via Task.async (default)
- Sandbox.allow in query_single_model/3 when sandbox_owner present
- model_spec string enables LLMDB to handle provider routing

## req_llm Integration
- model_spec format: "provider:model_name" (e.g., "azure-openai:o1-preview")
- ReqLLM.Response contains: id, model, message, usage, finish_reason, provider_meta
- Tests use req_cassette plug for HTTP recording

Test coverage: 47 core tests (async: true)
