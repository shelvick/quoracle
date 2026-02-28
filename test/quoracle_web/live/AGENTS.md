# test/quoracle_web/live/

## Test Files

### Dashboard Tests
- dashboard_live_test.exs: 51 tests (48 base + 3 pause/resume pipeline R6-R9)
- dashboard_delete_integration_test.exs: 16 tests
- dashboard_3panel_integration_test.exs: 16 tests
- buffer_integration_test.exs: 16 tests (UI persistence R17-R24, R35-R42)
- dashboard_async_pause_test.exs: async pause/resume
- dashboard_auto_subscription_test.exs: auto-subscribe to agent topics

### SecretManagementLive Tests
- secret_management_live_test.exs: Full CRUD tests for secrets, credentials, profiles, models, system settings
- profile_hot_reload_live_test.exs: Profile hot-reload LiveView + acceptance tests (R19-R24, 6 tests, 2026-02-27)
  - R19: save_profile broadcasts profile_updated event (integration)
  - R20: Profile rename broadcasts on old-name topic with new name (integration)
  - R21: Acceptance — saving profile updates running agent behavior end-to-end (system)
  - R22: Acceptance — editing profile in LiveView updates running agent behavior (system)
  - R23: New profile creation broadcasts profile_updated (integration)
  - R24: Failed profile save does not broadcast (unit)

## Patterns
- `live_isolated/3` with `session: %{"sandbox_owner" => pid, "pubsub" => atom}` for SecretManagementLive
- `live/2` with authenticated conn for DashboardLive
- `render(view)` after PubSub.broadcast to sync pending messages
- Isolated PubSub per test for all SecretManagement tests
- Real form submission via `form/3 + render_submit/1` for acceptance tests

## Dependencies
- test/support/conn_case.ex: Conn + sandbox setup
- test/support/data_case.ex: DB sandbox setup
