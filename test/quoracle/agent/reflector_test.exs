defmodule Quoracle.Agent.ReflectorTest do
  @moduledoc """
  Tests for AGENT_Reflector - LLM extraction of lessons and state.
  WorkGroupID: ace-20251207-140000, fix-20260213-reflector-retry-malformed
  Packet: 2 (Reflector Module), Packet 1 (Retry on Malformed)

  Tests R1-R12 from AGENT_Reflector.md spec:
  - R1: Basic extraction from valid LLM response
  - R2: Factual and behavioral lesson type parsing
  - R3: Automatic updated_at timestamp on state entries
  - R4: Error on empty messages
  - R5: Error on malformed JSON
  - R6: Error on missing required fields
  - R7: Retry on transient failure
  - R8: Error after retries exhausted
  - R9: Test mode returns mock without LLM
  - R10: Same model used for reflection (integration)
  - R11: Empty extraction result is valid
  - R12: Injectable delay function for retries

  Tests R22-R27 from AGENT_Reflector.md v3.0 spec:
  - R22: Retry on empty text response
  - R23: Retry on non-JSON text response
  - R24: Retry on JSON with invalid schema
  - R25: Distinct error after malformed exhaustion
  - R26: Successful retry recovery after malformed response
  - R27: Shared retry budget between transport and malformed failures
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Reflector

  # Helper to create mock LLM JSON response
  defp mock_reflection_response(lessons, state) do
    Jason.encode!(%{
      "lessons" =>
        Enum.map(lessons, fn l ->
          %{"type" => to_string(l.type), "content" => l.content}
        end),
      "state" =>
        Enum.map(state, fn s ->
          %{"summary" => s.summary}
        end)
    })
  end

  defp sample_messages do
    [
      %{role: "user", content: "Help me debug auth"},
      %{role: "assistant", content: "I'll check the auth module..."},
      %{role: "user", content: "The API requires a bearer token"}
    ]
  end

  describe "R1: Basic Extraction" do
    test "extracts lessons and state from valid LLM response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Mock LLM to return valid JSON
      mock_response =
        mock_reflection_response(
          [%{type: :factual, content: "API requires bearer auth"}],
          [%{summary: "Working on auth debugging"}]
        )

      opts = [
        test_mode: true,
        mock_response: mock_response
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:ok, %{lessons: lessons, state: state}} = result
      assert length(lessons) == 1
      assert length(state) == 1
      assert hd(lessons).content == "API requires bearer auth"
      assert hd(state).summary == "Working on auth debugging"
    end
  end

  describe "R2: Lesson Types" do
    test "parses factual and behavioral lesson types" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      mock_response =
        mock_reflection_response(
          [
            %{type: :factual, content: "API uses REST"},
            %{type: :behavioral, content: "User prefers concise answers"}
          ],
          []
        )

      opts = [test_mode: true, mock_response: mock_response]

      {:ok, %{lessons: lessons}} = Reflector.reflect(messages, model_id, opts)

      factual = Enum.find(lessons, &(&1.type == :factual))
      behavioral = Enum.find(lessons, &(&1.type == :behavioral))

      assert factual.content == "API uses REST"
      assert factual.confidence == 1
      assert behavioral.content == "User prefers concise answers"
      assert behavioral.confidence == 1
    end
  end

  describe "R3: State Timestamp" do
    test "adds updated_at timestamp to state entries" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      before_call = DateTime.utc_now()

      mock_response =
        mock_reflection_response(
          [],
          [%{summary: "Currently debugging auth module"}]
        )

      opts = [test_mode: true, mock_response: mock_response]

      {:ok, %{state: [state_entry]}} = Reflector.reflect(messages, model_id, opts)

      after_call = DateTime.utc_now()

      assert Map.has_key?(state_entry, :updated_at)
      assert DateTime.compare(state_entry.updated_at, before_call) in [:gt, :eq]
      assert DateTime.compare(state_entry.updated_at, after_call) in [:lt, :eq]
    end
  end

  describe "R4: Empty Messages" do
    test "returns error for empty messages" do
      model_id = "anthropic:claude-sonnet-4"

      result = Reflector.reflect([], model_id, [])

      assert {:error, :invalid_input} = result
    end
  end

  describe "R5: Malformed JSON" do
    test "handles malformed JSON response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Mock LLM returns invalid JSON
      opts = [
        test_mode: true,
        mock_response: "This is not valid JSON at all"
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:error, :malformed_response} = result
    end
  end

  describe "R6: Missing Fields" do
    test "validates required fields in response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # JSON is valid but missing required fields
      opts = [
        test_mode: true,
        mock_response: Jason.encode!(%{"something_else" => "value"})
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:error, :malformed_response} = result
    end

    test "validates lesson structure" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Lessons missing required "type" field
      opts = [
        test_mode: true,
        mock_response: Jason.encode!(%{"lessons" => [%{"content" => "test"}], "state" => []})
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:error, :malformed_response} = result
    end

    test "validates state structure" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # State missing required "summary" field
      opts = [
        test_mode: true,
        mock_response: Jason.encode!(%{"lessons" => [], "state" => [%{"other" => "value"}]})
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:error, :malformed_response} = result
    end
  end

  describe "R7: Retry on Failure" do
    test "retries LLM call on transient failure" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Track call count
      test_pid = self()

      query_fn = fn _messages, _model_id, _opts ->
        send(test_pid, :query_called)
        {:error, :timeout}
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      _result = Reflector.reflect(messages, model_id, opts)

      # Should have been called 3 times (1 initial + 2 retries)
      assert_receive :query_called
      assert_receive :query_called
      assert_receive :query_called
      refute_receive :query_called
    end
  end

  describe "R8: Retry Exhausted" do
    test "returns error after retries exhausted" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Always fail
      query_fn = fn _messages, _model_id, _opts ->
        {:error, :timeout}
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:error, :reflection_failed} = result
    end
  end

  describe "R9: Test Mode" do
    test "returns mock result in test mode" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Track if query_fn is called (it shouldn't be in test_mode)
      test_pid = self()

      query_fn = fn _messages, _model_id, _opts ->
        send(test_pid, :query_called)
        {:error, :should_not_be_called}
      end

      mock_response =
        mock_reflection_response(
          [%{type: :factual, content: "Test lesson"}],
          []
        )

      opts = [
        test_mode: true,
        mock_response: mock_response,
        query_fn: query_fn
      ]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:ok, %{lessons: [lesson], state: []}} = result
      assert lesson.content == "Test lesson"

      # query_fn should NOT have been called
      refute_receive :query_called
    end
  end

  describe "R10: Same Model Reflection" do
    @tag :integration
    test "queries the same model that is being condensed" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      test_pid = self()

      # Track which model was queried
      query_fn = fn _messages, queried_model_id, _opts ->
        send(test_pid, {:model_queried, queried_model_id})

        {:ok,
         mock_reflection_response(
           [%{type: :factual, content: "Lesson from specific model"}],
           []
         )}
      end

      opts = [query_fn: query_fn]

      {:ok, _result} = Reflector.reflect(messages, model_id, opts)

      # Verify the same model_id was passed to query
      assert_receive {:model_queried, ^model_id}
    end
  end

  describe "R11: Empty Extraction" do
    test "handles empty extraction result" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # LLM found nothing valuable
      mock_response = mock_reflection_response([], [])

      opts = [test_mode: true, mock_response: mock_response]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:ok, %{lessons: [], state: []}} = result
    end
  end

  describe "R12: Injectable Delay" do
    test "uses injectable delay function for retries" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      query_fn = fn _messages, _model_id, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count < 2 do
          {:error, :timeout}
        else
          {:ok,
           mock_reflection_response(
             [%{type: :factual, content: "Success after retry"}],
             []
           )}
        end
      end

      delay_fn = fn ms ->
        send(test_pid, {:delay_called, ms})
        :ok
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: delay_fn
      ]

      {:ok, _result} = Reflector.reflect(messages, model_id, opts)

      # delay_fn should have been called at least once
      assert_receive {:delay_called, _ms}
    end
  end

  # ===========================================================================
  # R22-R28: Retry on Malformed LLM Responses (v3.0)
  # WorkGroupID: fix-20260213-reflector-retry-malformed
  #
  # These tests use injectable query_fn (NOT test_mode) to exercise the real
  # retry loop. The query_fn returns {:ok, malformed_text} to simulate a
  # successful HTTP response with unusable content.
  # ===========================================================================

  describe "R22: Retry on Empty Response" do
    test "retries when LLM returns empty text response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      call_count = :counters.new(1, [:atomics])

      # query_fn always returns empty string (successful HTTP, no content)
      query_fn = fn _messages, _model_id, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, ""}
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Should have retried: 1 initial + 2 retries = 3 total calls
      assert :counters.get(call_count, 1) == 3

      # Final error should indicate malformed exhaustion, not transport failure
      assert {:error, :malformed_response_after_retries} = result
    end
  end

  describe "R23: Retry on Non-JSON Response" do
    test "retries when LLM returns non-JSON text response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      call_count = :counters.new(1, [:atomics])

      # query_fn returns prose text (no JSON at all)
      query_fn = fn _messages, _model_id, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, "I analyzed the conversation and found some interesting patterns."}
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Should have retried: 1 initial + 2 retries = 3 total calls
      assert :counters.get(call_count, 1) == 3

      # Final error should indicate malformed exhaustion
      assert {:error, :malformed_response_after_retries} = result
    end
  end

  describe "R24: Retry on Invalid Schema" do
    test "retries when LLM returns JSON with invalid schema" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      call_count = :counters.new(1, [:atomics])

      # query_fn returns valid JSON but missing required "lessons"/"state" fields
      query_fn = fn _messages, _model_id, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, ~s({"wrong": "schema", "no_lessons": true})}
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Should have retried: 1 initial + 2 retries = 3 total calls
      assert :counters.get(call_count, 1) == 3

      # Final error should indicate malformed exhaustion
      assert {:error, :malformed_response_after_retries} = result
    end
  end

  describe "R25: Distinct Error After Malformed Exhaustion" do
    test "returns malformed_response_after_retries when all retries produce bad output" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      # Each attempt returns a different kind of malformed response
      call_count = :counters.new(1, [:atomics])

      query_fn = fn _messages, _model_id, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          # Attempt 0: empty text
          0 -> {:ok, ""}
          # Attempt 1: prose (no JSON)
          1 -> {:ok, "Let me think about this..."}
          # Attempt 2: invalid schema
          _ -> {:ok, ~s({"not_lessons": []})}
        end
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Must be the distinct :malformed_response_after_retries error,
      # NOT :reflection_failed (which is for transport errors)
      assert {:error, :malformed_response_after_retries} = result
    end
  end

  describe "R26: Successful Retry Recovery" do
    test "recovers when retry produces valid response after initial malformed response" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      call_count = :counters.new(1, [:atomics])

      valid_json =
        mock_reflection_response(
          [%{type: :factual, content: "Recovered lesson"}],
          [%{summary: "Back on track"}]
        )

      # First call returns empty (malformed), second returns valid JSON
      query_fn = fn _messages, _model_id, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, ""}
        else
          {:ok, valid_json}
        end
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Should succeed on second attempt
      assert {:ok, %{lessons: [lesson], state: [state_entry]}} = result
      assert lesson.content == "Recovered lesson"
      assert state_entry.summary == "Back on track"

      # Exactly 2 calls: initial (malformed) + 1 retry (success)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "R27: Shared Retry Budget" do
    test "shares retry budget between transport and malformed failures" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      call_count = :counters.new(1, [:atomics])

      # Mix of transport failure and malformed responses:
      # Attempt 0: transport error ({:error, :timeout})
      # Attempt 1: malformed response ({:ok, "no json here"})
      # Attempt 2: malformed response ({:ok, "still no json"})
      # Total = 3 calls, budget exhausted (max_retries: 2)
      query_fn = fn _messages, _model_id, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 -> {:error, :timeout}
          1 -> {:ok, "no json here"}
          _ -> {:ok, "still no json"}
        end
      end

      opts = [
        query_fn: query_fn,
        max_retries: 2,
        delay_fn: fn _ms -> :ok end
      ]

      result = Reflector.reflect(messages, model_id, opts)

      # Total calls = 3 (1 initial + 2 retries), shared budget exhausted
      assert :counters.get(call_count, 1) == 3

      # Last failure was malformed (attempt 2), so final error reflects that.
      # maybe_retry returns based on the last failure_type, which is :malformed.
      assert {:error, :malformed_response_after_retries} = result
    end
  end

  # ===========================================================================
  # Message Construction (system/user split, HISTORY tags)
  # ===========================================================================

  describe "build_reflection_messages/1 structure" do
    test "returns system + user message pair" do
      messages = sample_messages()

      result = Reflector.build_reflection_messages(messages)

      assert [%{role: "system"}, %{role: "user"}] = result
    end

    test "history wrapped in randomized XML boundary tags" do
      messages = sample_messages()

      [_, user_msg] = Reflector.build_reflection_messages(messages)

      assert user_msg.content =~ ~r/<HISTORY_[0-9a-f]{8}>/
      assert user_msg.content =~ ~r/<\/HISTORY_[0-9a-f]{8}>/
    end

    test "boundary tag IDs are unique per invocation" do
      messages = sample_messages()

      [_, msg1] = Reflector.build_reflection_messages(messages)
      [_, msg2] = Reflector.build_reflection_messages(messages)

      [id1] = Regex.run(~r/HISTORY_([0-9a-f]{8})/, msg1.content, capture: :all_but_first)
      [id2] = Regex.run(~r/HISTORY_([0-9a-f]{8})/, msg2.content, capture: :all_but_first)

      refute id1 == id2
    end

    test "user message contains formatted conversation history inside tags" do
      messages = sample_messages()

      [_, user_msg] = Reflector.build_reflection_messages(messages)

      assert user_msg.content =~ "user: Help me debug auth"
      assert user_msg.content =~ "assistant: I'll check the auth module..."
    end
  end

  # ===========================================================================
  # R28-R33: ReqLLM.Response Extraction Regression Tests
  # Covers extract_text_from_response/1 with different content part types
  # to prevent the thinking-prose-as-JSON bug from recurring.
  # Root cause: DeepSeek puts output in reasoning_content (→ :thinking parts),
  # GLM with json_object mode stores JSON as :object content parts.
  # ===========================================================================

  defp build_response_with_thinking(thinking_text) do
    %ReqLLM.Response{
      id: "test-thinking",
      model: "azure:deepseek-v3.2",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :thinking, text: thinking_text}],
        tool_calls: nil,
        metadata: %{}
      }
    }
  end

  defp build_response_with_text(text) do
    %ReqLLM.Response{
      id: "test-text",
      model: "google-vertex:zai-org/glm-4.7-maas",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: text}],
        tool_calls: nil,
        metadata: %{}
      }
    }
  end

  defp build_response_with_text_and_thinking(text, thinking_text) do
    %ReqLLM.Response{
      id: "test-text-and-thinking",
      model: "azure:deepseek-v3.2",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: thinking_text},
          %ReqLLM.Message.ContentPart{type: :text, text: text}
        ],
        tool_calls: nil,
        metadata: %{}
      }
    }
  end

  defp build_response_with_object(object_map) do
    # :object content parts are plain maps (not ContentPart structs) —
    # created by ResponseBuilder.build_content_parts when looks_like_json? is true.
    # response.object stays nil in non-streaming decode path.
    %ReqLLM.Response{
      id: "test-object",
      model: "google-vertex:zai-org/glm-4.7-maas",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%{type: :object, object: object_map}],
        tool_calls: nil,
        metadata: %{}
      }
    }
  end

  describe "R28: Thinking prose extraction" do
    test "thinking content with chain-of-thought prose returns empty string" do
      response =
        build_response_with_thinking(
          "I analyzed the conversation carefully. The user is working on auth debugging. " <>
            "They mentioned bearer tokens. Let me think about what lessons to extract..."
        )

      result = Reflector.extract_text_from_response(response)

      assert result == ""
    end
  end

  describe "R29: Thinking with reflection JSON" do
    test "extracts reflection JSON embedded in thinking content" do
      valid_json =
        Jason.encode!(%{
          "lessons" => [%{"type" => "factual", "content" => "API requires bearer auth"}],
          "state" => [%{"summary" => "Debugging auth module"}]
        })

      response = build_response_with_thinking(valid_json)

      result = Reflector.extract_text_from_response(response)

      assert {:ok, data} = Jason.decode(result)
      assert Map.has_key?(data, "lessons")
      assert Map.has_key?(data, "state")
    end
  end

  describe "R30: Thinking with action JSON" do
    test "returns empty for thinking content containing action JSON" do
      action_json =
        Jason.encode!(%{
          "action" => "orient",
          "params" => %{},
          "reasoning" => "I should orient first"
        })

      response = build_response_with_thinking(action_json)

      result = Reflector.extract_text_from_response(response)

      # Action JSON has no "lessons"/"state" keys — rejected by validation
      assert result == ""
    end
  end

  describe "R31: Object content part extraction" do
    test "extracts from :object content parts when response.object is nil" do
      object = %{"lessons" => [], "state" => []}
      response = build_response_with_object(object)

      # Verify response.object is nil (non-streaming decode doesn't set it)
      assert response.object == nil

      result = Reflector.extract_text_from_response(response)

      assert {:ok, data} = Jason.decode(result)
      assert data == object
    end
  end

  describe "R32: Text with reflection JSON" do
    test "extracts text content directly when present" do
      valid_json =
        Jason.encode!(%{
          "lessons" => [%{"type" => "behavioral", "content" => "User prefers verbose output"}],
          "state" => []
        })

      response = build_response_with_text(valid_json)

      result = Reflector.extract_text_from_response(response)

      assert result == valid_json
    end
  end

  describe "R33: Thinking prose retry loop" do
    test "thinking prose triggers malformed_response retry loop" do
      messages = sample_messages()
      call_count = :counters.new(1, [:atomics])

      # Simulate DeepSeek returning prose in thinking content with empty text field.
      # The query_fn mimics what default_query does: extract text from response.
      query_fn = fn _messages, _model_id, _opts ->
        :counters.add(call_count, 1, 1)

        response =
          build_response_with_thinking(
            "Step 1: The user discussed auth. Step 2: They need bearer tokens..."
          )

        text = Reflector.extract_text_from_response(response)
        {:ok, text}
      end

      import ExUnit.CaptureLog

      capture_log(fn ->
        result =
          Reflector.reflect(messages, "azure:deepseek-v3.2",
            query_fn: query_fn,
            max_retries: 1,
            delay_fn: fn _ms -> :ok end
          )

        send(self(), {:result, result})
      end)

      assert_receive {:result, {:error, :malformed_response_after_retries}}
      # 1 initial + 1 retry = 2 calls
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "R34: Garbage text with valid thinking JSON" do
    test "extracts reflection JSON from thinking when text is garbage tokens" do
      # DeepSeek sometimes emits garbage tokens ("package", "#") in content
      # while putting the real reflection JSON in reasoning_content/thinking.
      valid_json =
        Jason.encode!(%{
          "lessons" => [%{"type" => "factual", "content" => "API requires bearer auth"}],
          "state" => [%{"summary" => "Debugging auth module"}]
        })

      response = build_response_with_text_and_thinking("package", valid_json)

      result = Reflector.extract_text_from_response(response)

      assert {:ok, data} = Jason.decode(result)
      assert Map.has_key?(data, "lessons")
      assert Map.has_key?(data, "state")
    end

    test "returns empty when both text and thinking lack JSON" do
      response =
        build_response_with_text_and_thinking(
          "#",
          "Let me think about this carefully..."
        )

      result = Reflector.extract_text_from_response(response)

      # Thinking branch matches (non-empty) but has no reflection JSON → ""
      assert result == ""
    end

    test "text containing { is used directly without checking thinking" do
      text_with_json = ~s({"lessons": [], "state": []})

      response =
        build_response_with_text_and_thinking(
          text_with_json,
          "Some thinking content"
        )

      result = Reflector.extract_text_from_response(response)

      # Text contains { so it's used directly (PATH 1)
      assert result == text_with_json
    end
  end

  # ===========================================================================
  # Edge Cases (existing)
  # ===========================================================================

  describe "Edge Cases" do
    test "handles single message" do
      messages = [%{role: "user", content: "Single message"}]
      model_id = "anthropic:claude-sonnet-4"

      mock_response =
        mock_reflection_response(
          [%{type: :factual, content: "From single message"}],
          []
        )

      opts = [test_mode: true, mock_response: mock_response]

      result = Reflector.reflect(messages, model_id, opts)

      assert {:ok, %{lessons: [_]}} = result
    end

    test "preserves lesson content exactly" do
      messages = sample_messages()
      model_id = "anthropic:claude-sonnet-4"

      content_with_special = "API endpoint: /api/v1/auth?token=xyz&refresh=true"

      mock_response =
        mock_reflection_response(
          [%{type: :factual, content: content_with_special}],
          []
        )

      opts = [test_mode: true, mock_response: mock_response]

      {:ok, %{lessons: [lesson]}} = Reflector.reflect(messages, model_id, opts)

      assert lesson.content == content_with_special
    end
  end
end
