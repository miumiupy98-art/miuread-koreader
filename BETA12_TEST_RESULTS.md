# MiuRead 6.5.0-beta.12 — offline verification record

Scope: this is a local source/build verification, **not** a Kindle or live WeRead integration certification.

## Passed
- Lua 5.4 syntax parser: 174 runtime Lua scripts, no syntax errors.
- beta.12 frozen progress / reading-time sources and exact beta.5 release workflow: `python tools/test_beta12_freeze_contract.py`.
- Direct Lua execution of beta.12 old-EPUB source-only backfill state, cache/anchor validation, account mismatch and stale callback guards: `tools/test_beta12_legacy_coordinate.lua`.
- Direct Lua execution of beta.10 coordinate gate and source mapping tests.
- Direct Lua execution of beta.11 coordinate retry, download resume policy, and resume coordination tests.
- Direct Lua execution of beta.9 reading-time worker ownership test.
- beta.11 Python download resume test.
- Runtime plugin ZIP archive verified against included files by `tools/build_package.py`.

## Not passed / not yet validated
- The unrestricted historical suite (`python -m unittest discover -s tools -p 'test_*.py'`) is **not green**: 158 collected, 25 failures and 10 errors. Many assertions target retired version numbers, legacy menus or the superseded post-beta.5 release workflow; some have environment/import dependencies. This must not be reported as passing.
- The exact beta.5 release workflow intentionally does not execute the historically conflicting `test_beta17_sync_contract.lua`. Its old `force_write=true` expectation must not be used as a reason to alter the frozen progress logic.
- Kindle hardware, low-memory/suspend behavior, real WeRead Web coordinate endpoints, GitHub Actions Release and OTA downloads remain untested.
- Some old EPUBs may be safely marked `needs_attention` if version/UID mapping is unavailable or EPUB entries are unsupported.

The project's original version-independent tests remain available under `tools/`; they are not deleted to conceal conflicts.
