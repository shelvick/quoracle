defmodule Quoracle.Vault do
  @moduledoc """
  Cloak vault for encrypting database fields with AES-256-GCM.

  The vault is optional in dev — if `CLOAK_ENCRYPTION_KEY` is not set,
  the vault won't start and encryption operations will fail at point-of-use.
  """

  use Cloak.Vault, otp_app: :quoracle

  @doc """
  Returns true if cipher configuration is present (i.e. the vault can start).
  """
  @spec configured?() :: boolean()
  def configured? do
    Application.get_env(:quoracle, __MODULE__, [])
    |> Keyword.has_key?(:ciphers)
  end
end
