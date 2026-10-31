# Frozen beta.9 progress function fingerprints

All hashes are SHA-256 of the full function source from the user-supplied beta.9. Beta.10 checks each function unchanged.

- `_submit_saved_pending_progress`: `e827d9499af80d933369e39f8f2117a1ad4bc745d71d062a1e97baa7c3882d45`
- `_commit_progress_verified`: `997e7ef5647bc2c88bd90788e47a20ca06e8e2756e60446b870df761c5f0d496`
- `_verify_progress_submission`: `0c08a90c91706e35de8e5dfade010ab1f704988554bae912e4f6e4d4ed0d0661`
- `_submit_progress_snapshot`: `9bc9426b46dcb07018304bb5b87609ef1cfd11f612b3d2ed7b9eada011226153`
- `on_remote_progress`: `d66069b0bfd6f6d1fa3abf057fbd99b6a570476ac21f3ddcfc78a5a67bba14a6`
- `_reading_end_sync`: `23663f025429fdfe23692bb83e6434f37b5530b1fb73254d0a24998a33f22c92`
- `_save_pending_progress`: `7b297e9c00222c740f9ac29f2e06337c9eb32cf1cd92d42e81eb5ae9ca7463af`

Changes in `sync.lua` are limited to four Web readtime credential revision uses, not a replacement of progress algorithms.
