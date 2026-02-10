defmodule Quoracle.Consensus.PromptBuilder.Context do
  @moduledoc """
  Context structs for system prompt building.

  Groups related parameters to reduce the parameter count of `build_integrated_prompt`
  to a cleaner 3-parameter signature. Each struct represents a logical
  grouping of data that flows through the prompt building pipeline.

  ## Usage

      action_ctx = %Context.Action{
        schemas: "...",
        allowed_actions: [:orient, :wait, ...],
        ...
      }

      profile_ctx = %Context.Profile{name: "research", ...}

      Sections.build_integrated_prompt(field_prompts, action_ctx, profile_ctx)
  """

  defmodule Action do
    @moduledoc """
    Action-related context for prompt building.

    Contains all information about available actions, their documentation,
    and the secrets formatting callback.
    """

    @type t :: %__MODULE__{
            schemas: String.t(),
            untrusted_docs: String.t(),
            trusted_docs: String.t(),
            allowed_actions: [atom()],
            format_secrets_fn: (-> String.t())
          }

    @enforce_keys [:schemas, :untrusted_docs, :trusted_docs, :allowed_actions, :format_secrets_fn]
    defstruct [:schemas, :untrusted_docs, :trusted_docs, :allowed_actions, :format_secrets_fn]
  end

  defmodule Profile do
    @moduledoc """
    Profile-related context for prompt building.

    Contains profile information for the agent's operating profile section
    and the list of available profiles for spawn_child decisions.
    """

    @type t :: %__MODULE__{
            name: String.t() | nil,
            description: String.t() | nil,
            permission_check: [atom()] | atom(),
            blocked_actions: [atom()],
            available_profiles: [map()]
          }

    defstruct name: nil,
              description: nil,
              permission_check: [],
              blocked_actions: [],
              available_profiles: []

    @doc """
    Returns true if this context has profile information to display.
    """
    @spec has_profile?(t()) :: boolean()
    def has_profile?(%__MODULE__{name: nil}), do: false
    def has_profile?(%__MODULE__{name: _}), do: true
  end
end
