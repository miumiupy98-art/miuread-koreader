# MiuRead 6.5.0-beta.15 — Local verification (2026-11-01)

## Passed

- Lua syntax parse for all 283 Lua sources, using Lua 5.4 syntax loader.
- `tools/test_beta15_epub_first.lua`: installed EPUB before Web, per-chapter mapping failure does not revoke EPUB, resume after simulated hibernate, identity/account fence.
- `tools/test_beta15_legacy_import.lua`: new-book Web status appears in download-management rows without creating a hidden background task.
- `tools/test_beta15_install_order.py`: EPUB `_save` before Web pass, pre-install Gate removed, frozen sync/readtime/transport/workflow byte equality.
- `tools/test_650_beta10_contract.py`: updated version-specific download order contract, historical frozen reading-progress function hashes.
- `tools/test_beta12_freeze_contract.py`: frozen reading progress/readtime and beta.5 workflow.
- `tools/test_650_beta10_coordinate_gate.lua`: historical standalone Gate behavior (not called by beta.15 new-book path).
- `tools/test_650_beta10_source_map.lua`: text matching behavior.
- `tools/test_650_beta11_coordinate_retry.lua`: historical retry state.
- `tools/test_beta12_legacy_coordinate.lua`: background old-book behavior unchanged.
- `tools/test_beta13_pending_replay_behavior.lua`: pending cloud write safety.
- `tools/test_beta13_b7_integration.lua`: integration of unrelated B7 UI guards.
- `tools/test_beta11_resume_coordinator.lua`, `tools/test_beta11_download_resume_policy.lua`.
- `tools/test_beta17_sync_contract.lua`, `tools/test_650_beta9_readtime_ownership.lua`.

## Not verified / limitations

- No Kindle Voyage hardware test or live WeRead network request performed.
- Python `tools/test_eink_download.py` and `test_eink_features.py` cannot run in this container: optional `lupa` package is absent.
- Tests cannot establish complete real-book Web coordinate coverage or prove previously observed precise-co conflicts are resolved. This version changes download flow only, not progress upload/coordinate runtime.
- EPUB metadata is immutable after installation; later Web-source verification is persisted in a sidecar and account-bound book record rather than rewriting the EPUB.
- If task is interrupted in the very brief window after EPUB installation but before its post-install checkpoint is written, repeating the download may repackage EPUB; prior installed file remains valid.
- An installed EPUB may not immediately be re-registered in the parent settings if the isolated worker is abruptly killed before returning its result; re-running the saved task can recover the same installed EPUB via post-install checkpoint.
- Newly installed full books complete Web filling in the same download worker; manual subsequent retry for a failed chapter is available in the download manager (old books retain their existing background workflow).
