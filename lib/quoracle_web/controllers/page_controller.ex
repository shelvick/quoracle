defmodule QuoracleWeb.PageController do
  @moduledoc """
  Controller for static pages.
  """
  use QuoracleWeb, :controller

  @doc """
  Renders the home page.
  """
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
