defmodule Quoracle.Consensus.PromptBuilder do
  @moduledoc """
  Generates comprehensive system prompts for LLMs in the consensus mechanism.
  Documents all available actions with JSON schema format and response instructions.
  """

  require Logger
  alias Quoracle.Actions.Schema
  alias Quoracle.Consensus.PromptBuilder.{Context, SchemaFormatter, Sections}
  alias Quoracle.Profiles.{ActionGate, CapabilityGroups, Resolver}

  # Delegate JSON schema generation to SchemaFormatter module
  defdelegate action_to_json_schema(action), to: SchemaFormatter
  defdelegate format_param_type(type), to: SchemaFormatter
  defdelegate format_wait_type(), to: SchemaFormatter

  @doc """
  Returns documentation for secret search and usage.

  v9.0: No longer lists secret names (use search_secrets action instead).
  v10.0: Added guidance on secret naming, reuse vs creation.
  Informs LLMs about search_secrets action and {{SECRET:name}} syntax.
  """
  @spec format_available_secrets() :: String.t()
  def format_available_secrets do
    """
    ## Secrets

    Secrets are stored securely and can be used in action parameters.

    **CRITICAL: Search Before Use OR Creation**
    ALWAYS search for existing secrets before:
    - Using a secret (to get the exact name)
    - Creating a new secret (to avoid duplicates)

    Never guess or hallucinate secret names. If you need a secret:
    1. Search with relevant terms: `{"action": "search_secrets", "params": {"search_terms": ["myproject", "stripe", "prod"]}}`
    2. If found, use the EXACT name returned (e.g., `{{SECRET:myproject_stripe_prod_api_key}}`)
    3. If not found, create with a specific, descriptive name (see naming rules below)

    **Finding Secrets:**
    To discover available secrets, use the search_secrets action:
    ```json
    {"action": "search_secrets", "params": {"search_terms": ["aws", "api", "key"]}}
    ```
    This returns secret names matching any search term (case-insensitive).

    **Secret Naming Rules (when creating new secrets):**
    Names must be specific enough that other agents can determine:
    - What project/site/application the secret is for
    - What external service it authenticates to
    - What environment (prod, staging, dev) if applicable
    - What scope/permissions it grants (if relevant)

    Good names (include project + service + environment):
    - `acme_website_stripe_prod_api_key`
    - `databot_github_ci_deploy_token`
    - `analytics_dash_aws_s3_readonly_key`
    - `myapp_sendgrid_prod_api_key`

    Bad names (too vague, will cause confusion across projects):
    - `stripe_api_key` (which project?)
    - `prod_database_password` (which database? which service?)
    - `api_key`, `token`, `password` (completely ambiguous)

    **Reuse vs. Create Decision:**
    - REUSE existing secret if: search finds a secret for the SAME project + service + environment
    - CREATE new secret if: search finds nothing matching, OR existing secret is for different project/environment
    - When in doubt, search with multiple term combinations before creating

    **Using Secrets:**
    Reference secrets in action parameters with: {{SECRET:name}}
    The secret value is resolved automatically before action execution.
    You will only see success/failure results - secret values are NEVER visible to you.
    """
  end

  @doc """
  Builds a system prompt with field prompts and profile context.

  Integrates field-based prompts if provided in opts[:field_prompts].

  ## Parameters
    * `opts` - Options including :field_prompts, :profile_name, :sandbox_owner

  ## Examples
      iex> build_system_prompt_with_context(field_prompts: %{system_prompt: "..."})
      # Returns prompt with field prompts integrated
  """
  @spec build_system_prompt_with_context(keyword()) :: String.t()
  def build_system_prompt_with_context(opts \\ []) do
    field_prompts = Keyword.get(opts, :field_prompts)

    # Get allowed actions filtered by capability_groups
    all_actions = Schema.list_actions()
    permission_check = get_permission_check(opts)
    allowed_actions = ActionGate.filter_actions(all_actions, permission_check)

    # v19.0: Extract profile opts and build profile_context for system prompt
    profile_name = Keyword.get(opts, :profile_name)

    profile_context =
      if profile_name do
        # Get capability_groups from opts, default to [] if nil or missing
        capability_groups = Keyword.get(opts, :capability_groups) || []

        %{
          name: profile_name,
          description: Keyword.get(opts, :profile_description),
          permission_check: capability_groups,
          blocked_actions: get_blocked_actions(capability_groups)
        }
      else
        nil
      end

    # NOTE: Budget is now injected into user messages via BudgetInjector (KV cache preservation)
    build_system_prompt_internal(
      field_prompts,
      allowed_actions,
      profile_context,
      opts
    )
  end

  @doc """
  Builds a comprehensive system prompt documenting all available actions.

  Optionally integrates field-based prompts (role, cognitive_style, constraints, etc.)
  at optimal positions following prompt engineering best practices:
  1. Identity (role, cognitive_style)
  2. Profile section (if profile_name provided)
  3. Context (global_context, constraints)
  4. Capabilities (available actions)
  5. Format (response schema, examples)

  ## Parameters
    * `opts` - Keyword list options:
      - `:field_prompts` - Map with :system_prompt key for field-based configuration
      - `:capability_groups` - List of capability group atoms (e.g., [:hierarchy, :local_execution])
      - `:profile_name` - Profile name string for profile section
      - `:profile_description` - Profile description string
      - `:forbidden_actions` - List of action atoms to exclude

  ## Examples
      iex> build_system_prompt()  # All actions
      iex> build_system_prompt(capability_groups: [])  # Base actions only
      iex> build_system_prompt(profile_name: "research", capability_groups: [:file_read])
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ [])

  def build_system_prompt(opts) when is_list(opts) do
    permission_check = get_permission_check(opts)
    forbidden_actions = Keyword.get(opts, :forbidden_actions, [])
    profile_name = Keyword.get(opts, :profile_name)
    profile_description = Keyword.get(opts, :profile_description)

    # Get all actions, filter by permission
    all_actions = Schema.list_actions()
    permission_filtered = ActionGate.filter_actions(all_actions, permission_check)

    # Apply forbidden_actions filter last
    allowed_actions = permission_filtered -- forbidden_actions

    # Build profile context for Sections
    profile_context =
      if profile_name do
        %{
          name: profile_name,
          description: profile_description,
          permission_check: permission_check,
          blocked_actions: get_blocked_actions(permission_check)
        }
      else
        nil
      end

    build_system_prompt_internal(nil, allowed_actions, profile_context, opts)
  end

  # Legacy support: map arg is treated as field_prompts
  def build_system_prompt(field_prompts) when is_map(field_prompts) do
    build_system_prompt_internal(field_prompts, [], nil, [])
  end

  def build_system_prompt(nil) do
    build_system_prompt_internal(nil, [], nil, [])
  end

  defp get_permission_check(opts) do
    Keyword.get(opts, :capability_groups, [])
  end

  defp get_blocked_actions(capability_groups) when is_list(capability_groups) do
    all_actions = Schema.list_actions()
    {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups(capability_groups)
    all_actions -- allowed
  end

  @doc """
  Builds example action invocations showing proper wait parameter usage.
  Returns a string with JSON examples for various actions.
  Optionally filters examples by allowed_actions list.
  """
  @spec build_action_examples([atom()] | nil) :: String.t()
  defdelegate build_action_examples(allowed_actions \\ nil), to: Sections

  @doc """
  Logs the system prompt if debug mode is enabled.
  Checks the debug option in opts, falling back to application config.
  """
  @spec debug_log_prompt(String.t(), keyword()) :: :ok
  def debug_log_prompt(prompt, opts \\ []) do
    debug_enabled =
      Keyword.get(opts, :debug, Application.get_env(:quoracle, :consensus_debug, false))

    if debug_enabled do
      Logger.debug("System prompt: #{prompt}")
    end

    :ok
  end

  # Internal implementation for system prompt building
  defp build_system_prompt_internal(
         field_prompts,
         allowed_actions_override,
         profile_context,
         opts
       ) do
    # Get allowed actions (use override if provided, otherwise all actions)
    allowed_actions =
      if allowed_actions_override != [], do: allowed_actions_override, else: Schema.list_actions()

    # Load profile names for spawn_child enum injection
    profile_names = load_profile_names(opts)
    schema_opts = [profile_names: profile_names]

    action_schemas =
      Enum.map_join(
        allowed_actions,
        "\n\n",
        &SchemaFormatter.document_action_with_schema(&1, schema_opts)
      )

    # Prepare untrusted/trusted action documentation
    {untrusted_docs, trusted_docs} = Sections.prepare_action_docs(allowed_actions)

    # Load available profiles for spawn_child decision making
    available_profiles = load_available_profiles(opts)

    # Build context structs (v2.0 - reduces params to 3)
    action_ctx = %Context.Action{
      schemas: action_schemas,
      untrusted_docs: untrusted_docs,
      trusted_docs: trusted_docs,
      allowed_actions: allowed_actions,
      format_secrets_fn: &format_available_secrets/0
    }

    profile_ctx =
      if profile_context do
        %Context.Profile{
          name: profile_context.name,
          description: profile_context.description,
          permission_check: profile_context.permission_check,
          blocked_actions: profile_context.blocked_actions,
          available_profiles: available_profiles
        }
      else
        %Context.Profile{available_profiles: available_profiles}
      end

    # Build integrated prompt using Sections module with context structs
    # Pass opts through for skill injection (v15.0)
    Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx, opts)
  end

  # Load profile names for spawn_child enum injection
  # Handles sandbox access for tests
  @spec load_profile_names(keyword()) :: [String.t()]
  defp load_profile_names(opts) do
    # Handle sandbox for tests
    if sandbox_owner = Keyword.get(opts, :sandbox_owner) do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    try do
      Resolver.list_names()
    rescue
      _ -> []
    end
  end

  # Load available profiles with descriptions and capabilities for spawn_child decisions
  # Handles sandbox access for tests
  @spec load_available_profiles(keyword()) :: [Resolver.profile_summary()]
  defp load_available_profiles(opts) do
    # Handle sandbox for tests
    if sandbox_owner = Keyword.get(opts, :sandbox_owner) do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    try do
      Resolver.list_all()
    rescue
      _ -> []
    end
  end
end
