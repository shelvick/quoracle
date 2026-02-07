defmodule QuoracleWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the application.

  This module acts as a facade that re-exports components from specialized modules
  for backward compatibility. Components are organized into:

  - FormComponents: Forms, inputs, buttons, labels, and errors
  - LayoutComponents: Flash messages, headers, tables, lists, and navigation
  - UtilityComponents: Icons, JavaScript animations, and error translation
  """

  # Re-export form components
  defdelegate simple_form(assigns), to: QuoracleWeb.FormComponents
  defdelegate button(assigns), to: QuoracleWeb.FormComponents
  defdelegate input(assigns), to: QuoracleWeb.FormComponents
  defdelegate label(assigns), to: QuoracleWeb.FormComponents
  defdelegate error(assigns), to: QuoracleWeb.FormComponents

  # Re-export layout components
  defdelegate flash(assigns), to: QuoracleWeb.LayoutComponents
  defdelegate flash_group(assigns), to: QuoracleWeb.LayoutComponents
  defdelegate header(assigns), to: QuoracleWeb.LayoutComponents
  defdelegate table(assigns), to: QuoracleWeb.LayoutComponents
  defdelegate list(assigns), to: QuoracleWeb.LayoutComponents
  defdelegate back(assigns), to: QuoracleWeb.LayoutComponents

  # Re-export utility components and functions
  defdelegate icon(assigns), to: QuoracleWeb.UtilityComponents
  defdelegate show(js \\ %Phoenix.LiveView.JS{}, selector), to: QuoracleWeb.UtilityComponents
  defdelegate hide(js \\ %Phoenix.LiveView.JS{}, selector), to: QuoracleWeb.UtilityComponents
  defdelegate translate_error(error_tuple), to: QuoracleWeb.UtilityComponents
end
