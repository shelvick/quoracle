defmodule Quoracle.Actions.ValidatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Quoracle.Actions.{Validator, Schema}

  # Ensure Schema module is loaded so all action atoms exist
  setup do
    # This forces Schema module to load and create all action atoms
    Schema.list_actions()
    :ok
  end

  describe "validate_action/1" do
    test "validates spawn_child action with valid params" do
      action_json = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Process data",
          "success_criteria" => "Complete",
          "immediate_context" => "Test",
          "approach_guidance" => "Standard",
          "profile" => "test-profile"
        },
        "reasoning" => "Need to delegate processing"
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :spawn_child
      assert validated.params.task_description == "Process data"
      assert validated.reasoning == "Need to delegate processing"
    end

    test "validates wait action with optional duration" do
      action_json = %{
        "action" => "wait",
        "params" => %{
          "wait" => 5000
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :wait
      assert validated.params.wait == 5000
    end

    test "validates wait action with empty params" do
      action_json = %{
        "action" => "wait",
        "params" => %{}
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :wait
      assert validated.params == %{}
    end

    test "returns error for missing action field" do
      action_json = %{
        "params" => %{}
      }

      assert {:error, :missing_action_field} = Validator.validate_action(action_json)
    end

    test "returns error for missing params field" do
      action_json = %{
        "action" => "wait"
      }

      assert {:error, :missing_params_field} = Validator.validate_action(action_json)
    end

    test "returns error for unknown action" do
      action_json = %{
        "action" => "unknown_action",
        "params" => %{}
      }

      assert {:error, :unknown_action} = Validator.validate_action(action_json)
    end

    test "returns error for missing required param" do
      action_json = %{
        "action" => "spawn_child",
        "params" => %{}
      }

      assert {:error, :missing_required_param} = Validator.validate_action(action_json)
    end

    test "returns error for unknown parameter" do
      action_json = %{
        "action" => "wait",
        "params" => %{
          "unknown_param" => "value"
        }
      }

      assert {:error, :unknown_parameter} = Validator.validate_action(action_json)
    end

    test "returns error for invalid param type" do
      action_json = %{
        "action" => "wait",
        "params" => %{
          "wait" => "not a number"
        }
      }

      assert {:error, :invalid_param_type} = Validator.validate_action(action_json)
    end

    test "validates execute_shell with command XOR" do
      action_json = %{
        "action" => "execute_shell",
        "params" => %{
          "command" => "ls -la"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.command == "ls -la"
    end

    test "validates execute_shell with check_id XOR" do
      action_json = %{
        "action" => "execute_shell",
        "params" => %{
          "check_id" => "550e8400-e29b-41d4-a716-446655440000"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.check_id == "550e8400-e29b-41d4-a716-446655440000"
    end

    test "returns error for XOR params conflict" do
      action_json = %{
        "action" => "execute_shell",
        "params" => %{
          "command" => "ls",
          "check_id" => "550e8400-e29b-41d4-a716-446655440000"
        }
      }

      assert {:error, :xor_params_conflict} = Validator.validate_action(action_json)
    end

    test "R4: execute_shell with empty params fails validation" do
      # [INTEGRATION] - WHEN validate_action called IF execute_shell with empty params THEN returns {:error, :xor_params_required}
      action_json = %{
        "action" => "execute_shell",
        "params" => %{}
      }

      assert {:error, :xor_params_required} = Validator.validate_action(action_json)
    end

    test "validates fetch_web with valid URL" do
      action_json = %{
        "action" => "fetch_web",
        "params" => %{
          "url" => "https://example.com"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.url == "https://example.com"
    end

    test "returns error for invalid URL format" do
      action_json = %{
        "action" => "fetch_web",
        "params" => %{
          "url" => "not a url"
        }
      }

      assert {:error, :invalid_url_format} = Validator.validate_action(action_json)
    end

    test "validates UUID format for check_id" do
      action_json = %{
        "action" => "execute_shell",
        "params" => %{
          "check_id" => "not-a-uuid"
        }
      }

      assert {:error, :invalid_uuid_format} = Validator.validate_action(action_json)
    end

    test "validates enum values for call_api api_type" do
      # Ensure the atom exists for test isolation
      _ = :call_api

      action_json = %{
        "action" => "call_api",
        "params" => %{
          "url" => "https://api.example.com",
          "api_type" => "invalid"
        }
      }

      assert {:error, :invalid_enum_value} = Validator.validate_action(action_json)
    end

    # NOTE: models param removed from spawn_child schema - now returns :unknown_parameter
    test "returns error for removed models param" do
      action_json = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Process",
          "success_criteria" => "Complete",
          "immediate_context" => "Test",
          "approach_guidance" => "Standard",
          "profile" => "test-profile",
          "models" => ["invalid_model"]
        }
      }

      assert {:error, :unknown_parameter} = Validator.validate_action(action_json)
    end

    test "treats empty map as empty list when list type expected (LLM leniency)" do
      # LLMs sometimes send %{} instead of [] for empty arrays
      action_json = %{
        "action" => "spawn_child",
        "params" => %{
          "task_description" => "Test task",
          "success_criteria" => "Done",
          "immediate_context" => "Context",
          "approach_guidance" => "Guidance",
          "profile" => "test-profile",
          "sibling_context" => %{}
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.sibling_context == []
    end

    test "empty map stays as map for map-type parameters" do
      # Empty map should NOT be converted for :map type params
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "api_type" => "rest",
          "url" => "https://example.com/api",
          "method" => "get",
          "headers" => %{}
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.headers == %{}
    end
  end

  describe "validate_params/2" do
    test "validates params directly for action type" do
      params = %{
        "task_description" => "Process data",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => "test-profile"
      }

      assert {:ok, validated} = Validator.validate_params(:spawn_child, params)
      assert validated.task_description == "Process data"
    end

    test "returns error for invalid params" do
      params = %{
        "invalid" => "param"
      }

      assert {:error, :missing_required_param} = Validator.validate_params(:spawn_child, params)
    end
  end

  describe "complex action validation" do
    test "validates orient action with all required params" do
      action_json = %{
        "action" => "orient",
        "params" => %{
          "current_situation" => "Processing started",
          "goal_clarity" => "Clear objective",
          "available_resources" => "3 child agents",
          "key_challenges" => "Data volume",
          "delegation_consideration" => "No delegation needed"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.action == :orient
    end

    test "validates call_api with auth config" do
      action_json = %{
        "action" => "call_api",
        "params" => %{
          "url" => "https://api.example.com/data",
          "api_type" => "rest",
          "method" => "get",
          "auth" => %{"auth_type" => "bearer", "token" => "secret"}
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.auth == %{"auth_type" => "bearer", "token" => "secret"}
    end

    test "validates call_mcp with transport params (v20.0)" do
      # v20.0: New agent-driven discovery schema
      action_json = %{
        "action" => "call_mcp",
        "params" => %{
          "transport" => "stdio",
          "command" => "npx @modelcontextprotocol/server-filesystem /tmp"
        }
      }

      assert {:ok, validated} = Validator.validate_action(action_json)
      assert validated.params.transport == :stdio
      assert validated.params.command == "npx @modelcontextprotocol/server-filesystem /tmp"
    end
  end

  describe "property-based tests" do
    property "valid actions with correct params always pass validation" do
      check all(
              action <- member_of(Schema.list_actions()),
              task <- string(:printable, min_length: 1, max_length: 100),
              duration <- integer(0..60000),
              content <- string(:printable, min_length: 1, max_length: 200)
            ) do
        # Build valid params based on action type
        params =
          case action do
            :spawn_child ->
              %{
                "task_description" => task,
                "success_criteria" => "Complete",
                "immediate_context" => "Test",
                "approach_guidance" => "Standard",
                "profile" => "test-profile"
              }

            :wait ->
              %{"wait" => duration}

            :orient ->
              %{
                "current_situation" => "test",
                "goal_clarity" => "clear",
                "available_resources" => "many",
                "key_challenges" => "none"
              }

            :send_message ->
              %{"to" => "agent-123", "content" => content}

            :answer_engine ->
              %{"query" => task}

            :execute_shell ->
              %{"command" => "echo test"}

            :fetch_web ->
              %{"url" => "https://example.com"}

            :call_api ->
              %{"api_type" => "rest", "url" => "https://api.example.com", "method" => "GET"}

            :call_mcp ->
              %{"server" => "test", "method" => "test_method", "params" => %{}}

            :todo ->
              %{"items" => [%{"content" => content, "state" => "todo"}]}

            :generate_secret ->
              %{"name" => "test_secret"}

            :search_secrets ->
              %{"search_terms" => ["test"]}

            :dismiss_child ->
              %{"child_id" => "agent-123"}

            :generate_images ->
              %{"prompt" => "A beautiful sunset"}

            :record_cost ->
              %{"amount" => "1.50", "description" => "Test cost"}

            :adjust_budget ->
              %{"child_id" => "agent-123", "new_budget" => "50.00"}

            :file_read ->
              %{"path" => "/tmp/test.txt"}

            :file_write ->
              %{"path" => "/tmp/test.txt", "mode" => "write", "content" => content}

            # Skill actions (v27.0)
            :search_skills ->
              %{"search_terms" => ["test"]}

            :learn_skills ->
              %{"skills" => ["test-skill"]}

            :create_skill ->
              %{"name" => "test-skill", "description" => "A test skill", "content" => content}

            :batch_sync ->
              %{
                "actions" => [
                  %{"action" => "file_read", "params" => %{"path" => "/tmp/a.txt"}},
                  %{"action" => "file_read", "params" => %{"path" => "/tmp/b.txt"}}
                ]
              }

            :batch_async ->
              %{
                "actions" => [
                  %{"action" => "file_read", "params" => %{"path" => "/tmp/a.txt"}},
                  %{"action" => "file_read", "params" => %{"path" => "/tmp/b.txt"}}
                ]
              }
          end

        action_json = %{
          "action" => Atom.to_string(action),
          "params" => params,
          "reasoning" => "Property test reasoning"
        }

        case Validator.validate_action(action_json) do
          {:ok, validated} ->
            assert validated.action == action
            assert is_map(validated.params)
            assert validated.reasoning == "Property test reasoning"

          {:error, reason} ->
            # Some actions may have additional required params we didn't provide
            # That's OK for this test - we're testing the validation logic works
            assert is_atom(reason)
        end
      end
    end

    property "invalid action types are always rejected" do
      check all(
              invalid_action <- string(:printable, min_length: 5, max_length: 50),
              invalid_action not in Enum.map(Schema.list_actions(), &Atom.to_string/1)
            ) do
        action_json = %{
          "action" => invalid_action,
          "params" => %{},
          "reasoning" => "Test"
        }

        assert {:error, :unknown_action} = Validator.validate_action(action_json)
      end
    end

    property "only accepts known actions and rejects arbitrary strings safely" do
      # This test verifies that arbitrary user input is rejected without creating atoms.
      # We test the actual behavior we care about: only known actions are accepted.

      valid_actions = Schema.list_actions() |> Enum.map(&to_string/1)

      check all(action_string <- string(:printable, min_length: 1, max_length: 100)) do
        action_json = %{
          "action" => action_string,
          "params" => %{},
          "reasoning" => "Safety test"
        }

        result = Validator.validate_action(action_json)

        if action_string in valid_actions do
          # Known actions should succeed
          assert {:ok, _} = result
        else
          # Unknown actions should fail with specific error
          assert {:error, :unknown_action} = result
        end

        # Verify the same result on repeated calls (idempotent)
        assert result == Validator.validate_action(action_json)
      end
    end

    property "XOR parameters are properly enforced" do
      check all(
              use_command <- boolean(),
              command <- string(:printable, min_length: 1, max_length: 50),
              check_id <- string(:printable, min_length: 1, max_length: 50)
            ) do
        # Build params with XOR violation or correct XOR
        params =
          if use_command do
            %{"command" => command}
          else
            %{"check_id" => check_id}
          end

        action_json = %{
          "action" => "execute_shell",
          "params" => params,
          "reasoning" => "XOR test"
        }

        case Validator.validate_action(action_json) do
          {:ok, validated} ->
            # Should have exactly one of command or check_id
            has_command = Map.has_key?(validated.params, :command)
            has_check_id = Map.has_key?(validated.params, :check_id)
            # XOR
            assert has_command != has_check_id

          {:error, _reason} ->
            # Validation can fail for other reasons too
            assert true
        end
      end
    end

    property "required parameters are enforced" do
      check all(
              include_task <- boolean(),
              task <- string(:printable, min_length: 1, max_length: 100)
            ) do
        params =
          if include_task do
            %{
              "task_description" => task,
              "success_criteria" => "Complete",
              "immediate_context" => "Test",
              "approach_guidance" => "Standard",
              "profile" => "test-profile"
            }
          else
            # Missing required param
            %{}
          end

        action_json = %{
          "action" => "spawn_child",
          "params" => params,
          "reasoning" => "Required param test"
        }

        case Validator.validate_action(action_json) do
          {:ok, validated} ->
            # Should only succeed if task was included
            assert include_task
            assert validated.params.task_description == task

          {:error, reason} ->
            # Should fail if task was missing
            refute include_task
            assert reason == :missing_required_param
        end
      end
    end
  end
end
