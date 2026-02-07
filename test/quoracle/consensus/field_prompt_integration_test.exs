defmodule Quoracle.Consensus.FieldPromptIntegrationTest do
  @moduledoc """
  Integration tests for field-based prompts in consensus mechanism.
  Verifies that consensus properly combines action schema prompts with field-based prompts.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus
  alias Quoracle.Consensus.PromptBuilder

  describe "ensure_system_prompts/2 - integration" do
    @tag :integration
    test "WHEN field prompts provided THEN integrates into single system message" do
      messages = [
        %{role: "user", content: "What should I do next?"}
      ]

      field_prompts = %{
        system_prompt: "<role>Security Analyst</role><cognitive_style>cautious</cognitive_style>",
        user_prompt: "<task>Audit system for vulnerabilities</task>"
      }

      # v15.0: user_prompt no longer injected by SystemPromptInjector
      # Initial message now flows through history via MessageHandler
      enhanced_messages = Consensus.ensure_system_prompts(messages, field_prompts)

      # Should have: integrated system + original user (no field user_prompt injection)
      assert length(enhanced_messages) == 2

      # First should be integrated system prompt with both action schema and field config
      system_prompt = hd(enhanced_messages)
      assert system_prompt.role == "system"

      # Contains action schema
      assert String.contains?(system_prompt.content, "Available Actions")
      assert String.contains?(system_prompt.content, "spawn_child")
      assert String.contains?(system_prompt.content, "send_message")

      # Contains field configuration with XML tags preserved
      assert String.contains?(system_prompt.content, "<role>Security Analyst</role>")

      assert String.contains?(
               system_prompt.content,
               "<cognitive_style>cautious</cognitive_style>"
             )

      # Original message preserved at end (user_prompt not injected)
      assert List.last(enhanced_messages).content == "What should I do next?"
    end

    @tag :integration
    test "WHEN no field prompts THEN uses only action schema prompt" do
      messages = [
        %{role: "user", content: "Help me"}
      ]

      enhanced_messages = Consensus.ensure_system_prompts(messages, %{})

      # Should have action schema prompt and original message
      assert length(enhanced_messages) == 2
      assert hd(enhanced_messages).role == "system"
      assert String.contains?(hd(enhanced_messages).content, "Available Actions")
      assert List.last(enhanced_messages).content == "Help me"
    end

    @tag :integration
    test "WHEN field prompts already in messages THEN does not duplicate" do
      field_prompts = %{
        system_prompt: "<role>Developer</role>",
        user_prompt: "<task>Build feature</task>"
      }

      # Messages already contain field prompts
      messages = [
        %{role: "system", content: "<role>Developer</role>"},
        %{role: "user", content: "<task>Build feature</task>"},
        %{role: "user", content: "Continue working"}
      ]

      enhanced_messages = Consensus.ensure_system_prompts(messages, field_prompts)

      # Should add integrated system prompt but not duplicate user task prompt
      task_count =
        Enum.count(enhanced_messages, fn msg ->
          String.contains?(msg.content || "", "<task>Build feature</task>")
        end)

      # Not duplicated
      assert task_count == 1

      # Should have integrated system prompt with actions
      assert Enum.any?(enhanced_messages, fn msg ->
               msg.role == "system" && String.contains?(msg.content, "Available Actions")
             end)
    end
  end

  describe "build_system_prompt/2 with field_prompts" do
    @tag :unit
    test "WHEN field prompts provided THEN integrates optimally" do
      field_prompts = %{
        system_prompt: "<role>Architect</role><cognitive_style>strategic</cognitive_style>",
        user_prompt: "<task>Design microservices</task>"
      }

      integrated_prompt = PromptBuilder.build_system_prompt(field_prompts)

      # Should contain action documentation section
      assert String.contains?(integrated_prompt, "Available Actions")
      assert String.contains?(integrated_prompt, "spawn_child")
      assert String.contains?(integrated_prompt, "execute_shell")

      # Should contain field prompts with XML tags preserved
      assert String.contains?(integrated_prompt, "<role>Architect</role>")
      assert String.contains?(integrated_prompt, "<cognitive_style>strategic</cognitive_style>")

      # Should contain proper structure markers from action schema
      assert String.contains?(integrated_prompt, "Response Format")
      assert String.contains?(integrated_prompt, "JSON Schema")
    end

    @tag :unit
    test "WHEN cognitive style present THEN integrates" do
      field_prompts = %{
        system_prompt: "<role>Analyst</role><cognitive_style>analytical</cognitive_style>"
      }

      integrated_prompt = PromptBuilder.build_system_prompt(field_prompts)

      # Should preserve XML tags
      assert String.contains?(integrated_prompt, "<role>Analyst</role>")
      assert String.contains?(integrated_prompt, "<cognitive_style>analytical</cognitive_style>")

      # Should maintain action documentation
      assert String.contains?(integrated_prompt, "Available Actions")
    end

    @tag :unit
    test "WHEN global constraints present THEN preserves XML tags" do
      field_prompts = %{
        system_prompt: """
        <role>Engineer</role>
        <global_constraints>
        - Never use deprecated APIs
        - Always validate input
        </global_constraints>
        """
      }

      integrated_prompt = PromptBuilder.build_system_prompt(field_prompts)

      # Should preserve XML tags and content
      assert String.contains?(integrated_prompt, "<role>Engineer</role>")
      assert String.contains?(integrated_prompt, "<global_constraints>")
      assert String.contains?(integrated_prompt, "Never use deprecated APIs")
      assert String.contains?(integrated_prompt, "Always validate input")
    end
  end

  describe "get_consensus/2 - field prompt flow" do
    @tag :integration
    test "WHEN agent state includes field prompts THEN consensus uses them" do
      # Mock messages that would come from ContextManager with field prompts
      messages_with_fields = [
        # Action schema
        %{role: "system", content: PromptBuilder.build_system_prompt()},
        # Field system
        %{
          role: "system",
          content: "<role>Reviewer</role><cognitive_style>thorough</cognitive_style>"
        },
        # Field user
        %{
          role: "user",
          content: "<task>Review code changes</task><success_criteria>No bugs</success_criteria>"
        },
        # Current question
        %{role: "user", content: "What's my next action?"}
      ]

      opts = [test_mode: true, models: [:test_model]]

      # Consensus should work with combined prompts
      result = Consensus.get_consensus(messages_with_fields, opts)

      assert {:ok, _consensus_result} = result

      # The decision should be informed by both prompt types
      # (actual decision will be mocked in test mode)
    end

    @tag :integration
    test "WHEN field prompts shape agent behavior THEN decisions reflect role and style" do
      analytical_messages = [
        %{role: "system", content: PromptBuilder.build_system_prompt()},
        %{
          role: "system",
          content: "<role>Data Scientist</role><cognitive_style>analytical</cognitive_style>"
        },
        %{role: "user", content: "<task>Analyze dataset</task>"},
        %{role: "user", content: "Found unexpected pattern in data"}
      ]

      creative_messages = [
        %{role: "system", content: PromptBuilder.build_system_prompt()},
        %{
          role: "system",
          content: "<role>Designer</role><cognitive_style>creative</cognitive_style>"
        },
        %{role: "user", content: "<task>Design new interface</task>"},
        %{role: "user", content: "Found unexpected pattern in data"}
      ]

      opts = [test_mode: true, models: [:test_model]]

      # Both should get consensus, but potentially different decisions based on role/style
      analytical_result = Consensus.get_consensus(analytical_messages, opts)
      creative_result = Consensus.get_consensus(creative_messages, opts)

      assert {:ok, _} = analytical_result
      assert {:ok, _} = creative_result

      # In production, these would likely produce different action choices
      # based on the cognitive style and role guidance
    end
  end

  describe "extract_field_prompts/1 - field prompt extraction" do
    @tag :unit
    test "WHEN messages contain field prompts THEN extracts them correctly" do
      messages = [
        %{role: "system", content: "Action documentation here"},
        %{
          role: "system",
          content: "<role>Manager</role><cognitive_style>decisive</cognitive_style>"
        },
        %{role: "user", content: "<task>Coordinate team</task>"},
        %{role: "user", content: "Regular message"}
      ]

      field_prompts = Consensus.extract_field_prompts(messages)

      assert field_prompts.system_prompt ==
               "<role>Manager</role><cognitive_style>decisive</cognitive_style>"

      assert field_prompts.user_prompt == "<task>Coordinate team</task>"
    end

    @tag :unit
    test "WHEN messages lack field prompts THEN returns empty map" do
      messages = [
        %{role: "system", content: "Just action docs"},
        %{role: "user", content: "Just a question"}
      ]

      field_prompts = Consensus.extract_field_prompts(messages)

      assert field_prompts == %{}
    end

    @tag :unit
    test "WHEN field prompts use XML tags THEN identifies them correctly" do
      messages = [
        %{role: "system", content: "<role>Engineer</role><output_style>concise</output_style>"},
        %{
          role: "user",
          content: "<task>Fix bug</task><approach_guidance>Test first</approach_guidance>"
        }
      ]

      field_prompts = Consensus.extract_field_prompts(messages)

      assert String.contains?(field_prompts.system_prompt, "<role>Engineer</role>")
      assert String.contains?(field_prompts.system_prompt, "<output_style>concise</output_style>")
      assert String.contains?(field_prompts.user_prompt, "<task>Fix bug</task>")

      assert String.contains?(
               field_prompts.user_prompt,
               "<approach_guidance>Test first</approach_guidance>"
             )
    end
  end
end
