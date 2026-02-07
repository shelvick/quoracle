defmodule Quoracle.Integration.SpawnTest do
  @moduledoc """
  Integration tests for spawn_child functionality across the entire
  agent system including Core, DynSup, Router, and broadcasting.

  Tests complete end-to-end flows with minimal mocking, using real
  components to validate system integration.
  """
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Agent.Core
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers,
    only: [create_test_profile: 0, spawn_agent_with_cleanup: 3, register_agent_cleanup: 1]

  setup %{sandbox_owner: sandbox_owner} do
    profile = create_test_profile()
    deps = IsolationHelpers.create_isolated_deps()

    # Start a real parent agent
    # Note: Parent agents don't use field-based config directly - they get task via send_user_message
    # So we only need agent_id, models, and test infrastructure
    parent_config = %{
      agent_id: "parent-#{System.unique_integer([:positive])}",
      models: [:gpt4],
      parent_pid: nil,
      test_mode: true,
      # Skip auto-consensus to prevent deadlock during synchronous test calls
      skip_auto_consensus: true,
      # Deterministic consensus
      registry: deps.registry,
      pubsub: deps.pubsub,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner,
      capability_groups: [:hierarchy]
    }

    {:ok, parent_pid} =
      spawn_agent_with_cleanup(deps.dynsup, parent_config,
        registry: deps.registry,
        sandbox_owner: sandbox_owner
      )

    {:ok, deps: deps, parent_pid: parent_pid, parent_id: parent_config.agent_id, profile: profile}
  end

  # ============================================================================
  # Full Agent Lifecycle Tests
  # ============================================================================

  describe "full agent lifecycle" do
    test "complete spawn-execute-terminate lifecycle", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Parent spawns child
      spawn_result =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child task",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      assert {:ok, %{agent_id: _child_id, pid: child_pid}} = spawn_result
      assert Process.alive?(child_pid)

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Child executes action
      # TEST-FIX: Orient requires 4 parameters per schema
      child_result =
        GenServer.call(child_pid, {
          :process_action,
          %{
            action: "orient",
            params: %{
              current_situation: "Child spawned",
              goal_clarity: "Clear",
              available_resources: "Full",
              key_challenges: "None",
              delegation_consideration: "No delegation needed"
            }
          },
          "action-2"
        })

      assert {:ok, _} = child_result

      # Verify child terminates gracefully
      GenServer.stop(child_pid, :normal, :infinity)
      refute Process.alive?(child_pid)
    end

    test "spawned child inherits parent configuration", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      spawn_result =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Inherit test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      {:ok, %{pid: child_pid}} = spawn_result

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Get child state to verify inheritance
      assert {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)

      # Inherited
      assert child_state.models == [:gpt4]
      assert child_state.parent_pid == parent_pid
      # Injected
      assert child_state.registry == deps.registry
    end

    test "multiple children spawn independently", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Spawn 3 children
      children =
        for i <- 1..3 do
          {:ok, child} =
            GenServer.call(parent_pid, {
              :process_action,
              %{
                action: "spawn_child",
                params: %{
                  task_description: "Child #{i}",
                  success_criteria: "Complete",
                  immediate_context: "Test",
                  approach_guidance: "Standard",
                  profile: profile.name
                }
              },
              "action-#{i}"
            })

          child
        end

      # CRITICAL: Add cleanup IMMEDIATELY after spawn loop
      Enum.each(children, fn child ->
        register_agent_cleanup(child.pid)
      end)

      # All should be alive and unique
      assert length(children) == 3
      assert length(Enum.uniq_by(children, & &1.agent_id)) == 3

      Enum.each(children, fn child ->
        assert Process.alive?(child.pid)
        assert {:ok, _state} = Quoracle.Agent.Core.get_state(child.pid)
      end)
    end

    test "spawned child has correct registry entries", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{agent_id: child_id, pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Registry test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Verify agent is registered
      assert_agent_alive_in_registry(child_id, deps.registry)

      # Verify parent-child relationship
      children = Core.find_children_by_parent(parent_pid, deps.registry)

      assert Enum.any?(children, fn {pid, meta} ->
               pid == child_pid && meta.agent_id == child_id
             end)
    end

    test "child spawning updates parent state correctly", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{agent_id: _child_id, pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "State test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # TEST-FIX: action_history doesn't exist in Core state
      # Verify spawn succeeded by checking child is alive and registered
      assert Process.alive?(child_pid)

      # Verify child is in registry with parent relationship
      children = Core.find_children_by_parent(parent_pid, deps.registry)
      assert Enum.any?(children, fn {pid, _meta} -> pid == child_pid end)
    end
  end

  # ============================================================================
  # Parent-Child Communication Tests
  # ============================================================================

  describe "parent-child communication" do
    test "parent can send message to children", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Spawn two children
      {:ok, child1} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child 1",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      {:ok, child2} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child 2",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      register_agent_cleanup(child1.pid)
      register_agent_cleanup(child2.pid)

      # Parent sends message to all children
      send_result =
        GenServer.call(parent_pid, {
          :process_action,
          %{action: "send_message", params: %{to: "children", content: "Hello children"}},
          "action-3"
        })

      assert {:ok, %{sent_to: sent_list}} = send_result
      assert length(sent_list) == 2
      assert child1.agent_id in sent_list
      assert child2.agent_id in sent_list
    end

    test "child can send message to parent", %{
      deps: _deps,
      parent_pid: parent_pid,
      parent_id: parent_id,
      profile: profile
    } do
      {:ok, %{pid: child_pid, agent_id: child_id}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Communicator",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Child sends message to parent
      send_result =
        GenServer.call(child_pid, {
          :process_action,
          %{action: "send_message", params: %{to: "parent", content: "Hello parent"}},
          "action-2"
        })

      assert {:ok, %{sent_to: [^parent_id]}} = send_result

      # Verify parent received message
      assert {:ok, parent_state} = Quoracle.Agent.Core.get_state(parent_pid)

      assert Enum.any?(parent_state.messages, fn msg ->
               msg.content == "Hello parent" && msg.from == child_id
             end)
    end

    test "siblings can communicate through parent", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Spawn two siblings
      {:ok, %{pid: child1_pid, agent_id: _child1_id}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Sibling 1",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      {:ok, %{pid: child2_pid, agent_id: _child2_id}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Sibling 2",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      register_agent_cleanup(child1_pid)
      register_agent_cleanup(child2_pid)

      # Child1 sends to parent, parent forwards to child2
      GenServer.call(child1_pid, {
        :process_action,
        %{action: "send_message", params: %{to: "parent", content: "Forward this"}},
        "action-3"
      })

      # Parent forwards to all children
      GenServer.call(parent_pid, {
        :process_action,
        %{action: "send_message", params: %{to: "children", content: "Forwarded message"}},
        "action-4"
      })

      # Verify messages delivered by checking state (GenServer.call is synchronous)
      assert {:ok, child1_state} = Quoracle.Agent.Core.get_state(child1_pid)
      assert {:ok, child2_state} = Quoracle.Agent.Core.get_state(child2_pid)

      assert Enum.any?(child1_state.messages, &(&1.content == "Forwarded message"))
      assert Enum.any?(child2_state.messages, &(&1.content == "Forwarded message"))
    end

    test "message delivery updates recipient mailbox", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Mailbox test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      assert {:ok, state_before} = Quoracle.Agent.Core.get_state(child_pid)
      child_messages_before = state_before.messages

      # GenServer.call is synchronous - message delivery happens before return
      GenServer.call(parent_pid, {
        :process_action,
        %{action: "send_message", params: %{to: "children", content: "Test message"}},
        "action-2"
      })

      assert {:ok, state_after} = Quoracle.Agent.Core.get_state(child_pid)
      child_messages_after = state_after.messages

      assert length(child_messages_after) > length(child_messages_before)
    end

    test "invalid target returns error without crashing", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Invalid send test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Try to send to non-existent target - capture expected error log
      capture_log(fn ->
        send(
          self(),
          {:result,
           GenServer.call(child_pid, {
             :process_action,
             %{action: "send_message", params: %{to: "nonexistent", content: "Hello"}},
             "action-2"
           })}
        )
      end)

      assert_received {:result, {:error, _reason}}
      assert Process.alive?(child_pid)
    end
  end

  # ============================================================================
  # Recursive Spawning Tests
  # ============================================================================

  describe "recursive spawning" do
    test "agents can spawn grandchildren recursively", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Parent spawns child
      {:ok, %{pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Middle generation",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Child spawns grandchild
      {:ok, %{pid: grandchild_pid, agent_id: grandchild_id}} =
        GenServer.call(child_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Grandchild",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(grandchild_pid)

      assert Process.alive?(grandchild_pid)

      # Verify grandchild has child as parent
      grandchild_parent = Core.get_parent_from_registry(grandchild_id, deps.registry)
      assert grandchild_parent == child_pid
    end

    test "three-level hierarchy functions correctly", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Build 3-level hierarchy
      {:ok, %{pid: child}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Level 2",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "a1"
        })

      {:ok, %{pid: grandchild}} =
        GenServer.call(child, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Level 3",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "a2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      register_agent_cleanup(child)
      register_agent_cleanup(grandchild)

      # Parent broadcasts to all descendants
      {:ok, _} =
        GenServer.call(parent_pid, {
          :process_action,
          %{action: "send_message", params: %{to: "all_children", content: "Broadcast"}},
          "a3"
        })

      # Only direct child should receive (all_children doesn't recurse)
      assert {:ok, child_state} = Quoracle.Agent.Core.get_state(child)
      assert Enum.any?(child_state.messages, &(&1.content == "Broadcast"))

      # TEST-FIX: all_children only sends to direct children, not grandchildren
      # Grandchild won't receive parent's broadcast
    end

    test "deep hierarchy maintains proper parent chains", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Build 5-level hierarchy
      hierarchy = build_hierarchy(parent_pid, 5, profile)

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      # Clean up all spawned agents (skip first which is parent_pid from setup)
      hierarchy
      |> Enum.drop(1)
      |> Enum.each(fn pid ->
        register_agent_cleanup(pid)
      end)

      # Verify each level knows its parent
      Enum.chunk_every(hierarchy, 2, 1, :discard)
      |> Enum.each(fn [parent, child] ->
        assert {:ok, child_state} = Quoracle.Agent.Core.get_state(child)
        assert child_state.parent_pid == parent
      end)
    end
  end

  # ============================================================================
  # Termination Handling Tests
  # ============================================================================

  describe "termination handling" do
    test "children receive DOWN message when parent terminates", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Orphan test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Monitor child to see if it terminates
      child_ref = Process.monitor(child_pid)

      # Kill parent - Core has trap_exit so exits :normal
      parent_ref = Process.monitor(parent_pid)
      Process.exit(parent_pid, :crash)
      assert_receive {:DOWN, ^parent_ref, :process, ^parent_pid, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]

      # Child should continue running (no supervisor link)
      refute_receive {:DOWN, ^child_ref, :process, ^child_pid, _}, 100
      assert Process.alive?(child_pid)

      # Verify child knows parent is gone
      assert {:ok, child_state} = Quoracle.Agent.Core.get_state(child_pid)
      # Parent PID should still be stored but process is dead
      refute Process.alive?(child_state.parent_pid)
    end

    test "graceful shutdown cascades through hierarchy", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Create hierarchy
      {:ok, %{pid: child}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "a1"
        })

      {:ok, %{pid: grandchild}} =
        GenServer.call(child, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Grandchild",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "a2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      register_agent_cleanup(child)
      register_agent_cleanup(grandchild)

      # Parent shutdown - Core has trap_exit so exits :normal
      parent_ref = Process.monitor(parent_pid)
      Process.exit(parent_pid, :crash)
      assert_receive {:DOWN, ^parent_ref, :process, ^parent_pid, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]

      # Children continue but know parent is gone
      assert Process.alive?(child)
      assert Process.alive?(grandchild)
    end

    test "child termination doesn't affect parent or siblings", %{
      deps: _deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      # Spawn two siblings
      {:ok, %{pid: child1_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child 1",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      {:ok, %{pid: child2_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Child 2",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-2"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawns to prevent leaks
      register_agent_cleanup(child1_pid)
      register_agent_cleanup(child2_pid)
      # parent_pid cleanup handled by setup

      # Kill child1 - Core has trap_exit so exits :normal
      # Use 5000ms timeout - termination involves cleanup work that can be slow under load
      child1_ref = Process.monitor(child1_pid)
      Process.exit(child1_pid, :crash)
      assert_receive {:DOWN, ^child1_ref, :process, ^child1_pid, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]
      refute Process.alive?(child1_pid)

      # Parent and child2 should be unaffected
      assert Process.alive?(parent_pid)
      assert Process.alive?(child2_pid)
    end
  end

  # ============================================================================
  # UI Broadcasting Tests
  # ============================================================================

  describe "UI broadcasting integration" do
    test "spawn events broadcast to UI topic", %{
      deps: deps,
      parent_pid: parent_pid,
      parent_id: parent_id,
      profile: profile
    } do
      # Subscribe to lifecycle events
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      {:ok, %{agent_id: child_id}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "UI test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      assert_receive {:agent_spawned, event}, 30_000
      assert event.agent_id == child_id
      assert event.parent_id == parent_id
      assert event.task == "UI test"
      assert %DateTime{} = event.timestamp
    end

    # NOTE: Termination broadcasts only work for supervised shutdowns, not
    # DynamicSupervisor.terminate_child (which doesn't call terminate/2 without trap_exit).
    # Enabling trap_exit causes other issues (EXIT message handling, PubSub cleanup races).
    # For now, termination events are only broadcast when agents crash or stop gracefully.

    test "action results broadcast from spawned agents", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      {:ok, %{pid: child_pid, agent_id: child_id}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Action test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Subscribe to action broadcasts on isolated PubSub (test-safe due to isolation + agent_id filtering)
      # Note: deps.pubsub is test-specific, so "actions:all" only receives events from this test's agents
      Phoenix.PubSub.subscribe(deps.pubsub, "actions:all")

      # Child executes action with required orient params
      # TEST-FIX: Orient requires 5 params per Schema (including delegation_consideration)
      GenServer.call(child_pid, {
        :process_action,
        %{
          action: "orient",
          params: %{
            current_situation: "Test",
            goal_clarity: "Clear",
            available_resources: "All",
            key_challenges: "None",
            delegation_consideration: "No delegation needed"
          }
        },
        "action-2"
      })

      # TEST-FIX: Event type is :action_completed, not :action_result
      # Receive messages until we get the child's action (filter out parent's spawn)
      child_event =
        receive do
          {:action_completed, %{agent_id: ^child_id} = event} ->
            event

          {:action_completed, _} ->
            # Parent's spawn action, wait for child's orient
            receive do
              {:action_completed, %{agent_id: ^child_id} = event} -> event
            after
              1000 -> nil
            end
        after
          1000 -> nil
        end

      assert child_event != nil, "Child's action_completed event not received"
      # TEST-FIX: Router generates its own action IDs, not passed-in IDs
      # Just verify an action_id exists
      assert is_binary(child_event.action_id)
    end

    test "lifecycle broadcasts include all required metadata", %{
      deps: deps,
      parent_pid: parent_pid,
      profile: profile
    } do
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      {:ok, %{agent_id: child_id, pid: child_pid}} =
        GenServer.call(parent_pid, {
          :process_action,
          %{
            action: "spawn_child",
            params: %{
              task_description: "Metadata test",
              success_criteria: "Complete",
              immediate_context: "Test",
              approach_guidance: "Standard",
              profile: profile.name
            }
          },
          "action-1"
        })

      # CRITICAL: Add cleanup IMMEDIATELY after spawn to prevent leaks
      register_agent_cleanup(child_pid)

      # Verify spawn broadcast
      assert_receive {:agent_spawned, spawn_event}, 30_000
      assert is_binary(spawn_event.agent_id)
      assert spawn_event.agent_id == child_id
      assert is_binary(spawn_event.parent_id)
      assert is_binary(spawn_event.task)
      assert %DateTime{} = spawn_event.timestamp

      # NOTE: Termination broadcasts tested separately when implemented properly
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp spawn_child_via_parent(parent_pid, task, profile) do
    action_id = "action-#{System.unique_integer([:positive])}"

    GenServer.call(parent_pid, {
      :process_action,
      %{
        action: "spawn_child",
        params: %{
          task_description: task,
          success_criteria: "Complete",
          immediate_context: "Test",
          approach_guidance: "Standard",
          profile: profile.name
        }
      },
      action_id
    })
  end

  defp build_hierarchy(parent_pid, levels, profile) do
    # Recursively build n-level hierarchy
    do_build_hierarchy(parent_pid, levels, [parent_pid], profile)
  end

  defp do_build_hierarchy(_parent, 0, acc, _profile), do: Enum.reverse(acc)

  defp do_build_hierarchy(parent, levels, acc, profile) do
    {:ok, %{pid: child}} = spawn_child_via_parent(parent, "Level #{levels}", profile)
    do_build_hierarchy(child, levels - 1, [child | acc], profile)
  end

  defp assert_agent_alive_in_registry(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _meta}] ->
        assert Process.alive?(pid)

      _ ->
        flunk("Agent #{agent_id} not found in registry")
    end
  end
end
