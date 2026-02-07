defmodule Quoracle.Models.CredentialBehaviour do
  @moduledoc """
  Behaviour for credential management.

  Defines the interface for fetching provider credentials.
  """

  @callback get_credentials(provider :: atom()) ::
              {:ok, map()} | {:error, atom()}
end
