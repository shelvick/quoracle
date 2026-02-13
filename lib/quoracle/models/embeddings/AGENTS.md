# lib/quoracle/models/embeddings/

## Modules
- **TokenChunker** (108 lines): Token-based text chunking for embedding models
  - `chunk_text_by_tokens/2`: Split text at word boundaries respecting token limits
  - `get_embedding_token_limit/1`: Look up model limits from LLMDB (default 8191)
  - `effective_token_limit/1`: Apply 90% safety margin to model limit

## Constants
- `@default_embedding_token_limit`: 8191 (OpenAI text-embedding-3-large)
- `@token_safety_margin`: 0.9

## Dependencies
- `Quoracle.Agent.TokenManager` for tiktoken token counting
- LLMDB for model context limit lookup

## Patterns
- Word-boundary chunking: splits at whitespace, never mid-word
- Single oversized word taken as-is to prevent infinite loops
- Enum.reduce accumulator pattern for chunk building
