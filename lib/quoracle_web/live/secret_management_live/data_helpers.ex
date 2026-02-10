defmodule QuoracleWeb.SecretManagementLive.DataHelpers do
  @moduledoc """
  Helper functions for loading, filtering, and paginating secrets and credentials.
  Extracted from SecretManagementLive to keep it under 500 lines.
  """

  alias Quoracle.Models.{TableSecrets, TableCredentials}
  alias QuoracleWeb.SecretManagementLive.ModelConfigHelpers

  @doc """
  Loads all secrets and credentials, applies filtering, search, sorting, and pagination.
  Returns updated socket with items and total_items assigns.
  """
  @spec load_items(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_items(socket) do
    # Load secrets (returns list directly)
    secrets = TableSecrets.list_all()

    secret_items =
      secrets
      |> Enum.map(fn secret ->
        %{
          id: secret.id,
          name: secret.name,
          type: :secret,
          description: secret.description,
          model_id: nil,
          model_spec: nil,
          inserted_at: secret.inserted_at,
          updated_at: secret.updated_at
        }
      end)

    # Load credentials
    credentials = TableCredentials.list_all()

    credential_items =
      credentials
      |> Enum.map(fn cred ->
        %{
          id: cred.id,
          name: cred.model_id,
          type: :credential,
          description: nil,
          model_id: cred.model_id,
          model_spec: cred.model_spec,
          inserted_at: cred.inserted_at,
          updated_at: cred.updated_at
        }
      end)

    # Combine and filter
    all_items = secret_items ++ credential_items

    filtered_items =
      case socket.assigns.filter do
        :all -> all_items
        :secrets -> Enum.filter(all_items, &(&1.type == :secret))
        :credentials -> Enum.filter(all_items, &(&1.type == :credential))
      end

    # Apply search
    searched_items =
      if socket.assigns.search_term != "" do
        term = String.downcase(socket.assigns.search_term)

        Enum.filter(filtered_items, fn item ->
          name_match = String.contains?(String.downcase(item.name), term)

          desc_match =
            if item.description do
              String.contains?(String.downcase(item.description), term)
            else
              false
            end

          name_match || desc_match
        end)
      else
        filtered_items
      end

    # Sort by (id ASC) for deterministic ordering
    # Using ID provides stable, predictable sort order for tests and UI
    sorted_items = Enum.sort_by(searched_items, & &1.id, :asc)

    # Apply pagination
    total_items = length(sorted_items)

    paginated_items =
      sorted_items
      |> Enum.drop((socket.assigns.page - 1) * socket.assigns.page_size)
      |> Enum.take(socket.assigns.page_size)

    socket
    |> Phoenix.Component.assign(:items, paginated_items)
    |> Phoenix.Component.assign(:total_items, total_items)
  end

  @doc """
  Prepare socket assigns for the edit modal based on item type.
  Finds the item by ID, loads the appropriate record from DB, and assigns modal state.
  """
  @spec prepare_edit_modal(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def prepare_edit_modal(socket, id) do
    item =
      Enum.find(socket.assigns.items, fn i ->
        to_string(i.id) == to_string(id)
      end)

    case item do
      nil ->
        socket

      item ->
        {modal_type, changeset, provider, selected_item} =
          case item.type do
            :secret ->
              case TableSecrets.get_by_name(item.name) do
                {:ok, _secret} -> {:edit_secret, nil, nil, item}
                {:error, _} -> {:edit_secret, nil, nil, item}
              end

            :credential ->
              case TableCredentials.get_by_id(id) do
                {:ok, cred} ->
                  provider = ModelConfigHelpers.extract_provider(cred.model_spec)
                  cred_item = build_credential_item(cred)
                  {:edit_credential, TableCredentials.changeset(cred, %{}), provider, cred_item}

                {:error, _} ->
                  {:edit_credential, nil, nil, item}
              end
          end

        socket
        |> Phoenix.Component.assign(:show_modal, modal_type)
        |> Phoenix.Component.assign(:modal_changeset, changeset)
        |> Phoenix.Component.assign(:selected_item, selected_item)
        |> Phoenix.Component.assign(:selected_provider, provider)
    end
  end

  @doc """
  Build credential item map for edit modal from credential struct.
  """
  @spec build_credential_item(struct()) :: map()
  def build_credential_item(cred) do
    %{
      id: cred.id,
      name: cred.model_id,
      type: :credential,
      model_id: cred.model_id,
      model_spec: cred.model_spec,
      endpoint_url: cred.endpoint_url,
      deployment_id: cred.deployment_id,
      resource_id: cred.resource_id,
      region: cred.region
    }
  end
end
