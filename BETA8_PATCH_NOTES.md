# MiuRead 6.5.0-beta.8 — code delivery

**Source**: user-provided `miuread-koreader-6.3.0-beta.7(3).zip`, not 6.5 beta.7.

## Changed
- `miuread.koplugin/miuread/source_position.lua`: validate same-version cached Web chapter source against actual Reader anchor; validate fresh network source before writing authoritative cache; add `ensureWebChapterSource` for worker-driven prewarming.
- `miuread.koplugin/miuread/sync.lua`: add `prepare_current_web_source` worker-backed current-chapter source preparation.
- `miuread.koplugin/main.lua`: trigger low-priority preparation from Reader ready and debounced page updates; remove forced Kindle-first on automatic open; Web-only preflight for pending unsent recovery with no blind force write.
- `miuread.koplugin/miuread/config.lua` and `_meta.lua`: beta.8 identity.

## Invariants
- No EPUB rewrite, no E-Ink XHTML accepted as authoritative Web `co`, no periodic page-turn progress uploads.
- Existing `resolve_saved_progress_anchor` and `SourcePosition.locate` still resolve delayed immutable anchors; home recovery supplies online fetch.
- Old pending snapshot is preserved when no trusted common anchor exists. This can make recovery wait for manual resolution instead of risking another-device overwrite.
- Explicit user-selected force-local action unchanged.

## Limitations
- This is a source build, not an installed/signed firmware artifact.
- No KOReader hardware/API connectivity tests performed.
- Real cross-device chronological ordering cannot always be proven with only upload timestamps; ambiguous conflicts park rather than guess.
- Existing `position_resolution.lua` compares server timestamps when neither side has a verified common anchor. Treat initial latest-wins inference as a heuristic, not guaranteed last human reading event.
- The 6.3.0 base's readtime smart channel is retained unchanged; no claim about all prior Web/E-Ink route regressions.
- Back up plugin settings and user data before replacing a beta.7 installation with this rebuild.

## Verification performed in this build environment

- Parsed all 271 Lua files with Lua 5.4 C parser: **0 syntax errors**. This does not imply LuaJIT/KOReader runtime compatibility.
- Ran `tools/verify_600_beta1.py`: **55/55 source/release checks passed**.
- Python unittest discovery: **142 cases discovered; 136 passed; 6 import errors** because `lupa` (LuaJIT embedded runtime) is unavailable in the build environment. No functional test failures among loadable tests.
- Ran new `test_650_beta8_progress_rebuild.py`: **6/6 source contracts passed**.
- Executed actual `source_position.lua` against a Lua 5.4 isolated worker stub: valid fresh Web fetch, same-version cache hit, stale cache refresh, E-Ink source rejection, and Web anchor mismatch rejection passed. This is a simulation, not live Web verification.
- Ran official `tools/build_package.py`; package zip integrity was checked.

**Unverified**: KOReader on physical Kindle, smart readtime switch across lock/suspend, chapter XPointer to Web co exactness on real content, multi-device server behavior, and state migration from installed 6.5.0-beta.7. Do not treat this as a certified stable release.
