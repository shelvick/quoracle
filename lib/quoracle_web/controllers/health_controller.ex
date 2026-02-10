defmodule QuoracleWeb.HealthController do
  @moduledoc "Health check endpoint for container orchestration."
  use QuoracleWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
