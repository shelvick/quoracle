# test/quoracle/providers/

## Test Modules (114 tests) - req_llm Migration Complete 2025-12
- ProviderInterfaceTest: Behaviour compliance (Hammox)
- ProviderBedrockTest, ProviderGoogleTest: req_cassette plug passthrough
- ProviderAzureOpenAITest, ProviderAzureOpenAIAuthTest: req_cassette plug passthrough
- ProviderAzureCustomTest: req_cassette plug passthrough
- RetryLogic tests: async: true (pure unit tests, no HTTP)

## req_cassette (replaced ExVCR)
- async: true (no adapter conflicts - plug-based)
- Use `ReqCassette.with_cassette` directly (default mode: :record replays if cassette exists)
- Cassettes stored in test/fixtures/cassettes/

## Coverage
DB config, AWS credential parsing, Azure fields, role transformations, auth errors, retry, embeddings, raw responses

Test data: req_cassette JSON files with sanitized credentials
