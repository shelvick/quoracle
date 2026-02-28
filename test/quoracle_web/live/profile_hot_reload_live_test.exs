defmodule QuoracleWeb.ProfileHotReloadLiveTest do
  @moduledoc """
  Packet 3 tests for feat-20260227-profile-hot-reload.

  Covers SecretManagementLive profile-save broadcasts and end-to-end hot-reload
  behavior for already-running agents.
  """

  use QuoracleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Agent.Core
  alias Quoracle.Models.TableCredentials
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.PubSub.AgentEvents
  alias Quoracle.Repo
  alias Quoracle.Tasks.TaskManager

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()
    unique = System.unique_integer([:positive])

    old_models = Enum.map(1..3, &"profile_hot_reload_old_#{&1}_#{unique}")
    new_models = Enum.map(1..3, &"profile_hot_reload_new_#{&1}_#{unique}")

    for model_id <- old_models ++ new_models do
      {:ok, _credential} =
        TableCredentials.insert(%{
          model_id: model_id,
          model_spec: "test:#{model_id}",
          api_key: "test-key-#{model_id}"
        })
    end

    %{
      deps: deps,
      sandbox_owner: sandbox_owner,
      models: %{
        old: hd(old_models),
        new: hd(new_models),
        old_pool: old_models,
        new_pool: new_models
      }
    }
  end

  @tag :integration
  test "save_profile broadcasts profile_updated event", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    profile_name = "broadcast_profile_#{System.unique_integer([:positive])}"

    profile =
      create_profile!(%{
        name: profile_name,
        model_pool: [models.old],
        max_refinement_rounds: 4,
        description: "before"
      })

    assert :ok = AgentEvents.subscribe_to_profile(profile.name, deps.pubsub)

    {:ok, view, _html} = mount_settings_isolated(conn, sandbox_owner, deps.pubsub)
    view = switch_to_profiles_tab(view)

    view
    |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: profile.name,
        description: "broadcasted update",
        model_pool: [models.old],
        capability_groups: ["file_read"],
        max_refinement_rounds: 6
      }
    })
    |> render_submit()

    assert_receive {:profile_updated, payload}, 1_000
    assert payload.old_name == profile.name
    assert payload.new_name == profile.name
    assert payload.model_pool == [models.old]
    assert payload.max_refinement_rounds == 6
    assert payload.profile_description == "broadcasted update"
  end

  @tag :integration
  test "profile rename broadcasts on old name topic with new name", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    old_name = "rename_from_#{System.unique_integer([:positive])}"
    new_name = "rename_to_#{System.unique_integer([:positive])}"

    profile =
      create_profile!(%{
        name: old_name,
        model_pool: [models.old],
        max_refinement_rounds: 3,
        description: "rename before"
      })

    assert :ok = AgentEvents.subscribe_to_profile(old_name, deps.pubsub)

    {:ok, view, _html} = mount_settings_isolated(conn, sandbox_owner, deps.pubsub)
    view = switch_to_profiles_tab(view)

    view
    |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: new_name,
        description: "rename after",
        model_pool: [models.old],
        capability_groups: ["file_read"],
        max_refinement_rounds: 5
      }
    })
    |> render_submit()

    assert_receive {:profile_updated, payload}, 1_000
    assert payload.old_name == old_name
    assert payload.new_name == new_name
    assert payload.profile_description == "rename after"
  end

  @tag :acceptance
  @tag :system
  test "saving profile updates running agent behavior end-to-end", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    profile_name = "integration_hot_reload_#{System.unique_integer([:positive])}"

    profile =
      create_profile!(%{
        name: profile_name,
        model_pool: models.old_pool,
        max_refinement_rounds: 2,
        description: "integration before"
      })

    {_task, agent_pid, _state} = start_task_agent!(profile.name, sandbox_owner, deps, [])

    agent_id = Core.get_agent_id(agent_pid)

    assert :ok = AgentEvents.subscribe_to_agent(agent_id, deps.pubsub)

    {:ok, before_state} = Core.get_state(agent_pid)
    assert before_state.max_refinement_rounds == 2

    assert {:ok, before_summary} =
             send_user_message_and_await_consensus_summary(
               agent_pid,
               "integration-before #{System.unique_integer([:positive])}",
               5_000
             )

    assert before_summary.model_ids == Enum.sort(models.old_pool)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => deps.pubsub
      })
      |> live("/settings")

    view = switch_to_profiles_tab(view)

    view
    |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: profile.name,
        description: "integration after",
        model_pool: models.new_pool,
        capability_groups: ["file_read"],
        max_refinement_rounds: 8
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ profile.name
    assert html =~ "Rounds: 8"
    refute html =~ "has already been taken"

    {:ok, after_state} = Core.get_state(agent_pid)
    assert after_state.max_refinement_rounds == 8

    assert {:ok, after_summary} =
             send_user_message_and_await_consensus_summary(
               agent_pid,
               "integration-after #{System.unique_integer([:positive])}",
               5_000
             )

    assert after_summary.model_ids == Enum.sort(models.new_pool)
  end

  @tag :acceptance
  @tag :system
  test "editing profile in LiveView updates running agent behavior", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    profile_name = "acceptance_hot_reload_#{System.unique_integer([:positive])}"

    profile =
      create_profile!(%{
        name: profile_name,
        model_pool: models.old_pool,
        max_refinement_rounds: 3,
        description: "acceptance before"
      })

    {_task, agent_pid, _state} = start_task_agent!(profile.name, sandbox_owner, deps, [])

    agent_id = Core.get_agent_id(agent_pid)

    assert :ok = AgentEvents.subscribe_to_agent(agent_id, deps.pubsub)

    {:ok, acceptance_before_state} = Core.get_state(agent_pid)
    assert acceptance_before_state.max_refinement_rounds == 3

    assert {:ok, acceptance_before_summary} =
             send_user_message_and_await_consensus_summary(
               agent_pid,
               "acceptance-before #{System.unique_integer([:positive])}",
               5_000
             )

    assert acceptance_before_summary.model_ids == Enum.sort(models.old_pool)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => deps.pubsub
      })
      |> live("/settings")

    view = switch_to_profiles_tab(view)

    view
    |> element("[phx-click='edit_profile'][phx-value-id='#{profile.id}']")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: profile.name,
        description: "acceptance after",
        model_pool: models.new_pool,
        capability_groups: ["file_read"],
        max_refinement_rounds: 9
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ profile.name
    assert html =~ "Rounds: 9"
    refute html =~ "has already been taken"

    {:ok, acceptance_after_state} = Core.get_state(agent_pid)
    assert acceptance_after_state.max_refinement_rounds == 9

    assert {:ok, acceptance_after_summary} =
             send_user_message_and_await_consensus_summary(
               agent_pid,
               "acceptance-after #{System.unique_integer([:positive])}",
               5_000
             )

    assert acceptance_after_summary.model_ids == Enum.sort(models.new_pool)
  end

  @tag :integration
  test "new profile creation broadcasts profile_updated", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    new_profile_name = "new_profile_broadcast_#{System.unique_integer([:positive])}"

    assert :ok = AgentEvents.subscribe_to_profile(new_profile_name, deps.pubsub)

    {:ok, view, _html} = mount_settings_isolated(conn, sandbox_owner, deps.pubsub)
    view = switch_to_profiles_tab(view)

    view
    |> element("button", "New Profile")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: new_profile_name,
        description: "brand new",
        model_pool: [models.old],
        capability_groups: ["file_read"],
        max_refinement_rounds: 3
      }
    })
    |> render_submit()

    assert_receive {:profile_updated, payload}, 1_000
    assert payload.new_name == new_profile_name
    assert payload.model_pool == [models.old]
    assert payload.max_refinement_rounds == 3
  end

  @tag :integration
  test "failed profile save does not broadcast", %{
    conn: conn,
    sandbox_owner: sandbox_owner,
    deps: deps,
    models: models
  } do
    existing_name = "existing_unique_#{System.unique_integer([:positive])}"

    existing =
      create_profile!(%{
        name: existing_name,
        model_pool: [models.old],
        description: "existing"
      })

    assert :ok = AgentEvents.subscribe_to_profile(existing_name, deps.pubsub)

    {:ok, view, _html} = mount_settings_isolated(conn, sandbox_owner, deps.pubsub)
    view = switch_to_profiles_tab(view)

    view
    |> element("[phx-click='edit_profile'][phx-value-id='#{existing.id}']")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: existing_name,
        description: "existing-updated",
        model_pool: [models.old],
        capability_groups: ["file_read"],
        max_refinement_rounds: 7
      }
    })
    |> render_submit()

    assert_receive {:profile_updated, first_payload}, 1_000
    assert first_payload.new_name == existing_name
    assert first_payload.max_refinement_rounds == 7

    view
    |> element("button", "New Profile")
    |> render_click()

    view
    |> form("#profile-form", %{
      profile: %{
        name: existing_name,
        description: "duplicate",
        model_pool: [models.old],
        capability_groups: ["file_read"],
        max_refinement_rounds: 2
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "has already been taken"
    refute_receive {:profile_updated, _}, 300
  end

  defp mount_settings_isolated(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub
      }
    )
  end

  defp switch_to_profiles_tab(view) do
    view
    |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
    |> render_click()

    view
  end

  defp create_profile!(attrs) do
    defaults = %{
      name: "profile_#{System.unique_integer([:positive])}",
      description: "profile",
      model_pool: ["gpt_4o"],
      capability_groups: ["file_read"],
      max_refinement_rounds: 4
    }

    %TableProfiles{}
    |> TableProfiles.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp start_task_agent!(profile_name, sandbox_owner, deps, opts) do
    create_task_opts = [
      sandbox_owner: sandbox_owner,
      dynsup: deps.dynsup,
      registry: deps.registry,
      pubsub: deps.pubsub
    ]

    {:ok, {task, agent_pid}} =
      TaskManager.create_task(
        %{profile: profile_name},
        %{task_description: "hot reload test task #{System.unique_integer([:positive])}"},
        Keyword.merge(create_task_opts, opts)
      )

    on_exit(fn ->
      stop_agent_tree(agent_pid, deps.registry)
    end)

    {:ok, state} = Core.get_state(agent_pid)

    {task, agent_pid, state}
  end

  defp send_user_message_and_await_consensus_summary(agent_pid, content, timeout_ms) do
    drain_log_mailbox()
    :ok = Core.send_user_message(agent_pid, content)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_consensus_log(deadline)
  end

  defp await_consensus_log(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:log_entry, %{message: message, metadata: metadata}}
        when is_binary(message) and is_map(metadata) ->
          if String.contains?(message, "Sending to consensus") do
            model_ids =
              metadata
              |> Map.get(:sent_messages, [])
              |> Enum.map(&Map.get(&1, :model_id))
              |> Enum.reject(&is_nil/1)
              |> Enum.sort()

            {:ok, %{model_ids: model_ids, refinement_round_count: 0}}
          else
            await_consensus_log(deadline)
          end

        {:log_entry, _} ->
          await_consensus_log(deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp drain_log_mailbox do
    receive do
      {:log_entry, _} -> drain_log_mailbox()
    after
      0 -> :ok
    end
  end
end
