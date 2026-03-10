defmodule QuoracleWeb.SecretManagementLive.SystemConfigHelpers do
  @moduledoc """
  Helpers for system configuration management in SecretManagementLive.
  Handles skills_path and groves_path persistence with error accumulation.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Quoracle.Models.ConfigModelSettings

  @doc """
  Saves system configuration with error accumulation.
  Takes a {socket, errors} tuple, applies the handler, and accumulates any errors.
  """
  @spec save_with_errors(
          {Phoenix.LiveView.Socket.t(), [term()]},
          (Phoenix.LiveView.Socket.t(), map() -> Phoenix.LiveView.Socket.t()),
          map()
        ) :: {Phoenix.LiveView.Socket.t(), [term()]}
  def save_with_errors({socket, errors}, handler, params) do
    try do
      {handler.(socket, params), errors}
    rescue
      e ->
        require Logger
        Logger.error("System config save error: #{inspect(e)}")
        {socket, [e | errors]}
    end
  end

  @doc """
  Handles skills_path update from system config form.
  Empty string deletes the config, non-empty sets it.
  """
  @spec handle_skills_path(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_skills_path(socket, params) do
    skills_path = Map.get(params, "skills_path", "")

    case String.trim(skills_path) do
      "" ->
        ConfigModelSettings.delete_skills_path()
        assign(socket, :skills_path, nil)

      path ->
        case ConfigModelSettings.set_skills_path(path) do
          {:ok, saved_path} ->
            assign(socket, :skills_path, saved_path)

          {:error, _reason} ->
            socket
        end
    end
  end

  @doc """
  Handles groves_path update from system config form.
  Empty string deletes the config, non-empty sets it.
  """
  @spec handle_groves_path(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_groves_path(socket, params) do
    groves_path = Map.get(params, "groves_path", "")

    case String.trim(groves_path) do
      "" ->
        ConfigModelSettings.delete_groves_path()
        assign(socket, :groves_path, nil)

      path ->
        case ConfigModelSettings.set_groves_path(path) do
          {:ok, saved_path} ->
            assign(socket, :groves_path, saved_path)

          {:error, _reason} ->
            socket
        end
    end
  end

  @doc """
  Formats capability groups for display.
  Returns "all", "none (base only)", or comma-separated list.
  """
  @spec display_capability_groups(list() | term()) :: String.t()
  def display_capability_groups(groups) when is_list(groups) do
    QuoracleWeb.SecretManagementLive.ProfileHelpers.format_groups_display(groups)
  end

  def display_capability_groups(_), do: "none (base only)"
end
