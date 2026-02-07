defmodule Quoracle.Actions.Shared.BatchValidationTest do
  @moduledoc """
  Tests for SHARED_BatchValidation v1.0 - shared validation logic for batch actions.
  WorkGroupID: feat-20260126-batch-async
  Packet: 1 (Foundation)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Shared.BatchValidation
  alias Quoracle.Actions.Schema

  # Simulate batch_sync's batchable_actions list
  @sync_batchable_actions [
    :spawn_child,
    :send_message,
    :orient,
    :todo,
    :generate_secret,
    :search_secrets,
    :dismiss_child,
    :adjust_budget,
    :record_cost,
    :file_read,
    :file_write,
    :learn_skills,
    :create_skill
  ]

  # Helper functions - defined once at module level
  defp always_eligible(_action), do: true
  defp sync_batchable_small?(action), do: action in [:file_read, :todo, :orient, :spawn_child]
  defp sync_batchable_full?(action), do: action in @sync_batchable_actions
  defp async_batchable?(action), do: action not in [:wait, :batch_sync, :batch_async]

  # Ensure Schema module is loaded so all action atoms exist
  setup do
    Schema.list_actions()
    :ok
  end

  # ARC Verification Criteria from SHARED_BatchValidation v1.0

  describe "validate_batch_size/1 (R1-R3)" do
    # R1: Empty Batch
    test "validate_batch_size rejects empty list" do
      # [UNIT] - WHEN validate_batch_size called with [] THEN returns {:error, :empty_batch}
      assert {:error, :empty_batch} = BatchValidation.validate_batch_size([])
    end

    # R2: Single Action
    test "validate_batch_size rejects single action" do
      # [UNIT] - WHEN validate_batch_size called with [single] THEN returns {:error, :batch_too_small}
      actions = [%{action: :file_read, params: %{path: "/a.txt"}}]
      assert {:error, :batch_too_small} = BatchValidation.validate_batch_size(actions)
    end

    # R3: Valid Size
    test "validate_batch_size accepts 2+ actions" do
      # [UNIT] - WHEN validate_batch_size called with 2+ actions THEN returns :ok
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{path: "/b.txt"}}
      ]

      assert :ok = BatchValidation.validate_batch_size(actions)
    end

    test "validate_batch_size accepts many actions" do
      actions =
        for i <- 1..10 do
          %{action: :file_read, params: %{path: "/file#{i}.txt"}}
        end

      assert :ok = BatchValidation.validate_batch_size(actions)
    end
  end

  describe "validate_actions_eligible/2 (R4-R7)" do
    # R4: All Eligible
    test "validate_actions_eligible accepts all eligible actions" do
      # [UNIT] - WHEN validate_actions_eligible called with all eligible actions THEN returns :ok
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :todo, params: %{operation: :list}}
      ]

      assert :ok = BatchValidation.validate_actions_eligible(actions, &always_eligible/1)
    end

    # R5: Ineligible Action
    test "validate_actions_eligible rejects ineligible action" do
      # [UNIT] - WHEN validate_actions_eligible called with ineligible action THEN returns {:error, :unbatchable_action}
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :execute_shell, params: %{command: "ls"}}
      ]

      # Using sync_batchable? which excludes execute_shell
      assert {:error, :unbatchable_action} =
               BatchValidation.validate_actions_eligible(actions, &sync_batchable_small?/1)
    end

    # R6: Nested Batch Sync
    test "validate_actions_eligible rejects nested batch_sync" do
      # [UNIT] - WHEN validate_actions_eligible called with :batch_sync THEN returns {:error, :nested_batch}
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      # Even with always_eligible, batch_sync triggers nested_batch error
      assert {:error, :nested_batch} =
               BatchValidation.validate_actions_eligible(actions, &always_eligible/1)
    end

    # R7: Nested Batch Async
    test "validate_actions_eligible rejects nested batch_async" do
      # [UNIT] - WHEN validate_actions_eligible called with :batch_async THEN returns {:error, :nested_batch}
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :batch_async, params: %{actions: []}}
      ]

      # Even with always_eligible, batch_async triggers nested_batch error
      assert {:error, :nested_batch} =
               BatchValidation.validate_actions_eligible(actions, &always_eligible/1)
    end

    test "validate_actions_eligible checks nested_batch before unbatchable" do
      # Nested batch error takes precedence
      actions = [
        %{action: :batch_sync, params: %{actions: []}}
      ]

      # sync_batchable? would also reject batch_sync, but nested_batch error comes first
      assert {:error, :nested_batch} =
               BatchValidation.validate_actions_eligible(actions, &sync_batchable_small?/1)
    end

    test "validate_actions_eligible with async eligibility allows slow actions" do
      actions = [
        %{action: :execute_shell, params: %{command: "ls"}},
        %{action: :fetch_web, params: %{url: "https://example.com"}}
      ]

      assert :ok = BatchValidation.validate_actions_eligible(actions, &async_batchable?/1)
    end

    test "validate_actions_eligible with async eligibility rejects wait" do
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :wait, params: %{wait: 5000}}
      ]

      assert {:error, :unbatchable_action} =
               BatchValidation.validate_actions_eligible(actions, &async_batchable?/1)
    end
  end

  describe "validate_action_params/1 (R8-R9)" do
    # R8: Valid Params
    test "validate_action_params accepts valid params" do
      # [UNIT] - WHEN validate_action_params called with valid params THEN returns :ok
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{path: "/b.txt"}}
      ]

      assert :ok = BatchValidation.validate_action_params(actions)
    end

    # R9: Invalid Params
    test "validate_action_params rejects invalid params with details" do
      # [UNIT] - WHEN validate_action_params called with invalid params THEN returns {:error, {:invalid_action, type, reason}}
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{}}
      ]

      # file_read requires path param
      assert {:error, {:invalid_action, :file_read, _reason}} =
               BatchValidation.validate_action_params(actions)
    end

    test "validate_action_params fails on first invalid action" do
      actions = [
        %{action: :file_read, params: %{}},
        %{action: :file_read, params: %{}}
      ]

      # Should fail on first invalid action
      assert {:error, {:invalid_action, :file_read, _reason}} =
               BatchValidation.validate_action_params(actions)
    end

    test "validate_action_params validates all action types" do
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{
          action: :send_message,
          params: %{to: :parent, content: "Hello"}
        },
        %{
          action: :orient,
          params: %{
            current_situation: "Testing",
            goal_clarity: "Clear",
            available_resources: "Many",
            key_challenges: "None",
            delegation_consideration: "Not needed"
          }
        }
      ]

      assert :ok = BatchValidation.validate_action_params(actions)
    end
  end

  describe "validate_batch/2 (R10-R11)" do
    # R10: Full Validation Success
    test "validate_batch passes all validations" do
      # [UNIT] - WHEN validate_batch called with valid batch THEN returns :ok
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{path: "/b.txt"}}
      ]

      assert :ok = BatchValidation.validate_batch(actions, &async_batchable?/1)
    end

    # R11: Full Validation Fails Fast
    test "validate_batch fails fast in order" do
      # [UNIT] - WHEN validate_batch called THEN fails on first error (size before eligibility before params)

      # Test 1: Size check fails first (empty batch)
      assert {:error, :empty_batch} = BatchValidation.validate_batch([], &async_batchable?/1)

      # Test 2: Size check fails (single action)
      actions_single = [%{action: :file_read, params: %{path: "/a.txt"}}]

      assert {:error, :batch_too_small} =
               BatchValidation.validate_batch(actions_single, &async_batchable?/1)

      # Test 3: Eligibility check fails (after size passes)
      actions_ineligible = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :wait, params: %{wait: 5000}}
      ]

      assert {:error, :unbatchable_action} =
               BatchValidation.validate_batch(actions_ineligible, &async_batchable?/1)

      # Test 4: Params check fails (after size and eligibility pass)
      actions_invalid_params = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{}}
      ]

      assert {:error, {:invalid_action, :file_read, _reason}} =
               BatchValidation.validate_batch(actions_invalid_params, &async_batchable?/1)
    end

    test "validate_batch with nested batch fails at eligibility" do
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      assert {:error, :nested_batch} =
               BatchValidation.validate_batch(actions, &async_batchable?/1)
    end
  end

  describe "integration with batch_sync eligibility" do
    test "validate_batch rejects slow actions for batch_sync" do
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :execute_shell, params: %{command: "ls"}}
      ]

      assert {:error, :unbatchable_action} =
               BatchValidation.validate_batch(actions, &sync_batchable_full?/1)
    end

    test "validate_batch accepts fast actions for batch_sync" do
      actions = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :file_read, params: %{path: "/b.txt"}}
      ]

      assert :ok = BatchValidation.validate_batch(actions, &sync_batchable_full?/1)
    end
  end

  describe "integration with batch_async eligibility" do
    test "validate_batch accepts slow actions for batch_async" do
      actions = [
        %{action: :execute_shell, params: %{command: "ls"}},
        %{action: :fetch_web, params: %{url: "https://example.com"}}
      ]

      assert :ok = BatchValidation.validate_batch(actions, &async_batchable?/1)
    end

    test "validate_batch rejects only excluded actions for batch_async" do
      # wait is excluded
      actions_wait = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :wait, params: %{wait: 5000}}
      ]

      assert {:error, :unbatchable_action} =
               BatchValidation.validate_batch(actions_wait, &async_batchable?/1)

      # batch_sync is excluded (nested_batch error)
      actions_sync = [
        %{action: :file_read, params: %{path: "/a.txt"}},
        %{action: :batch_sync, params: %{actions: []}}
      ]

      assert {:error, :nested_batch} =
               BatchValidation.validate_batch(actions_sync, &async_batchable?/1)
    end
  end
end
