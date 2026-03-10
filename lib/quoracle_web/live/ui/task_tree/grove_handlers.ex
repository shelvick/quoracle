defmodule QuoracleWeb.UI.TaskTree.GroveHandlers do
  @moduledoc """
  Extracted grove selection event handlers for TaskTree LiveComponent.
  Handles grove_selected events, BootstrapResolver resolution, and
  grove_skills_path injection into task creation params.
  """

  import Phoenix.LiveView, only: [push_event: 3]
  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Quoracle.Groves.{BootstrapResolver, Loader}

  @doc """
  Handles grove_selected event when no grove is chosen (empty value).
  Resets selected_grove and grove_skills_path to nil.
  """
  @spec handle_grove_cleared(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_grove_cleared(socket) do
    send(socket.root_pid, {:grove_skills_path_updated, nil})
    send(socket.root_pid, {:selected_grove_updated, nil})
    send(socket.root_pid, {:loaded_grove_updated, nil})

    {:noreply,
     socket
     |> assign(:selected_grove, nil)
     |> assign(:grove_skills_path, nil)
     |> push_event("grove_prefill", %{clear: true})}
  end

  @doc """
  Handles grove_selected event with a grove name.
  Loads grove once, resolves bootstrap fields via BootstrapResolver, pushes
  prefill event, and tracks grove_skills_path for task creation.
  On error, sends :grove_error to root_pid for flash display.
  """
  @spec handle_grove_selected(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_grove_selected(grove_name, socket) do
    groves_path = socket.assigns[:groves_path]
    opts = if groves_path, do: [groves_path: groves_path], else: []

    # Load grove once and extract both bootstrap fields and skills_path
    case Loader.load_grove(grove_name, opts) do
      {:ok, grove} ->
        case BootstrapResolver.resolve_from_grove(grove) do
          {:ok, fields} ->
            grove_skills_path = grove.skills_path
            send(socket.root_pid, {:grove_skills_path_updated, grove_skills_path})
            send(socket.root_pid, {:selected_grove_updated, grove_name})
            send(socket.root_pid, {:loaded_grove_updated, grove})

            # Convert nil values to "" so JS hook clears stale fields from previous grove
            sanitized_fields = Map.new(fields, fn {k, v} -> {k, v || ""} end)

            socket =
              socket
              |> assign(:selected_grove, grove_name)
              |> assign(:grove_skills_path, grove_skills_path)
              |> push_event("grove_prefill", sanitized_fields)

            {:noreply, socket}

          {:error, reason} ->
            Logger.warning("Failed to resolve grove #{grove_name}: #{inspect(reason)}")
            send(socket.root_pid, {:grove_error, "Failed to load grove: #{grove_name}"})
            send(socket.root_pid, {:grove_skills_path_updated, nil})
            send(socket.root_pid, {:selected_grove_updated, nil})
            send(socket.root_pid, {:loaded_grove_updated, nil})

            {:noreply, assign(socket, :selected_grove, nil) |> assign(:grove_skills_path, nil)}
        end

      {:error, reason} ->
        Logger.warning("Failed to load grove #{grove_name}: #{inspect(reason)}")
        send(socket.root_pid, {:grove_error, "Failed to load grove: #{grove_name}"})
        send(socket.root_pid, {:grove_skills_path_updated, nil})
        send(socket.root_pid, {:selected_grove_updated, nil})
        send(socket.root_pid, {:loaded_grove_updated, nil})

        {:noreply, assign(socket, :selected_grove, nil) |> assign(:grove_skills_path, nil)}
    end
  end

  @doc """
  Augments task creation params with grove_skills_path if a grove was selected,
  sends :submit_prompt to root_pid, and resets grove state.
  """
  @spec handle_create_task(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_task(params, socket) do
    params =
      if socket.assigns[:grove_skills_path] do
        Map.put(params, "grove_skills_path", socket.assigns.grove_skills_path)
      else
        params
      end

    send(socket.root_pid, {:submit_prompt, params})
    send(socket.root_pid, {:grove_skills_path_updated, nil})

    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:selected_grove, nil)
     |> assign(:grove_skills_path, nil)}
  end
end
