defmodule QuoracleWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.
  """
  use QuoracleWeb, :html

  embed_templates("page_html/*")
end
