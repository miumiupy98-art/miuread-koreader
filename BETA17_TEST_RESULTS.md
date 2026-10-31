# 6.5.0-beta.17 local verification

- Lua syntax: 291 files compiled successfully (host Lua 5.3).
- Installed plugin changed only `_meta.lua`, `config.lua`, and `network_metadata.lua` versus beta.16.
- HTTP core, synchronization, progress submission, reading-time worker, download, Web source/EPUB, release scripts unchanged byte-for-byte.
- Unit tests run with local Lua and mocked third-party HTTP; no real Google Books, Open Library or Kindle/WeRead end-to-end run.
- Unmodified older `test_beta16_sync_contract.lua` has a pre-existing stale `5.9.0-beta.16` version assertion and is not counted as passing.
- Old persisted global cooldown from beta.16 remains until expiry; this patch prevents NEW third-party metadata 429 from writing to global.

## Executed tests
- tools/test_beta17_metadata_isolation.lua: PASS — PASS beta17: Google Books and Open Library scopes isolated; Google 429 fallback; fail-fast; both Open Library requests scoped
- tools/test_beta17_http_scope.lua: PASS — PASS beta17 HTTP: independent provider cooldown files and global WeRead isolation
- tools/test_beta16_source_acquisition.lua: PASS — PASS beta16: trusted Web cache, short chapter, no duplicate Web calls, untrusted cache, native rejected
- tools/test_beta16_failed_index_resume.lua: PASS — PASS beta16 same-task failed-index recovery, no repeated successful chapters
- tools/test_beta16_manual_failed_uids.lua: PASS — PASS beta16 manual retry only originally failed indices
- tools/test_beta15_epub_first.lua: PASS — PASS beta15 EPUB-first, per-chapter failure isolation, saved resume, account fence
- tools/test_beta12_legacy_coordinate.lua: PASS — PASS beta12 legacy source backfill queue, web validation, account guard, replay guard
