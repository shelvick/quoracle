defmodule Quoracle.Profiles.ProfileNotFoundError do
  @moduledoc """
  Exception raised when a profile lookup fails.
  """

  defexception [:name]

  @impl true
  def message(%{name: name}) do
    "Profile not found: #{name}"
  end
end
