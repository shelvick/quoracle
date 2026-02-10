defmodule QuoracleWeb.Router do
  @moduledoc """
  The main router for the Quoracle web application.
  Defines all routes and pipelines for handling HTTP requests.
  """
  use QuoracleWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {QuoracleWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # Health check — no pipeline, minimal overhead
  get("/healthz", QuoracleWeb.HealthController, :index)

  scope "/", QuoracleWeb do
    pipe_through(:browser)

    live("/", DashboardLive)
    live("/logs", LogViewLive)
    live("/mailbox", MailboxLive)
    live("/settings", SecretManagementLive)
    get("/static", PageController, :home)
  end

  # Test-only routes for component isolation
  if Mix.env() == :test do
    scope "/test", QuoracleWeb do
      pipe_through(:browser)
      live("/component", LiveComponentTestHelper)
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:quoracle, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: QuoracleWeb.Telemetry)
    end
  end
end
