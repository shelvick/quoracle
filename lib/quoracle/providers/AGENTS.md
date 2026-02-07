# lib/quoracle/providers/

## Provider Layer Simplification (2025-12)

Most provider modules DELETED - ModelQuery now calls ReqLLM directly with model_spec.

### Remaining Module
- **ProviderGoogle**: Vertex AI/Gemini 2.5 Pro - RETAINED for AnswerEngine grounded search
  - Uses ReqLLM.generate_text with google-vertex:model_name spec
  - Handles Google-specific features: service account files, grounding options
  - 250 lines, normalizes response to plain map format

### Deleted Modules (replaced by direct ReqLLM calls)
- ~~ProviderBedrock~~
- ~~ProviderAzureOpenAI~~
- ~~ProviderAzureCustom~~
- ~~ProviderInterface~~ (behaviour)
- ~~translators/~~ (entire directory)

## RetryHelper (Retained)
Exponential backoff, configurable max_retries/initial_delay
Complements Req's built-in retry for provider-specific error handling

## ProviderGoogle Response Format
Returns plain map (normalized from ReqLLM.Response):
- content: String.t()
- model: String.t()
- usage: %{input_tokens, output_tokens, total_tokens}
- finish_reason: String.t()
- provider_meta: map() (includes grounding metadata)

## Error Atoms
:authentication_failed, :model_not_found, :rate_limit_exceeded, :service_unavailable, :unknown_error
