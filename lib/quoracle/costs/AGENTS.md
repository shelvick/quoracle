# lib/quoracle/costs/

## Modules
- AgentCost: Ecto schema for cost records (53 lines)
- Recorder: Cost recording + PubSub broadcast (90 lines)
- Aggregator: Query module with recursive CTE for agent trees (446 lines, v3.0)

## Key Functions
- AgentCost.changeset/2: Validates cost_type in [llm_consensus, llm_embedding, llm_answer, llm_summarization, llm_condensation, image_generation, external, child_budget_absorbed]
- Recorder.record/2: Insert + broadcast to tasks/agents topics, requires pubsub opt
- Recorder.record_silent/1: Insert without broadcast
- Aggregator.by_agent/1: Agent's own costs
- Aggregator.by_agent_children/1: Descendants only (recursive CTE)
- Aggregator.by_task/1: All agents in task
- Aggregator.by_task_and_model/1: JSONB aggregation by model_spec
- Aggregator.by_task_and_model_detailed/1: v2.0 - 5 token types + aggregate costs (detailed breakdown)
- Aggregator.by_agent_and_model_detailed/1: v2.0 - Same detailed breakdown for single agent
- Aggregator.by_agent_tree_and_model_detailed/1: v3.0 - Subtree costs including NULL model_spec (for DismissChild)
- Aggregator.by_agent_ids_and_model_detailed/1: v3.0 - Multi-agent detailed breakdown
- Aggregator.get_descendant_agent_ids/1: Recursive CTE for agent tree

## Types
- model_cost_detailed: `model_spec: String.t() | nil` (nil for non-model costs like external/child_budget_absorbed)

## Schema
```
agent_costs: id(uuid), agent_id(string), task_id(uuid), cost_type(string),
             cost_usd(decimal 12,10), metadata(jsonb), inserted_at
```

## Patterns
- Explicit pubsub parameter (test isolation)
- safe_broadcast for PubSub cleanup races
- Decimal for monetary precision
- Recursive CTE for agent tree traversal
- JSONB for model_spec aggregation
- @detailed_select/@detailed_group_order module attributes (DRY SQL across detailed queries)
- execute_detailed_sql/2 shared helper for query execution + row mapping

## Dependencies
- Ecto.Repo for DB operations
- Phoenix.PubSub for broadcasts
- TABLE_Tasks (foreign key)

Test coverage: 111 tests (29 schema + 28 recorder + 54 aggregator)
