# test/quoracle_web/live/ui/

## Test Modules
- message_test.exs: 34 tests (21 accordion display + 13 reply functionality)
- mailbox_test.exs: 24 tests (14 accordion UI + 10 lifecycle integration)

## Message Tests
Collapsed/expanded views, toggle behavior, reply forms, agent_alive button disable, edge cases

## Mailbox Tests
MapSet expansion, newest-first ordering, Registry lookup + Core.send_user_message, agent lifecycle tracking via PubSub, race conditions

## Integration
dashboard_live_test.exs verifies agents={@agents} passing, reply button enable/disable

Patterns: Isolated PubSub/Registry per test, async: true, live_isolated/3, render_click, direct send for PubSub events
