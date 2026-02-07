# lib/quoracle/pubsub/

## Modules
- AgentEvents: Centralized PubSub event broadcasting with mandatory explicit pubsub parameter

## Key Functions (All REQUIRE explicit pubsub parameter)
- broadcast_agent_spawned/4,5,6: Lifecycle event for agent creation (root/child, with optional budget_data)
- broadcast_agent_terminated/3: Lifecycle event for agent termination
- broadcast_action_started/5: Action execution start
- broadcast_action_completed/4: Action execution success
- broadcast_action_error/4: Action execution failure
- broadcast_log/5: Agent-specific log entries
- broadcast_user_message/4: Task-specific messages
- broadcast_state_change/4: Agent state transitions
- broadcast_todos_updated/3: TODO list updates
- subscribe_to_agent/2: Subscribe to all agent topics
- subscribe_to_task/2: Subscribe to task messages
- subscribe_to_all_agents/1: Subscribe to lifecycle/action topics

## Topics
- agents:lifecycle - spawn/terminate events
- agents:[id]:state - state changes
- agents:[id]:logs - log entries
- agents:[id]:todos - TODO list updates
- agents:[id]:metrics - metrics updates
- actions:all - action events
- tasks:[id]:messages - task messages

## PubSub Isolation (As-Built)
- **NO backward-compatibility defaults** - pubsub parameter is REQUIRED
- **NO Process dictionary usage** - fully eliminated
- All functions require explicit pubsub parameter
- Enables complete test isolation with async: true
- Follows explicit dependency injection pattern

## Dependencies
- Phoenix.PubSub
