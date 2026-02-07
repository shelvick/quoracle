defmodule Mix.Tasks.Quoracle.ShowLlmPrompts do
  @moduledoc """
  Displays complete LLM conversation histories for various scenarios.
  Shows VERBATIM prompts by calling actual prompt construction code.

  ## Usage

      mix quoracle.show_llm_prompts <scenario>

  ## Available Scenarios

      generalist_initial       - Generalist agent's first interaction
      generalist_with_history  - Generalist after several actions
      with_fields_full         - Agent with all 11 hierarchical fields
      with_cognitive_style     - Agent with specific cognitive style
      refinement_round         - Consensus refinement (no majority)
      with_secrets             - Agent with available secrets
      consensus_immediate      - Immediate consensus (3 models agree, round 1)
      consensus_exact_match_params - execute_shell params must match exactly
      consensus_semantic_params    - spawn_child params with semantic matching
      consensus_different_actions  - Models disagree on action type initially
      consensus_max_rounds         - No convergence, forced decision after 5 rounds
      consensus_cluster_merge      - 2-1 split, minority swayed in refinement
      all                      - Show all scenarios

  ## Examples

      mix quoracle.show_llm_prompts generalist_initial
      mix quoracle.show_llm_prompts with_fields_full
      mix quoracle.show_llm_prompts all
  """

  use Mix.Task

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Fields.{PromptFieldManager, CognitiveStyles}

  @shortdoc "Display verbatim LLM conversation histories for scenarios"

  @scenarios [
    :generalist_initial,
    :generalist_with_history,
    :with_fields_full,
    :with_cognitive_style,
    :refinement_round,
    :with_secrets,
    :consensus_immediate,
    :consensus_exact_match_params,
    :consensus_semantic_params,
    :consensus_different_actions,
    :consensus_max_rounds,
    :consensus_cluster_merge,
    :all
  ]

  def run(args) do
    # Start the application and Repo for DB access
    {:ok, _} = Application.ensure_all_started(:quoracle)

    case args do
      [] ->
        show_usage()

      [scenario_name] ->
        # Safe atom conversion - only converts if atom already exists
        scenario =
          try do
            String.to_existing_atom(scenario_name)
          rescue
            ArgumentError -> :unknown_scenario
          end

        if scenario in @scenarios do
          if scenario == :all do
            show_all_scenarios()
          else
            show_scenario(scenario)
          end
        else
          IO.puts("❌ Unknown scenario: #{scenario_name}\n")
          show_usage()
        end

      _ ->
        IO.puts("❌ Too many arguments\n")
        show_usage()
    end
  end

  defp show_usage do
    IO.puts("""
    Usage: mix quoracle.show_llm_prompts <scenario>

    Available scenarios:
    #{Enum.map_join(@scenarios, "\n", fn s -> "  - #{s}" end)}
    """)
  end

  defp show_all_scenarios do
    # Show all except :all itself
    @scenarios
    |> Enum.reject(&(&1 == :all))
    |> Enum.each(fn scenario ->
      show_scenario(scenario)
      IO.puts("\n" <> String.duplicate("=", 100) <> "\n")
    end)
  end

  defp show_scenario(scenario) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("SCENARIO: #{scenario}")
    IO.puts(String.duplicate("=", 100) <> "\n")

    messages = build_messages_for_scenario(scenario)
    display_messages(messages)
  end

  # ============================================================================
  # Scenario Builders - Each calls REAL prompt construction code
  # ============================================================================

  defp build_messages_for_scenario(:generalist_initial) do
    # Generalist agent, first interaction, no history
    # Calls actual PromptBuilder functions
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_prompt = "$INITIAL_TASK_DESCRIPTION"

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]
  end

  defp build_messages_for_scenario(:generalist_with_history) do
    # Generalist with conversation history
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "$INITIAL_TASK"},
      %{
        role: "assistant",
        content: """
        {
          "action": "orient",
          "params": {
            "current_situation": "Starting new task with data analysis request",
            "goal_clarity": "Need to analyze CSV file at /path/to/data.csv to identify structure and patterns",
            "available_resources": "Shell access, file system read permissions, web search capability",
            "key_challenges": "Unknown data format and size, need to inspect before processing"
          },
          "wait": false,
          "reasoning": "Need to understand the task before proceeding"
        }
        """
      },
      %{
        role: "user",
        content: """
        <action_result action="orient">
        {
          "action": "orient",
          "current_situation": "Starting new task with data analysis request",
          "goal_clarity": "Need to analyze CSV file at /path/to/data.csv to identify structure and patterns",
          "available_resources": "Shell access, file system read permissions, web search capability",
          "key_challenges": "Unknown data format and size, need to inspect before processing",
          "timestamp": "2024-01-15T10:30:00Z",
          "agent_id": "$AGENT_ID"
        }
        </action_result>
        """
      },
      %{
        role: "assistant",
        content: """
        {
          "action": "execute_shell",
          "params": {
            "command": "head -20 /path/to/data.csv"
          },
          "wait": true,
          "reasoning": "Need to examine data structure before analysis"
        }
        """
      },
      %{
        role: "user",
        content: """
        <NO_EXECUTE_a1b2c3d4>
        <action_result action="execute_shell">
        id,name,value,timestamp
        1,Alice,42,2024-01-15T10:30:00Z
        2,Bob,37,2024-01-15T11:45:00Z
        ...
        </action_result>
        </NO_EXECUTE_a1b2c3d4>
        """
      },
      %{role: "user", content: "$NEXT_USER_MESSAGE"}
    ]
  end

  defp build_messages_for_scenario(:with_fields_full) do
    # Agent with all 11 hierarchical prompt fields
    fields = %{
      provided: %{
        role: "$AGENT_ROLE",
        cognitive_style: "exploratory",
        output_style: "$OUTPUT_STYLE_PREFERENCE",
        delegation_strategy: "$DELEGATION_APPROACH",
        task_description: "$TASK_DESCRIPTION",
        success_criteria: "$SUCCESS_CRITERIA",
        immediate_context: "$IMMEDIATE_CONTEXT",
        approach_guidance: "$APPROACH_GUIDANCE",
        sibling_context: [
          %{agent_id: "$SIBLING_1_ID", task: "$SIBLING_1_TASK"},
          %{agent_id: "$SIBLING_2_ID", task: "$SIBLING_2_TASK"}
        ]
      },
      transformed: %{
        constraints: ["$CONSTRAINT_1", "$CONSTRAINT_2", "$CONSTRAINT_3"],
        accumulated_narrative: "$PARENT_NARRATIVE_SUMMARY"
      },
      injected: %{
        global_context: "$GLOBAL_CONTEXT_FROM_TASK"
      }
    }

    {system_prompt, user_prompt} = PromptFieldManager.build_prompts_from_fields(fields)

    # Build action schema prompt with field prompts integrated
    action_schema_prompt =
      PromptBuilder.build_system_prompt_with_context(
        field_prompts: %{system_prompt: system_prompt}
      )

    [
      %{role: "system", content: action_schema_prompt},
      %{role: "user", content: user_prompt}
    ]
  end

  defp build_messages_for_scenario(:with_cognitive_style) do
    # Generalist agent with specific cognitive style
    {:ok, cognitive_style_prompt} = CognitiveStyles.get_style_prompt(:problem_solving)

    field_prompts = %{
      system_prompt: cognitive_style_prompt
    }

    system_prompt =
      PromptBuilder.build_system_prompt_with_context(field_prompts: field_prompts)

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "$DEBUGGING_TASK"}
    ]
  end

  defp build_messages_for_scenario(:refinement_round) do
    # Consensus refinement when no majority reached
    # In production, refinement prompts are appended to per-model histories
    # via MessageBuilder. This shows a representative example.
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "$ORIGINAL_TASK"},
      %{role: "assistant", content: "$PREVIOUS_DECISION"},
      %{
        role: "user",
        content: """
        ## Consensus Refinement - Round 2

        The models did not reach consensus. Here are the divergent responses:

        **Cluster 1 (40% - 2 models):**
        - Action: spawn_child
        - Reasoning: "Need delegation for database analysis"

        **Cluster 2 (40% - 2 models):**
        - Action: execute_shell
        - Reasoning: "Can analyze data directly with shell commands"

        **Cluster 3 (20% - 1 model):**
        - Action: orient
        - Reasoning: "Need more information before proceeding"

        Please reconsider and provide your best action choice.
        """
      }
    ]
  end

  defp build_messages_for_scenario(:with_secrets) do
    # Generalist agent with available secrets for API access
    # The secrets section is automatically included in build_system_prompt_with_context
    # via format_available_secrets() call inside add_capabilities_section
    base_system_prompt = PromptBuilder.build_system_prompt_with_context()

    [
      %{role: "system", content: base_system_prompt},
      %{role: "user", content: "$TASK_REQUIRING_API_AUTHENTICATION"}
    ]
  end

  # ============================================================================
  # Consensus Scenarios - Multi-Round Parameter Matching
  # ============================================================================

  defp build_messages_for_scenario(:consensus_immediate) do
    # Scenario: All 3 models agree immediately (>50% consensus on first round)
    # Action: orient (has semantic_similarity rules with 0.8 threshold)
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial =
      "Analyze the current system state and identify the best approach for database migration."

    # Round 1: All 3 models agree on orient with identical parameters
    assistant_1a =
      mock_action_response(
        :orient,
        %{
          current_situation: "Database migration needed from PostgreSQL 12 to 14",
          goal_clarity: "Clear: migrate database while maintaining zero downtime",
          available_resources: "Blue-green deployment setup, backup system, monitoring tools",
          key_challenges: "Large dataset (500GB), need to maintain service availability"
        },
        "Need to understand current state before making migration plan"
      )

    assistant_1b =
      mock_action_response(
        :orient,
        %{
          current_situation: "Database migration needed from PostgreSQL 12 to 14",
          goal_clarity: "Clear: migrate database while maintaining zero downtime",
          available_resources: "Blue-green deployment setup, backup system, monitoring tools",
          key_challenges: "Large dataset (500GB), need to maintain service availability"
        },
        "Understanding the situation is critical for planning the migration"
      )

    assistant_1c =
      mock_action_response(
        :orient,
        %{
          current_situation: "Database migration needed from PostgreSQL 12 to 14",
          goal_clarity: "Clear: migrate database while maintaining zero downtime",
          available_resources: "Blue-green deployment setup, backup system, monitoring tools",
          key_challenges: "Large dataset (500GB), need to maintain service availability"
        },
        "Must assess current situation before proceeding with migration"
      )

    analysis = """

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    CONSENSUS ANALYSIS
    ═══════════════════════════════════════════════════════════════════════════════════════════════

    Round 1 Results:
    ✓ CONSENSUS REACHED (100% - 3/3 models)

    Action: orient
    Cluster Analysis:
      • Cluster 1: 3 models (100%)
        - All parameters identical
        - Semantic similarity: 1.0 (exact match)

    Consensus Rule: semantic_similarity (threshold: 0.8)
    Result: Immediate consensus - all models chose identical action and parameters

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{role: "analysis", content: analysis}
    ]
  end

  defp build_messages_for_scenario(:consensus_exact_match_params) do
    # Scenario: execute_shell requires exact_match - takes 3 rounds to converge
    # Shows how exact_match params must be identical (not just similar)
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial = "Check what files are in the current directory."

    # Round 1: 3 different shell commands
    assistant_1a =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Use ls with long format to see all details"
      )

    assistant_1b =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -lh"
        },
        "Use ls with human-readable sizes"
      )

    assistant_1c =
      mock_action_response(
        :execute_shell,
        %{
          command: "find . -maxdepth 1"
        },
        "Use find for more control"
      )

    refinement_1 = """
    Round 2 refinement for goal: Check what files are in the current directory.

    All proposed actions (JSON format):
    #{assistant_1a}

    #{assistant_1b}

    #{assistant_1c}

    Please review all proposals and decide on ONE action.
    Consider which action best serves the goal.

    Respond with your chosen action in JSON format.
    """

    # Round 2: 2 models converge to ls -la, 1 still different
    assistant_2a =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Long format with hidden files is most comprehensive"
      )

    assistant_2b =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Agree that ls -la provides the most complete view"
      )

    assistant_2c =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls"
        },
        "Simple ls is sufficient for basic listing"
      )

    refinement_2 = """
    Round 3 refinement for goal: Check what files are in the current directory.

    All proposed actions (JSON format):
    #{assistant_2a}

    #{assistant_2b}

    #{assistant_2c}

    Previous reasoning from earlier rounds:
    Round 1:
      - Use ls with long format to see all details
      - Use ls with human-readable sizes
      - Use find for more control

    Round 2:
      - Long format with hidden files is most comprehensive
      - Agree that ls -la provides the most complete view
      - Simple ls is sufficient for basic listing

    Please review all proposals and decide on ONE action.
    Consider which action best serves the goal.

    Respond with your chosen action in JSON format.
    """

    # Round 3: All converge to ls -la
    assistant_3a =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Consensus: ls -la provides complete visibility"
      )

    assistant_3b =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Agreed: ls -la is the standard choice"
      )

    assistant_3c =
      mock_action_response(
        :execute_shell,
        %{
          command: "ls -la"
        },
        "Converging to ls -la for consistency"
      )

    # Generate real consensus analysis using actual Aggregator code
    analysis =
      generate_real_consensus_analysis([
        {1, [assistant_1a, assistant_1b, assistant_1c]},
        {2, [assistant_2a, assistant_2b, assistant_2c]},
        {3, [assistant_3a, assistant_3b, assistant_3c]}
      ]) <>
        """

        Consensus Rule: exact_match (command parameter)
        Why consensus rules matter: Commands must be EXACTLY identical - "ls -la" ≠ "ls -lh" ≠ "find"
        Result: Converged after 3 rounds - exact string match achieved
        """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{role: "user", content: refinement_1},
      %{role: "assistant", content: assistant_2a, model: "a"},
      %{role: "assistant", content: assistant_2b, model: "b"},
      %{role: "assistant", content: assistant_2c, model: "c"},
      %{role: "user", content: refinement_2},
      %{role: "assistant", content: assistant_3a, model: "a"},
      %{role: "assistant", content: assistant_3b, model: "b"},
      %{role: "assistant", content: assistant_3c, model: "c"},
      %{role: "analysis", content: analysis}
    ]
  end

  defp build_messages_for_scenario(:consensus_semantic_params) do
    # Scenario: spawn_child with semantic_similarity on 6 text fields
    # Shows how semantically similar values across multiple fields cluster together
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial = "We need to understand our database structure before making changes."

    # Round 1: All 3 models choose spawn_child with semantically similar values across all 6 text fields
    assistant_1a =
      mock_action_response(
        :spawn_child,
        %{
          task_description:
            "Analyze the database schema to identify all tables, relationships, and constraints",
          success_criteria: "Complete schema documentation produced",
          immediate_context: "PostgreSQL 14 production database with 50+ tables",
          approach_guidance: "Start by querying information_schema, then examine foreign keys",
          role: "Database architect",
          downstream_constraints: "Read-only access, no modifications to production data"
        },
        "Need specialized analysis of database structure"
      )

    assistant_1b =
      mock_action_response(
        :spawn_child,
        %{
          task_description:
            "Examine database structure including tables, foreign keys, and indexes",
          success_criteria: "Full schema report generated",
          immediate_context: "PostgreSQL production system with approximately 50 tables",
          approach_guidance: "Begin with information_schema queries, then analyze relationships",
          role: "Database specialist",
          downstream_constraints: "Read-only operations only, no production modifications"
        },
        "Database structure analysis requires focused attention"
      )

    assistant_1c =
      mock_action_response(
        :spawn_child,
        %{
          task_description:
            "Review data model to understand table definitions, relationships, and key constraints",
          success_criteria: "Comprehensive schema analysis completed",
          immediate_context: "Postgres 14 database in production with 50+ tables",
          approach_guidance: "Query information_schema first, then map foreign key relationships",
          role: "Database expert",
          downstream_constraints:
            "No write operations allowed, production data must remain unchanged"
        },
        "Delegate schema analysis to specialized agent"
      )

    analysis = """

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    CONSENSUS ANALYSIS
    ═══════════════════════════════════════════════════════════════════════════════════════════════

    Round 1 Results:
    ✓ CONSENSUS REACHED (100% - 3/3 models)

    Action: spawn_child
    Cluster Analysis:
      • Cluster 1: 3 models (100%)
        - All 6 semantic text fields achieve consensus independently

    Semantic Fields Comparison (each evaluated separately with its own threshold):

    1. task_description (threshold: 0.95):
      Model A: "Analyze the database schema to identify all tables, relationships, and constraints"
      Model B: "Examine database structure including tables, foreign keys, and indexes"
      Model C: "Review data model to understand table definitions, relationships, and key constraints"
      → Semantic match: "Analyze" ≈ "Examine" ≈ "Review", "schema" ≈ "structure" ≈ "data model"

    2. success_criteria (threshold: 0.90):
      Model A: "Complete schema documentation produced"
      Model B: "Full schema report generated"
      Model C: "Comprehensive schema analysis completed"
      → Semantic match: "Complete documentation" ≈ "Full report" ≈ "Comprehensive analysis"

    3. immediate_context (threshold: 0.85):
      Model A: "PostgreSQL 14 production database with 50+ tables"
      Model B: "PostgreSQL production system with approximately 50 tables"
      Model C: "Postgres 14 database in production with 50+ tables"
      → Semantic match: Minor wording variations, same factual context

    4. approach_guidance (threshold: 0.85):
      Model A: "Start by querying information_schema, then examine foreign keys"
      Model B: "Begin with information_schema queries, then analyze relationships"
      Model C: "Query information_schema first, then map foreign key relationships"
      → Semantic match: Same methodology with different phrasing

    5. role (threshold: 0.90):
      Model A: "Database architect"
      Model B: "Database specialist"
      Model C: "Database expert"
      → Semantic match: All synonymous database expertise roles

    6. downstream_constraints (threshold: 0.90):
      Model A: "Read-only access, no modifications to production data"
      Model B: "Read-only operations only, no production modifications"
      Model C: "No write operations allowed, production data must remain unchanged"
      → Semantic match: Same constraint expressed differently

    Key Insight: Multi-field semantic matching enables consensus!
    - Each field is evaluated INDEPENDENTLY with its own threshold
    - Different wording but aligned MEANING across ALL fields → full consensus
    - This is the power of semantic matching - natural variation while ensuring aligned intent

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{role: "analysis", content: analysis}
    ]
  end

  defp build_messages_for_scenario(:consensus_different_actions) do
    # Scenario: Models disagree on action type initially, converge after refinement
    # Shows that action type must match before params are even considered
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial = "Figure out what's causing the high CPU usage on the server."

    # Round 1: Three completely different actions
    assistant_1a =
      mock_action_response(
        :execute_shell,
        %{
          command: "top -b -n 1"
        },
        "Check current processes to see CPU usage"
      )

    assistant_1b =
      mock_action_response(
        :fetch_web,
        %{
          url: "https://serverdocs.internal/troubleshooting/cpu"
        },
        "Consult documentation for CPU troubleshooting steps"
      )

    assistant_1c =
      mock_action_response(
        :orient,
        %{
          current_situation: "Server experiencing high CPU usage",
          goal_clarity: "Need to identify root cause",
          available_resources: "Shell access, monitoring tools, logs",
          key_challenges: "Unknown which process is causing the issue"
        },
        "Need to assess situation before taking action"
      )

    refinement_1 = """
    Round 2 refinement for goal: Figure out what's causing the high CPU usage on the server.

    All proposed actions (JSON format):
    #{assistant_1a}

    #{assistant_1b}

    #{assistant_1c}

    Please review all proposals and decide on ONE action.
    Consider which action best serves the goal.

    Respond with your chosen action in JSON format.
    """

    # Round 2: 2 models converge to execute_shell, 1 still wants orient
    assistant_2a =
      mock_action_response(
        :execute_shell,
        %{
          command: "top -b -n 1"
        },
        "Direct investigation is most efficient"
      )

    assistant_2b =
      mock_action_response(
        :execute_shell,
        %{
          command: "ps aux --sort=-%cpu | head -10"
        },
        "Check top CPU-consuming processes"
      )

    assistant_2c =
      mock_action_response(
        :orient,
        %{
          current_situation: "Server experiencing high CPU usage",
          goal_clarity: "Need to identify root cause",
          available_resources: "Shell access, monitoring tools",
          key_challenges: "Unknown process causing issue"
        },
        "Still think we should orient first"
      )

    refinement_2 = """
    Round 3 refinement for goal: Figure out what's causing the high CPU usage on the server.

    All proposed actions (JSON format):
    #{assistant_2a}

    #{assistant_2b}

    #{assistant_2c}

    Previous reasoning from earlier rounds:
    Round 1:
      - Check current processes to see CPU usage
      - Consult documentation for CPU troubleshooting steps
      - Need to assess situation before taking action

    Round 2:
      - Direct investigation is most efficient
      - Check top CPU-consuming processes
      - Still think we should orient first

    Please review all proposals and decide on ONE action.
    Consider which action best serves the goal.

    Respond with your chosen action in JSON format.
    """

    # Round 3: All converge to execute_shell with same command
    assistant_3a =
      mock_action_response(
        :execute_shell,
        %{
          command: "top -b -n 1"
        },
        "Consensus: direct investigation with top command"
      )

    assistant_3b =
      mock_action_response(
        :execute_shell,
        %{
          command: "top -b -n 1"
        },
        "Agreed: top command is standard for CPU analysis"
      )

    assistant_3c =
      mock_action_response(
        :execute_shell,
        %{
          command: "top -b -n 1"
        },
        "Converging: top provides immediate visibility"
      )

    # Generate real consensus analysis using actual Aggregator code
    analysis =
      generate_real_consensus_analysis([
        {1, [assistant_1a, assistant_1b, assistant_1c]},
        {2, [assistant_2a, assistant_2b, assistant_2c]},
        {3, [assistant_3a, assistant_3b, assistant_3c]}
      ]) <>
        """

        Consensus Journey:
        1. Round 1: Complete disagreement on action type
        2. Round 2: Action type convergence (67%), parameter divergence
        3. Round 3: Full consensus on both action AND parameters

        Key Insight: Action type must align first, then parameters can converge
        """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{role: "user", content: refinement_1},
      %{role: "assistant", content: assistant_2a, model: "a"},
      %{role: "assistant", content: assistant_2b, model: "b"},
      %{role: "assistant", content: assistant_2c, model: "c"},
      %{role: "user", content: refinement_2},
      %{role: "assistant", content: assistant_3a, model: "a"},
      %{role: "assistant", content: assistant_3b, model: "b"},
      %{role: "assistant", content: assistant_3c, model: "c"},
      %{role: "analysis", content: analysis}
    ]
  end

  defp build_messages_for_scenario(:consensus_max_rounds) do
    # Scenario: Models never converge - forced decision after 5 rounds
    # Shows what happens when parameter incompatibility prevents consensus
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial = "Delete the temporary files to free up disk space."

    # Round 1: Three different delete approaches
    assistant_1a =
      mock_action_response(
        :execute_shell,
        %{
          command: "rm -rf /tmp/*"
        },
        "Clean entire tmp directory"
      )

    assistant_1b =
      mock_action_response(
        :execute_shell,
        %{
          command: "find /tmp -type f -mtime +7 -delete"
        },
        "Delete only old files (7+ days)"
      )

    assistant_1c =
      mock_action_response(
        :execute_shell,
        %{
          command: "rm /tmp/*.tmp"
        },
        "Delete only .tmp files"
      )

    # Rounds 2-5: Models keep changing but never align
    # (abbreviated for space - showing pattern)

    # Generate real consensus analysis for Round 1 only (others abbreviated)
    round_1_analysis =
      generate_real_consensus_analysis([{1, [assistant_1a, assistant_1b, assistant_1c]}])

    analysis =
      round_1_analysis <>
        """

        Round 2-5: [Abbreviated] Models continue to propose different commands, never achieving >50%

        Final Result: {:forced_decision, ...}
        Command chosen: "find /tmp -type f -mtime +7 -delete" (plurality - would be selected by tiebreaker)

        Why no consensus:
        - execute_shell uses exact_match for command parameter
        - Commands are fundamentally incompatible:
          * "rm -rf /tmp/*" - DANGEROUS, deletes everything
          * "find /tmp -type f -mtime +7 -delete" - Safe, age-based
          * "rm /tmp/*.tmp" - Selective, extension-based
        - Models have valid disagreement about safety vs thoroughness tradeoff
        - No amount of refinement can bridge this fundamental approach difference

        Consensus Rule: exact_match - requires IDENTICAL command strings

        Key Insight: Some decisions genuinely don't have consensus!
        - When models fundamentally disagree on approach, forced decision selects plurality
        - This is a feature, not a bug - indicates genuine uncertainty that humans should review
        """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{
        role: "analysis",
        content:
          "[Rounds 2-4 omitted for brevity - models continue to propose different commands]\n\n" <>
            analysis
      }
    ]
  end

  defp build_messages_for_scenario(:consensus_cluster_merge) do
    # Scenario: 2-1 split, minority swayed in refinement
    # Shows how clustering and refinement influence minority opinions
    system_prompt = PromptBuilder.build_system_prompt_with_context()

    user_initial = "We need help analyzing the large dataset efficiently."

    # Round 1: 2 models want to spawn child, 1 wants to orient first
    # Note: task_description strings are nearly identical to ensure clustering (threshold 0.95)
    assistant_1a =
      mock_action_response(
        :spawn_child,
        %{
          task_description: "Analyze the large dataset to extract statistics and patterns",
          success_criteria: "Statistical summary and pattern report produced",
          immediate_context: "50GB CSV dataset needs analysis",
          approach_guidance: "Use data analysis tools to process the dataset",
          profile: "data_analyst"
        },
        "This requires specialized data analysis expertise"
      )

    assistant_1b =
      mock_action_response(
        :spawn_child,
        %{
          task_description: "Analyze the large dataset to extract statistics and patterns",
          success_criteria: "Statistical summary and pattern report produced",
          immediate_context: "50GB CSV dataset needs analysis",
          approach_guidance: "Use data analysis tools to process the dataset",
          profile: "data_analyst"
        },
        "Need dedicated agent for intensive data processing"
      )

    assistant_1c =
      mock_action_response(
        :orient,
        %{
          current_situation: "Need to analyze 50GB dataset",
          goal_clarity: "Unclear what specific analysis is needed",
          available_resources: "Computational resources, data tools",
          key_challenges: "Dataset size, undefined requirements"
        },
        "Should clarify requirements before spawning child"
      )

    refinement_1 = """
    Round 2 refinement for goal: We need help analyzing the large dataset efficiently.

    All proposed actions (JSON format):
    #{assistant_1a}

    #{assistant_1b}

    #{assistant_1c}

    Please review all proposals and decide on ONE action.
    Consider which action best serves the goal.

    Respond with your chosen action in JSON format.
    """

    # Round 2: All 3 converge to spawn_child (minority swayed by majority reasoning)
    # Note: All have identical task_description to ensure 100% clustering
    assistant_2a =
      mock_action_response(
        :spawn_child,
        %{
          task_description: "Analyze the large dataset to extract statistics and patterns",
          success_criteria: "Statistical summary and pattern report produced",
          immediate_context: "50GB CSV dataset needs analysis",
          approach_guidance: "Use data analysis tools to process the dataset",
          profile: "data_analyst"
        },
        "Spawning child is the right approach for large datasets"
      )

    assistant_2b =
      mock_action_response(
        :spawn_child,
        %{
          task_description: "Analyze the large dataset to extract statistics and patterns",
          success_criteria: "Statistical summary and pattern report produced",
          immediate_context: "50GB CSV dataset needs analysis",
          approach_guidance: "Use data analysis tools to process the dataset",
          profile: "data_analyst"
        },
        "Child agent can handle both clarification and analysis"
      )

    assistant_2c =
      mock_action_response(
        :spawn_child,
        %{
          task_description: "Analyze the large dataset to extract statistics and patterns",
          success_criteria: "Statistical summary and pattern report produced",
          immediate_context: "50GB CSV dataset needs analysis",
          approach_guidance: "Use data analysis tools to process the dataset",
          profile: "data_analyst"
        },
        "Convinced: child agent can clarify requirements during analysis"
      )

    # Generate real consensus analysis using actual Aggregator code
    analysis =
      generate_real_consensus_analysis([
        {1, [assistant_1a, assistant_1b, assistant_1c]},
        {2, [assistant_2a, assistant_2b, assistant_2c]}
      ]) <>
        """

        Consensus Journey:
        1. Round 1: 67% consensus reached (2 models: spawn_child, 1 model: orient)
        2. Round 2: 100% unanimous (all models: spawn_child with data_analyst)

        Key Insight: Majority → Unanimity progression
        - Round 1: Majority (67%) triggers consensus immediately per >50% rule
        - Round 2: Shows what happens when minority is persuaded (100% alignment)
        - This scenario demonstrates refinement improving from "good enough" to "perfect"

        Consensus Rule: spawn_child uses semantic_similarity (threshold: 0.95) for task_description
        Threshold: >50% of models in single cluster (Round 1: 67% ✓, Round 2: 100% ✓)
        Result: Both rounds reach consensus - refinement shown for educational purposes
        """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_initial},
      %{role: "assistant", content: assistant_1a, model: "a"},
      %{role: "assistant", content: assistant_1b, model: "b"},
      %{role: "assistant", content: assistant_1c, model: "c"},
      %{role: "user", content: refinement_1},
      %{role: "assistant", content: assistant_2a, model: "a"},
      %{role: "assistant", content: assistant_2b, model: "b"},
      %{role: "assistant", content: assistant_2c, model: "c"},
      %{role: "analysis", content: analysis}
    ]
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Generate realistic action response JSON
  defp mock_action_response(action, params, reasoning) do
    Jason.encode!(
      %{
        action: action,
        params: params,
        reasoning: reasoning,
        wait: false
      },
      pretty: true
    )
  end

  # Run real consensus analysis on mock responses (no embeddings - exact_match only)
  # Takes list of {round_num, [response_json_strings]} tuples
  # Returns formatted analysis text using actual Aggregator code
  @spec generate_real_consensus_analysis([{integer(), [String.t()]}]) :: String.t()
  defp generate_real_consensus_analysis(rounds_data) do
    alias Quoracle.Consensus.Aggregator

    rounds_analysis =
      Enum.map_join(rounds_data, "\n\n---\n\n", fn {round_num, response_jsons} ->
        # Parse mock JSON responses into maps
        # Note: keys: :atoms only converts keys, not values - must also convert action string to atom
        parsed_responses =
          Enum.map(response_jsons, fn json_str ->
            decoded = Jason.decode!(json_str, keys: :atoms)
            # Convert action string to atom for Schema.get_schema/1 guard clause
            %{decoded | action: String.to_existing_atom(decoded.action)}
          end)

        # Actually run the clustering algorithm
        clusters = Aggregator.cluster_responses(parsed_responses)

        total = length(parsed_responses)

        # Actually check for majority using real code
        {_result_status, result_text} =
          case Aggregator.find_majority_cluster(clusters, total) do
            {:majority, cluster} ->
              pct = round(cluster.count / total * 100)
              {:consensus, "✓ CONSENSUS REACHED (#{pct}% - #{cluster.count}/#{total} models)"}

            {:no_majority, clusters} when clusters != [] ->
              # Find largest cluster for reporting
              largest = Enum.max_by(clusters, & &1.count)
              pct = round(largest.count / total * 100)
              {:no_consensus, "✗ NO CONSENSUS (#{pct}% not >50%)"}

            {:no_majority, []} ->
              {:no_consensus, "✗ NO CONSENSUS (no valid responses)"}
          end

        # Generate cluster breakdown
        cluster_text =
          clusters
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {cluster, idx} ->
            pct = round(cluster.count / total * 100)
            action = cluster.representative.action
            # Get representative parameter for display
            param_display = get_cluster_param_display(cluster.representative)

            "  • Cluster #{idx}: #{action} - #{param_display} (#{cluster.count} model#{if cluster.count > 1, do: "s", else: ""}, #{pct}%)"
          end)

        """
        Round #{round_num} Results:
        #{result_text}

        Cluster Analysis:
        #{cluster_text}
        """
      end)

    """

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    CONSENSUS ANALYSIS
    ═══════════════════════════════════════════════════════════════════════════════════════════════

    #{rounds_analysis}

    ═══════════════════════════════════════════════════════════════════════════════════════════════
    """
  end

  # Get a human-readable display of the key parameter from a cluster representative
  @spec get_cluster_param_display(map()) :: String.t()
  defp get_cluster_param_display(%{action: :execute_shell, params: %{command: cmd}})
       when is_binary(cmd) do
    "\"#{cmd}\""
  end

  defp get_cluster_param_display(%{action: :execute_shell, params: %{check_id: id}})
       when is_binary(id) do
    "check_id: #{id}"
  end

  defp get_cluster_param_display(%{action: :execute_shell, params: params}) do
    inspect(params)
  end

  defp get_cluster_param_display(%{params: params}) when map_size(params) > 0 do
    # For other actions, show first param value
    {key, value} = Enum.at(params, 0)

    value_str =
      if is_binary(value), do: "\"#{String.slice(value, 0..30)}...\"", else: inspect(value)

    "#{key}: #{value_str}"
  end

  defp get_cluster_param_display(%{params: _params}) do
    "no params"
  end

  # ============================================================================
  # Display Functions - Format messages with readable headers
  # ============================================================================

  defp display_messages(messages) do
    # Group messages and handle parallel assistant responses
    messages
    |> group_parallel_responses()
    |> Enum.each(fn message_group ->
      display_message_group(message_group)
      IO.puts("")
    end)
  end

  # Group consecutive assistant messages together (parallel responses)
  defp group_parallel_responses(messages) do
    messages
    |> Enum.chunk_by(fn msg ->
      # Group by role, but treat all assistant messages with model field as same chunk
      case msg do
        %{role: "assistant", model: _} -> :parallel_assistant
        %{role: role} -> role
      end
    end)
    |> Enum.reduce({[], 1}, fn chunk, {acc, msg_num} ->
      case chunk do
        # Multiple assistant messages with model field = parallel responses
        [%{role: "assistant", model: _} | _] = assistants ->
          grouped = %{
            type: :parallel_assistants,
            messages: assistants,
            message_number: msg_num
          }

          {acc ++ [grouped], msg_num + 1}

        # Single message
        [single_msg] ->
          grouped = %{
            type: :single,
            message: single_msg,
            message_number: msg_num
          }

          {acc ++ [grouped], msg_num + 1}

        # Shouldn't happen, but handle gracefully
        other ->
          grouped =
            Enum.map(other, fn msg ->
              %{type: :single, message: msg, message_number: msg_num}
            end)

          {acc ++ grouped, msg_num + length(other)}
      end
    end)
    |> elem(0)
  end

  defp display_message_group(%{
         type: :parallel_assistants,
         messages: assistants,
         message_number: num
       }) do
    # Display parallel assistant responses as 2a/2b/2c
    Enum.each(assistants, fn %{content: content, model: model} ->
      header = "MESSAGE #{num}#{model}: ASSISTANT RESPONSE (Model #{String.upcase(model)})"
      IO.puts(header)
      IO.puts(String.duplicate("-", 100))
      IO.puts(content)
      IO.puts(String.duplicate("-", 100))
      IO.puts("")
    end)
  end

  defp display_message_group(%{type: :single, message: message, message_number: num}) do
    display_message(message, num)
  end

  defp display_message(%{role: role, content: content}, index) do
    header = format_header(role, index)
    IO.puts(header)
    IO.puts(String.duplicate("-", 100))
    IO.puts(content)
    IO.puts(String.duplicate("-", 100))
  end

  defp format_header("system", index) do
    "MESSAGE #{index}: SYSTEM PROMPT"
  end

  defp format_header("user", index) do
    "MESSAGE #{index}: USER MESSAGE"
  end

  defp format_header("assistant", index) do
    "MESSAGE #{index}: ASSISTANT RESPONSE"
  end

  defp format_header("analysis", _index) do
    "\n" <> String.duplicate("═", 100) <> "\nCONSENSUS ANALYSIS\n" <> String.duplicate("═", 100)
  end

  defp format_header(role, index) do
    "MESSAGE #{index}: #{String.upcase(role)}"
  end
end
