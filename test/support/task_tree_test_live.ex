defmodule QuoracleWeb.UI.TaskTreeTestLive do
  @moduledoc """
  Test harness LiveView for testing TaskTree LiveComponent.
  """
  use Phoenix.LiveView

  alias QuoracleWeb.UI.TaskTree

  @doc """
  Renders the TaskTree component with provided assigns.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <div :if={@flash["error"]} class="flash-error"><%= @flash["error"] %></div>
      <.live_component
        module={TaskTree}
        id="task-tree"
        tasks={@tasks}
        agents={@agents}
        selected_agent_id={@selected_agent_id}
        groves={@groves}
        groves_path={@groves_path}
        profiles={@profiles}
      />
    </div>
    """
  end

  @doc """
  Mounts the test LiveView with tasks, agents, and test_pid from session.
  Supports groves_path session key for grove integration tests.
  """
  @spec mount(any(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    # Grant sandbox access for components that make DB queries (e.g., CostDisplay)
    if sandbox_owner = session["sandbox_owner"] do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    # Load groves from session -- either a pre-built list or from groves_path
    groves_path = session["groves_path"]
    groves = session["groves"] || load_groves(groves_path)

    # Load profiles from DB (needed for profile selector in NewTaskModal)
    profiles = load_profiles()

    {:ok,
     assign(socket,
       tasks: session["tasks"] || %{},
       agents: session["agents"] || %{},
       selected_agent_id: nil,
       test_pid: session["test_pid"],
       groves: groves,
       groves_path: groves_path,
       profiles: profiles
     )}
  end

  @doc """
  Forwards submit_prompt messages to the test process.
  """
  @spec handle_info(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:submit_prompt, params}, socket) do
    if socket.assigns[:test_pid] do
      send(socket.assigns.test_pid, {:submit_prompt, params})
    end

    {:noreply, socket}
  end

  def handle_info({:task_creation_result, {:error, {:skill_not_found, name}}}, socket) do
    {:noreply, put_flash(socket, :error, "Skill '#{name}' not found")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Loads grove metadata from groves_path if provided
  defp load_groves(nil), do: []

  defp load_groves(groves_path) do
    {:ok, groves} = Quoracle.Groves.Loader.list_groves(groves_path: groves_path)
    groves
  end

  # Loads profiles from database ordered by name
  defp load_profiles do
    import Ecto.Query

    alias Quoracle.Profiles.TableProfiles

    Quoracle.Repo.all(from(p in TableProfiles, order_by: p.name))
    |> Enum.map(fn p ->
      groups = TableProfiles.capability_groups_as_atoms(p)

      %{
        name: p.name,
        capability_groups: groups
      }
    end)
  rescue
    _ -> []
  end
end
