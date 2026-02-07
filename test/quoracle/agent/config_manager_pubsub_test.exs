defmodule Quoracle.Agent.ConfigManagerPubSubTest do
  @moduledoc """
  Tests for ConfigManager PubSub dependency injection support.
  """
  use ExUnit.Case, async: true
  alias Quoracle.Agent.ConfigManager

  setup do
    # Create isolated dependencies
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"

    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    # Start DynSup with unique ID to avoid conflicts
    # CRITICAL: shutdown: :infinity prevents kill escalation during cleanup
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    %{pubsub: pubsub_name, registry: registry_name, dynsup: dynsup}
  end

  describe "build_agent_config/3 with PubSub injection" do
    test "includes pubsub in agent configuration", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    } do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      base_config = %{
        agent_id: agent_id,
        parent_pid: self(),
        task_id: "task-1"
      }

      # Build config with dependencies
      deps = %{
        pubsub: pubsub,
        registry: registry,
        dynsup: dynsup
      }

      config = ConfigManager.build_agent_config(base_config, deps)

      # Should include all dependencies
      assert config.pubsub == pubsub
      assert config.registry == registry
      assert config.dynsup == dynsup
      assert config.agent_id == agent_id
    end

    test "preserves existing pubsub in base config", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    } do
      custom_pubsub = :"custom_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: custom_pubsub}, id: :custom_ps)

      # Base config already has pubsub
      base_config = %{
        agent_id: "agent-1",
        parent_pid: nil,
        task_id: "task-1",
        pubsub: custom_pubsub
      }

      deps = %{
        # Different pubsub in deps
        pubsub: pubsub,
        registry: registry,
        dynsup: dynsup
      }

      config = ConfigManager.build_agent_config(base_config, deps)

      # Should preserve base config pubsub
      assert config.pubsub == custom_pubsub
    end
  end

  describe "inject_dependencies/2" do
    test "injects pubsub along with other dependencies", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup
    } do
      config = %{
        agent_id: "agent-1",
        task_id: "task-1"
      }

      deps = %{
        pubsub: pubsub,
        registry: registry,
        dynsup: dynsup
      }

      updated = ConfigManager.inject_dependencies(config, deps)

      assert updated.pubsub == pubsub
      assert updated.registry == registry
      assert updated.dynsup == dynsup
    end

    test "uses Map.put_new to avoid overwriting existing values", %{pubsub: pubsub} do
      existing_pubsub = :"existing_pubsub_#{System.unique_integer([:positive])}"

      config = %{
        agent_id: "agent-1",
        # Already has pubsub
        pubsub: existing_pubsub
      }

      deps = %{
        # Try to inject different pubsub
        pubsub: pubsub
      }

      updated = ConfigManager.inject_dependencies(config, deps)

      # Should keep existing pubsub
      assert updated.pubsub == existing_pubsub
    end
  end

  describe "propagate_to_children/2" do
    test "propagates pubsub to child agent configurations", %{pubsub: pubsub, registry: registry} do
      parent_config = %{
        agent_id: "parent-agent",
        pubsub: pubsub,
        registry: registry
      }

      child_base = %{
        agent_id: "child-agent",
        parent_pid: self(),
        task_id: "child-task"
      }

      child_config = ConfigManager.propagate_to_children(parent_config, child_base)

      # Child should inherit parent's pubsub
      assert child_config.pubsub == pubsub
      assert child_config.registry == registry
    end

    test "child can override inherited pubsub", %{pubsub: parent_pubsub} do
      child_pubsub = :"child_pubsub_#{System.unique_integer([:positive])}"
      {:ok, _} = start_supervised({Phoenix.PubSub, name: child_pubsub}, id: :child_ps)

      parent_config = %{
        agent_id: "parent-agent",
        pubsub: parent_pubsub
      }

      child_base = %{
        agent_id: "child-agent",
        parent_pid: self(),
        # Child specifies own pubsub
        pubsub: child_pubsub
      }

      child_config = ConfigManager.propagate_to_children(parent_config, child_base)

      # Should use child's pubsub
      assert child_config.pubsub == child_pubsub
    end
  end

  describe "validate_config/1 with PubSub" do
    test "accepts valid config with pubsub", %{pubsub: pubsub} do
      config = %{
        agent_id: "agent-1",
        pubsub: pubsub,
        registry: :some_registry,
        dynsup: self()
      }

      assert :ok = ConfigManager.validate_config(config)
    end

    test "accepts config without pubsub (will use default)", %{} do
      config = %{
        agent_id: "agent-1",
        registry: :some_registry,
        dynsup: self()
      }

      assert :ok = ConfigManager.validate_config(config)
    end

    test "validates pubsub is atom when present", %{} do
      config = %{
        agent_id: "agent-1",
        # Invalid type
        pubsub: "not_an_atom"
      }

      assert {:error, :invalid_pubsub} = ConfigManager.validate_config(config)
    end
  end
end
