# MiuRead 6.5.0-beta.16 — Offline test report (2026-11-01)

## Changes tested

- EPUB installation remains before the same-worker Web source acquisition phase; no pre-install Web hard gate.
- Real `legacy_coordinate_backfill.perform()` exercised with stubbed EPUB/Web inputs: ordinary text, short/mismatched XHTML, untrusted previous cache, authority rejection, and proven cached source reuse.
- Content/account/chapter/version provenance checks tested with stubbed digest and JSON storage.
- Same-task checkpoint resume retested, including precise retry of previously failed chapter indices.
- Download-manager manual retry tested to select only failed chapter indices imported from the previous same-worker pass.
- A frozen-file SHA/byte diff confirms that readtime, sync, progress coordinate conversion, Web/E-Ink download transport, and the original beta.5 GitHub release workflow are unchanged from beta.15.

## Actual local outcomes

- **289 Lua files** pass the available Lua 5.3 syntax checker (does not replace KOReader LuaJIT runtime verification).
- PASS `tools/test_beta16_source_acquisition.lua`.
- PASS `tools/test_beta16_web_provenance.lua`.
- PASS `tools/test_beta16_failed_index_resume.lua`.
- PASS `tools/test_beta16_manual_failed_uids.lua`.
- PASS `tools/test_beta15_epub_first.lua` (fixture amended with explicit mapped outcome, matching its intended scenario).
- PASS `tools/test_beta12_legacy_coordinate.lua` (provenance mocked for original legacy assertions).
- PASS `tools/test_beta15_install_order.py` (version assertion updated to current version).
- PASS `tools/test_650_beta10_contract.py` (5 tests).
- PASS `tools/test_650_beta9_readtime_contract.py` (5 tests).
- PASS `tools/test_beta12_freeze_contract.py`.

## Not counted as passed

- The old `test_beta12_sync_contract.lua`, `test_beta14_sync_contract.lua`, and `test_beta15_sync_contract.lua` contain literal **5.9.0-beta.12/.14/.15** version assertions (a different lineage); direct execution stops at that assertion. Hash comparison of frozen code was used instead.
- `test_beta12_release_regression.py` expects a newer release workflow. The explicitly requested **beta.5 workflow is preserved byte-for-byte**, so its expectations cannot both be true. Not treated as a release workflow defect.
- No live WeRead API, Kindle Voyage memory/suspend, authentication refresh, cloud co mapping, or physical-device tests were performed. MD5/JSON in the provenance unit test were stubbed; actual runtime codec availability and performance still require a device trial.

## Important safety/meaning distinction

`Web source cached` means the chapter content was obtained through a Web Reader response and saved with the correct version and chapter key. It does **not** imply an exact EPUB XHTML mapping or that an arbitrary reading position can be uploaded. Existing position-level anchor/coordinate conflict protections remain in place.
