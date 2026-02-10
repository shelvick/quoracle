# lib/quoracle_web/live/secret_management_live/

## Architecture (5-module, ~950 lines total)
- **Main**: SecretManagementLive (500 lines) - LiveView coordinator, event handlers
- **DataHelpers** (116 lines): DB operations, list loading, credential item building
- **ValidationHelpers** (139 lines): Credential validation, changeset building, param normalization
- **ModelConfigHelpers** (228 lines): Model config tab logic, provider extraction, save_model_config
- **ProfileHelpers** (119 lines): Profile CRUD operations, changeset building

## Key Functions (DataHelpers)
- load_items/1: Load and merge secrets + credentials
- merge_items/2: Combine secret and credential lists
- build_credential_item/1: Build credential map for edit modal

## Key Functions (ValidationHelpers)
- build_credential_changeset/2: Build validated credential changeset
- extract_model_spec/1: Extract model_spec from params (fallback to model_id)
- normalize_credential_params/1: Normalize params with model_spec
- build_credential_params/1: Build credential params map for insert/update

## Key Functions (ModelConfigHelpers)
- extract_provider/1: Extract provider from model_spec
- save_model_config/1: Save all model config settings (consensus, embedding, etc.)
- load_credentialed_models/0, load_chat_capable_models/0, load_image_capable_models/0

## Key Functions (ProfileHelpers)
- new_profile_changeset/0, edit_profile_changeset/1, validate_changeset/2
- get_profile/1, list_profiles/0, save_profile/2, delete_profile/1
- reset_profile_assigns/1, apply_error_action/2

## State
```elixir
active_tab: :secrets | :credentials | :model_config | :profiles | :system
profiles: [TableProfiles.t()], profile_changeset: Ecto.Changeset.t()
selected_profile: TableProfiles.t() | nil
skills_path: String.t() | nil
```

## Patterns
- Five-tab interface (Secrets | Credentials | Model Config | Profiles | System)
- System tab: skills_path configuration (v5.0), empty clears DB setting
- Helper module extraction for 500-line limit compliance
- Direct delete (no confirmation modal) for profiles
- DataHelpers: prepare_edit_modal/2 extracted for profile edit modal prep

## Template
- secret_management_live.html.heex (~420 lines, includes profile modal)

## Test Coverage
- 19 secret management tests (R1-R19)
- 11 profile management tests (R1-R10)
