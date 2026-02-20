# lib/quoracle/models/

## Architecture (2025-12 ReqLLM Migration)
ModelQuery calls ReqLLM directly with model_spec from credentials.
No provider abstraction layer - ~7,340 lines of provider code deleted.

## Concurrency
EmbeddingCache owns ETS table (process-owned)

## Modules
- **ModelQuery** (368 lines): Parallel LLM query via Task.async
  - Calls ReqLLM.generate_text directly with credential.model_spec
  - Returns ReqLLM.Response passthrough (no normalization)
  - v19.0: Local model LLMDB bypass via `LocalModelHelper.resolve_model_ref/2`
  - `build_options/2`: Delegated to OptionsBuilder, public with `@doc false` for testing
- **ModelQuery.OptionsBuilder** (245 lines): Provider-specific LLM options builder
  - `build_options/2`: Provider-specific options for ReqLLM (Azure, Vertex, Bedrock, default)
  - `build_embedding_options/2`: Provider-specific options for embedding requests
  - `get_provider_prefix/1`: Extracts provider prefix from model_spec
  - v19.0: Forwards `endpoint_url` as `base_url` for local models
- **ModelQuery.MessageBuilder** (164 lines): Message building and validation (extracted v11.0)
  - `validate_messages/1`, `build_messages/1`: ReqLLM.Message list construction
  - Supports multimodal content: text, image (base64), image_url
  - v13.0: Calls ImageCompressor.maybe_compress for all :image types
- **ModelQuery.CacheHelper** (55 lines): Anthropic prompt caching for Bedrock
  - `maybe_add_cache_options/2`: Add caching provider_options when prompt_cache present
  - `log_cache_metrics/1`: Debug logging for cache read/write tokens
- **ModelQuery.UsageHelper** (228 lines): Usage/cost calculation helpers
  - v12.0: Captures 5 token types + aggregate costs
  - `calculate_aggregate_usage/1`, `maybe_record_costs/2`, `record_single_request/4`
  - `extract_usage/1`, `extract_total_cost/1`, `format_cost/1`
- **LocalModelHelper** (111 lines): Shared local model routing logic (NEW 2026-02)
  - `cloud_provider?/1`: Check if model_spec is cloud provider (Azure/Vertex/Bedrock)
  - `split_model_spec/1`: Extract provider and model name from "provider:model" string
  - `local_model?/1`: Check if credential struct represents local model
  - `resolve_model_ref/2`: Build map bypass or string model_spec for ReqLLM
  - `@local_providers`: vllm, ollama, lmstudio, llamacpp, tgi
  - `@cloud_provider_prefixes`: azure, google, bedrock, vertex, amazon
- **Embeddings** (427 lines): Text embedding via ReqLLM, caching, token-based chunking
  - Model from ConfigModelSettings.get_embedding_model!() (config-driven)
  - v8.0: Local model LLMDB bypass via LocalModelHelper
  - v7.0: Multi-provider support, token-based chunking via TokenChunker
- **Embeddings.TokenChunker** (108 lines): Token-based text chunking for embedding models
  - `chunk_text_by_tokens/2`: Split text at word boundaries respecting token limits
  - `get_embedding_token_limit/1`: Look up model limits from LLMDB (default 8191)
  - `effective_token_limit/1`: Apply 90% safety margin to model limit
- **Embeddings.CostHelper** (100 lines): Cost computation and recording (NEW 2026-02)
  - `compute_embedding_cost/2`: Compute cost_usd from LLMDB pricing (Decimal arithmetic)
  - `record_cost/3`: Record or accumulate embedding cost
  - `accumulate_cost/4`: Thread cost accumulator for batch writes
  - `resolve_configured_model_spec/0`: DRYed model_spec resolution
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
  - v3.0: api_key optional when endpoint_url present (local model support)
- **TableSecretUsage**: Audit trail for secret access
- **TableModelConfigs**: Model metadata (retained for ProviderGoogle)

## Deleted Modules
- ~~ModelRegistry~~: Replaced by LLMDB queries via model_spec
- ~~ProviderSetup~~: Provider initialization no longer needed

## Key Flow
```
CredentialManager.get_credentials(model_id)
  → credential.model_spec (e.g., "openai:gpt-4o")
    → LocalModelHelper.resolve_model_ref(model_spec, credential)
      → map bypass (local) OR string path (cloud)
        → ReqLLM.generate_text(model_ref, messages, opts)
          → ReqLLM.Response passthrough
```

## Patterns
- Parallel execution via Task.async (default)
- Sandbox.allow in query_single_model/3 when sandbox_owner present
- model_spec string enables LLMDB to handle provider routing
- Local models bypass LLMDB via map-based model ref (LocalModelHelper)

## req_llm Integration
- model_spec format: "provider:model_name" (e.g., "azure-openai:o1-preview", "vllm:llama3")
- ReqLLM.Response contains: id, model, message, usage, finish_reason, provider_meta
- Tests use req_cassette plug for HTTP recording
- Local models: endpoint_url forwarded as base_url via OptionsBuilder

Test coverage: 47 core + 9 local model + 6 embedding local + 14 audit findings tests (async: true)
