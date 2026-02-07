defmodule QuoracleWeb.SecretManagementLive do
  @moduledoc """
  Unified LiveView interface for managing secrets, model credentials, and model settings.
  Three-tab layout: Secrets | Credentials | Model Config
  """

  use QuoracleWeb, :live_view

  alias Quoracle.Models.TableSecrets
  alias Quoracle.Models.TableCredentials
  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.LLMDBModelLoader
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  alias QuoracleWeb.SecretManagementLive.{
    DataHelpers,
    ValidationHelpers,
    ModelConfigHelpers,
    ProfileHelpers
  }

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    pubsub = session["pubsub"] || Quoracle.PubSub
    sandbox_owner = session["sandbox_owner"]
    if sandbox_owner, do: Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())

    topic = session["topic"] || "secrets:all"
    Phoenix.PubSub.subscribe(pubsub, topic)

    llmdb_available = session["llmdb_available"] != false and LLMDBModelLoader.available?()
    model_settings = ConfigModelSettings.get_all()
    credentialed_models = ModelConfigHelpers.load_credentialed_models()
    image_capable_models = ModelConfigHelpers.load_image_capable_models()

    image_credentialed_models =
      ModelConfigHelpers.filter_image_models(credentialed_models, image_capable_models)

    available_models = if(llmdb_available, do: LLMDBModelLoader.all_models(), else: [])

    socket =
      socket
      |> assign(
        pubsub: pubsub,
        topic: topic,
        items: [],
        show_modal: :none,
        modal_changeset: nil,
        selected_item: nil,
        error_message: nil,
        filter: :all,
        search_term: "",
        page: 1,
        page_size: 20,
        total_items: 0,
        active_tab: :credentials,
        llmdb_available: llmdb_available,
        available_models: available_models,
        selected_provider: nil,
        embedding_model: model_settings.embedding_model,
        answer_engine_model: model_settings.answer_engine_model,
        summarization_model: model_settings.summarization_model,
        credentialed_models: credentialed_models,
        chat_capable_models: ModelConfigHelpers.load_chat_capable_models(),
        image_generation_models: model_settings.image_generation_models || [],
        image_credentialed_models: image_credentialed_models,
        delete_warning: nil,
        profiles: Repo.all(TableProfiles),
        profile_changeset: TableProfiles.changeset(%TableProfiles{}, %{}),
        selected_profile: nil
      )
      |> DataHelpers.load_items()

    {:ok, socket}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom =
      case tab do
        "secrets" -> :secrets
        "credentials" -> :credentials
        "model_config" -> :model_config
        "profiles" -> :profiles
        _ -> :secrets
      end

    {:noreply, assign(socket, :active_tab, tab_atom)}
  end

  def handle_event("new_secret", _params, socket) do
    changeset =
      %TableSecrets{}
      |> TableSecrets.changeset(%{})
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket, show_modal: :new_secret, modal_changeset: changeset, selected_item: nil)}
  end

  def handle_event("new_credential", _params, socket) do
    changeset = TableCredentials.changeset(%TableCredentials{}, %{})

    socket =
      socket
      |> assign(:show_modal, :new_credential)
      |> assign(:modal_changeset, changeset)
      |> assign(:selected_item, nil)
      |> assign(:selected_provider, nil)

    {:noreply, socket}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    item =
      Enum.find(socket.assigns.items, fn i ->
        to_string(i.id) == to_string(id)
      end)

    case item do
      nil ->
        {:noreply, socket}

      item ->
        {modal_type, changeset, provider, selected_item} =
          case item.type do
            :secret ->
              case TableSecrets.get_by_name(item.name) do
                {:ok, _secret} ->
                  {:edit_secret, nil, nil, item}

                {:error, _} ->
                  {:edit_secret, nil, nil, item}
              end

            :credential ->
              case TableCredentials.get_by_id(id) do
                {:ok, cred} ->
                  provider = ModelConfigHelpers.extract_provider(cred.model_spec)
                  cred_item = DataHelpers.build_credential_item(cred)
                  {:edit_credential, TableCredentials.changeset(cred, %{}), provider, cred_item}

                {:error, _} ->
                  {:edit_credential, nil, nil, item}
              end
          end

        socket =
          socket
          |> assign(:show_modal, modal_type)
          |> assign(:modal_changeset, changeset)
          |> assign(:selected_item, selected_item)
          |> assign(:selected_provider, provider)

        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    item =
      Enum.find(socket.assigns.items, fn i ->
        to_string(i.id) == to_string(id)
      end)

    delete_warning =
      if item && item.type == :credential do
        ModelConfigHelpers.check_credential_in_active_config(item.model_id)
      else
        nil
      end

    socket =
      socket
      |> assign(:show_modal, :confirm_delete)
      |> assign(:selected_item, item)
      |> assign(:delete_warning, delete_warning)

    {:noreply, socket}
  end

  def handle_event("confirm_delete", _params, socket) do
    item = socket.assigns.selected_item

    result =
      case item.type do
        :secret ->
          TableSecrets.delete(item.name,
            pubsub: socket.assigns.pubsub,
            topic: socket.assigns.topic
          )

        :credential ->
          case TableCredentials.get_by_id(item.id) do
            {:ok, cred} ->
              TableCredentials.delete(cred)

            {:error, _} ->
              {:error, "Credential not found"}
          end
      end

    case result do
      {:ok, _} ->
        socket =
          socket
          |> assign(:show_modal, :none)
          |> assign(:selected_item, nil)
          |> assign(:error_message, nil)
          |> DataHelpers.load_items()

        {:noreply, socket}

      {:error, message} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  def handle_event("validate_secret", %{"secret" => params}, socket) do
    changeset =
      case socket.assigns.show_modal do
        :new_secret ->
          %TableSecrets{}
          |> TableSecrets.changeset(params)
          |> Map.put(:action, :validate)

        :edit_secret ->
          case TableSecrets.get_by_name(socket.assigns.selected_item.name) do
            {:ok, secret} ->
              secret
              |> TableSecrets.changeset(params)
              |> Map.put(:action, :validate)

            {:error, _} ->
              nil
          end
      end

    {:noreply, assign(socket, :modal_changeset, changeset)}
  end

  def handle_event("validate_credential", %{"credential" => params}, socket) do
    model_spec = ValidationHelpers.extract_model_spec(params)
    provider = ModelConfigHelpers.extract_provider(model_spec)
    params_with_spec = ValidationHelpers.normalize_credential_params(params)

    changeset =
      case socket.assigns.show_modal do
        :new_credential ->
          ValidationHelpers.build_credential_changeset(nil, params_with_spec)

        :edit_credential ->
          case TableCredentials.get_by_id(socket.assigns.selected_item.id) do
            {:ok, cred} -> ValidationHelpers.build_credential_changeset(cred, params_with_spec)
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(:modal_changeset, changeset)
      |> assign(:selected_provider, provider)

    {:noreply, socket}
  end

  def handle_event("save_secret", %{"secret" => params}, socket) do
    result =
      case socket.assigns.show_modal do
        :new_secret ->
          TableSecrets.create(params, pubsub: socket.assigns.pubsub, topic: socket.assigns.topic)

        :edit_secret ->
          TableSecrets.update(socket.assigns.selected_item.name, params,
            pubsub: socket.assigns.pubsub,
            topic: socket.assigns.topic
          )
      end

    case result do
      {:ok, _secret} ->
        socket =
          socket
          |> assign(:show_modal, :none)
          |> assign(:modal_changeset, nil)
          |> assign(:selected_item, nil)
          |> DataHelpers.load_items()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :modal_changeset, changeset)}
    end
  end

  def handle_event("save_credential", %{"credential" => params}, socket) do
    credential_params = ValidationHelpers.build_credential_params(params)

    result =
      case socket.assigns.show_modal do
        :new_credential ->
          TableCredentials.insert(credential_params)

        :edit_credential ->
          case TableCredentials.get_by_id(socket.assigns.selected_item.id) do
            {:ok, cred} ->
              TableCredentials.update_credential(cred, credential_params)

            {:error, _} ->
              {:error, "Credential not found"}
          end

        _ ->
          {:error, "Invalid modal state"}
      end

    case result do
      {:ok, _credential} ->
        socket =
          socket
          |> assign(:show_modal, :none)
          |> assign(:modal_changeset, nil)
          |> assign(:selected_item, nil)
          |> assign(:selected_provider, nil)
          |> assign(:credentialed_models, ModelConfigHelpers.load_credentialed_models())
          |> DataHelpers.load_items()

        {:noreply, socket}

      {:error, changeset} when is_struct(changeset) ->
        {:noreply, assign(socket, :modal_changeset, changeset)}

      {:error, _message} ->
        {:noreply, socket}
    end
  end

  def handle_event("filter", %{"type" => type}, socket) do
    filter =
      case type do
        "all" -> :all
        "secrets" -> :secrets
        "credentials" -> :credentials
        _ -> :all
      end

    socket =
      socket
      |> assign(:filter, filter)
      |> DataHelpers.load_items()

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"term" => term}}, socket) do
    socket =
      socket
      |> assign(:search_term, term)
      |> DataHelpers.load_items()

    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, :none)
      |> assign(:modal_changeset, nil)
      |> assign(:selected_item, nil)
      |> assign(:error_message, nil)

    {:noreply, socket}
  end

  def handle_event("next_page", _params, socket) do
    socket =
      socket
      |> assign(:page, socket.assigns.page + 1)
      |> DataHelpers.load_items()

    {:noreply, socket}
  end

  def handle_event("save_model_config", %{"model_config" => params}, socket) do
    case ModelConfigHelpers.save_model_config(params) do
      {:ok, config} ->
        socket =
          socket
          |> assign(:embedding_model, config.embedding_model)
          |> assign(:answer_engine_model, config.answer_engine_model)
          |> assign(:summarization_model, config.summarization_model)
          |> assign(:image_generation_models, config.image_generation_models)
          |> put_flash(:info, "Model configuration saved")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error saving config: #{inspect(reason)}")}
    end
  end

  def handle_event("new_profile", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, :new_profile)
      |> assign(:profile_changeset, ProfileHelpers.new_profile_changeset())
      |> assign(:selected_profile, nil)

    {:noreply, socket}
  end

  def handle_event("edit_profile", %{"id" => id}, socket) do
    case ProfileHelpers.get_profile(id) do
      nil ->
        {:noreply, socket}

      profile ->
        socket =
          socket
          |> assign(:show_modal, :edit_profile)
          |> assign(:profile_changeset, ProfileHelpers.edit_profile_changeset(profile))
          |> assign(:selected_profile, profile)

        {:noreply, socket}
    end
  end

  def handle_event("validate_profile", %{"profile" => params}, socket) do
    changeset = ProfileHelpers.validate_changeset(socket.assigns.selected_profile, params)
    {:noreply, assign(socket, :profile_changeset, changeset)}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case ProfileHelpers.save_profile(socket.assigns.selected_profile, params) do
      {:ok, _profile} ->
        {:noreply, ProfileHelpers.reset_profile_assigns(socket)}

      {:error, changeset} ->
        changeset = ProfileHelpers.apply_error_action(changeset, socket.assigns.selected_profile)
        {:noreply, assign(socket, :profile_changeset, changeset)}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    case ProfileHelpers.delete_profile(id) do
      {:ok, _} ->
        {:noreply, assign(socket, :profiles, ProfileHelpers.list_profiles())}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:secret_created, data}, socket) do
    # Skip if already in list (prevents duplicate from load_items + PubSub)
    if Enum.any?(socket.assigns.items, &(&1.id == data.id)) do
      {:noreply, socket}
    else
      now = DateTime.utc_now()

      item = %{
        id: data.id,
        name: data.name,
        type: :secret,
        description: data[:description],
        model_id: nil,
        model_spec: nil,
        inserted_at: now,
        updated_at: now
      }

      {:noreply, assign(socket, :items, [item | socket.assigns.items])}
    end
  end

  def handle_info({:secret_deleted, data}, socket) do
    items = Enum.reject(socket.assigns.items, &(to_string(&1.id) == to_string(data.id)))
    {:noreply, assign(socket, :items, items)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Display helper for capability_groups (Packet 5, feat-20260107-capability-groups)
  # Returns "all", "none (base only)", or comma-separated list per spec Section 4.3
  defp display_capability_groups(groups) when is_list(groups) do
    ProfileHelpers.format_groups_display(groups)
  end

  defp display_capability_groups(_), do: "none (base only)"
end
