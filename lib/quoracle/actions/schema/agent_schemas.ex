defmodule Quoracle.Actions.Schema.AgentSchemas do
  @moduledoc """
  Schema definitions for agent-related actions: spawn_child, wait, send_message, orient, todo.
  """

  @schemas %{
    spawn_child: %{
      required_params: [
        :task_description,
        :success_criteria,
        :immediate_context,
        :approach_guidance,
        :profile
      ],
      optional_params: [
        # NOTE: :models removed from schema - agents can't know which models
        # are configured, so these params would fail anyway.
        :role,
        :cognitive_style,
        :output_style,
        :delegation_strategy,
        :sibling_context,
        :downstream_constraints,
        :skills,
        :budget
      ],
      param_types: %{
        task_description: :string,
        success_criteria: :string,
        immediate_context: :string,
        approach_guidance: :string,
        profile: :string,
        role: :string,
        cognitive_style:
          {:enum, [:efficient, :exploratory, :problem_solving, :creative, :systematic]},
        output_style: {:enum, [:detailed, :concise, :technical, :narrative]},
        delegation_strategy: {:enum, [:sequential, :parallel, :none]},
        sibling_context: {:list, :map},
        # NOTE: models types removed - see optional_params comment
        downstream_constraints: :string,
        skills: {:list, :string},
        budget: :string
      },
      param_descriptions: %{
        task_description:
          "What the child agent should accomplish - define a specific, BOUNDED objective. When spawning multiple children, ensure each task specifies what they own AND what is out of scope (e.g., 'Build frontend ONLY - do not touch backend or database'). Part of the child's initial USER prompt.",
        success_criteria:
          "Specific, measurable conditions that indicate the task is complete. Part of the child's initial USER prompt.",
        immediate_context:
          "Situational information the child needs to start working - relevant facts, data, or background. Part of the child's initial USER prompt.",
        approach_guidance:
          "Suggested strategy or methodology for tackling the task - how to approach the work. Part of the child's initial USER prompt.",
        profile:
          "Name of the profile that defines which models the child can use and what actions it's allowed to perform. Must be an existing profile name.",
        role:
          "What role the child should embody (e.g., 'strict and grumpy code reviewer', 'world-class data analyst and expert in R', 'Finnish whale researcher who can't swim'. Part of the child's SYSTEM prompt.)",
        cognitive_style:
          "Thinking pattern to adopt: 'efficient' (direct), 'exploratory' (investigative), 'problem_solving' (scientific), 'creative' (novel solutions), 'systematic' (methodical)",
        output_style:
          "How to format results: 'concise' (brief summaries), 'detailed' (comprehensive), 'technical' (precise terminology), or 'narrative' (flowing explanation)",
        delegation_strategy:
          "How child should delegate further work: 'parallel' (divide into concurrent tasks), 'sequential' (step-by-step), or 'none' (avoid delegation)",
        sibling_context:
          "Other child agents and their scopes - array of {agent_id, task} objects. Use this to define NON-OVERLAPPING territories: the child should treat sibling scopes as OFF-LIMITS to prevent redundant work. Part of the child's initial USER prompt.",
        downstream_constraints:
          "Additional constraint that will apply to this child and ALL its descendants - accumulates with any inherited constraints from upstream (e.g., 'No external API calls' or 'Read-only operations only' or 'Complete within 5 minutes'). Part of each descendant's SYSTEM prompt.",
        skills:
          "List of skill names to pre-load into the child's system prompt. Skills provide domain knowledge (e.g., ['elixir-testing', 'api-design']). Available skills are listed in your system prompt. The child will have this knowledge immediately without needing to learn_skills.",
        budget:
          "Budget allocation for child agent in USD (e.g., '50.00'). If omitted, child gets unlimited budget. Must be a positive decimal string. Parent must have sufficient available budget."
      },
      consensus_rules: %{
        task_description: {:semantic_similarity, threshold: 0.95},
        success_criteria: {:semantic_similarity, threshold: 0.85},
        immediate_context: {:semantic_similarity, threshold: 0.85},
        approach_guidance: {:semantic_similarity, threshold: 0.85},
        profile: :exact_match,
        role: {:semantic_similarity, threshold: 0.85},
        cognitive_style: :mode_selection,
        output_style: :mode_selection,
        delegation_strategy: :exact_match,
        sibling_context: :structural_merge,
        downstream_constraints: {:semantic_similarity, threshold: 0.90},
        skills: :union_merge,
        budget: :exact_match
      }
    },
    wait: %{
      required_params: [],
      optional_params: [:wait],
      param_types: %{
        wait: {:union, [:boolean, :number]}
      },
      param_descriptions: %{
        wait:
          "Wait value: true (indefinite), false/0 (immediate), or N seconds (timed). Unified with wait parameter - same behavior."
      },
      consensus_rules: %{
        wait: {:percentile, 50}
      }
    },
    send_message: %{
      required_params: [:to, :content],
      optional_params: [],
      param_types: %{
        to: {:union, [:atom, {:list, :string}]},
        content: :string
      },
      param_descriptions: %{
        to:
          "Message recipient: 'parent' (your creator - use for status updates and results), 'children' (direct children only), 'announcement' (broadcast directives/corrections to all descendants - NEVER for status updates, use 'parent' instead), or array of specific agent IDs",
        content: "The message text to send"
      },
      consensus_rules: %{
        to: :exact_match,
        content: {:semantic_similarity, threshold: 0.85}
      }
    },
    orient: %{
      required_params: [
        :current_situation,
        :goal_clarity,
        :available_resources,
        :key_challenges,
        :delegation_consideration
      ],
      optional_params: [
        :assumptions,
        :unknowns,
        :approach_options,
        :parallelization_opportunities,
        :risk_factors,
        :success_criteria,
        :next_steps,
        :constraints_impact
      ],
      param_types: %{
        current_situation: :string,
        goal_clarity: :string,
        available_resources: :string,
        key_challenges: :string,
        assumptions: :string,
        unknowns: :string,
        approach_options: :string,
        parallelization_opportunities: :string,
        risk_factors: :string,
        success_criteria: :string,
        next_steps: :string,
        constraints_impact: :string,
        delegation_consideration: :string
      },
      param_descriptions: %{
        current_situation: "Where you are right now - describe the present state of the task",
        goal_clarity:
          "How well you understand what you're trying to achieve - are objectives clear or ambiguous?",
        available_resources:
          "What tools, data, actions, or capabilities you can leverage to make progress",
        key_challenges:
          "Primary obstacles, blockers, or difficulties standing between you and the goal",
        assumptions: "Beliefs or premises you're operating under that may need validation",
        unknowns: "Critical information gaps or uncertainties that could affect your approach",
        approach_options: "Different strategies or paths you could take to accomplish the goal",
        parallelization_opportunities:
          "Which parts of the work could be done concurrently by spawning child agents",
        risk_factors: "Potential failure modes, edge cases, or things that could go wrong",
        success_criteria:
          "How you'll know when the orientation is complete and you're ready to act",
        next_steps: "Immediate actions to take based on this strategic assessment",
        constraints_impact:
          "How existing constraints (time, resources, permissions) affect your options",
        delegation_consideration:
          "Would delegating parts of this task to child agents help? Consider whether the work can be parallelized, involves distinct subtasks, or would benefit from specialized focus. If yes, describe what kind of child agent(s) would help and why."
      },
      consensus_rules: %{
        current_situation: {:semantic_similarity, threshold: 0.8},
        goal_clarity: {:semantic_similarity, threshold: 0.8},
        available_resources: {:semantic_similarity, threshold: 0.8},
        key_challenges: {:semantic_similarity, threshold: 0.8},
        assumptions: {:semantic_similarity, threshold: 0.8},
        unknowns: {:semantic_similarity, threshold: 0.8},
        approach_options: {:semantic_similarity, threshold: 0.8},
        parallelization_opportunities: {:semantic_similarity, threshold: 0.8},
        risk_factors: {:semantic_similarity, threshold: 0.8},
        success_criteria: {:semantic_similarity, threshold: 0.8},
        next_steps: {:semantic_similarity, threshold: 0.8},
        constraints_impact: {:semantic_similarity, threshold: 0.8},
        delegation_consideration: {:semantic_similarity, threshold: 0.8}
      }
    },
    todo: %{
      required_params: [:items],
      optional_params: [],
      param_types: %{
        items:
          {:list,
           {:map,
            %{
              content: :string,
              state: {:enum, [:todo, :pending, :done]}
            }}}
      },
      param_descriptions: %{
        items:
          "Full replacement TODO list - array of {content, state} objects where state is 'todo' (not started), 'pending' (in progress), or 'done' (completed)"
      },
      consensus_rules: %{
        items: {:semantic_similarity, threshold: 0.85}
      }
    },
    dismiss_child: %{
      required_params: [:child_id],
      optional_params: [:reason],
      param_types: %{
        child_id: :string,
        reason: :string
      },
      param_descriptions: %{
        child_id: "ID of the child agent to dismiss (must be direct child of caller)",
        reason: "Optional reason for dismissal (logged and included in events)"
      },
      consensus_rules: %{
        child_id: :exact_match,
        reason: :first_non_nil
      }
    },
    adjust_budget: %{
      required_params: [:child_id, :new_budget],
      optional_params: [],
      param_types: %{
        child_id: :string,
        new_budget: :string
      },
      param_descriptions: %{
        child_id: "ID of the direct child agent whose budget to adjust",
        new_budget: "New budget allocation amount (must be positive)"
      },
      consensus_rules: %{
        child_id: :exact_match,
        new_budget: :exact_match
      }
    }
  }

  @spec schemas() :: map()
  def schemas, do: @schemas
end
