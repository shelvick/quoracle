defmodule QuoracleWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.
  """
  use QuoracleWeb, :html

  embed_templates("error_html/*")

  @doc """
  The default is to render a plain text page based on
  the template name. For example, "404.html" becomes
  "Not Found".
  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
