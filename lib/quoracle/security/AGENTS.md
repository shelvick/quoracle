# lib/quoracle/security/

## Modules
- SecretResolver: Template parser for {{SECRET:name}} syntax
- OutputScrubber: Result sanitizer removing secret values

## Key Functions
- SecretResolver.resolve_params/1: Map params, replace templates with DB values
- SecretResolver.resolve_value/1: Recursive resolution (strings, maps, lists)
- OutputScrubber.scrub_result/2: Remove secrets from action results
- OutputScrubber.scrub_value/2: Recursive scrubbing (structs, maps, lists, strings)

## Patterns
- Template syntax: {{SECRET:secret_name}}
- Map return type: {:ok, resolved_params, secrets_used} | {:error, :secret_not_found, name}
- Recursive processing for nested structures
- Case-insensitive secret matching
- Struct-aware scrubbing (preserves struct types)

## Dependencies
- Quoracle.Models.TableSecrets for DB lookups
- Integrated into ACTION_Router.Security module

Test coverage: 24 secret_resolver tests (property-based), 21 output_scrubber tests
