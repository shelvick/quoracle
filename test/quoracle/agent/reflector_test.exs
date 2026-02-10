defmodule Quoracle.Agent.ReflectorTest do
  @moduledoc """
  Tests for AGENT_Reflector - LLM extraction of lessons and state.
  WorkGroupID: ace-20251207-140000
  Packet: 2 (Reflector Module)

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
