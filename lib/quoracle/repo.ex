defmodule Quoracle.Repo do
  @moduledoc """
  The database repository for Quoracle.

  This module is the main interface to the database.
  """

  use Ecto.Repo,
    otp_app: :quoracle,
    adapter: Ecto.Adapters.Postgres
end
