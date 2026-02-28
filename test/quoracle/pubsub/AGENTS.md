# test/quoracle/pubsub/

## Test Files
- agent_events_test.exs: Core broadcast/subscribe tests, isolated PubSub per test
- agent_events_explicit_test.exs: Explicit pubsub parameter enforcement tests
- profile_events_test.exs: Profile hot-reload PubSub infrastructure (R1-R3, 3 tests, 2026-02-27)
  - R1: broadcast_profile_updated publishes to profile-specific topic
  - R2: subscribe_to_profile enables receiving broadcasts
  - R3: unsubscribe_from_profile stops receiving broadcasts

## Patterns
- Isolated Phoenix.PubSub per test (unique atom name via System.unique_integer)
- subscribe before broadcast, assert_receive after
- async: true for all tests
