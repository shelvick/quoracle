defmodule Quoracle.Actions.ValidatorBatchAsyncTest do
  @moduledoc """
  Tests for ACTION_Validator v11.0 - batch_async validation rules.
  WorkGroupID: feat-20260126-batch-async
  Packet: 1 (Validation)
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Validator
  alias Quoracle.Actions.Schema

  # Ensure Schema module is loaded so all action atoms exist
  setup do
    Schema.list_actions()
    :ok
  end

  # ARC Verification Criteria from ACTION_Validator v11.0

  describe "batch_async validation (v11.0)" do
    # R1: Validate Empty Batch
    test "batch_async rejects empty actions list" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: []}) THEN returns {:error, :empty_batch}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => []
        },
        "reasoning" => "Testing empty batch"
      }

      assert {:error, :empty_batch} = Validator.validate_action(action_json)
    end

    # R2: Validate Single Action
    test "batch_async rejects single action" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [single]}) THEN returns {:error, :batch_too_small}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}}
          ]
        },
        "reasoning" => "Testing single action batch"
      }

      assert {:error, :batch_too_small} = Validator.validate_action(action_json)
    end

    # R3: Validate Valid Batch
    test "batch_async accepts valid batch" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [a, b]}) with valid actions THEN returns :ok
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
          ]
        },
        "reasoning" => "Testing valid batch"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
      assert length(validated.params.actions) == 2
    end

    # R4: Reject Wait Action
    test "batch_async rejects :wait action" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [%{action: :wait, ...}]}) THEN returns {:error, :unbatchable_action}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "wait", "params" => %{"wait" => 5000}}
          ]
        },
        "reasoning" => "Testing wait rejection"
      }

      assert {:error, :unbatchable_action} = Validator.validate_action(action_json)
    end

    # R5: Reject batch_sync Action
    test "batch_async rejects nested batch_sync" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [%{action: :batch_sync, ...}]}) THEN returns {:error, :nested_batch}
      action_json = %{
        "action" => "batch_async",
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
        "reasoning" => "Testing nested batch_sync rejection"
      }

      assert {:error, :nested_batch} = Validator.validate_action(action_json)
    end

    # R6: Reject batch_async Action
    test "batch_async rejects nested batch_async" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [%{action: :batch_async, ...}]}) THEN returns {:error, :nested_batch}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "batch_async",
              "params" => %{
                "actions" => [
                  %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
                ]
              }
            }
          ]
        },
        "reasoning" => "Testing nested batch_async rejection"
      }

      assert {:error, :nested_batch} = Validator.validate_action(action_json)
    end

    # R7: Accept All Other Actions
    test "batch_async accepts slow actions (unlike batch_sync)" do
      # [UNIT] - WHEN validate(:batch_async, ...) with execute_shell, fetch_web, etc. THEN returns :ok
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "execute_shell", "params" => %{"command" => "ls -la"}},
            %{"action" => "fetch_web", "params" => %{"url" => "https://example.com"}}
          ]
        },
        "reasoning" => "Testing slow actions acceptance"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
      assert length(validated.params.actions) == 2
    end

    # R8: Validate Wait Param Type
    test "batch_async rejects non-boolean wait" do
      # [UNIT] - WHEN validate(:batch_async, %{wait: "string"}) THEN returns {:error, :invalid_wait_type}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
          ],
          "wait" => "invalid"
        },
        "reasoning" => "Testing invalid wait type"
      }

      assert {:error, :invalid_wait_type} = Validator.validate_action(action_json)
    end

    # R9: Wait Param Optional
    test "batch_async accepts missing wait param" do
      # [UNIT] - WHEN validate(:batch_async, %{actions: [...]}) without wait THEN returns :ok
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
          ]
        },
        "reasoning" => "Testing optional wait"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
    end

    # R10: Validate Sub-Action Params
    test "batch_async validates sub-action params" do
      # [UNIT] - WHEN sub-action has invalid params THEN returns {:error, {:invalid_action, type, reason}}
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "file_read", "params" => %{}}
          ]
        },
        "reasoning" => "Testing sub-action param validation"
      }

      # file_read requires path param
      assert {:error, {:invalid_action, :file_read, :missing_required_param}} =
               Validator.validate_action(action_json)
    end
  end

  describe "batch_async accepts slow/async actions" do
    test "accepts execute_shell in batch" do
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "execute_shell", "params" => %{"command" => "ls"}}
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
    end

    test "accepts fetch_web in batch" do
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "fetch_web", "params" => %{"url" => "https://example.com"}}
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
    end

    test "accepts call_api in batch" do
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{
              "action" => "call_api",
              "params" => %{
                "api_type" => "rest",
                "url" => "https://api.example.com",
                "method" => "GET"
              }
            }
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
    end

    test "accepts answer_engine in batch" do
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
            %{"action" => "answer_engine", "params" => %{"prompt" => "Hello"}}
          ]
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async
    end
  end

  describe "batch_async validate_params/2" do
    test "validates batch_async params directly" do
      params = %{
        "actions" => [
          %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
          %{"action" => "file_read", "params" => %{"path" => "/b.txt"}}
        ]
      }

      assert {:ok, validated} = Validator.validate_params(:batch_async, params)
      assert is_list(validated.actions)
      assert length(validated.actions) == 2
    end

    test "validate_params fails for empty actions" do
      params = %{"actions" => []}

      assert {:error, :empty_batch} = Validator.validate_params(:batch_async, params)
    end
  end

  describe "batch_async string key handling (LLM responses)" do
    test "handles string keys in actions list" do
      action_json = %{
        "action" => "batch_async",
        "params" => %{
          "actions" => [
            %{"action" => "file_read", "params" => %{"path" => "/a.txt"}},
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
        "reasoning" => "Testing string keys"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :batch_async

      # Verify actions were atomized
      [first, second] = validated.params.actions
      assert first.action == :file_read
      assert second.action == :orient
    end
  end
end
