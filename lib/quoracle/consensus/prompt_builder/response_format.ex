defmodule Quoracle.Consensus.PromptBuilder.ResponseFormat do
  @moduledoc """
  Response format documentation for the system prompt.

  Extracted from Sections to improve maintainability. Contains:
  - Response JSON schema
  - Wait parameter documentation
  - Auto-complete TODO documentation
  - Bug report field documentation
  - Condense parameter documentation
  - Action examples (delegated to Examples module)
  """

  alias Quoracle.Consensus.PromptBuilder.Examples

  @doc """
  Builds the complete response format section for the system prompt.

  This section tells the LLM how to structure its JSON response, including
  the reasoning/action/params structure and optional parameters like wait,
  auto_complete_todo, bug_report, and condense.
  """
  @spec build_format_section([atom()] | nil) :: String.t()
  def build_format_section(allowed_actions \\ nil) do
    """
    ## Response Format

    IMPORTANT: Your entire response must be a single, raw JSON object — nothing else. Think through your reasoning BEFORE deciding on an action, then put that reasoning in the "reasoning" field. Do NOT write any text outside the JSON object. No explanations, no markdown, no commentary.

    #{response_json_schema()}

    #{grounding_verification_docs()}

    #{Examples.build_action_examples(allowed_actions)}

    #{wait_parameter_docs()}

    #{auto_complete_todo_docs()}

    #{bug_report_docs()}

    #{condense_parameter_docs()}

    #{important_notes()}
    """
    |> String.trim()
  end

  @doc "Response JSON schema documentation."
  @spec response_json_schema() :: String.t()
  def response_json_schema do
    """
    <response_schema>
    {
      "type": "object",
      "properties": {
        "reasoning": {
          "type": "string",
          "description": "Your thought process BEFORE choosing an action. Analyze the situation, consider options, then decide. ALL reasoning goes here - never outside the JSON."
        },
        "action": {
          "type": "string",
          "description": "The action you decided on after reasoning"
        },
        "params": {
          "type": "object",
          "description": "COMPLETE parameter specification for your chosen action. Must be self-contained with all values explicitly stated - do NOT reference external context like 'Proposal 2' or 'parameters mentioned above'."
        },
        "wait": {
          "type": ["boolean", "integer"],
          "minimum": 0,
          "description": "Controls flow continuation (required for all actions except :wait)"
        },
        "auto_complete_todo": {
          "type": "boolean",
          "description": "When true, marks the first TODO item as done after successful action execution (optional for all actions except :todo)"
        },
        "bug_report": {
          "type": "string",
          "description": "Optional diagnostic field for reporting issues with prompts, unexpected issues/errors, or confusing instructions. Does not affect system behavior - used for logging only."
        },
        "condense": {
          "type": "integer",
          "minimum": 1,
          "description": "Request condensation of your N oldest messages to free context space (optional)"
        }
      },
      "required": ["reasoning", "action", "params"],
      "additionalProperties": false
    }
    </response_schema>
    """
    |> String.trim()
  end

  @doc "Wait parameter documentation."
  @spec wait_parameter_docs() :: String.t()
  def wait_parameter_docs do
    """
    Wait Parameter:
    All actions (except the :wait action itself) require a "wait" parameter that controls flow continuation:
    - false or 0: Continue immediately (use when you have more work to do right now)
    - true: Block until new external message arrives (parent, child, or other event)
    - integer > 0: Timer-based check-in - continue after N seconds if no message (use to periodically check on long-running work)

    IMPORTANT - Wait behavior differs by action type:
    - INTERNAL actions (messaging, planning, configuration): These complete instantly (<1ms).
      Use wait:false to continue to your next action (TYPICAL).
      Only use wait:true if you are explicitly waiting for an external message (e.g., reply from parent/child).
      WARNING: wait:true on internal actions will STALL indefinitely if no external message arrives!
    - EXTERNAL actions (API calls, web fetches, shell commands, MCP): These may take seconds to minutes.
      Use wait:true when you need the result before continuing. Use wait:false to proceed in parallel.
    """
    |> String.trim()
  end

  @doc "Auto-complete TODO parameter documentation."
  @spec auto_complete_todo_docs() :: String.t()
  def auto_complete_todo_docs do
    """
    Auto-Complete TODO Parameter:
    All actions (except the :todo action itself) support an optional "auto_complete_todo" parameter:
    - true: Marks the first TODO item as done after successful action execution
    - false or omitted: No automatic TODO completion (default behavior)
    """
    |> String.trim()
  end

  @doc "Bug report field documentation."
  @spec bug_report_docs() :: String.t()
  def bug_report_docs do
    """
    Bug Report Field:
    All actions support an optional "bug_report" field at the response level (not in params).
    Use when: prompts seem contradictory, requests are malformed, expected context is missing, or you detect errors the system should have handled.
    Omit when: everything appears normal (most responses).

    IMPORTANT: When writing a bug report, assume the developer reading it knows NOTHING about your agent, task, or conversation. Include enough context to debug:
    - Your role and profile
    - The last 1-2 relevant messages from your conversation history
    - What action you were attempting and why
    - What specifically confused you or went wrong

    This field is for diagnostics only and does not affect your action execution or the consensus process.
    """
    |> String.trim()
  end

  @doc "Grounding verification guidance (Pythea-inspired self-check)."
  @spec grounding_verification_docs() :: String.t()
  def grounding_verification_docs do
    """
    Grounding Your Reasoning:
    Before finalizing your action, reflect on what's driving your choice:

    1. **Know your basis**: Is this action driven by something in your context
       (messages, results, instructions), or by general patterns of "what agents do"?
       Both can be valid, but you should know which it is.

    2. **Be specific when you can**: If your reasoning references context ("the user
       asked for X", "based on the output"), verify those references are accurate.
       Don't fabricate supporting evidence.

    3. **Exploration is fine**: When figuring out HOW to do something, inference and
       experimentation are expected. The goal isn't to restrict action - it's to be
       honest about whether you're responding to THIS situation vs. a similar one
       from training.
    """
    |> String.trim()
  end

  @doc "Condense parameter documentation."
  @spec condense_parameter_docs() :: String.t()
  def condense_parameter_docs do
    """
    Condense Parameter:
    All actions support an optional "condense" parameter to request inline message condensation:
    - Positive integer N: Condense your N oldest conversation messages (not counting system prompt) into lessons/summaries
    - Omitted: No condensation (default behavior)

    **Condense proactively, not reactively.** The `<ctx>` tag in your messages shows your current token count. Condense when:
    - You've completed a subtask and are moving to something new
    - The topic or approach has shifted significantly
    - Your history contains "junk" - large command outputs, web page content, verbose API responses
    - Earlier messages are now stale (superseded by newer information or decisions)

    The cost of condensing is trivial. The cost of dragging stale context through every future query is substantial - both in tokens and in polluting your reasoning with irrelevant history.
    """
    |> String.trim()
  end

  @doc "Important notes about response format."
  @spec important_notes() :: String.t()
  def important_notes do
    """
    Important:
    - You must select exactly ONE action per response
    - Include all required parameters for the chosen action
    - Include the "wait" parameter for all actions except :wait
    - Optionally include "auto_complete_todo": true to mark first TODO as done after action succeeds
    - Provide clear reasoning for your decision
    - Your response MUST be a single raw JSON object. No preamble, no postamble, no markdown code fences, no explanation. Start with { and end with }.
    """
    |> String.trim()
  end
end
