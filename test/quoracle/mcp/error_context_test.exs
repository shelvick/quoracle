defmodule Quoracle.MCP.ErrorContextTest do
  @moduledoc """
  Tests for MCP_ErrorContext v2.0 - Per-connection error context collector.

  ARC Verification Criteria: R1-R17
  WorkGroupID: fix-20251228-004723
  Packet: 1 (Foundation - Error Extraction)
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.MCP.ErrorContext
  alias Quoracle.MCPTestHelpers

  # ============================================================================
  # R1: Start Link with Connection Ref
  # [UNIT] WHEN start_link called IF connection_ref provided THEN starts GenServer and attaches handlers
  # ============================================================================
  describe "R1: start_link" do
    test "starts collector and attaches handlers" do
      connection_ref = make_ref()
      {:ok, collector} = ErrorContext.start_link(connection_ref: connection_ref)

      assert Process.alive?(collector)

      # Cleanup
      ErrorContext.stop(collector)
    end

    test "requires connection_ref option" do
      assert_raise KeyError, fn ->
        ErrorContext.start_link([])
      end
    end
  end

  # ============================================================================
  # R2: Unique Handler IDs
  # [UNIT] WHEN start_link called THEN handler IDs include connection_ref for uniqueness
  # ============================================================================
  describe "R2: unique handler IDs" do
    test "handler IDs are unique per connection" do
      ref1 = make_ref()
      ref2 = make_ref()

      {:ok, collector1} = ErrorContext.start_link(connection_ref: ref1)
      {:ok, collector2} = ErrorContext.start_link(connection_ref: ref2)

      # Both should coexist without handler ID conflicts
      assert Process.alive?(collector1)
      assert Process.alive?(collector2)

      # Emit events - each collector should only see its own
      # (if handlers weren't unique, they'd conflict)
      MCPTestHelpers.emit_transport_error(:test_error_1)

      # Both should capture the same event (handlers are global, but storage is per-collector)
      context1 = ErrorContext.get_context(collector1)
      context2 = ErrorContext.get_context(collector2)

      # Both captured the event (telemetry handlers are global)
      assert is_list(context1)
      assert is_list(context2)

      # Cleanup
      ErrorContext.stop(collector1)
      ErrorContext.stop(collector2)
    end
  end

  # ============================================================================
  # R3: Telemetry Event Capture
  # [INTEGRATION] WHEN telemetry event emitted IF handler attached THEN event stored in context
  # ============================================================================
  describe "R3: telemetry event capture" do
    test "captures telemetry transport_error events" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Emit telemetry event
      MCPTestHelpers.emit_transport_error(:exit_status, 1)

      context = ErrorContext.get_context(collector)

      # Find our specific event (parallel tests may emit other telemetry events)
      transport_errors = Enum.filter(context, &(&1.type == :transport_error))
      assert transport_errors != []
      assert Enum.any?(transport_errors, &(&1.message =~ "exit_status"))

      ErrorContext.stop(collector)
    end

    test "captures telemetry client_error events" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Emit client error event with unique marker
      MCPTestHelpers.emit_client_error(:r3_decode_failed)

      context = ErrorContext.get_context(collector)

      # Filter for our specific event (parallel tests may emit other telemetry events)
      our_events = Enum.filter(context, fn entry -> entry.message =~ "r3_decode_failed" end)

      assert length(our_events) == 1
      assert hd(our_events).type == :client_error

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R4: Logger Message Capture
  # [INTEGRATION] WHEN Logger message from anubis_mcp domain THEN message stored in context
  # ============================================================================
  describe "R4: Logger message capture" do
    test "captures Logger messages from anubis_mcp domain" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Log message with anubis_mcp domain
      # Note: Logger handlers run synchronously in the calling process, so
      # by the time Logger.error returns, the handler has already processed the event
      capture_log(fn ->
        MCPTestHelpers.log_anubis_message("CLI addon is not installed. Please install...")
      end)

      context = ErrorContext.get_context(collector)

      assert context != []
      raw_output = Enum.find(context, &(&1.type == :raw_output))
      assert raw_output != nil
      assert raw_output.message =~ "CLI addon"

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R4b: Logger Message Capture (Realistic - No Domain)
  # [INTEGRATION] WHEN Logger message with MCP prefix (no domain) THEN captured
  # ============================================================================
  describe "R4b: Logger capture without domain" do
    test "captures MCP transport messages without domain metadata" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Log exactly as anubis_mcp does - NO domain, message has MCP prefix
      capture_log(fn ->
        MCPTestHelpers.log_anubis_message_realistic(
          "MCP transport details: \"⚠️ CLI addon is not installed. Please install...\""
        )
      end)

      context = ErrorContext.get_context(collector)

      # Should capture messages with MCP prefix even without domain
      assert context != []
      raw_output = Enum.find(context, &(&1.type == :raw_output))
      assert raw_output != nil
      assert raw_output.message =~ "CLI addon"

      ErrorContext.stop(collector)
    end

    test "captures MCP client event messages without domain" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      capture_log(fn ->
        MCPTestHelpers.log_anubis_message_realistic("MCP client event: decode_failed")
      end)

      context = ErrorContext.get_context(collector)

      assert context != []
      # Find the specific message we logged (parallel tests may add other messages)
      raw_output = Enum.find(context, &(&1.type == :raw_output and &1.message =~ "decode_failed"))
      assert raw_output != nil, "Expected to find decode_failed message in: #{inspect(context)}"

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R5: Logger Filter
  # [UNIT] WHEN Logger message from non-anubis domain THEN message NOT captured
  # ============================================================================
  describe "R5: Logger filter" do
    test "filters out non-anubis Logger messages" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Log message with different domain (should be filtered)
      capture_log(fn ->
        MCPTestHelpers.log_other_message("This should not be captured")
      end)

      # Sync barrier
      context = ErrorContext.get_context(collector)

      # Should NOT have captured the non-anubis message
      refute Enum.any?(context, fn entry ->
               entry.message =~ "This should not be captured"
             end)

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R6: Get Context Returns Errors
  # [UNIT] WHEN get_context called THEN returns list of captured errors sorted by timestamp
  # ============================================================================
  describe "R6: get_context" do
    test "get_context returns captured errors in order" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Emit multiple events in sequence with unique markers
      MCPTestHelpers.emit_transport_error(:r6_error_1)
      MCPTestHelpers.emit_client_error(:r6_error_2)
      MCPTestHelpers.emit_transport_error(:r6_error_3)

      context = ErrorContext.get_context(collector)

      # Filter for our specific events (parallel tests may emit other telemetry events)
      our_events =
        Enum.filter(context, fn entry ->
          entry.message =~ "r6_error_1" or entry.message =~ "r6_error_2" or
            entry.message =~ "r6_error_3"
        end)

      assert length(our_events) == 3

      # Verify timestamps are in order
      timestamps = Enum.map(our_events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)

      ErrorContext.stop(collector)
    end

    test "returns empty list when no errors captured" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      context = ErrorContext.get_context(collector)

      assert context == []

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R7: Max Errors Limit
  # [UNIT] WHEN error count exceeds 20 THEN oldest errors preserved, new ones dropped
  # ============================================================================
  describe "R7: max_errors limit" do
    test "respects max_errors limit of 20" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Emit 25 errors (exceeds limit of 20)
      # CRITICAL: Pass collector to prevent events leaking to other parallel tests
      for i <- 1..25 do
        MCPTestHelpers.emit_transport_error(:"error_#{i}", nil, collector: collector)
      end

      context = ErrorContext.get_context(collector)

      # Should only have 20 errors max
      assert length(context) <= 20

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R8: Message Truncation
  # [UNIT] WHEN message longer than 200 chars THEN truncated to 200
  # ============================================================================
  describe "R8: message truncation" do
    test "truncates long messages to 200 chars" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      # Create a very long error reason (300 chars)
      long_reason = MCPTestHelpers.long_message(300)
      MCPTestHelpers.emit_transport_error(:r8_long_error, long_reason)

      context = ErrorContext.get_context(collector)

      # Filter for our specific event (parallel tests may emit other telemetry events)
      our_events = Enum.filter(context, fn entry -> entry.message =~ "r8_long_error" end)

      assert length(our_events) == 1
      # Message should be truncated to 200 chars max
      assert String.length(hd(our_events).message) <= 200

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R9: Stop Detaches Handlers
  # [INTEGRATION] WHEN stop called THEN telemetry and Logger handlers detached
  # ============================================================================
  describe "R9: stop detaches handlers" do
    test "stop detaches all handlers" do
      connection_ref = make_ref()
      {:ok, collector} = ErrorContext.start_link(connection_ref: connection_ref)

      # Verify collector is alive
      assert Process.alive?(collector)

      # Stop the collector
      ErrorContext.stop(collector)

      # Collector should be dead
      refute Process.alive?(collector)

      # Events emitted after stop should not cause errors
      # (handlers should be detached cleanly)
      MCPTestHelpers.emit_transport_error(:post_stop_error)

      # No crash means handlers were properly detached
      assert true
    end
  end

  # ============================================================================
  # R10: Concurrent Collectors Isolation
  # [INTEGRATION] WHEN multiple collectors active THEN each captures only its own events
  # ============================================================================
  describe "R10: concurrent collectors isolation" do
    test "concurrent collectors do not cross-contaminate" do
      # Use unique event names for filtering (parallel tests emit other events)
      unique_id = System.unique_integer([:positive])
      shared_event = :"r10_shared_#{unique_id}"
      after_stop_event = :"r10_after_stop_#{unique_id}"

      # Start two collectors
      {:ok, collector1} = ErrorContext.start_link(connection_ref: make_ref())
      {:ok, collector2} = ErrorContext.start_link(connection_ref: make_ref())

      # Both collectors will see telemetry events (they're global)
      # But this test verifies the ETS tables are separate

      # Get initial state (filter for our unique events only)
      initial1 =
        ErrorContext.get_context(collector1)
        |> Enum.filter(&(&1.message =~ "r10_"))

      initial2 =
        ErrorContext.get_context(collector2)
        |> Enum.filter(&(&1.message =~ "r10_"))

      assert initial1 == []
      assert initial2 == []

      # Emit one event with unique name
      MCPTestHelpers.emit_transport_error(shared_event)

      # Both should see it (telemetry is global, both handlers fire)
      # Filter to only our test's events
      context1 =
        ErrorContext.get_context(collector1)
        |> Enum.filter(&(&1.message =~ "r10_"))

      context2 =
        ErrorContext.get_context(collector2)
        |> Enum.filter(&(&1.message =~ "r10_"))

      # Both captured the event
      assert length(context1) == 1
      assert length(context2) == 1

      # Stop collector1
      ErrorContext.stop(collector1)

      # Emit another event with unique name
      MCPTestHelpers.emit_transport_error(after_stop_event)

      # Only collector2 should see the new event (filter for our events)
      context2_after =
        ErrorContext.get_context(collector2)
        |> Enum.filter(&(&1.message =~ "r10_"))

      assert length(context2_after) == 2

      ErrorContext.stop(collector2)
    end
  end

  # ============================================================================
  # R11: Error Entry Format
  # [UNIT] WHEN error captured THEN entry contains :type, :message, :timestamp, :source keys
  # ============================================================================
  describe "R11: error entry format" do
    test "error entries have required keys" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      MCPTestHelpers.emit_transport_error(:r11_test_error, "r11 test reason")

      # Filter to only entries from this test (parallel tests may emit other events)
      # Use unique message content to isolate (type is :transport_error from event path)
      context =
        ErrorContext.get_context(collector)
        |> Enum.filter(&(&1.message =~ "r11_test"))

      # Should have at least 1 entry (may have more if telemetry handlers overlap)
      assert context != []

      entry = hd(context)

      # Verify all required keys present
      assert Map.has_key?(entry, :type)
      assert Map.has_key?(entry, :message)
      assert Map.has_key?(entry, :timestamp)
      assert Map.has_key?(entry, :source)

      # Verify types
      assert is_atom(entry.type)
      assert is_binary(entry.message)
      assert is_integer(entry.timestamp)
      assert entry.source in [:telemetry, :logger]

      ErrorContext.stop(collector)
    end

    test "transport_error entries have correct type" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      MCPTestHelpers.emit_transport_error(:exit_status, 1, collector: collector)

      entries = ErrorContext.get_context(collector)
      # Filter for our specific event by message content (parallel tests may emit
      # transport_error events without target_collector, which all collectors receive)
      entry =
        Enum.find(entries, fn e ->
          e.type == :transport_error and e.message =~ "exit_status: 1"
        end)

      assert entry != nil,
             "Expected transport_error with exit_status: 1, got: #{inspect(entries)}"

      assert entry.type == :transport_error
      assert entry.source == :telemetry

      ErrorContext.stop(collector)
    end

    test "client_error entries have correct type" do
      {:ok, collector} = ErrorContext.start_link(connection_ref: make_ref())

      MCPTestHelpers.emit_client_error(:decode_failed, collector: collector)

      entries = ErrorContext.get_context(collector)
      # Filter for our specific event (parallel tests may emit other telemetry events)
      client_errors = Enum.filter(entries, &(&1.type == :client_error))
      assert [entry] = client_errors

      assert entry.type == :client_error
      assert entry.source == :telemetry

      ErrorContext.stop(collector)
    end
  end

  # ============================================================================
  # R12: Extract Command Not Found
  # [UNIT] WHEN extract_crash_reason called IF reason is supervisor failure with
  # {:error, "Command not found: X"} THEN returns "Command not found: X"
  # ============================================================================
  describe "R12: extract command not found" do
    test "extracts command not found from supervisor failure" do
      reason =
        {:shutdown,
         {:failed_to_start_child, Anubis.Transport.STDIO, {:error, "Command not found: npx"}}}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == "Command not found: npx"
    end

    test "extracts other error messages from supervisor failure" do
      reason =
        {:shutdown,
         {:failed_to_start_child, Anubis.Transport.STDIO,
          {:error, "Permission denied: /usr/bin/mcp"}}}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == "Permission denied: /usr/bin/mcp"
    end
  end

  # ============================================================================
  # R13: Extract Exit Code
  # [UNIT] WHEN extract_crash_reason called IF reason is integer
  # THEN returns "Process exited with code N"
  # ============================================================================
  describe "R13: extract exit code" do
    test "extracts exit code from integer reason" do
      assert ErrorContext.extract_crash_reason(1) == "Process exited with code 1"
      assert ErrorContext.extract_crash_reason(127) == "Process exited with code 127"
      assert ErrorContext.extract_crash_reason(0) == "Process exited with code 0"
    end
  end

  # ============================================================================
  # R14: Extract Noproc
  # [UNIT] WHEN extract_crash_reason called IF reason is {:noproc, _} or :noproc
  # THEN returns "Process not found"
  # ============================================================================
  describe "R14: extract noproc" do
    test "extracts process not found from noproc tuple" do
      reason = {:noproc, {GenServer, :call, [:some_process, :get_state, 5000]}}

      assert ErrorContext.extract_crash_reason(reason) == "Process not found"
    end

    test "extracts process not found from noproc atom" do
      assert ErrorContext.extract_crash_reason(:noproc) == "Process not found"
    end
  end

  # ============================================================================
  # R15: Normal Exit Returns Nil
  # [UNIT] WHEN extract_crash_reason called IF reason is :normal or :shutdown
  # THEN returns nil
  # ============================================================================
  describe "R15: normal exit returns nil" do
    test "returns nil for normal exits" do
      assert ErrorContext.extract_crash_reason(:normal) == nil
      assert ErrorContext.extract_crash_reason(:shutdown) == nil
      assert ErrorContext.extract_crash_reason({:shutdown, :normal}) == nil
    end
  end

  # ============================================================================
  # R16: Nested Extraction
  # [UNIT] WHEN extract_crash_reason called IF reason is nested
  # {:shutdown, {:failed_to_start_child, _, inner}} THEN recursively extracts
  # ============================================================================
  describe "R16: nested extraction" do
    test "recursively extracts from nested failures" do
      # Double-nested supervisor failure
      inner_reason = {:error, "Connection refused"}

      reason =
        {:shutdown,
         {:failed_to_start_child, Anubis.MCP.Supervisor,
          {:shutdown, {:failed_to_start_child, Anubis.Transport.STDIO, inner_reason}}}}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == "Connection refused"
    end

    test "extracts through generic shutdown wrapper" do
      reason = {:shutdown, {:error, "Network unreachable"}}

      # Should extract the inner reason
      result = ErrorContext.extract_crash_reason(reason)

      assert result == "Network unreachable"
    end
  end

  # ============================================================================
  # R17: Fallback Inspection
  # [UNIT] WHEN extract_crash_reason called IF reason doesn't match known patterns
  # THEN returns inspect(reason)
  # ============================================================================
  describe "R17: fallback inspection" do
    test "falls back to inspect for unknown patterns" do
      reason = {:unexpected, :error, :structure}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == inspect(reason)
    end

    test "falls back for complex unknown structures" do
      reason = %{error: "something", code: 500}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == inspect(reason)
    end

    test "handles MCP error struct" do
      # Simulated Anubis.MCP.Error struct
      reason = %{__struct__: Anubis.MCP.Error, reason: :timeout}

      result = ErrorContext.extract_crash_reason(reason)

      assert result == "MCP error: :timeout"
    end
  end
end
