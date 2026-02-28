defmodule Quoracle.Agent.ProfileHotReloadTest do
  @moduledoc """
  Tests for feat-20260227-profile-hot-reload Packet 2.

  Covers AGENT_ConfigManager subscription + AGENT_Core profile update handling.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Models.TableCredentials
  alias Quoracle.PubSub.AgentEvents

  setup %{sandbox_owner: sandbox_owner} do
    deps = create_isolated_deps()
    unique = System.unique_integer([:positive])

    models =
      Enum.into([:a, :b, :c, :d], %{}, fn key ->
        model_id = "profile-hot-reload-#{unique}-#{key}"

        {:ok, _credential} =
          TableCredentials.insert(%{
            model_id: model_id,
            model_spec: "test:profile-hot-reload-#{unique}-#{key}",
            api_key: "test-key-#{unique}-#{key}"
          })

        {key, model_id}
      end)

    profile_name = "profile-#{unique}"
    renamed_profile_name = "profile-#{unique}-renamed"

    %{
      deps: deps,
      models: models,
      profile_name: profile_name,
      renamed_profile_name: renamed_profile_name,
      sandbox_owner: sandbox_owner
    }
  end

  test "agent subscribes to profile topic during initialization", context do
    {:ok, agent_pid} = spawn_profile_agent(context)
    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: before_state.max_refinement_rounds + 3
      })

    assert {:ok, updated_state} =
             await_state(
               agent_pid,
               &(&1.max_refinement_rounds == before_state.max_refinement_rounds + 3)
             )

    assert updated_state.profile_name == before_state.profile_name
  end

  test "agent without profile_name does not subscribe to profile topic", context do
    {:ok, profiled_agent_pid} = spawn_profile_agent(context)

    {:ok, unprofiled_agent_pid} =
      spawn_profile_agent(context, profile_name: nil, max_refinement_rounds: 2)

    {:ok, profiled_before} = Core.get_state(profiled_agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, profiled_before, %{
        max_refinement_rounds: profiled_before.max_refinement_rounds + 5
      })

    assert {:ok, _profiled_after} =
             await_state(
               profiled_agent_pid,
               &(&1.max_refinement_rounds == profiled_before.max_refinement_rounds + 5)
             )

    {:ok, unprofiled_after} = Core.get_state(unprofiled_agent_pid)
    assert unprofiled_after.max_refinement_rounds == 2
  end

  test "profile update changes max_refinement_rounds in agent state", context do
    {:ok, agent_pid} = spawn_profile_agent(context, max_refinement_rounds: 4)
    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: 9
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.max_refinement_rounds == 9))
    assert updated_state.max_refinement_rounds != before_state.max_refinement_rounds
  end

  test "profile update applies force_reflection if field exists in state", context do
    {:ok, agent_pid} = spawn_profile_agent(context, max_refinement_rounds: 3)
    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        force_reflection: true,
        max_refinement_rounds: 7
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.max_refinement_rounds == 7))

    if Map.has_key?(updated_state, :force_reflection) do
      assert Map.get(updated_state, :force_reflection) == true
    else
      refute Map.has_key?(updated_state, :force_reflection)
    end
  end

  test "profile update changes profile_description and invalidates prompt cache", context do
    {:ok, agent_pid} =
      spawn_profile_agent(context,
        profile_description: "before description",
        cached_system_prompt: "cached before"
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        profile_description: "after description"
      })

    assert {:ok, updated_state} =
             await_state(agent_pid, &(&1.profile_description == "after description"))

    assert updated_state.cached_system_prompt == nil
  end

  test "profile update triggers model pool switch with history transfer", context do
    old_pool = [context.models.a, context.models.b]
    new_pool = [context.models.c, context.models.d]

    histories = %{
      context.models.a => [history_entry("alpha-1"), history_entry("alpha-2")],
      context.models.b => [history_entry("beta-1")]
    }

    {:ok, agent_pid} =
      spawn_profile_agent(context,
        model_pool: old_pool,
        model_histories: histories
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        model_pool: new_pool
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.model_pool == new_pool), 3_000)
    assert Map.keys(updated_state.model_histories) |> Enum.sort() == Enum.sort(new_pool)
    assert updated_state.model_histories[context.models.c] != []
    assert updated_state.model_histories[context.models.d] != []
  end

  test "model pool switch failure applies other fields and keeps old pool", context do
    old_pool = [context.models.a]

    huge_history = [history_entry(String.duplicate("very-large-entry-", 300))]

    {:ok, agent_pid} =
      spawn_profile_agent(context,
        model_pool: old_pool,
        model_histories: %{context.models.a => huge_history},
        test_opts: [target_limit: 0],
        max_refinement_rounds: 2,
        profile_description: "before"
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        model_pool: [context.models.c],
        max_refinement_rounds: 6,
        profile_description: "partial-apply"
      })

    assert {:ok, updated_state} =
             await_state(
               agent_pid,
               &(&1.max_refinement_rounds == 6 and &1.profile_description == "partial-apply"),
               3_000
             )

    assert updated_state.model_pool == old_pool
  end

  test "any profile field change invalidates cached system prompt", context do
    {:ok, agent_pid} =
      spawn_profile_agent(context,
        max_refinement_rounds: 4,
        cached_system_prompt: "hot cache"
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: 5
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.max_refinement_rounds == 5))
    assert updated_state.cached_system_prompt == nil
  end

  test "empty model_pool in profile update rejected", context do
    old_pool = [context.models.a, context.models.b]

    {:ok, agent_pid} =
      spawn_profile_agent(context,
        model_pool: old_pool,
        max_refinement_rounds: 3
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        model_pool: [],
        max_refinement_rounds: 8
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.max_refinement_rounds == 8), 3_000)
    assert updated_state.model_pool == old_pool
  end

  test "profile update does not change capability_groups", context do
    {:ok, agent_pid} =
      spawn_profile_agent(context,
        capability_groups: [:hierarchy],
        max_refinement_rounds: 2
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        capability_groups: [:external_api, :file_write],
        max_refinement_rounds: 9
      })

    assert {:ok, updated_state} = await_state(agent_pid, &(&1.max_refinement_rounds == 9), 3_000)
    assert updated_state.capability_groups == before_state.capability_groups
  end

  test "profile name change triggers resubscribe to new topic", context do
    {:ok, agent_pid} = spawn_profile_agent(context)
    {:ok, before_state} = Core.get_state(agent_pid)

    _payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        new_name: context.renamed_profile_name,
        max_refinement_rounds: before_state.max_refinement_rounds + 1
      })

    assert {:ok, updated_state} =
             await_state(
               agent_pid,
               &(&1.profile_name == context.renamed_profile_name),
               3_000
             )

    assert updated_state.max_refinement_rounds == before_state.max_refinement_rounds + 1
  end

  test "agent receives updates on new profile name topic after rename", context do
    {:ok, agent_pid} = spawn_profile_agent(context, max_refinement_rounds: 2)
    {:ok, before_state} = Core.get_state(agent_pid)

    _rename_payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        new_name: context.renamed_profile_name,
        max_refinement_rounds: 3
      })

    assert {:ok, renamed_state} =
             await_state(agent_pid, &(&1.profile_name == context.renamed_profile_name), 3_000)

    second_payload = %{
      old_name: context.renamed_profile_name,
      new_name: context.renamed_profile_name,
      model_pool: renamed_state.model_pool,
      max_refinement_rounds: 11,
      force_reflection: false,
      profile_description: "after-rename-update"
    }

    :ok =
      AgentEvents.broadcast_profile_updated(
        context.renamed_profile_name,
        second_payload,
        context.deps.pubsub
      )

    assert {:ok, final_state} =
             await_state(
               agent_pid,
               &(&1.max_refinement_rounds == 11 and
                   &1.profile_description == "after-rename-update"),
               3_000
             )

    assert final_state.profile_name == context.renamed_profile_name
  end

  test "profile update with identical values is a no-op", context do
    {:ok, agent_pid} =
      spawn_profile_agent(context,
        max_refinement_rounds: 4,
        profile_description: "unchanged",
        cached_system_prompt: "still-cached"
      )

    {:ok, before_state} = Core.get_state(agent_pid)

    _noop_payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        new_name: before_state.profile_name,
        model_pool: before_state.model_pool,
        max_refinement_rounds: before_state.max_refinement_rounds,
        profile_description: before_state.profile_description,
        capability_groups: before_state.capability_groups,
        force_reflection: false
      })

    # Verify no-op keeps state stable
    {:ok, no_op_state} = Core.get_state(agent_pid)
    assert no_op_state.max_refinement_rounds == before_state.max_refinement_rounds
    assert no_op_state.profile_description == before_state.profile_description
    assert no_op_state.cached_system_prompt == before_state.cached_system_prompt

    # Then verify future real updates still apply
    _changed_payload =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: before_state.max_refinement_rounds + 2
      })

    assert {:ok, _updated_state} =
             await_state(
               agent_pid,
               &(&1.max_refinement_rounds == before_state.max_refinement_rounds + 2),
               3_000
             )
  end

  test "rapid successive profile updates applied in order", context do
    {:ok, agent_pid} = spawn_profile_agent(context, max_refinement_rounds: 1)
    {:ok, before_state} = Core.get_state(agent_pid)

    _payload_one =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: 6,
        profile_description: "first-update"
      })

    _payload_two =
      broadcast_profile_update(context.deps.pubsub, before_state, %{
        max_refinement_rounds: 10,
        profile_description: "second-update"
      })

    assert {:ok, final_state} =
             await_state(
               agent_pid,
               &(&1.max_refinement_rounds == 10 and &1.profile_description == "second-update"),
               3_000
             )

    assert final_state.max_refinement_rounds == 10
  end

  test "profile update during agent termination does not crash", context do
    {:ok, agent_pid} = spawn_profile_agent(context)

    monitor_ref = Process.monitor(agent_pid)

    send(agent_pid, {
      :profile_updated,
      %{
        old_name: context.profile_name,
        new_name: context.profile_name,
        model_pool: [context.models.a],
        max_refinement_rounds: 5,
        force_reflection: false,
        profile_description: "during-termination"
      }
    })

    try do
      GenServer.stop(agent_pid, :normal, :infinity)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^monitor_ref, :process, ^agent_pid, reason}, 3_000

    assert clean_termination_reason?(reason),
           "expected clean termination reason, got: #{inspect(reason)}"
  end

  defp spawn_profile_agent(context, opts \\ []) do
    model_pool = Keyword.get(opts, :model_pool, [context.models.a, context.models.b])

    default_histories =
      Map.new(model_pool, fn model_id ->
        {model_id, [history_entry("history-#{model_id}")]}
      end)

    default_lessons = Map.new(model_pool, fn model_id -> {model_id, []} end)
    default_states = Map.new(model_pool, fn model_id -> {model_id, nil} end)

    config =
      %{
        agent_id: "profile-hot-reload-agent-#{System.unique_integer([:positive])}",
        task_id: "profile-hot-reload-task-#{System.unique_integer([:positive])}",
        registry: context.deps.registry,
        dynsup: context.deps.dynsup,
        pubsub: context.deps.pubsub,
        sandbox_owner: context.sandbox_owner,
        test_mode: true,
        profile_name: Keyword.get(opts, :profile_name, context.profile_name),
        profile_description: Keyword.get(opts, :profile_description, "before"),
        max_refinement_rounds: Keyword.get(opts, :max_refinement_rounds, 4),
        model_pool: model_pool,
        model_histories: Keyword.get(opts, :model_histories, default_histories),
        context_lessons: Keyword.get(opts, :context_lessons, default_lessons),
        model_states: Keyword.get(opts, :model_states, default_states),
        capability_groups: Keyword.get(opts, :capability_groups, [:hierarchy]),
        cached_system_prompt: Keyword.get(opts, :cached_system_prompt, "cached prompt"),
        test_opts: Keyword.get(opts, :test_opts, [])
      }
      |> Map.merge(Map.new(opts))

    spawn_agent_with_cleanup(
      context.deps.dynsup,
      config,
      registry: context.deps.registry,
      pubsub: context.deps.pubsub,
      sandbox_owner: context.sandbox_owner
    )
  end

  defp broadcast_profile_update(pubsub, state, overrides) do
    payload = %{
      old_name: state.profile_name,
      new_name: Map.get(overrides, :new_name, state.profile_name),
      model_pool: Map.get(overrides, :model_pool, state.model_pool),
      max_refinement_rounds:
        Map.get(overrides, :max_refinement_rounds, state.max_refinement_rounds),
      force_reflection: Map.get(overrides, :force_reflection, false),
      profile_description: Map.get(overrides, :profile_description, state.profile_description),
      capability_groups: Map.get(overrides, :capability_groups, state.capability_groups)
    }

    :ok = AgentEvents.broadcast_profile_updated(payload.old_name, payload, pubsub)
    payload
  end

  defp await_state(agent_pid, predicate, timeout \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_state(agent_pid, predicate, deadline)
  end

  defp do_await_state(agent_pid, predicate, deadline) do
    case safe_get_state(agent_pid) do
      {:ok, state} ->
        if predicate.(state) do
          {:ok, state}
        else
          if System.monotonic_time(:millisecond) < deadline do
            receive do
            after
              20 -> do_await_state(agent_pid, predicate, deadline)
            end
          else
            {:error, {:timeout, state}}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_get_state(agent_pid) do
    try do
      Core.get_state(agent_pid)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp history_entry(content) do
    %{type: :user, content: content, timestamp: DateTime.utc_now()}
  end

  defp clean_termination_reason?(reason) do
    reason == :normal or reason == :noproc or reason == :shutdown or
      match?({:shutdown, _}, reason)
  end
end
