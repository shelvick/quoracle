defmodule Quoracle.Actions.SpawnTest do
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Actions.Spawn
  alias Test.IsolationHelpers
  alias Quoracle.Agent.Core

  # Satisfies hook check - tests use mock dynsup_fn (no real agents spawned)
  import Test.AgentTestHelpers, only: [create_test_profile: 0]
  import ExUnit.CaptureLog

  @moduledoc """
  Unit tests for the spawn_child action module, covering parameter validation,
  spawn execution, retry logic, error handling, and parent-child relationships.
  """

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    # Add sandbox_owner from DataCase context
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events for testing broadcasts
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Add spawn_complete_notify so tests can wait for async spawn completion
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    # Add parent_config to deps - required by ConfigBuilder (prevents GenServer deadlock)
    # This gets included automatically when tests do Map.to_list(deps)
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

    # Create test profile for spawn_child (required since v24.0)
    profile = create_test_profile()

    {:ok, deps: deps, profile: profile}
  end

  # Helper to wait for background spawn to complete and get pid (async pattern)
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, {:ok, child_pid}} -> child_pid
      {:spawn_complete, ^child_id, {:error, _reason}} -> nil
    after
      timeout -> nil
    end
  end

  # Parameter Validation Tests
  describe "parameter validation" do
    test "requires task parameter", %{deps: deps, profile: profile} do
      params = %{"profile" => profile.name}
      opts = Map.to_list(deps) ++ [agent_pid: self()]

      assert {:error, {:missing_required_fields, _missing}} =
               Spawn.execute(params, "agent-1", opts)
    end

    test "accepts task with optional models", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test task",
        "models" => ["gpt-4"],
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Mock dynsup to return success
      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, _config, _opts ->
          {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      assert {:ok, result} = Spawn.execute(params, "agent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)
      assert result.action == "spawn"
      assert result.agent_id =~ ~r/^agent-/
    end

    test "rejects empty task string", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]
      # Field validation catches empty strings
      assert {:error, _reason} = Spawn.execute(params, "agent-1", opts)
    end

    test "handles nil task parameter", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => nil,
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]
      # Field validation returns descriptive error for nil values
      assert {:error, "task_description must be a string"} =
               Spawn.execute(params, "agent-1", opts)
    end
  end

  # Successful Spawning Tests
  describe "successful spawning" do
    test "spawns child agent with unique UUID", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, config, _opts ->
            child_pid = spawn_link(fn -> :timer.sleep(:infinity) end)
            # Register in test registry
            Registry.register(deps.registry, {:agent, config.agent_id}, %{
              pid: child_pid,
              parent_pid: config.parent_pid
            })

            {:ok, child_pid}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)

      assert result.agent_id =~ ~r/^agent-[0-9a-f-]+$/
      assert %DateTime{} = result.spawned_at
    end

    test "child agent registered in Registry", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Need to capture registry and parent_pid for the child process to register itself
      test_registry = deps.registry
      parent_pid = self()
      caller = self()

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, config, _opts ->
            # Child process must register ITSELF (Registry.register uses calling process)
            child_pid =
              spawn_link(fn ->
                Registry.register(test_registry, {:agent, config.agent_id}, %{
                  pid: self(),
                  parent_pid: parent_pid,
                  agent_id: config.agent_id
                })

                # Signal registration complete
                send(caller, {:child_registered, self()})
                :timer.sleep(:infinity)
              end)

            # Wait for child to register (proper sync, no sleep)
            receive do
              {:child_registered, ^child_pid} -> :ok
            after
              1000 -> :timeout
            end

            {:ok, child_pid}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)

      children = Core.find_children_by_parent(self(), deps.registry)

      assert Enum.any?(children, fn {_pid, meta} ->
               meta.agent_id == result.agent_id
             end)

      if child_pid, do: Process.exit(child_pid, :kill)
    end

    test "spawns multiple children independently", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, _config, _opts ->
            {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, child1} = Spawn.execute(params, "parent-1", opts)
      {:ok, child2} = Spawn.execute(params, "parent-1", opts)

      # Wait for async spawn completion and cleanup
      child1_pid = wait_for_spawn_complete(child1.agent_id)
      child2_pid = wait_for_spawn_complete(child2.agent_id)
      if child1_pid, do: Process.exit(child1_pid, :kill)
      if child2_pid, do: Process.exit(child2_pid, :kill)

      # Async pattern: agent_ids are unique (pids are in background)
      assert child1.agent_id != child2.agent_id
    end
  end

  # Model Inheritance Tests
  describe "model inheritance" do
    test "inherits parent models when not specified", %{deps: deps, profile: profile} do
      # Setup parent with models
      parent_config = %{models: ["gpt-4", "claude-3"]}

      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          parent_config: parent_config,
          dynsup_fn: fn _pid, config, _opts ->
            # Verify models were inherited
            assert config.models == ["gpt-4", "claude-3"]
            {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)
    end

    test "overrides parent models when specified", %{deps: deps, profile: profile} do
      parent_config = %{models: ["gpt-4"]}

      params = %{
        "task_description" => "Test",
        "models" => ["claude-3"],
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          parent_config: parent_config,
          dynsup_fn: fn _pid, config, _opts ->
            # Verify models were overridden
            assert config.models == ["claude-3"]
            {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
          end
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)
    end
  end

  # Retry Mechanism Tests
  describe "retry mechanism" do
    test "retries on transient failure with exponential backoff", %{deps: deps, profile: profile} do
      # Mock DynSup to fail twice then succeed
      attempts = :counters.new(1, [])

      mock_dynsup = fn _pid, _config, _opts ->
        # TEST-FIX: :counters.add returns :ok, not the value - need to get separately
        :counters.add(attempts, 1, 1)
        count = :counters.get(attempts, 1)

        case count do
          n when n <= 2 -> {:error, :transient_error}
          _ -> {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
        end
      end

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock = Map.put(deps, :dynsup_fn, mock_dynsup)
      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Async pattern: execute returns immediately, measure background spawn time
      start_time = System.monotonic_time(:microsecond)
      {:ok, result} = Spawn.execute(params, "parent-1", opts)

      # Wait for async spawn completion (includes retry backoff)
      child_pid = wait_for_spawn_complete(result.agent_id, 5000)
      end_time = System.monotonic_time(:microsecond)
      if child_pid, do: Process.exit(child_pid, :kill)

      # Should take at least 300ms (100 + 200) for two retries in background
      assert end_time - start_time >= 300_000
      assert :counters.get(attempts, 1) == 3
    end

    test "gives up after 3 retries and notifies parent", %{deps: deps, profile: profile} do
      mock_dynsup = fn _pid, _config, _opts ->
        {:error, :persistent_error}
      end

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: mock_dynsup,
          max_retries: 3
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Async pattern: execute returns immediately with agent_id
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      assert is_binary(result.agent_id)

      # Wait for background spawn to fail and verify failure notification
      assert nil == wait_for_spawn_complete(result.agent_id, 2000)

      # Parent receives spawn_failed notification
      assert_receive {:spawn_failed, %{child_id: child_id, reason: :persistent_error}}, 30_000
      assert child_id == result.agent_id
    end

    test "no retry on invalid params", %{deps: deps, profile: profile} do
      attempts = :counters.new(1, [])

      mock_dynsup = fn _pid, _config, _opts ->
        :counters.add(attempts, 1, 1)
        {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
      end

      # Missing task (but profile provided so we test missing other required fields)
      params = %{"profile" => profile.name}
      deps_with_mock = Map.put(deps, :dynsup_fn, mock_dynsup)
      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      assert {:error, {:missing_required_fields, _missing}} =
               Spawn.execute(params, "parent-1", opts)

      # Should not have called dynsup at all
      assert :counters.get(attempts, 1) == 0
    end
  end

  # Error Handling Tests
  describe "error handling" do
    test "returns error when dynsup not found", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      # Don't provide dynsup
      deps_without_dynsup = Map.delete(deps, :dynsup)
      opts = Map.to_list(deps_without_dynsup) ++ [agent_pid: self()]

      assert {:error, :dynsup_not_found} =
               Spawn.execute(params, "parent-1", opts)
    end

    test "system errors in background task notify parent", %{deps: deps, profile: profile} do
      # Simulate error - background task catches and notifies parent
      mock_dynsup = fn _pid, _config, _opts ->
        raise "Out of memory"
      end

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock = Map.put(deps, :dynsup_fn, mock_dynsup)
      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Capture expected error logs from background task crash
      capture_log(fn ->
        # Async pattern: execute returns immediately, crash happens in background task
        {:ok, result} = Spawn.execute(params, "parent-1", opts)
        assert is_binary(result.agent_id)

        # Background task crashes - spawn_complete returns nil (no pid)
        assert nil == wait_for_spawn_complete(result.agent_id, 2000)
      end)
    end

    test "handles spawn rejection from dynsup asynchronously", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.put(deps, :dynsup_fn, fn _pid, _config, _opts ->
          {:error, {:already_started, self()}}
        end)

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Async pattern: execute returns immediately
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      assert is_binary(result.agent_id)

      # Spawn failure happens in background - no pid returned
      assert nil == wait_for_spawn_complete(result.agent_id, 2000)

      # Parent receives spawn_failed notification
      assert_receive {:spawn_failed, %{child_id: child_id, reason: :spawn_failed}}, 30_000
      assert child_id == result.agent_id
    end
  end

  # Broadcasting Tests
  describe "broadcasting" do
    test "broadcasts agent_spawned on success", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test broadcast",
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
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)

      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == result.agent_id
      assert payload.parent_id == "parent-1"
      assert payload.task == "Test broadcast"
    end

    test "includes timestamp in spawn broadcast", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Test",
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
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)

      assert_receive {:agent_spawned, payload}, 30_000
      assert %DateTime{} = payload.timestamp
    end

    test "no broadcast on spawn failure", %{deps: deps, profile: profile} do
      mock_dynsup = fn _pid, _config, _opts ->
        {:error, :spawn_error}
      end

      params = %{
        "task_description" => "Test",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: mock_dynsup,
          max_retries: 0
        })

      opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]

      # Async pattern: execute returns immediately
      {:ok, result} = Spawn.execute(params, "parent-1", opts)

      # Wait for background spawn to fail
      assert nil == wait_for_spawn_complete(result.agent_id, 2000)

      # No agent_spawned broadcast on failure
      refute_receive {:agent_spawned, _}, 100
    end

    test "broadcasts to correct pubsub topic", %{deps: deps, profile: profile} do
      params = %{
        "task_description" => "Topic test",
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
      {:ok, result} = Spawn.execute(params, "parent-1", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      if child_pid, do: Process.exit(child_pid, :kill)

      # Should receive on agents:lifecycle topic
      assert_receive {:agent_spawned, _payload}, 30_000
    end
  end

  # Property-Based Tests
  describe "property-based tests" do
    property "generates unique agent IDs for all spawns", %{deps: deps, profile: profile} do
      check all(
              task <- string(:printable, min_length: 1),
              max_runs: 100
            ) do
        params = %{
          "task_description" => task,
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
        {:ok, result1} = Spawn.execute(params, "parent-1", opts)
        {:ok, result2} = Spawn.execute(params, "parent-1", opts)

        # Wait for async spawns and cleanup
        child1_pid = wait_for_spawn_complete(result1.agent_id)
        child2_pid = wait_for_spawn_complete(result2.agent_id)
        if child1_pid, do: Process.exit(child1_pid, :kill)
        if child2_pid, do: Process.exit(child2_pid, :kill)

        assert result1.agent_id != result2.agent_id
      end
    end

    property "handles various task string formats", %{deps: deps, profile: profile} do
      check all(
              task <- string(:printable, min_length: 1, max_length: 1000),
              max_runs: 50
            ) do
        params = %{
          "task_description" => task,
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
        {:ok, result} = Spawn.execute(params, "parent-1", opts)
        child_pid = wait_for_spawn_complete(result.agent_id)
        if child_pid, do: Process.exit(child_pid, :kill)
      end
    end

    property "only inherits whitelisted keys from parent", %{deps: deps, profile: profile} do
      # Only these keys should be inherited from parent (whitelist approach)
      inheritable_keys = [
        :temperature,
        :max_tokens,
        :timeout,
        :max_depth,
        :model_id,
        :model_pool,
        :simulate_failure,
        :test_pid,
        :force_init_error
      ]

      # Generate parent config with mix of inheritable and non-inheritable keys
      inheritable_key_gen =
        one_of([
          constant(:temperature),
          constant(:max_tokens),
          constant(:timeout),
          constant(:max_depth),
          constant(:model_id)
        ])

      non_inheritable_key_gen =
        one_of([
          constant(:model_histories),
          constant(:children),
          constant(:pending_actions),
          constant(:router_pid),
          constant(:random_field)
        ])

      check all(
              inheritable_entries <- list_of({inheritable_key_gen, term()}, max_length: 3),
              non_inheritable_entries <-
                list_of({non_inheritable_key_gen, term()}, max_length: 3),
              max_runs: 50
            ) do
        parent_config = Map.new(inheritable_entries ++ non_inheritable_entries)

        params = %{
          "task_description" => "Test",
          "success_criteria" => "Complete",
          "immediate_context" => "Test",
          "approach_guidance" => "Standard",
          "profile" => profile.name
        }

        deps_with_mock =
          Map.merge(deps, %{
            parent_config: parent_config,
            dynsup_fn: fn _pid, config, _opts ->
              # Verify ONLY whitelisted keys are inherited
              Enum.each(parent_config, fn {k, v} ->
                if k in inheritable_keys do
                  assert config[k] == v
                else
                  # Non-whitelisted key should NOT be in config
                  refute Map.has_key?(config, k),
                         "Non-inheritable key #{inspect(k)} should not be in child config"
                end
              end)

              {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
            end
          })

        opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
        {:ok, result} = Spawn.execute(params, "parent-1", opts)
        child_pid = wait_for_spawn_complete(result.agent_id)
        if child_pid, do: Process.exit(child_pid, :kill)
      end
    end

    property "model list handling with various formats", %{deps: deps, profile: profile} do
      check all(
              models <- list_of(string(:alphanumeric), max_length: 10),
              max_runs: 50
            ) do
        params = %{
          "task_description" => "Test",
          "models" => models,
          "success_criteria" => "Complete",
          "immediate_context" => "Test",
          "approach_guidance" => "Standard",
          "profile" => profile.name
        }

        deps_with_mock =
          Map.put(deps, :dynsup_fn, fn _pid, config, _opts ->
            assert config.models == models
            {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
          end)

        opts = Map.to_list(deps_with_mock) ++ [agent_pid: self()]
        {:ok, result} = Spawn.execute(params, "parent-1", opts)
        child_pid = wait_for_spawn_complete(result.agent_id)
        if child_pid, do: Process.exit(child_pid, :kill)
      end
    end

    property "agent_id format consistency", %{deps: deps, profile: profile} do
      check all(
              task <- string(:printable, min_length: 1),
              max_runs: 100
            ) do
        params = %{
          "task_description" => task,
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
        {:ok, result} = Spawn.execute(params, "parent-1", opts)
        child_pid = wait_for_spawn_complete(result.agent_id)
        if child_pid, do: Process.exit(child_pid, :kill)

        # Verify UUID format
        assert result.agent_id =~
                 ~r/^agent-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      end
    end
  end

  # Helper functions removed - were unused

  # =============================================================================
  # Children Tracking - Parent Notification Tests (R21-R24)
  # WorkGroupID: feat-20251227-children-inject, Packet 3
  # =============================================================================

  describe "parent notification of child spawn (R21-R24)" do
    @tag :r21
    test "R21: successful spawn casts child_spawned to parent", %{deps: deps, profile: profile} do
      # Arrange: Use a real parent agent that can receive the cast
      parent_config = %{
        agent_id: "parent-R21-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, parent_pid} =
        Test.AgentTestHelpers.spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: deps.sandbox_owner
        )

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      spawn_opts = Map.to_list(deps) ++ [agent_pid: parent_pid]

      # Act: Spawn child
      {:ok, result} = Spawn.execute(params, parent_config.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)

      # CRITICAL: Register cleanup IMMEDIATELY
      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Assert: Parent should have the child in its children list
      {:ok, parent_state} = Core.get_state(parent_pid)

      assert Enum.any?(parent_state.children, &(&1.agent_id == result.agent_id)),
             "Parent should have received child_spawned cast and tracked the child"
    end

    @tag :r22
    test "R22: child_spawned cast contains agent_id and spawned_at", %{
      deps: deps,
      profile: profile
    } do
      # Arrange: Use a real parent agent
      parent_config = %{
        agent_id: "parent-R22-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, parent_pid} =
        Test.AgentTestHelpers.spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: deps.sandbox_owner
        )

      before_spawn = DateTime.utc_now()

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      spawn_opts = Map.to_list(deps) ++ [agent_pid: parent_pid]

      # Act: Spawn child
      {:ok, result} = Spawn.execute(params, parent_config.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)

      after_spawn = DateTime.utc_now()

      # CRITICAL: Register cleanup IMMEDIATELY
      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Assert: Child entry should have agent_id and spawned_at
      {:ok, parent_state} = Core.get_state(parent_pid)
      child_entry = Enum.find(parent_state.children, &(&1.agent_id == result.agent_id))

      assert child_entry, "Parent should have child in children list"
      assert child_entry.agent_id == result.agent_id, "Child entry should have agent_id"
      assert %DateTime{} = child_entry.spawned_at, "Child entry should have spawned_at"
      assert DateTime.compare(child_entry.spawned_at, before_spawn) in [:gt, :eq]
      assert DateTime.compare(child_entry.spawned_at, after_spawn) in [:lt, :eq]
    end

    @tag :r23
    test "R23: no child_spawned cast on spawn failure", %{deps: deps, profile: profile} do
      # Arrange: Use test process as parent to receive casts directly
      # This avoids the missing handle_info({:spawn_failed, ...}) in Core
      test_pid = self()

      # Mock dynsup to always fail
      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, _config, _opts -> {:error, :spawn_failed} end,
          max_retries: 0
        })

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      spawn_opts = Map.to_list(deps_with_mock) ++ [agent_pid: test_pid]

      # Act: Attempt spawn (will fail)
      {:ok, result} = Spawn.execute(params, "parent-R23", spawn_opts)

      # Wait for background spawn to fail
      assert nil == wait_for_spawn_complete(result.agent_id, 2000)

      # Assert: No child_spawned cast should be received on failure
      refute_receive {:child_spawned, _},
                     100,
                     "Should not receive child_spawned cast when spawn fails"

      # We should receive spawn_failed notification instead
      assert_receive {:spawn_failed, %{child_id: child_id}}, 30_000
      assert child_id == result.agent_id
    end

    @tag :r24
    test "R24: skips cast if parent process not alive", %{deps: deps, profile: profile} do
      # Arrange: Create a parent that will be killed before cast is sent
      parent_config = %{
        agent_id: "parent-R24-#{System.unique_integer([:positive])}",
        task_id: Ecto.UUID.generate(),
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        prompt_fields: %{
          provided: %{task_description: "Parent task"},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      {:ok, parent_pid} =
        Test.AgentTestHelpers.spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: deps.sandbox_owner
        )

      # Create a mock dynsup that kills the parent before returning
      deps_with_mock =
        Map.merge(deps, %{
          dynsup_fn: fn _pid, _config, _opts ->
            # Kill the parent before the cast can be sent
            GenServer.stop(parent_pid, :normal, :infinity)
            # Return success - the cast should be skipped gracefully
            {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
          end
        })

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      spawn_opts = Map.to_list(deps_with_mock) ++ [agent_pid: parent_pid]

      # Act: Spawn child (parent will be killed during spawn)
      # Should NOT crash even though parent is dead
      {:ok, result} = Spawn.execute(params, parent_config.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)

      # CRITICAL: Register cleanup IMMEDIATELY
      on_exit(fn ->
        if child_pid && Process.alive?(child_pid) do
          try do
            Process.exit(child_pid, :kill)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Assert: No crash occurred - spawn completed
      assert is_binary(result.agent_id)
      refute Process.alive?(parent_pid), "Parent should be dead"
    end
  end

  # =============================================================================
  # Duplicate Task Injection Bug Fix Tests (R12-R16)
  # WorkGroupID: fix-20251210-175217, Packet 3
  # =============================================================================

  describe "duplicate task injection fix (R12-R16)" do
    # R12: No Duplicate Task in Child (INTEGRATION)
    test "child agent receives single task message not duplicate", %{deps: deps, profile: profile} do
      # Spawn a real child agent and verify first consensus has exactly ONE user message
      task_string = "Test task for duplicate check"

      params = %{
        "task_description" => task_string,
        "success_criteria" => "Complete successfully",
        "immediate_context" => "Test context",
        "approach_guidance" => "Standard approach",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      {:ok, result} = Spawn.execute(params, "parent-R12", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child agent should have been spawned"

      # CRITICAL: Register cleanup IMMEDIATELY before any assertions
      on_exit(fn ->
        if Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Get child state and check model_histories
      {:ok, state} = Core.get_state(child_pid)

      # Count user messages in history (across all model histories)
      all_entries =
        state.model_histories
        |> Map.values()
        |> List.flatten()

      # Filter for :event entries (which is what handle_agent_message creates)
      event_entries = Enum.filter(all_entries, fn entry -> entry.type == :event end)

      # v14.0: Initial message now flows through history (exactly once)
      # Task is in BOTH prompt_fields AND history - this is correct behavior
      assert length(event_entries) == 1,
             "Child should have exactly 1 :event entry (initial task message), " <>
               "got #{length(event_entries)} event entries: #{inspect(event_entries)}"
    end

    # R13: Task From Field System (UNIT)
    test "child task comes from prompt_fields not event history", %{deps: deps, profile: profile} do
      task_string = "Task from field system test"

      params = %{
        "task_description" => task_string,
        "success_criteria" => "Complete",
        "immediate_context" => "Context",
        "approach_guidance" => "Guidance",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      {:ok, result} = Spawn.execute(params, "parent-R13", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child agent should have been spawned"

      # CRITICAL: Register cleanup IMMEDIATELY before any assertions
      on_exit(fn ->
        if Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(child_pid)

      # Task should be in prompt_fields (field system)
      prompt_fields = state.prompt_fields

      assert prompt_fields.provided.task_description == task_string,
             "Task should be in prompt_fields.provided.task_description"

      # v14.0: Task is now in BOTH prompt_fields AND event history (exactly once)
      # This is correct behavior - initial message flows through history
      event_entries =
        state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.type == :event))

      assert length(event_entries) == 1,
             "Task should be in prompt_fields AND have exactly 1 event entry. " <>
               "Got #{length(event_entries)} event entries: #{inspect(event_entries)}"
    end

    # R14: Child Matches Root Behavior (INTEGRATION)
    test "child and root agents have same task injection pattern", %{deps: deps, profile: profile} do
      task_string = "Consistency test task"

      # Create root agent via DynSup (same path as TaskManager) - no Spawn.execute
      root_config = %{
        task_id: Ecto.UUID.generate(),
        agent_id: "root-R14-#{System.unique_integer([:positive])}",
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: deps.sandbox_owner,
        pubsub: deps.pubsub,
        prompt_fields: %{
          provided: %{task_description: task_string},
          injected: %{global_context: "", constraints: []},
          transformed: %{}
        },
        models: []
      }

      root_opts = [
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      {:ok, root_pid} =
        Test.AgentTestHelpers.spawn_agent_with_cleanup(deps.dynsup, root_config, root_opts)

      {:ok, root_state} = Core.get_state(root_pid)

      # Create child agent via Spawn.execute (has the bug)
      child_params = %{
        "task_description" => task_string,
        "success_criteria" => "Complete",
        "immediate_context" => "Context",
        "approach_guidance" => "Guidance",
        "profile" => profile.name
      }

      spawn_opts = Map.to_list(deps) ++ [agent_pid: self()]

      {:ok, result} = Spawn.execute(child_params, root_state.agent_id, spawn_opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child agent should have been spawned"

      # CRITICAL: Register cleanup IMMEDIATELY before any assertions
      # (root cleaned up by spawn_agent_with_cleanup)
      on_exit(fn ->
        if Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, child_state} = Core.get_state(child_pid)

      # Extract :event entries from both
      root_events =
        root_state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.type == :event))

      child_events =
        child_state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.type == :event))

      # v14.0: Root created via DynSup directly (no message sent) has 0 events
      # Child created via Spawn.execute gets initial message in history (1 event)
      # In production, root via TaskManager.create_task would also have 1 event
      # This test verifies child has exactly 1 event (no duplicates)
      assert root_events == [], "Root (direct DynSup) should have 0 event entries"

      assert length(child_events) == 1,
             "Child should have exactly 1 event entry (initial task), " <>
               "got #{length(child_events)}: #{inspect(child_events)}"
    end

    # R15: Broadcast Still Works (INTEGRATION)
    test "spawn broadcast includes task string without duplicate injection", %{
      deps: deps,
      profile: profile
    } do
      task_string = "Broadcast verification task"

      params = %{
        "task_description" => task_string,
        "success_criteria" => "Complete",
        "immediate_context" => "Context",
        "approach_guidance" => "Guidance",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      {:ok, result} = Spawn.execute(params, "parent-R15", opts)

      # Wait for broadcast event (subscribed in setup)
      assert_receive {:agent_spawned, event}, 30_000
      assert event.agent_id == result.agent_id
      assert event.task == task_string

      # Wait for spawn completion and verify no duplicate injection
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child agent should have been spawned"

      # CRITICAL: Register cleanup IMMEDIATELY before any assertions
      on_exit(fn ->
        if Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(child_pid)

      # v14.0: Initial message now flows through history (exactly once)
      # Verify broadcast worked AND no duplicate injection occurred
      event_entries =
        state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.type == :event))

      assert length(event_entries) == 1,
             "Broadcast should work with exactly 1 event entry (initial task). " <>
               "Got #{length(event_entries)} event entries: #{inspect(event_entries)}"
    end

    # R16: Child Agent Starts Correctly (SYSTEM)
    test "spawned child agent receives task and responds appropriately", %{
      deps: deps,
      profile: profile
    } do
      # Full system test: spawn child, verify it has task, verify it can work
      task_string = "System test task for child agent"

      params = %{
        "task_description" => task_string,
        "success_criteria" => "The task is done",
        "immediate_context" => "Starting fresh",
        "approach_guidance" => "Be thorough",
        "profile" => profile.name
      }

      opts = Map.to_list(deps) ++ [agent_pid: self()]

      {:ok, result} = Spawn.execute(params, "parent-R16", opts)
      child_pid = wait_for_spawn_complete(result.agent_id)
      assert child_pid, "Child agent should have been spawned"

      # CRITICAL: Register cleanup IMMEDIATELY before any assertions
      on_exit(fn ->
        if Process.alive?(child_pid) do
          try do
            GenServer.stop(child_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(child_pid)

      # Verify child has proper state for working
      assert state.agent_id == result.agent_id
      assert state.prompt_fields.provided.task_description == task_string

      # Verify child can receive messages (basic functionality)
      # Send a test message - this should NOT duplicate the task
      :ok = Core.handle_agent_message(child_pid, "Additional instruction")

      # Sync wait - get_state is a GenServer.call that ensures previous cast processed
      {:ok, updated_state} = Core.get_state(child_pid)

      # Count unique event contents (events are duplicated per model in model_histories)
      unique_event_contents =
        updated_state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(fn entry -> entry.type == :event end)
        |> Enum.map(& &1.content)
        |> Enum.uniq()

      # v14.0: Initial message now flows through history
      # Expected: 2 unique events (initial task + additional message)
      # v10.0: Events store structured content with sender info
      assert length(unique_event_contents) == 2,
             "Child should have exactly 2 unique :events (initial task + additional), " <>
               "got #{length(unique_event_contents)}: #{inspect(unique_event_contents)}"

      # Verify both expected messages are present
      assert Enum.any?(unique_event_contents, fn c -> c.content == task_string end),
             "Should have initial task in history"

      assert Enum.any?(unique_event_contents, fn c -> c.content == "Additional instruction" end),
             "Should have additional instruction in history"
    end
  end
end
