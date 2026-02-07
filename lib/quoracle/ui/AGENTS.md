# lib/quoracle/ui/

## Modules
- RingBuffer: Pure functional circular buffer, O(1) insert via :queue, FIFO eviction
- EventHistory: GenServer for UI event buffering, PubSub subscriber, per-agent/task storage

## RingBuffer (80 lines)
- new/1: Create buffer with max_size
- insert/2: Add item, evict oldest if full
- to_list/1: Return items oldest-first
- size/1, empty?/1, clear/1: Utility functions
- Uses Erlang :queue for O(1) operations
- Immutable (returns new struct)

## EventHistory (256 lines)
- start_link/1: Requires pubsub option, optional registry/sandbox_owner/buffer sizes
- get_logs/2: Query logs for agent IDs, returns %{agent_id => [logs]}
- get_messages/2: Query messages for task IDs, returns merged list
- get_pid/0: Discover running instance via Application supervisor
- Subscribes to agents:lifecycle, agents:[id]:logs, tasks:[id]:messages
- Retains buffers after agent termination (intentional for page refresh)

## Key Functions
- RingBuffer.insert/2: Evicts oldest when at capacity
- EventHistory.get_logs/2: Returns logs oldest-first per agent
- EventHistory.get_messages/2: Merges task messages oldest-first

## Patterns
- Pure functional data structure (RingBuffer)
- GenServer with explicit PubSub injection (EventHistory)
- No named processes (PID discovery via supervisor)
- Test isolation via session-based injection

## Dependencies
- Phoenix.PubSub for subscriptions
- Registry for existing agent discovery (optional)
- Ecto.Sandbox for test DB access (optional)

Test coverage: 17 ring_buffer_test, 16 event_history_test (all async: true)
