defmodule Quoracle.Agent.ConfigManagerForceReflectionTest do
  @moduledoc """
  Tests for force_reflection extraction in ConfigManager (ARC R32-R33).
  WorkGroupID: feat-20260225-forced-reflection
  """
  use Quoracle.DataCase, async: true
  alias Quoracle.Agent.ConfigManager
  import Test.IsolationHelpers

  test "normalize_config extracts force_reflection" do
    config =
      ConfigManager.normalize_config(%{agent_id: "test", test_mode: true, force_reflection: true})

    assert config.force_reflection == true
  end

  test "setup_agent includes force_reflection in state" do
    deps = create_isolated_deps()

    config = %{
      agent_id: "test",
      parent_pid: self(),
      test_mode: true,
      force_reflection: true,
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub
    }

    state =
      ConfigManager.setup_agent(config,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      )

    assert state.force_reflection == true
  end
end
