defmodule Quoracle.Profiles.SpawnIntegrationTest do
  @moduledoc """
  Integration tests for TEST_ProfileSpawn v2.0 - Profile inheritance through spawn_child.

  WorkGroupID: feat-20260107-capability-groups
  Packet: 4 (Integration)

  ARC Requirements (v2.0 - Capability Groups):
  - R1: Profile resolved at spawn
  - R2: Profile not found error
  - R3: Profile required error
  - R4: Child has capability_groups as atoms
  - R5: Description propagated
  - R6: Snapshot semantics (for capability_groups)
  - R7: Empty capability_groups propagated correctly
  - R8: Acceptance - Child uses models (SYSTEM level)
  - R9: Acceptance - Empty groups blocks actions (SYSTEM level)
  - R10: Acceptance - Read-only pattern (SYSTEM level)
  - R11: Acceptance - Full flow with capability_groups (SYSTEM level)
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Spawn
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Profiles.Resolver
  alias Quoracle.Repo
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers, warn: false

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

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

  defp create_profile(attrs) do
    # Ensure capability_groups has a default
    attrs = Map.put_new(attrs, :capability_groups, [])

    %TableProfiles{}
    |> TableProfiles.changeset(attrs)
    |> Repo.insert!()
  end

  describe "profile resolution integration" do
    # R1: Profile Resolved at Spawn
    test "spawn calls ProfileResolver.resolve with profile name", %{deps: deps} do
      profile =
        create_profile(%{
          name: "integration-resolve-test",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      # Verify profile exists via Resolver
      assert {:ok, _data} = Resolver.resolve(profile.name)

      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, _config, _opts ->
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Spawn should succeed because profile exists
      assert {:ok, %{agent_id: _}} = Spawn.execute(params, "agent-1", opts)
    end

    # R2: Profile Not Found Error
    test "spawn returns profile_not_found for missing profile", %{deps: deps} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => "definitely-does-not-exist"
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      assert {:error, :profile_not_found} = Spawn.execute(params, "agent-1", opts)
    end

    # R3: Profile Required Error
    test "spawn returns profile_required when profile missing", %{deps: deps} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard"
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      assert {:error, :profile_required} = Spawn.execute(params, "agent-1", opts)
    end
  end

  describe "profile data propagation integration" do
    # R4: Child Has Profile Data
    test "child agent state has all profile fields", %{deps: deps} do
      profile =
        create_profile(%{
          name: "state-test-profile",
          description: "Test description",
          model_pool: ["gpt-4o", "claude-opus"],
          capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
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
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured_config, :config)

      # Verify all profile fields present in config
      assert config.profile_name == "state-test-profile"
      assert config.profile_description == "Test description"
      assert config.model_pool == ["gpt-4o", "claude-opus"]

      assert config.capability_groups == [
               :local_execution,
               :file_read,
               :file_write,
               :external_api
             ]
    end

    # R5: Description Propagated
    test "profile description flows to child config", %{deps: deps} do
      profile =
        create_profile(%{
          name: "desc-flow-test",
          description: "This profile is for web research only",
          model_pool: ["model-1"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      params = %{
        "task_description" => "Research",
        "success_criteria" => "Found",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)
      assert config.profile_description == "This profile is for web research only"
    end

    # R6: Snapshot Semantics
    test "profile changes after spawn don't affect child", %{deps: deps} do
      profile =
        create_profile(%{
          name: "snapshot-semantic-test",
          model_pool: ["old-model"],
          capability_groups: ["hierarchy", "local_execution"]
        })

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      # Modify the profile after spawn
      profile
      |> TableProfiles.changeset(%{model_pool: ["new-model"], capability_groups: []})
      |> Repo.update!()

      # Config captured at spawn time should have OLD values
      [{:config, config}] = :ets.lookup(captured, :config)
      assert config.model_pool == ["old-model"]
      assert config.capability_groups == [:hierarchy, :local_execution]
    end
  end

  describe "acceptance tests" do
    @tag :acceptance
    # R7: Acceptance - Child Uses Models
    test "spawned child config includes correct model_pool", %{deps: deps} do
      profile =
        create_profile(%{
          name: "acceptance-models",
          model_pool: ["gpt-4o-mini", "claude-haiku"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      params = %{
        "task_description" => "Process data",
        "success_criteria" => "Data processed",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # User expectation: child should use profile's model pool
      assert config.model_pool == ["gpt-4o-mini", "claude-haiku"]
    end

    @tag :acceptance
    # R8: Acceptance - Child Uses Models
    test "profile flows completely from params to child config", %{deps: deps} do
      # Create two profiles for parent and child
      _parent_profile =
        create_profile(%{
          name: "acceptance-parent",
          model_pool: ["parent-model"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })

      child_profile =
        create_profile(%{
          name: "acceptance-child",
          description: "Limited child profile",
          model_pool: ["child-model-1", "child-model-2"],
          capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
        })

      params = %{
        "task_description" => "Work with helper",
        "success_criteria" => "Helper completed task",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => child_profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # User expectation: Complete profile data reaches child
      assert result.action == "spawn"
      assert is_binary(result.agent_id)
      assert config.profile_name == "acceptance-child"
      assert config.profile_description == "Limited child profile"
      assert config.model_pool == ["child-model-1", "child-model-2"]

      assert config.capability_groups == [
               :local_execution,
               :file_read,
               :file_write,
               :external_api
             ]
    end
  end

  # ==========================================================================
  # v2.0: Capability Groups Tests (Packet 4)
  # ==========================================================================

  describe "capability_groups propagation v2.0" do
    # R4: Child Has Capability Groups as Atoms
    @tag :r4_integration
    test "child config contains capability_groups as atoms", %{deps: deps} do
      # Create profile directly with capability_groups
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "capgroups-atom-test",
          model_pool: ["gpt-4o"],
          capability_groups: ["file_read", "external_api"]
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Test capability groups",
        "success_criteria" => "Groups propagated",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # CRITICAL: capability_groups must be atoms, not strings
      assert config.capability_groups == [:file_read, :external_api]
      assert is_list(config.capability_groups)
      assert Enum.all?(config.capability_groups, &is_atom/1)
    end

    # R6: Snapshot Semantics for Capability Groups
    @tag :r6_integration
    test "capability_groups snapshot preserved after DB update", %{deps: deps} do
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "capgroups-snapshot-test",
          model_pool: ["gpt-4o"],
          capability_groups: ["hierarchy", "local_execution"]
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Test snapshot",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      # Update profile AFTER spawn
      profile
      |> TableProfiles.changeset(%{capability_groups: []})
      |> Repo.update!()

      [{:config, config}] = :ets.lookup(captured, :config)

      # Child should have ORIGINAL capability_groups (snapshot semantics)
      assert config.capability_groups == [:hierarchy, :local_execution]
    end

    # R7: Empty Capability Groups Propagated Correctly
    @tag :r7_integration
    test "empty capability_groups propagated correctly", %{deps: deps} do
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "capgroups-empty-test",
          model_pool: ["gpt-4o"],
          capability_groups: []
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Test empty groups",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # Empty capability_groups should propagate as empty list
      assert config.capability_groups == []
    end

    # R4 variant: All 5 groups propagated
    @tag :r4_integration
    test "all capability_groups propagated correctly", %{deps: deps} do
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "capgroups-all-test",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Test all groups",
        "success_criteria" => "Done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # All 5 groups should be present as atoms
      assert :hierarchy in config.capability_groups
      assert :local_execution in config.capability_groups
      assert :file_read in config.capability_groups
      assert :file_write in config.capability_groups
      assert :external_api in config.capability_groups
      assert length(config.capability_groups) == 5
    end
  end

  # ==========================================================================
  # v2.0: Acceptance Tests for Capability Groups (Packet 4)
  # ==========================================================================

  describe "acceptance: capability_groups v2.0" do
    @tag :acceptance
    @tag :r9_integration
    # R9: Acceptance - Empty Groups Blocks Actions
    test "spawned child with empty groups has empty capability_groups", %{deps: deps} do
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "acceptance-empty-groups",
          model_pool: ["gpt-4o"],
          capability_groups: []
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Safe research task",
        "success_criteria" => "Research done",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # User expectation: child with empty groups should have no capability_groups
      assert config.capability_groups == []
      assert config.profile_name == "acceptance-empty-groups"
    end

    @tag :acceptance
    @tag :r10_integration
    # R10: Acceptance - Read-Only Pattern
    test "spawned child with file_read only has correct groups", %{deps: deps} do
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "acceptance-read-only",
          model_pool: ["gpt-4o"],
          capability_groups: ["file_read"]
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Analyze files",
        "success_criteria" => "Analysis complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, _} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # User expectation: read-only profile should have only file_read
      assert config.capability_groups == [:file_read]
      # Should NOT have file_write
      refute :file_write in config.capability_groups
    end

    @tag :acceptance
    @tag :r11_integration
    # R11: Acceptance - Full Flow with Capability Groups
    test "capability_groups flow from profile to child config", %{deps: deps} do
      # Create profile with specific capability groups
      profile =
        %TableProfiles{}
        |> TableProfiles.changeset(%{
          name: "acceptance-capgroups-flow",
          description: "Profile for capability groups flow test",
          model_pool: ["gpt-4o-mini", "claude-haiku"],
          capability_groups: ["hierarchy", "file_read", "external_api"]
        })
        |> Repo.insert!()

      params = %{
        "task_description" => "Work with specific capabilities",
        "success_criteria" => "Task completed",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
          :ets.insert(captured, {:config, config})
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "agent-1", opts)

      # Wait for async spawn to complete
      assert_receive {:spawn_complete, _child_id, _spawn_result}, 30_000

      [{:config, config}] = :ets.lookup(captured, :config)

      # User expectation: Complete flow verification
      assert result.action == "spawn"
      assert is_binary(result.agent_id)
      assert config.profile_name == "acceptance-capgroups-flow"
      assert config.profile_description == "Profile for capability groups flow test"
      assert config.model_pool == ["gpt-4o-mini", "claude-haiku"]

      # CRITICAL: capability_groups must be present and correct
      assert config.capability_groups == [:hierarchy, :file_read, :external_api]
      assert :hierarchy in config.capability_groups
      assert :file_read in config.capability_groups
      assert :external_api in config.capability_groups
      # Should NOT have local_execution or file_write
      refute :local_execution in config.capability_groups
      refute :file_write in config.capability_groups
    end
  end
end
