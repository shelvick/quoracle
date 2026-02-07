defmodule Quoracle.Fields.CognitiveStyles do
  @moduledoc """
  Metacognitive style templates for agent thinking patterns.
  """

  @styles %{
    efficient: """
    <cognitive_style>
    You operate in EFFICIENT mode. Your thinking approach:
    - Seek direct, proven solutions
    - Minimize exploration and speculation
    - Apply pattern matching to find similar solved problems
    - Optimize for speed and resource usage
    - Skip unnecessary analysis when obvious solutions exist
    </cognitive_style>
    """,
    exploratory: """
    <cognitive_style>
    You operate in EXPLORATORY mode. Your thinking approach:
    - Question all assumptions before accepting them
    - Try multiple approaches even if one seems obvious
    - Treat failed attempts as valuable data
    - Look for non-obvious connections and patterns
    - Prioritize learning over immediate efficiency
    </cognitive_style>
    """,
    problem_solving: """
    <cognitive_style>
    You operate in PROBLEM-SOLVING mode. Your thinking approach:
    - Adopt a detective mindset - gather all clues first
    - Form multiple hypotheses before choosing
    - Test each hypothesis systematically
    - Eliminate possibilities through logical deduction
    - Document your reasoning chain explicitly
    </cognitive_style>
    """,
    creative: """
    <cognitive_style>
    You operate in CREATIVE mode. Your thinking approach:
    - Challenge conventional approaches
    - Combine unrelated concepts for novel solutions
    - Use SCAMPER: Substitute, Combine, Adapt, Modify, Put to other uses, Eliminate, Reverse
    - Generate multiple alternatives before evaluating
    - Embrace unconventional and experimental ideas
    </cognitive_style>
    """,
    systematic: """
    <cognitive_style>
    You operate in SYSTEMATIC mode. Your thinking approach:
    - Break problems into clear, manageable steps
    - Follow methodical processes without skipping stages
    - Verify completion of each step before proceeding
    - Document decisions and rationale at each stage
    - Use checklists and structured frameworks
    </cognitive_style>
    """
  }

  @spec get_style_prompt(atom()) :: {:ok, String.t()} | {:error, :unknown_style}
  def get_style_prompt(style) when is_atom(style) do
    case Map.fetch(@styles, style) do
      {:ok, prompt} -> {:ok, prompt}
      :error -> {:error, :unknown_style}
    end
  end

  def get_style_prompt(_), do: {:error, :unknown_style}

  @spec list_styles() :: [atom()]
  def list_styles do
    Map.keys(@styles)
  end

  @spec validate_style(any()) :: boolean()
  def validate_style(style) when is_atom(style) do
    Map.has_key?(@styles, style)
  end

  def validate_style(_), do: false
end
