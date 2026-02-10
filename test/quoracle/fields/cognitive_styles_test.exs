defmodule Quoracle.Fields.CognitiveStylesTest do
  @moduledoc """
  Tests for CognitiveStyles - metacognitive style templates.
  Tests all ARC verification criteria from the specification.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Fields.CognitiveStyles

  describe "get_style_prompt/1" do
    # R1: Style Retrieval
    test "retrieves prompt for valid style" do
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(:efficient)
      assert is_binary(prompt)
      assert prompt =~ "EFFICIENT"
      assert prompt =~ "proven solutions"
      assert prompt =~ "Minimize exploration"
    end

    test "retrieves exploratory style prompt" do
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(:exploratory)
      assert is_binary(prompt)
      assert prompt =~ "EXPLORATORY"
      assert prompt =~ "Question all assumptions"
      assert prompt =~ "multiple approaches"
    end

    test "retrieves problem_solving style prompt" do
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(:problem_solving)
      assert is_binary(prompt)
      assert prompt =~ "PROBLEM-SOLVING"
      assert prompt =~ "detective mindset"
      assert prompt =~ "hypotheses"
    end

    test "retrieves creative style prompt" do
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(:creative)
      assert is_binary(prompt)
      assert prompt =~ "CREATIVE"
      assert prompt =~ "SCAMPER"
      assert prompt =~ "unconventional"
    end

    test "retrieves systematic style prompt" do
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(:systematic)
      assert is_binary(prompt)
      assert prompt =~ "SYSTEMATIC"
      assert prompt =~ "methodical"
      assert prompt =~ "checklists"
    end

    # R2: Unknown Style Handling
    test "returns error for unknown style" do
      assert {:error, :unknown_style} = CognitiveStyles.get_style_prompt(:unknown_style)
      assert {:error, :unknown_style} = CognitiveStyles.get_style_prompt(:invalid)
      assert {:error, :unknown_style} = CognitiveStyles.get_style_prompt(:nonexistent)
    end

    test "handles nil style" do
      assert {:error, :unknown_style} = CognitiveStyles.get_style_prompt(nil)
    end

    test "handles string instead of atom" do
      # Should only accept atoms
      assert {:error, :unknown_style} = CognitiveStyles.get_style_prompt("efficient")
    end
  end

  describe "list_styles/0" do
    # R3: Style List
    test "lists all available styles" do
      styles = CognitiveStyles.list_styles()

      assert is_list(styles)
      assert length(styles) == 5
      assert :efficient in styles
      assert :exploratory in styles
      assert :problem_solving in styles
      assert :creative in styles
      assert :systematic in styles
    end

    test "returns consistent style list" do
      # Should always return same list
      list1 = CognitiveStyles.list_styles()
      list2 = CognitiveStyles.list_styles()

      assert list1 == list2
    end
  end

  describe "validate_style/1" do
    # R4: Style Validation
    test "validates known styles" do
      assert CognitiveStyles.validate_style(:efficient) == true
      assert CognitiveStyles.validate_style(:exploratory) == true
      assert CognitiveStyles.validate_style(:problem_solving) == true
      assert CognitiveStyles.validate_style(:creative) == true
      assert CognitiveStyles.validate_style(:systematic) == true
    end

    test "returns false for unknown styles" do
      assert CognitiveStyles.validate_style(:unknown) == false
      assert CognitiveStyles.validate_style(:invalid_style) == false
      assert CognitiveStyles.validate_style(nil) == false
    end

    test "only accepts atoms" do
      assert CognitiveStyles.validate_style("efficient") == false
      assert CognitiveStyles.validate_style(123) == false
      assert CognitiveStyles.validate_style(%{}) == false
    end
  end

  describe "style prompt content" do
    # R5: XML Tag Format
    test "style prompts use XML tags" do
      styles = CognitiveStyles.list_styles()

      for style <- styles do
        {:ok, prompt} = CognitiveStyles.get_style_prompt(style)

        # Check for opening and closing XML tags
        assert prompt =~ "<cognitive_style>"
        assert prompt =~ "</cognitive_style>"
      end
    end

    # R6: Content Uniqueness
    test "each style has distinct prompt content" do
      styles = CognitiveStyles.list_styles()

      prompts =
        Enum.map(styles, fn style ->
          {:ok, prompt} = CognitiveStyles.get_style_prompt(style)
          prompt
        end)

      # All prompts should be unique
      unique_prompts = Enum.uniq(prompts)
      assert length(unique_prompts) == length(prompts)
    end

    test "efficient style contains expected keywords" do
      {:ok, prompt} = CognitiveStyles.get_style_prompt(:efficient)

      expected_keywords = [
        "direct",
        "proven solutions",
        "Minimize exploration",
        "pattern matching",
        "speed",
        "resource usage"
      ]

      for keyword <- expected_keywords do
        assert prompt =~ keyword,
               "Expected efficient style to contain '#{keyword}'"
      end
    end

    test "exploratory style contains expected keywords" do
      {:ok, prompt} = CognitiveStyles.get_style_prompt(:exploratory)

      expected_keywords = [
        "Question",
        "assumptions",
        "multiple approaches",
        "failed attempts",
        "valuable data",
        "non-obvious",
        "learning"
      ]

      for keyword <- expected_keywords do
        assert prompt =~ keyword,
               "Expected exploratory style to contain '#{keyword}'"
      end
    end

    test "problem_solving style contains expected keywords" do
      {:ok, prompt} = CognitiveStyles.get_style_prompt(:problem_solving)

      expected_keywords = [
        "detective mindset",
        "clues",
        "hypotheses",
        "Test",
        "systematically",
        "logical deduction",
        "reasoning chain"
      ]

      for keyword <- expected_keywords do
        assert prompt =~ keyword,
               "Expected problem_solving style to contain '#{keyword}'"
      end
    end

    test "creative style contains expected keywords" do
      {:ok, prompt} = CognitiveStyles.get_style_prompt(:creative)

      expected_keywords = [
        "Challenge conventional",
        "unrelated concepts",
        "novel solutions",
        "SCAMPER",
        "Substitute",
        "Combine",
        "Adapt",
        "Modify",
        "Eliminate",
        "Reverse",
        "unconventional",
        "experimental"
      ]

      for keyword <- expected_keywords do
        assert prompt =~ keyword,
               "Expected creative style to contain '#{keyword}'"
      end
    end

    test "systematic style contains expected keywords" do
      {:ok, prompt} = CognitiveStyles.get_style_prompt(:systematic)

      expected_keywords = [
        "manageable steps",
        "methodical processes",
        "Verify completion",
        "Document decisions",
        "rationale",
        "checklists",
        "structured frameworks"
      ]

      for keyword <- expected_keywords do
        assert prompt =~ keyword,
               "Expected systematic style to contain '#{keyword}'"
      end
    end

    test "all style prompts have consistent structure" do
      styles = CognitiveStyles.list_styles()

      for style <- styles do
        {:ok, prompt} = CognitiveStyles.get_style_prompt(style)

        # Each should start with XML tag
        assert prompt =~ ~r/^\s*<cognitive_style>/

        # Each should mention the style name in uppercase
        style_name = style |> to_string() |> String.upcase() |> String.replace("_", "-")
        assert prompt =~ style_name

        # Each should have "Your thinking approach:" section
        assert prompt =~ "Your thinking approach:"

        # Each should have bullet points (at least 3)
        bullet_count = prompt |> String.split("- ") |> length()
        assert bullet_count >= 4, "Expected at least 3 bullet points in #{style}"

        # Each should end with XML closing tag
        assert prompt =~ ~r/<\/cognitive_style>\s*$/
      end
    end
  end

  describe "usage patterns" do
    test "style can be retrieved and validated in sequence" do
      style = :efficient

      # First validate
      assert CognitiveStyles.validate_style(style) == true

      # Then retrieve
      assert {:ok, prompt} = CognitiveStyles.get_style_prompt(style)
      assert is_binary(prompt)
    end

    test "can iterate through all styles" do
      styles = CognitiveStyles.list_styles()

      for style <- styles do
        assert CognitiveStyles.validate_style(style) == true
        assert {:ok, prompt} = CognitiveStyles.get_style_prompt(style)
        # Should have substantial content
        assert String.length(prompt) > 100
      end
    end

    test "handles style selection workflow" do
      # Simulate selecting a style from available options
      available = CognitiveStyles.list_styles()
      selected = Enum.random(available)

      assert CognitiveStyles.validate_style(selected) == true
      assert {:ok, _prompt} = CognitiveStyles.get_style_prompt(selected)
    end
  end

  describe "error handling" do
    test "gracefully handles various invalid inputs" do
      invalid_inputs = [
        :not_a_style,
        "string_style",
        123,
        nil,
        [],
        %{},
        true,
        false
      ]

      for input <- invalid_inputs do
        assert CognitiveStyles.get_style_prompt(input) == {:error, :unknown_style}
        assert CognitiveStyles.validate_style(input) == false
      end
    end
  end
end
