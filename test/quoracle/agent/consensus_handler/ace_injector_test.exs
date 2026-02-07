defmodule Quoracle.Agent.ConsensusHandler.AceInjectorTest do
  @moduledoc """
  Unit and integration tests for AceInjector module.

  Validates formatting, injection into first user message, edge case handling,
  and UI visibility of ACE (Adaptive Context Engine) context.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 1 (ACE Injector Implementation)

  ARC Verification Criteria: R1-R15 + A1
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler.AceInjector

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{
      content: content,
      type: type,
      confidence: confidence
    }
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_message(role, content) do
    %{role: role, content: content}
  end

  defp make_state(lessons, model_state, model_id \\ "test-model") do
    %{
      context_lessons: if(lessons, do: %{model_id => lessons}, else: %{}),
      model_states: if(model_state, do: %{model_id => model_state}, else: %{})
    }
  end

  # ========== R1: EMPTY LESSONS AND NO STATE ==========

  describe "R1: inject_ace_context/3 with no ACE content" do
    test "returns messages unchanged when no ACE content" do
      state = make_state([], nil)
      messages = [make_message("user", "Hello")]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      assert result == messages
    end

    test "returns messages unchanged when lessons empty and state nil" do
      state = %{context_lessons: %{"test-model" => []}, model_states: %{}}
      messages = [make_message("user", "Hello"), make_message("assistant", "Hi")]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      assert result == messages
    end
  end

  # ========== R2: EMPTY MESSAGES LIST ==========

  describe "R2: inject_ace_context/3 with empty messages" do
    test "creates user message with ACE content when messages empty but lessons exist" do
      state = make_state([make_lesson("Test lesson")], nil)

      result = AceInjector.inject_ace_context(state, [], "test-model")

      # After condensation, messages may be empty but ACE context should still be injected
      assert length(result) == 1
      assert hd(result).role == "user"
      assert hd(result).content =~ "<lessons>"
      assert hd(result).content =~ "Test lesson"
    end

    test "creates user message with ACE content when messages empty but model state exists" do
      state = make_state([], make_model_state("Some state"))

      result = AceInjector.inject_ace_context(state, [], "test-model")

      # After condensation, messages may be empty but ACE context should still be injected
      assert length(result) == 1
      assert hd(result).role == "user"
      assert hd(result).content =~ "<state>"
      assert hd(result).content =~ "Some state"
    end
  end

  # ========== R3-R5: FORMATTING ==========

  describe "R3: format_ace_context/2 lessons only" do
    test "formats lessons only when no model state" do
      lessons = [make_lesson("API requires auth")]

      result = AceInjector.format_ace_context(lessons, nil)

      assert result =~ "<lessons>"
      assert result =~ "</lessons>"
      assert result =~ "[Fact] API requires auth"
      refute result =~ "<state>"
    end

    test "wraps lessons in XML tags" do
      lessons = [make_lesson("Test lesson")]

      result = AceInjector.format_ace_context(lessons, nil)

      assert String.starts_with?(result, "<lessons>")
      assert String.ends_with?(result, "</lessons>")
    end
  end

  describe "R4: format_ace_context/2 state only" do
    test "formats state only when no lessons" do
      state = make_model_state("Task 50% complete")

      result = AceInjector.format_ace_context([], state)

      assert result =~ "<state>"
      assert result =~ "</state>"
      assert result =~ "Task 50% complete"
      refute result =~ "<lessons>"
    end

    test "wraps state in XML tags" do
      state = make_model_state("Summary text")

      result = AceInjector.format_ace_context([], state)

      assert String.starts_with?(result, "<state>")
      assert String.ends_with?(result, "</state>")
    end
  end

  describe "R5: format_ace_context/2 both lessons and state" do
    test "formats both lessons and state" do
      lessons = [make_lesson("API requires auth")]
      state = make_model_state("Task 50% complete")

      result = AceInjector.format_ace_context(lessons, state)

      assert result =~ "<lessons>"
      assert result =~ "<state>"
    end

    test "lessons appear before state" do
      lessons = [make_lesson("API requires auth")]
      state = make_model_state("Task 50% complete")

      result = AceInjector.format_ace_context(lessons, state)

      lessons_pos = :binary.match(result, "<lessons>") |> elem(0)
      state_pos = :binary.match(result, "<state>") |> elem(0)
      assert lessons_pos < state_pos
    end

    test "returns empty string when both empty" do
      result = AceInjector.format_ace_context([], nil)

      assert result == ""
    end
  end

  # ========== R6: LESSONS SORTED BY CONFIDENCE ==========

  describe "R6: lessons sorted by confidence descending" do
    test "sorts lessons by confidence descending" do
      lessons = [
        make_lesson("Low confidence", :factual, 0.5),
        make_lesson("High confidence", :factual, 0.9),
        make_lesson("Medium confidence", :factual, 0.7)
      ]

      result = AceInjector.format_ace_context(lessons, nil)

      high_pos = :binary.match(result, "High confidence") |> elem(0)
      medium_pos = :binary.match(result, "Medium confidence") |> elem(0)
      low_pos = :binary.match(result, "Low confidence") |> elem(0)

      assert high_pos < medium_pos
      assert medium_pos < low_pos
    end

    test "handles equal confidence values" do
      lessons = [
        make_lesson("First", :factual, 0.8),
        make_lesson("Second", :factual, 0.8)
      ]

      result = AceInjector.format_ace_context(lessons, nil)

      # Should not crash and should contain both
      assert result =~ "First"
      assert result =~ "Second"
    end
  end

  # ========== R7: TYPE LABELS ==========

  describe "R7: type labels for lessons" do
    test "uses [Fact] for factual lessons" do
      lessons = [make_lesson("Factual lesson", :factual, 0.8)]

      result = AceInjector.format_ace_context(lessons, nil)

      assert result =~ "[Fact] Factual lesson"
    end

    test "uses [Pattern] for behavioral lessons" do
      lessons = [make_lesson("Behavioral lesson", :behavioral, 0.8)]

      result = AceInjector.format_ace_context(lessons, nil)

      assert result =~ "[Pattern] Behavioral lesson"
    end

    test "uses correct labels for mixed types" do
      lessons = [
        make_lesson("Factual lesson", :factual, 0.8),
        make_lesson("Behavioral lesson", :behavioral, 0.7)
      ]

      result = AceInjector.format_ace_context(lessons, nil)

      assert result =~ "[Fact] Factual lesson"
      assert result =~ "[Pattern] Behavioral lesson"
    end
  end

  # ========== R8: INJECT INTO FIRST USER MESSAGE ==========

  describe "R8: injection into first user message" do
    test "prepends ACE to first user message" do
      state = make_state([make_lesson("Test lesson")], nil)

      messages = [
        make_message("system", "System prompt"),
        make_message("user", "First user message"),
        make_message("assistant", "Response"),
        make_message("user", "Second user message")
      ]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      # System message unchanged
      assert Enum.at(result, 0).content == "System prompt"
      # First user message has ACE prepended
      first_user = Enum.at(result, 1)
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "First user message"
      # Second user message unchanged
      assert Enum.at(result, 3).content == "Second user message"
    end

    test "does not modify other messages" do
      state = make_state([make_lesson("Test lesson")], nil)

      messages = [
        make_message("user", "User message"),
        make_message("assistant", "Assistant response")
      ]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      # Assistant message should be unchanged
      assert Enum.at(result, 1).content == "Assistant response"
    end
  end

  # ========== R9: CREATE SYNTHETIC USER MESSAGE ==========

  describe "R9: create synthetic user message when none exist" do
    test "creates synthetic user message when only system and assistant messages" do
      state = make_state([make_lesson("Test lesson")], nil)

      messages = [
        make_message("system", "System prompt"),
        make_message("assistant", "Response")
      ]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      # Should have 3 messages now (synthetic user inserted at start)
      assert length(result) == 3
      # First message should be the synthetic user with ACE
      first = Enum.at(result, 0)
      assert first.role == "user"
      assert first.content =~ "<lessons>"
    end
  end

  # ========== R10: HISTORY STARTS WITH ASSISTANT ==========

  describe "R10: history starts with assistant" do
    test "inserts synthetic user before assistant-first history" do
      state = make_state([make_lesson("Test lesson")], nil)
      messages = [make_message("assistant", "I'm ready")]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      # Synthetic user should be first
      assert Enum.at(result, 0).role == "user"
      assert Enum.at(result, 0).content =~ "<lessons>"
      # Original assistant message second
      assert Enum.at(result, 1).role == "assistant"
      assert Enum.at(result, 1).content == "I'm ready"
    end

    test "maintains proper message count after synthetic insertion" do
      state = make_state([make_lesson("Test lesson")], nil)
      messages = [make_message("assistant", "Response")]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      assert length(result) == 2
    end
  end

  # ========== R11: PRESERVE ORIGINAL CONTENT ==========

  describe "R11: preserve original message content" do
    test "preserves original message content after ACE" do
      state = make_state([make_lesson("Test lesson")], nil)
      original_content = "This is the original user message"
      messages = [make_message("user", original_content)]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      content = Enum.at(result, 0).content
      assert content =~ "<lessons>"
      assert content =~ original_content
      # ACE should come before original
      ace_pos = :binary.match(content, "</lessons>") |> elem(0)
      original_pos = :binary.match(content, original_content) |> elem(0)
      assert ace_pos < original_pos
    end

    test "preserves other message properties" do
      state = make_state([make_lesson("Test lesson")], nil)
      messages = [%{role: "user", content: "Test", metadata: %{id: 123}}]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      first_msg = hd(result)
      assert first_msg.role == "user"
      assert first_msg.metadata == %{id: 123}
    end
  end

  # ========== R12: MODEL-SPECIFIC LESSONS ==========

  describe "R12: model-specific lessons" do
    test "injects only lessons for specific model" do
      state = %{
        context_lessons: %{
          "model-a" => [make_lesson("Lesson for A")],
          "model-b" => [make_lesson("Lesson for B")]
        },
        model_states: %{}
      }

      messages = [make_message("user", "Hello")]

      result_a = AceInjector.inject_ace_context(state, messages, "model-a")
      result_b = AceInjector.inject_ace_context(state, messages, "model-b")

      assert Enum.at(result_a, 0).content =~ "Lesson for A"
      refute Enum.at(result_a, 0).content =~ "Lesson for B"

      assert Enum.at(result_b, 0).content =~ "Lesson for B"
      refute Enum.at(result_b, 0).content =~ "Lesson for A"
    end

    test "model-specific state also applied" do
      state = %{
        context_lessons: %{},
        model_states: %{
          "model-a" => make_model_state("State for A"),
          "model-b" => make_model_state("State for B")
        }
      }

      messages = [make_message("user", "Hello")]

      result_a = AceInjector.inject_ace_context(state, messages, "model-a")
      result_b = AceInjector.inject_ace_context(state, messages, "model-b")

      assert Enum.at(result_a, 0).content =~ "State for A"
      refute Enum.at(result_a, 0).content =~ "State for B"

      assert Enum.at(result_b, 0).content =~ "State for B"
      refute Enum.at(result_b, 0).content =~ "State for A"
    end
  end

  # ========== R13: NO LESSONS FOR MODEL ==========

  describe "R13: no lessons for model" do
    test "handles missing model_id in context_lessons" do
      state = %{
        context_lessons: %{"other-model" => [make_lesson("Other lesson")]},
        model_states: %{}
      }

      messages = [make_message("user", "Hello")]

      result = AceInjector.inject_ace_context(state, messages, "missing-model")

      # Should return unchanged (no lessons for this model)
      assert result == messages
    end

    test "handles nil context_lessons map" do
      state = %{context_lessons: nil, model_states: nil}
      messages = [make_message("user", "Hello")]

      result = AceInjector.inject_ace_context(state, messages, "any-model")

      assert result == messages
    end

    test "handles missing keys gracefully" do
      state = %{}
      messages = [make_message("user", "Hello")]

      result = AceInjector.inject_ace_context(state, messages, "any-model")

      assert result == messages
    end
  end

  # ========== R14: MULTIMODAL CONTENT ==========

  describe "R14: multimodal message content" do
    test "handles multimodal message content (list)" do
      state = make_state([make_lesson("Test lesson")], nil)

      multimodal_content = [
        %{type: :text, text: "Original text"},
        %{type: :image_url, url: "http://example.com/image.png"}
      ]

      messages = [%{role: "user", content: multimodal_content}]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      content = Enum.at(result, 0).content
      # Should be a list with ACE text prepended
      assert is_list(content)
      assert Enum.at(content, 0).type == :text
      assert Enum.at(content, 0).text =~ "<lessons>"
    end

    test "preserves image parts in multimodal content" do
      state = make_state([make_lesson("Test lesson")], nil)

      multimodal_content = [
        %{type: :text, text: "Original text"},
        %{type: :image_url, url: "http://example.com/image.png"}
      ]

      messages = [%{role: "user", content: multimodal_content}]

      result = AceInjector.inject_ace_context(state, messages, "test-model")

      content = Enum.at(result, 0).content
      # Image part should still be present
      image_part = Enum.find(content, &(&1.type == :image_url))
      assert image_part.url == "http://example.com/image.png"
    end
  end

  # ========== R15: INJECTION ORDER (INTEGRATION) ==========

  describe "R15: injection order with other injectors" do
    test "ACE in first message, todos in last message" do
      alias Quoracle.Agent.ConsensusHandler.TodoInjector

      ace_state = make_state([make_lesson("Historical knowledge")], nil)
      state = Map.merge(ace_state, %{todos: [%{content: "Current task", state: :todo}]})

      messages = [
        make_message("user", "First message"),
        make_message("assistant", "Response"),
        make_message("user", "Last message")
      ]

      # ACE injected first (into first user message)
      messages_with_ace = AceInjector.inject_ace_context(state, messages, "test-model")
      # Todos injected after (into last message)
      result = TodoInjector.inject_todo_context(state, messages_with_ace)

      # First user message has ACE
      first_user = Enum.at(result, 0)
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "Historical knowledge"

      # Last message has todos
      last = Enum.at(result, -1)
      assert last.content =~ "<todos>"
      assert last.content =~ "Current task"

      # ACE should NOT be in last message
      refute last.content =~ "<lessons>"
      # Todos should NOT be in first message
      refute first_user.content =~ "<todos>"
    end

    test "works with single message - both ACE and todos injected" do
      alias Quoracle.Agent.ConsensusHandler.TodoInjector

      ace_state = make_state([make_lesson("Historical knowledge")], nil)
      state = Map.merge(ace_state, %{todos: [%{content: "Current task", state: :todo}]})

      messages = [make_message("user", "Single message")]

      # ACE injected first (into first = only = last user message)
      messages_with_ace = AceInjector.inject_ace_context(state, messages, "test-model")
      # Todos injected after (into last = same message)
      result = TodoInjector.inject_todo_context(state, messages_with_ace)

      # Single message should have both
      content = Enum.at(result, 0).content
      assert content =~ "<lessons>"
      assert content =~ "<todos>"
      assert content =~ "Historical knowledge"
      assert content =~ "Current task"
    end
  end

  # ========== v2.0 INTEGRATION TESTS (fix-20260106-condense-ordering) ==========
  # These tests verify ACE injection position after TokenManager fix.
  # The bug: TokenManager removed NEWEST instead of OLDEST, causing ACE to
  # be injected into the wrong message position.

  describe "R16: ACE Injected Into First User Message" do
    test "ACE injected into first user message after condensation" do
      alias Quoracle.Agent.TokenManager

      model_id = "anthropic:claude-sonnet-4"

      # State with ACE content
      state = %{
        context_lessons: %{
          model_id => [%{type: :factual, content: "Test lesson", confidence: 1}]
        },
        model_states: %{
          model_id => %{summary: "Test state"}
        }
      }

      # Create newest-first history (production storage format)
      # id:10 is newest (index 0), id:1 is oldest (index 9)
      history =
        10..1//-1
        |> Enum.map(fn id ->
          %{
            id: id,
            role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
            content: "Message #{id} content"
          }
        end)

      # Condense 4 oldest messages
      {_to_remove, to_keep} = TokenManager.messages_to_condense(history, 4)

      # Reverse to oldest-first for LLM (as ContextManager does)
      messages_for_llm = Enum.reverse(to_keep)

      # Inject ACE context
      result = AceInjector.inject_ace_context(state, messages_for_llm, model_id)

      # ACE should be in FIRST user message (chronologically oldest KEPT user)
      first_user = Enum.find(result, &(&1.role == "user"))
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "Test lesson"
      assert first_user.content =~ "<state>"
      assert first_user.content =~ "Test state"

      # The first user message should be id:5 (oldest kept user after removing 1-4)
      # id:5 is user (odd), id:6 is assistant (even)
      assert first_user.id == 5, "Expected oldest kept user (id:5), got id:#{first_user.id}"
    end
  end

  describe "R17: First User is Chronologically Oldest" do
    test "first user message is chronologically oldest after reversal" do
      alias Quoracle.Agent.TokenManager

      model_id = "test-model"
      state = make_state([make_lesson("Test")], nil, model_id)

      # Newest-first history: [id:8, id:7, ..., id:1]
      history =
        8..1//-1
        |> Enum.map(fn id ->
          %{
            id: id,
            role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
            content: "Message #{id}"
          }
        end)

      # Condense 2 oldest
      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 2)

      # Verify to_remove has OLDEST (not newest)
      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2], "Should remove oldest [1,2], got #{inspect(removed_ids)}"

      # Reverse to_keep for LLM
      messages = Enum.reverse(to_keep)

      # First message should be oldest kept (id:3)
      assert hd(messages).id == 3, "First message should be oldest kept"

      # First USER should be oldest kept user
      first_user = Enum.find(messages, &(&1.role == "user"))
      assert first_user.id == 3, "First user should be id:3 (oldest kept user)"

      # Inject and verify
      result = AceInjector.inject_ace_context(state, messages, model_id)
      injected_user = Enum.find(result, &(&1.role == "user"))
      assert injected_user.content =~ "<lessons>"
      assert injected_user.id == 3
    end
  end

  describe "R18: ACE Visible After Condensation" do
    @tag :acceptance
    test "ACE context visible in UI logs after condensation" do
      alias Quoracle.Agent.TokenManager

      # Full integration test: TokenManager + AceInjector
      model_id = "anthropic:claude-sonnet-4"

      # Simulated state after condensation extracted lessons
      state = %{
        context_lessons: %{
          model_id => [
            %{type: :factual, content: "API requires auth header", confidence: 2},
            %{type: :behavioral, content: "User prefers concise responses", confidence: 1}
          ]
        },
        model_states: %{
          model_id => %{summary: "Working on auth module, 60% complete"}
        }
      }

      # Production-like newest-first history
      history =
        12..1//-1
        |> Enum.map(fn id ->
          %{
            id: id,
            role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
            content: "Conversation message #{id}"
          }
        end)

      # Model requests condense=6
      {to_remove, to_keep} = TokenManager.messages_to_condense(history, 6)

      # POSITIVE: Oldest 6 removed
      removed_ids = Enum.map(to_remove, & &1.id)
      assert removed_ids == [1, 2, 3, 4, 5, 6], "Expected oldest 6 removed"

      # POSITIVE: Newest 6 kept
      kept_ids = Enum.map(to_keep, & &1.id)
      assert 12 in kept_ids, "Newest (id:12) should be kept"
      assert 7 in kept_ids, "id:7 should be kept"

      # Reverse for LLM (oldest-first)
      messages = Enum.reverse(to_keep)

      # Inject ACE
      result = AceInjector.inject_ace_context(state, messages, model_id)

      # POSITIVE: ACE in first user message
      first_user = Enum.find(result, &(&1.role == "user"))
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "API requires auth header"
      assert first_user.content =~ "[Fact]"
      assert first_user.content =~ "User prefers concise responses"
      assert first_user.content =~ "[Pattern]"
      assert first_user.content =~ "<state>"
      assert first_user.content =~ "60% complete"

      # POSITIVE: First user is oldest kept user (id:7)
      assert first_user.id == 7, "ACE should be in oldest kept user (id:7)"

      # NEGATIVE: ACE not in other messages
      other_users = Enum.filter(result, &(&1.role == "user" && &1.id != 7))

      for msg <- other_users do
        refute msg.content =~ "<lessons>", "ACE should only be in first user"
      end

      # NEGATIVE: Original content preserved
      assert first_user.content =~ "Conversation message 7"
    end
  end

  # ========== A1: UI VISIBILITY (ACCEPTANCE) ==========

  describe "A1: UI visibility after condensation" do
    @tag :acceptance
    test "lessons appear in conversation history after condensation" do
      # This acceptance test verifies the full user-observable flow:
      # 1. Agent accumulates lessons via condensation
      # 2. Next consensus query injects lessons into first user message
      # 3. Lessons visible in conversation history (not hidden in system messages)
      #
      # The test will fail until AceInjector is implemented - correct for TEST phase

      model_id = "test-model"
      lessons = [make_lesson("Learned from condensation", :factual, 0.9)]

      state = %{
        context_lessons: %{model_id => lessons},
        model_states: %{model_id => make_model_state("Task progress: 50%")}
      }

      messages = [
        make_message("user", "Continue working on the task"),
        make_message("assistant", "I'll proceed with the next step")
      ]

      # Inject ACE context (this is what makes lessons visible in UI)
      result = AceInjector.inject_ace_context(state, messages, model_id)

      # POSITIVE ASSERTION: Lessons should appear in first user message
      first_user = Enum.find(result, &(&1.role == "user"))
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "Learned from condensation"
      assert first_user.content =~ "[Fact]"

      # POSITIVE ASSERTION: State should also be visible
      assert first_user.content =~ "<state>"
      assert first_user.content =~ "Task progress: 50%"

      # NEGATIVE ASSERTION: Should NOT be in a system message
      system_messages = Enum.filter(result, &(&1.role == "system"))

      for msg <- system_messages do
        refute msg.content =~ "<lessons>"
        refute msg.content =~ "Learned from condensation"
      end

      # NEGATIVE ASSERTION: Original content preserved
      assert first_user.content =~ "Continue working on the task"
    end
  end
end
