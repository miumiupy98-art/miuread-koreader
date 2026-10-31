# MiuRead 6.5.0-beta.11 test results

Validated against the 6.5.0-beta.10 source base; this build has NOT been tested on a Kindle or live WeRead.

- 277 Lua scripts: Lua 5.4 parser, 0 syntax errors.
- 152 available Python regression tests: all passed; includes six new beta.11 contracts.
- Three existing/new Lua source tests actually executed using liblua5.4: coordinate gate, source mapping, persistent coordinate retry policy — all passed.
- Six legacy Python test modules require the unavailable `lupa` package and were not run in this environment.
- The seven critical progress-sync functions have unchanged SHA-256 hashes from beta.10 (also from user's beta.9).
- `sync.lua`, `readtime_controller.lua`, `download_task.lua`, `download_source_gate.lua` and `source_position.lua` are byte-identical to beta.10.
- Live WeRead login, rate limit and exact remote-coordinate restoration NOT verified.

**Risk:** The main UI scheduling changes, subprocess recovery transitions and persistence under abrupt power loss still require real-device validation. Deterministic Web/E-Ink body mismatch is intentionally paused for manual attention after one bounded recheck.
