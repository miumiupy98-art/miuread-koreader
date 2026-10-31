# 6.5.0-beta.14 — local verification

- Lua 5.4 syntax compilation: 271 files PASS (different interpreter from Kindle LuaJIT, not a device-run guarantee).
- `test_650_beta10_coordinate_gate.lua`: PASS.
- `test_650_beta10_source_map.lua`: PASS (repeated full-text and strict mismatch coverage).
- `test_650_beta14_coordinate_fallback.lua`: PASS (authoritative Web failure classification).
- `test_650_beta11_coordinate_retry.lua`: PASS.
- `test_beta12_legacy_coordinate.lua`: PASS (task snapshots, account isolation, persisted retry).
- `test_650_beta9_readtime_ownership.lua`: PASS.
- `test_beta17_sync_contract.lua`: PASS.
- `test_beta13_pending_replay_behavior.lua`: PASS.
- `test_beta13_b7_integration.lua`: PASS.
- `test_beta11_download_resume_policy.lua`: PASS.
- `test_beta11_resume_coordinator.lua`: PASS.
- `tools/test_beta12_freeze_contract.py`: PASS after excluding intentional download-only Gate change from old hash expectations.
- `test_beta13_b4_download_policy.lua`: FAIL (inherited fixture expects a `local function` declaration; beta.13 already defines it by assignment). The source in question is unchanged.
- Seven key progress functions, sync.lua, readtime_controller.lua, other readtime files, download_transport.lua, and beta.5 release workflow: byte-identical to beta.13.
- Runtime installation ZIP: 283 files, CRC validation PASS.

**Not verified:** Kindle hardware execution, live Web original for 《一九八四》 (first chapter), full exhaustive regression suite, all 8 chapters of that book, mixed source fallback in a real WeRead account, and real Release publishing.
