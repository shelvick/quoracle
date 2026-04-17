# lib/quoracle/actions/dismiss_child/

## Modules
- CostTransaction (151 lines, v1.0): Atomic child cost absorption — `Repo.transaction` wrapping per-model snapshot → bulk DELETE → batch INSERT

## Key Functions
- `absorb_subtree/3`: parent_id×child_id×absorption_ctx→{:ok,[AgentCost.t()]}|{:error,atom()}, single Repo.transaction
- `collect_subtree_agent_ids/1`: recursive CTE via `Aggregator.get_descendant_agent_ids/1`
- `snapshot_per_model/1`: `Aggregator.by_agent_ids_and_model_detailed/1` inside transaction
- `build_absorption_records/4`: one record per non-zero model_spec group, sentinel `"(external)"` for nil
- `validate_absorption_batch/1`: rolls back on nil/non-binary task_id

## Patterns
- No GenServer calls, no PubSub, no process spawns inside transaction body
- `Recorder.record_silent_batch/1` for atomic insert without broadcast
- Caller broadcasts per-row via `Recorder.broadcast_cost_recorded/2` AFTER commit

## Dependencies
- COST_Aggregator (subtree collection, per-model snapshot)
- COST_Recorder (silent batch insert)
- Ecto.Repo (transaction, delete_all)
