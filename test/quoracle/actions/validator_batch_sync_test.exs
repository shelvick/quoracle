defmodule Quoracle.Actions.ValidatorBatchSyncTest do
  @moduledoc """
  Tests for ACTION_Validator v9.0 - batch_sync validation rules.
  WorkGroupID: feat-20260123-batch-sync
  Packet: 1 (Schema Foundation)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Validator
  alias Quoracle.Actions.Schema

  # Ensure Schema module is loaded so all action atoms exist
  setup do
    Schema.list_actions()
    :ok
  end

  # ARC Verification Criteria from ACTION_Validator v9.0

  describe "batch_sync validation (v9.0)" do
    # R21: Batch Length Minimum - Empty batch
    test "batch_sync rejects empty batch" do
      # [UNIT] - WHEN validate called for batch_sync with 0 actions THEN returns {:error, :batch_too_short}
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => []
        },
        "reasoning" => "Testing empty batch"
      }

      assert {:error, :batch_too_short} = Validator.validate_action(action_json)
    end

    # R21: Batch Length Minimum - Single action
    test "batch_sync rejects single-action batch" do
      # [UNIT] - WHEN validate called for batch_sync with 1 action THEN returns {:error, :batch_too_short}
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}}
          ]
        },
        "reasoning" => "Testing single action batch"
      }

      assert {:error, :batch_too_short} = Validator.validate_action(action_json)
    end

    # R22: Batch Length Valid
    test "batch_sync accepts two-action batch" do
      # [UNIT] - WHEN validate called for batch_sync with 2+ actions THEN length check passes
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
          ]
        },
        "reasoning" => "Testing valid batch"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
      assert length(validated.params.actions) == 2
    end

    # R23: Nested Batch Rejection
    test "batch_sync rejects nested batch_sync" do
      # [UNIT] - WHEN validate called for batch_sync containing batch_sync THEN returns {:error, :nested_batch}
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "batch_sync",
              "params" => %{
                "actions" => [
                  %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
                ]
              }
            }
          ]
        },
        "reasoning" => "Testing nested batch"
      }

      assert {:error, :nested_batch} = Validator.validate_action(action_json)
    end

    # R24: Non-Batchable Action Rejection
    test "batch_sync rejects non-batchable action" do
      # [UNIT] - WHEN validate called for batch_sync containing :wait THEN returns {:error, {:not_batchable, :wait}}
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "wait", "params" => %{"wait" => 5000}}
          ]
        },
        "reasoning" => "Testing non-batchable action"
      }

      assert {:error, {:not_batchable, :wait}} = Validator.validate_action(action_json)
    end

    # R25: All Batchable Actions Accepted
    test "batch_sync accepts all batchable actions" do
      # [UNIT] - WHEN validate called for batch_sync with only batchable actions THEN batchable check passes
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{"path" => "/b.txt"}},
            %{
              "action" => "orient",
              "params" => %{
                "current_situation" => "Testing",
                "goal_clarity" => "Clear",
                "available_resources" => "Many",
                "key_challenges" => "None",
                "delegation_consideration" => "Not needed"
              }
            }
          ]
        },
        "reasoning" => "Testing multiple batchable actions"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
      assert length(validated.params.actions) == 3
    end

    # R26: Each Action Validated
    test "batch_sync validates each action's params" do
      # [UNIT] - WHEN validate called for batch_sync THEN each action validated against its schema
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/valid/path.txt"}},
            %{"action" => "send_message", "params" => %{"to" => "parent", "content" => "Hello"}}
          ]
        },
        "reasoning" => "Testing per-action validation"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync

      # Verify params were validated and atomized
      [first, second] = validated.params.actions
      assert first.action == :file_read
      assert first.params.path == "/valid/path.txt"
      assert second.action == :send_message
      assert second.params.to == :parent
    end

    # R27: Action Validation Failure Propagation
    test "batch_sync fails if any action invalid" do
      # [UNIT] - WHEN any action in batch fails validation THEN batch validation fails with action context
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{}}
          ]
        },
        "reasoning" => "Testing action validation failure"
      }

      # file_read requires path param
      assert {:error, {:action_invalid, :file_read, :missing_required_param}} =
               Validator.validate_action(action_json)
    end

    # R28: Eager Validation
    test "batch validation is eager not lazy" do
      # [INTEGRATION] - WHEN batch_sync validated THEN ALL validation happens before execution starts
      # This test verifies that validation errors are detected upfront, not during execution

      # Invalid action at position 1 should be caught immediately
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "execute_shell", "params" => %{"command" => "ls"}}
          ]
        },
        "reasoning" => "Testing eager validation"
      }

      # execute_shell is not batchable - should fail before any execution
      assert {:error, {:not_batchable, :execute_shell}} = Validator.validate_action(action_json)
    end
  end

  describe "batch_sync non-batchable actions" do
    test "rejects execute_shell in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "execute_shell", "params" => %{"command" => "ls"}}
          ]
        }
      }

      assert {:error, {:not_batchable, :execute_shell}} = Validator.validate_action(action_json)
    end

    test "rejects fetch_web in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "fetch_web", "params" => %{"url" => "https://example.com"}}
          ]
        }
      }

      assert {:error, {:not_batchable, :fetch_web}} = Validator.validate_action(action_json)
    end

    test "rejects call_api in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "call_api",
              "params" => %{
                "api_type" => "rest",
                "url" => "https://api.example.com"
              }
            }
          ]
        }
      }

      assert {:error, {:not_batchable, :call_api}} = Validator.validate_action(action_json)
    end

    test "rejects answer_engine in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "answer_engine", "params" => %{"prompt" => "Hello"}}
          ]
        }
      }

      assert {:error, {:not_batchable, :answer_engine}} = Validator.validate_action(action_json)
    end
  end

  describe "batch_sync valid batchable actions" do
    test "accepts spawn_child in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "spawn_child",
              "params" => %{
                "task_description" => "Test task",
                "success_criteria" => "Complete",
                "immediate_context" => "Testing",
                "approach_guidance" => "Standard",
                "profile" => "test"
              }
            }
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
    end

    test "accepts send_message in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "send_message",
              "params" => %{
                "to" => "parent",
                "content" => "Hello"
              }
            }
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
    end

    test "accepts file_write in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "file_write",
              "params" => %{
                "path" => "/b.txt",
                "content" => "Hello",
                "mode" => "write"
              }
            }
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
    end

    test "accepts generate_secret in batch" do
      action_json = %{
        "action" => "batch_sync",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "generate_secret",
              "params" => %{
                "name" => "test_secret"
              }
            }
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_sync
    end
  end

  describe "batch_sync validate_params/2" do
    test "validates batch_sync params directly" do
      params = %{
        "actions" => [
          %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
          %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
        ]
      }

      assert {:ok, validated} = Validator.validate_params(:batch_sync, params)
      assert is_list(validated.actions)
      assert length(validated.actions) == 2
    end

    test "validate_params fails for empty actions" do
      params = %{"actions" => []}

      assert {:error, :batch_too_short} = Validator.validate_params(:batch_sync, params)
    end
  end
end
