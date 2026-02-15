# lib/quoracle/tasks/task_restorer/

## Modules
- ConflictResolver: Registry conflict resolution during agent restoration (102 lines)

## Key Functions
- restore_agent_with_retry/4: dynsup_pid×db_agent×agent_opts×registry→{:ok,pid}|{:error,term}, retries once on Registry conflict
- registry_conflict?/1: Matches RuntimeError "Duplicate agent ID", {:already_started,_}, {:already_registered,_}
- terminate_orphan/1: GenServer.stop with :infinity timeout, catch :exit
- wait_for_registry_cleanup/2: Polls Registry with :erlang.yield(), 5-second deadline

## Patterns
- Single retry on conflict (not infinite)
- Registry cleanup is async via monitors — poll with yield until unregistered
- :infinity timeout for GenServer.stop per project convention

## Dependencies
- DynSup.restore_agent/3: Actual agent restoration
- Registry: Lookup orphan PID for termination
