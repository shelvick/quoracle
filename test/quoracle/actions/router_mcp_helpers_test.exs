defmodule Quoracle.Actions.Router.MCPHelpersTest do
  @moduledoc """
  Tests for Router.MCPHelpers - MCP client lazy initialization.

  WorkGroupID: fix-20260220-audit-gaps
  ARC Verification Criteria: R1-R2

  ## Findings Addressed

  The MCPHelpers.get_or_init_mcp_client/1 currently logs at :warning level
  on every MCP lazy-init path (line 21 of mcp_helpers.ex). This is debug-era
  diagnostic noise that inflates production logs. The fix is to downgrade the
  log from Logger.warning to Logger.debug (or remove it entirely).

  R1: [UNIT] WHEN MCPHelpers source is inspected THEN get_or_init_mcp_client
      does NOT use Logger.warning for diagnostic messages
  R2: [UNIT] WHEN MCPHelpers source is inspected THEN no "DEBUG" comments
      remain (debug-era noise cleanup)

  Note: Logger.warning calls are compile-time purged in test env
  (config :logger, level: :error), so runtime capture_log cannot detect them.
  Source analysis is required instead.
  """

  use ExUnit.Case, async: true

  @mcp_helpers_path Path.join([
                      File.cwd!(),
                      "lib",
                      "quoracle",
                      "actions",
                      "router",
                      "mcp_helpers.ex"
                    ])

  # ============================================================================
  # R1: No Logger.warning in get_or_init_mcp_client
  # [UNIT] WHEN MCPHelpers source is inspected THEN the diagnostic log on the
  # lazy-init path uses Logger.debug (NOT Logger.warning).
  #
  # FAILS: Current source contains Logger.warning on line 21 of mcp_helpers.ex.
  # The fix will change Logger.warning to Logger.debug.
  # ============================================================================

  describe "R1: lazy-init log level" do
    test "get_or_init_mcp_client does not use Logger.warning for diagnostics" do
      source = File.read!(@mcp_helpers_path)

      # FAILS: Source currently contains Logger.warning with MCP diagnostic info.
      # After fix, this will be Logger.debug instead.
      refute source =~ "Logger.warning",
             "MCPHelpers should not use Logger.warning for diagnostic messages. " <>
               "Found Logger.warning in source. Change to Logger.debug to prevent " <>
               "production log inflation on every MCP lazy-init path."
    end
  end

  # ============================================================================
  # R2: No stale DEBUG comments
  # [UNIT] WHEN MCPHelpers source is inspected THEN no "# DEBUG:" comments
  # remain — these are debug-era artifacts that should be cleaned up.
  #
  # FAILS: Line 18 of mcp_helpers.ex contains "# DEBUG: Track MCP client creation"
  # which is a stale debug comment that should be removed.
  # ============================================================================

  describe "R2: no stale debug comments" do
    test "source does not contain stale DEBUG comments" do
      source = File.read!(@mcp_helpers_path)

      # FAILS: Line 18 contains "# DEBUG: Track MCP client creation"
      refute source =~ "# DEBUG:",
             "MCPHelpers contains stale '# DEBUG:' comments that should be removed. " <>
               "These are debug-era artifacts from development."
    end
  end
end
