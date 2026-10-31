# 6.5.0-beta.12 implementation notes

## Version origin

This source is based on the user-provided `miuread-6.5.0-beta.11-full-source.zip`, **not** rebased from 6.3.x.

## Changes

- Restored beta.4's standalone KOReader native screensaver option through existing configuration logic.
- Changed Home shortcut long press into the existing hierarchical menu. Short-press callbacks are unchanged; sync long press provides existing immediate sync/status/settings actions.
- Consolidated comment fetch/update actions for current chapter and selected chapter range; range refresh-existing toggle defaults off. Existing comment database and downloader are unchanged.
- Added source-only `legacy_coordinate_backfill.lua`. It discovers MiuRead-owned old EPUB files, processes one installed chapter at a time through an isolated background Worker, compares local XHTML against authoritative Web chapter XHTML, and caches sources only after text-anchor validation. Failed, paused, cancelled and completed jobs are independently recorded. Existing EPUB files are never rewritten.
- Added `EpubInstaller.read_chapter_text` for bounded read-only extraction of one chapter from generated stored ZIP EPUBs.
- Added a Home book-menu entry for inspection, manual retry, pause and cancel; work is scheduled only during available Home idle and yields to foreground, download, lockscreen and power changes. No progress POST or reading-time request is called by the new module.
- Restored byte-for-byte `v6.5.0-beta.5` `.github/workflows/release-beta.yml` and `.github/scripts/sync_release_identity.py`. `tools/build_package.py` remains unchanged, and GitHub Releases should contain one install ZIP only.

## Frozen functionality

The seven explicit reading-progress functions in `main.lua` have unchanged SHA-256. `sync.lua`, `readtime_controller.lua`, `read_report_service.lua`, `download_source_gate.lua` and `download_coordinate_retry.lua` are byte-for-byte unchanged. No changes were made to the global HTTP defaults.

## Limitations

- Kindle real-device, actual Web Reader endpoint, OTA and real GitHub Release are not tested. The installed version should be treated as experimental until those pass.
- Legacy books with missing/ambiguous chapter UID, non-MiuRead/unsupported EPUB, unknown Web source version, image-only or divergent HTML can enter `needs_attention` instead of falsely claiming exact coordinates.
- A MiuRead-generated EPUB normally uses stored text ZIP entries; unsupported compressed entries are rejected rather than decompressed unsafely.
- Old-source backfill only runs while KOReader is active and a suitable Home idle period is available, not during deep Kindle suspend.
- Source includes earlier historical tests that assert obsolete versions, menu layouts or the discarded post-beta.5 Release workflow. These may fail when run indiscriminately. Current beta.12 contract and targeted runtime tests are kept separate. The original beta.5 Release workflow does not execute the obsolete beta17 progress test.
- Beta.5's manual Release regenerates version metadata in the Actions workspace without committing it back to `beta`; Tag source metadata can therefore differ from distributed package metadata. This is an intentional consequence of restoring the exact workflow requested.

## GitHub

The archive does not modify the remote repository. A prior attempt to write the workflow directly to the connected GitHub repository was rejected with 403; pushing the source still requires a repository write-enabled connection or local Git push.
