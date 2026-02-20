defmodule Quoracle.Agent.DispatchTaskCrashCommentaryTest do
  @moduledoc """
  Tests for FIX_DispatchTaskCrashPropagation audit evidence quality.

  WorkGroupID: fix-20260220-audit-gaps

  ## Findings Addressed

  The dispatch_task_crash_test.exs still contains stale "FAILS: no crash
  injection mechanism exists" commentary even though crash-injection and
  outer rescue/catch are implemented and tests pass. This is misleading
  audit evidence that suggests the mechanism doesn't exist when it does.

  R1: [UNIT] WHEN dispatch_task_crash_test.exs source is inspected THEN
      no stale "FAILS:" commentary referencing non-existent mechanisms remains
  R2: [UNIT] WHEN dispatch_task_crash_test.exs moduledoc is inspected THEN
      "Why Tests Fail Without Fix" section does not describe the mechanism
      as non-existent
  """

  use ExUnit.Case, async: true

  @crash_test_path Path.join([
                     File.cwd!(),
                     "test",
                     "quoracle",
                     "agent",
                     "dispatch_task_crash_test.exs"
                   ])

  # ============================================================================
  # R1: No stale "FAILS:" commentary about non-existent mechanisms
  # [UNIT] WHEN source is inspected THEN comments do not claim the crash
  # injection mechanism "doesn't exist" or "is ignored"
  #
  # FAILS: Multiple comments throughout the file contain phrases like:
  #   "FAILS: No crash injection mechanism exists"
  #   "crash_in_task key is ignored"
  #   "mechanism doesn't exist"
  # These are stale because the mechanism IS implemented and tests pass.
  # ============================================================================

  describe "R1: no stale FAILS commentary" do
    test "source does not contain stale commentary claiming mechanism doesn't exist" do
      source = File.read!(@crash_test_path)

      # FAILS: Multiple occurrences of "FAILS:" with stale descriptions exist.
      # The crash injection mechanism IS implemented (action_executor.ex lines
      # 216-222) and tests pass. These comments are misleading audit evidence.
      refute source =~ "FAILS: No crash injection mechanism exists",
             "dispatch_task_crash_test.exs contains stale commentary claiming " <>
               "'No crash injection mechanism exists' but the mechanism IS implemented. " <>
               "Remove or update these stale FAILS comments."
    end
  end

  # ============================================================================
  # R2: Moduledoc does not describe mechanism as absent
  # [UNIT] WHEN moduledoc section "Why Tests Fail Without Fix" is inspected
  # THEN it does not claim the :crash_in_task key "is ignored" since it is
  # now properly handled by ActionExecutor.
  #
  # FAILS: The moduledoc contains "The :crash_in_task state key is ignored"
  # on line 25, which is inaccurate since the mechanism is implemented.
  # ============================================================================

  describe "R2: moduledoc accuracy" do
    test "moduledoc does not claim crash_in_task key is ignored" do
      source = File.read!(@crash_test_path)

      # FAILS: Line 25 contains "The :crash_in_task state key is ignored"
      # but the key IS handled by ActionExecutor (lines 216-222).
      refute source =~ "The :crash_in_task state key is ignored",
             "dispatch_task_crash_test.exs moduledoc claims ':crash_in_task state key " <>
               "is ignored' but it IS handled by ActionExecutor. Update the moduledoc " <>
               "to accurately reflect the implemented state."
    end
  end
end
