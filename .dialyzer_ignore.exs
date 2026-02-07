[
  # Mix tasks use Mix.Task functions that dialyzer can't see
  {"lib/mix/tasks/quoracle.show_llm_prompts.ex", :callback_info_missing},
  # ACE Reflector: All current callers are tests with test_mode: true.
  # Production integration (TokenManager) will call without test_mode, making else branch reachable.
  {"lib/quoracle/agent/reflector.ex", :pattern_match},
  # Spawn: parent_pid is nil for root agents (no parent), but dialyzer infers it's always a pid
  # through do_spawn_child flow. The is_pid guard is necessary for runtime nil safety.
  {"lib/quoracle/actions/spawn.ex", :pattern_match}
]
