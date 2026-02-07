defmodule Quoracle.Test.Mocks do
  @moduledoc """
  Mock definitions for testing
  """

  # Define mock for MCP anubis client (MCP_Client tests)
  Hammox.defmock(Quoracle.MCP.AnubisMock, for: Quoracle.MCP.AnubisBehaviour)

  # Define mocks for agent core dependencies (these behaviours don't exist yet)
  # Hammox.defmock(Quoracle.ConsensusMock, for: Quoracle.Agent.ConsensusBehaviour)
  # Hammox.defmock(Quoracle.RouterMock, for: Quoracle.Action.RouterBehaviour)
  # Mox.defmock(Quoracle.Models.MockModelQuery, for: Quoracle.Models.ModelQueryBehaviour)
end
