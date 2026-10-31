# MiuRead 6.5.0-beta.10 — implementation and limitations

## Actual source base
The *user-uploaded* `miuread-6.5.0-beta.9-full-source(1).zip`, not the old 6.3.0 tree and not the broken 6.5.0-beta.7.

## Pre-install Web coordinate gate
- Final downloader transaction uses `miuread.download_source_gate.prepare()` after chapter and annotation retrieval, **before** `Downloader:_save()` packages/installs the EPUB.
- Non-structural chapters physically included in this EPUB must each have both a local checkpoint XHTML and an authoritative Web chapter of the same UID / version.
- Web source is read from exact-version cache or fetched through `reader.chapter(...,{fresh_context=true,images=false})` (Web only). The canonical cache is written separately, **not into EPUB**.
- The existing PosMap normalizer verifies 1–3 unique, monotonic chapter text anchors distributed across chapter content. This is a conservative readiness check, not a proof that every arbitrary future KOReader XPointer maps exactly to WeRead.
- With missing/mismatched/ambiguous sources the old EPUB remains, checkpoint files remain, download is marked `coordinate_pending`, and only retries of unresolved chapters are needed. The new EPUB is NOT installed and no 100% success is displayed.
- For *new* downloads. Existing installed books are not modified or removed. Image-only, short, or different-edition chapters may be blocked rather than falsely marked ready. Internet and valid Web credentials are required.
- Web position preparation increases network requests by up to one Web source request per missing chapter and can trigger rate limiting. No position progress POST is made here.

## Features selectively restored
- Reading-time: preserve user's beta.9 Web/E-Ink worker ownership and close-session safety, restore Web credential revision isolation and stopped-reader offline outbox safety condition.
- Comment acquisition: opt-in next-chapter background preloading and late comment task progress UI; Home sync management shortcuts.
- No late-version ProgressFence, progress replay policy, or broken `progress_source_backfill.lua` is copied.

## Testing limitation
Offline parser, mocked actual Lua gate and source mapper, source-contract and available Python suites run. No real Kindle, live WeRead authentication or server credit / actual page restoration tested. Six existing test modules depend on unavailable `lupa`; see `TEST_RESULTS.md`.
