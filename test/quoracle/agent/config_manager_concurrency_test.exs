defmodule Quoracle.Agent.ConfigManagerConcurrencyTest do
  @moduledoc """
  Property-based and stress tests for Registry atomicity.
  Ensures the race condition is completely eliminated under concurrent load.
  """
  # async: true - uses isolated registry per test
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData
  require Logger

  alias Quoracle.Agent.ConfigManager

  # Setup isolated registry for each test
  setup do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
    {:ok, registry: registry_name}
  end

  property "concurrent registrations are atomic", %{registry: registry} do
    check all(
            agent_ids <-
              list_of(binary(min_length: 5, max_length: 20), min_length: 10, max_length: 100),
            agent_ids = Enum.uniq(agent_ids)
          ) do
      parent = self()

      # Spawn all agents concurrently
      tasks =
        Task.async_stream(
          agent_ids,
          fn agent_id ->
            config = %{agent_id: agent_id, parent_pid: parent}
            ConfigManager.register_agent(config, registry)

            # Immediately query to check atomicity
            case Registry.lookup(registry, {:agent, agent_id}) do
              [{_pid, %{parent_pid: ^parent}}] ->
                :ok

              [] ->
                flunk("Registration disappeared - not atomic!")

              [{_pid, partial}] ->
                flunk("Incomplete registration: #{inspect(partial)}")
            end
          end,
          max_concurrency: 50,
          timeout: 5000
        )

      # Verify all succeeded
      results = Enum.to_list(tasks)
      assert length(results) == length(agent_ids)

      assert Enum.all?(results, fn
               {:ok, :ok} -> true
               _ -> false
             end)

      # Clean up
      for agent_id <- agent_ids do
        case Registry.lookup(registry, {:agent, agent_id}) do
          [{_pid, _}] -> Registry.unregister(registry, {:agent, agent_id})
          _ -> :ok
        end
      end
    end
  end

  describe "stress tests" do
    test "concurrent registrations are atomic - no partial states", %{registry: registry} do
      parent = self()
      # Reasonable concurrency level for deterministic results
      agent_count = 100
      test_pid = self()

      # Generate unique agent IDs
      agent_ids = for i <- 1..agent_count, do: "stress-agent-#{i}"

      # Spawn all concurrently
      tasks =
        for agent_id <- agent_ids do
          Task.async(fn ->
            config = %{agent_id: agent_id, parent_pid: parent}

            # Register and immediately verify atomicity
            :ok = ConfigManager.register_agent(config, registry)

            # Check complete registration - must be atomic
            [{_pid, value}] = Registry.lookup(registry, {:agent, agent_id})
            assert value.parent_pid == parent
            assert is_integer(value.registered_at)

            # Signal completion
            send(test_pid, {:registered, agent_id})

            # Keep process alive to maintain Registry entry
            receive do
              :cleanup -> :ok
            end

            agent_id
          end)
        end

      # Wait for all registration signals (proper synchronization)
      registered_ids =
        for _ <- 1..agent_count do
          receive do
            {:registered, id} -> id
          after
            5000 -> flunk("Registration timeout - task failed to complete")
          end
        end

      # Verify all registrations in Registry - only check OUR agents
      all_agents =
        Registry.select(registry, [
          {{{:agent, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}
        ])

      # Filter to only the agents we created in this test
      our_agents =
        all_agents
        |> Enum.filter(fn agent_id -> agent_id in agent_ids end)
        |> Enum.sort()

      # Clean up - tell all tasks to exit
      for task <- tasks do
        send(task.pid, :cleanup)
      end

      # Wait for tasks to exit cleanly and collect results
      task_results = tasks |> Enum.map(&Task.await(&1, :infinity))

      # Binary test: ALL must succeed for atomicity guarantee
      assert length(registered_ids) == agent_count
      assert length(our_agents) == agent_count
      assert our_agents == Enum.sort(agent_ids)
      assert length(task_results) == agent_count
      assert Enum.sort(task_results) == Enum.sort(agent_ids)
    end

    test "no partial state visible during registration", %{registry: registry} do
      agent_id = "race-test-agent-#{System.unique_integer()}"
      parent = self()

      # Spawn registration task
      registration_task =
        Task.async(fn ->
          config = %{agent_id: agent_id, parent_pid: parent}
          ConfigManager.register_agent(config, registry)
        end)

      # Spawn multiple readers trying to catch partial state
      reader_tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            for _ <- 1..100 do
              case Registry.lookup(registry, {:agent, agent_id}) do
                [] ->
                  :not_registered

                [{_pid, %{parent_pid: ^parent, registered_at: ts}}] when is_integer(ts) ->
                  :fully_registered

                [{_pid, incomplete}] ->
                  # This should NEVER happen with atomic registration
                  flunk("Caught partial state: #{inspect(incomplete)}")
              end
            end
          end)
        end

      # Wait for registration
      Task.await(registration_task)

      # Wait for all readers
      Enum.each(reader_tasks, &Task.await/1)
    end

    test "duplicate agent IDs are rejected - exactly one succeeds", %{registry: registry} do
      agent_id = "duplicate-concurrent-test-#{System.unique_integer()}"
      config = %{agent_id: agent_id, parent_pid: self()}
      test_pid = self()

      # Spawn multiple processes trying to register the same ID
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result =
              try do
                ConfigManager.register_agent(config, registry)
                # Signal successful registration
                send(test_pid, {:registered, i})

                # Keep the successful process alive to maintain Registry entry
                receive do
                  :cleanup -> :ok
                end

                :registered
              rescue
                e in RuntimeError ->
                  if e.message =~ "Duplicate agent ID" do
                    send(test_pid, {:duplicate, i})
                    :duplicate
                  else
                    reraise e, __STACKTRACE__
                  end
              end

            result
          end)
        end

      # Collect registration signals (wait for all tasks to signal completion)
      for _ <- 1..10 do
        receive do
          {:registered, _i} -> :ok
          {:duplicate, _i} -> :ok
        after
          1000 -> flunk("Registration signal timeout")
        end
      end

      # Clean up tasks
      for task <- tasks do
        send(task.pid, :cleanup)
      end

      # Collect results
      results = Enum.map(tasks, &Task.await/1)

      # Binary assertion: EXACTLY one succeeds, all others fail with duplicate
      registered_count = Enum.count(results, &(&1 == :registered))
      duplicate_count = Enum.count(results, &(&1 == :duplicate))

      assert registered_count == 1
      assert duplicate_count == 9
      assert registered_count + duplicate_count == 10
    end

    test "parent-child relationships remain consistent under load", %{registry: registry} do
      parent = self()
      child_count = 100

      # Register many children concurrently - keep processes alive
      child_ids = for i <- 1..child_count, do: "child-stress-#{i}"

      test_pid = self()

      tasks =
        for child_id <- child_ids do
          Task.async(fn ->
            config = %{agent_id: child_id, parent_pid: parent}

            # Try to register
            result =
              try do
                ConfigManager.register_agent(config, registry)
                :ok
              rescue
                e -> {:error, e}
              end

            # Signal that registration is complete
            send(test_pid, {:registered, child_id, result})

            # Keep process alive to maintain Registry entry
            receive do
              :cleanup -> result
            end
          end)
        end

      # Wait for all registration signals
      registration_results =
        for _ <- child_ids do
          receive do
            {:registered, id, result} -> {id, result}
          after
            1000 -> {:timeout, nil}
          end
        end

      # Count successful registrations
      successful_ids =
        registration_results
        |> Enum.filter(fn {_, result} -> result == :ok end)
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.sort()

      # Query the Registry BEFORE cleaning up (while processes are still alive)
      children =
        Registry.select(registry, [
          {{{:agent, :"$1"}, :"$2", :"$3"}, [{:==, {:map_get, :parent_pid, :"$3"}, parent}],
           [:"$1"]}
        ])

      # Children are returned as agent_ids directly from the select
      found_ids =
        children
        |> Enum.filter(fn id -> id in child_ids end)
        |> Enum.sort()

      # NOW clean up - tell all tasks to exit
      for task <- tasks do
        send(task.pid, :cleanup)
      end

      # Wait for all tasks to complete
      _results = tasks |> Enum.map(&Task.await(&1, :infinity))

      # All successfully registered children should be found
      assert found_ids == successful_ids
      assert length(successful_ids) == child_count
    end
  end

  describe "performance benchmarks" do
    @tag :benchmark
    test "registration performance logging", %{registry: registry} do
      parent = self()

      # Warmup
      warmup_ids = for i <- 1..10, do: "warmup-#{i}"

      for id <- warmup_ids do
        ConfigManager.register_agent(%{agent_id: id, parent_pid: parent}, registry)
      end

      # Benchmark 1000 registrations
      agent_ids = for i <- 1..1000, do: "perf-#{i}"

      {time_us, results} =
        :timer.tc(fn ->
          tasks =
            Task.async_stream(
              agent_ids,
              fn id ->
                ConfigManager.register_agent(%{agent_id: id, parent_pid: parent}, registry)
              end,
              max_concurrency: 100,
              timeout: 10000
            )

          Enum.to_list(tasks)
        end)

      ms = time_us / 1000
      _per_agent = ms / 1000

      # Performance: 1000 agents registered in #{ms}ms (#{per_agent}ms per agent)
      # Log removed to keep test output clean

      # Verify all registrations succeeded (deterministic test)
      successful_count =
        Enum.count(results, fn
          {:ok, :ok} -> true
          _ -> false
        end)

      assert successful_count == 1000
    end

    test "no deadlocks under extreme concurrency", %{registry: registry} do
      parent = self()

      # Try to cause deadlocks with many simultaneous operations
      operations =
        for i <- 1..500 do
          Task.async(fn ->
            agent_id = "deadlock-test-#{i}"
            config = %{agent_id: agent_id, parent_pid: parent}

            # Register
            ConfigManager.register_agent(config, registry)

            # Query multiple times
            for _ <- 1..10 do
              Registry.lookup(registry, {:agent, agent_id})
            end

            # Query parent's children
            Registry.select(registry, [
              {{:"$1", :"$2", :"$3"}, [{:==, {:map_get, :parent_pid, :"$3"}, parent}], [:"$3"]}
            ])

            :ok
          end)
        end

      # All should complete within timeout (no deadlocks)
      results =
        Enum.map(operations, fn task ->
          Task.await(task, 5000)
        end)

      assert Enum.all?(results, &(&1 == :ok))
    end
  end
end
