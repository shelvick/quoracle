defmodule Quoracle.Encrypted.Binary do
  @moduledoc """
  Encrypted binary field type using Cloak.Ecto for transparent encryption/decryption.
  """

  use Cloak.Ecto.Binary, vault: Quoracle.Vault
end
