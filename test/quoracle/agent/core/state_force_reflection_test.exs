defmodule Quoracle.Agent.Core.StateForceReflectionTest do
  @moduledoc """
  Tests for force_reflection field in Core.State (ARC R75-R77).
  WorkGroupID: feat-20260225-forced-reflection
  """
  use ExUnit.Case, async: true
  alias Quoracle.Agent.Core.State

  test "State.new/1 includes force_reflection from config" do
    state =
      State.new(%{
        agent_id: "test",
        registry: self(),
        dynsup: self(),
        pubsub: :test_pubsub,
        force_reflection: true
      })

    assert state.force_reflection == true
  end

  test "force_reflection defaults to false" do
    state = State.new(%{agent_id: "test", registry: self(), dynsup: self(), pubsub: :test_pubsub})
    assert state.force_reflection == false
  end
end
