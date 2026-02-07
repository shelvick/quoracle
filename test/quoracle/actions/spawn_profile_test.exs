defmodule Quoracle.Actions.SpawnProfileTest do
  @moduledoc """
  Tests for ACTION_Spawn v14.0 - Profile resolution and propagation.

  ARC Requirements (v14.0):
  - R32: Profile resolved from params
  - R33: Profile not found error
  - R34: Profile required error
  - R35: Profile data in child config
  - R36: Profile description propagated
  - R37: Snapshot semantics
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Spawn
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers, warn: false

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Add spawn_complete_notify for async spawn waiting
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    # Add parent_config
    deps =
      Map.put(deps, :parent_config, %{
        task_id: Ecto.UUID.generate(),
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{},
          transformed: %{}
        },
        models: [],
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      })

    {:ok, deps: deps}
  end

  # Helper to create test profile
  defp create_profile(attrs) do
    attrs = Map.put_new(attrs, :capability_groups, [])

    %TableProfiles{}
    |> TableProfiles.changeset(attrs)
    |> Repo.insert!()
  end

  describe "profile resolution in spawn" do
    # R32: Profile Resolved from Params
    test "spawn resolves profile from params", %{deps: deps} do
      profile =
        create_profile(%{
          name: "spawn-test-profile",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Mock dynsup to capture config
      captured_config =
        :ets.new(:"captured_config_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured_config, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      result = Spawn.execute(params, "agent-1", opts)

      # Should succeed and resolve profile
      assert {:ok, %{agent_id: _child_id}} = result
    end

    # R33: Profile Not Found Error
    test "spawn fails for non-existent profile", %{deps: deps} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => "nonexistent-profile-xyz"
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]
      result = Spawn.execute(params, "agent-1", opts)

      assert {:error, :profile_not_found} = result
    end

    # R34: Profile Required Error
    test "spawn fails without profile param", %{deps: deps} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard"
        # No profile param
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]
      result = Spawn.execute(params, "agent-1", opts)

      assert {:error, :profile_required} = result
    end
  end

  describe "profile data propagation" do
    # R35: Profile Data in Child Config
    test "child config contains profile data", %{deps: deps} do
      profile =
        create_profile(%{
          name: "propagation-test",
          model_pool: ["gpt-4o", "claude-opus"],
          capability_groups: ["hierarchy", "file_read", "file_write", "external_api"]
        })

      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Capture the config passed to dynsup
      captured_config =
        :ets.new(:"captured_config_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured_config, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _result} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      # Retrieve captured config
      [{:config, config}] = :ets.lookup(captured_config, :config)

      assert config.profile_name == "propagation-test"
      assert config.model_pool == ["gpt-4o", "claude-opus"]
      assert config.capability_groups == [:hierarchy, :file_read, :file_write, :external_api]
    end

    # R36: Profile Description Propagated
    test "profile description propagated to child", %{deps: deps} do
      profile =
        create_profile(%{
          name: "desc-test",
          description: "Important context for the LLM about this profile's purpose",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured_config =
        :ets.new(:"captured_config_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured_config, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _result} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured_config, :config)

      assert config.profile_description ==
               "Important context for the LLM about this profile's purpose"
    end

    # R37: Snapshot Semantics
    test "child keeps snapshot of profile at spawn time", %{deps: deps} do
      profile =
        create_profile(%{
          name: "snapshot-test",
          model_pool: ["original-model"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured_config =
        :ets.new(:"captured_config_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured_config, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _result} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      # Get original config
      [{:config, original_config}] = :ets.lookup(captured_config, :config)

      # Update the profile in the database
      profile
      |> TableProfiles.changeset(%{
        model_pool: ["updated-model"],
        capability_groups: []
      })
      |> Repo.update!()

      # The captured config should have original values (snapshot)
      assert original_config.model_pool == ["original-model"]

      assert original_config.capability_groups == [
               :hierarchy,
               :local_execution,
               :file_read,
               :file_write,
               :external_api
             ]
    end
  end
end
