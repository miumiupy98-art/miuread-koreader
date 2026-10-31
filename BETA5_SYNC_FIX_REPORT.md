# MiuRead 6.5.0-beta.5 — progress synchronization fix report

## Scope
Base: user-provided 6.5.0-beta.4 full source. This build is NOT certified on a Kindle device.

1. Reading-end event snapshot: the pending state and the upload guard now share the final position's genuine reading-event watermark. `pending_already_saved` does not silently skip restoration of the same saved event. Old pending records cannot borrow a newer reading event.
2. Genuine page events: allocate the next sequence against in-memory AND durable on-disk watermarks and flush immediately; Store progress merges cannot lower the independently maintained event watermark. Programmatic jumps do not count as user page movements.
3. Web progress readback: native Web `wr_data_co` offsets in the same UID may differ by up to 100 units; the result is `chapter_offset_equivalent`, NOT exact or proof of identical page layouts. Reject different chapters, unverified zero coordinates, and stale/missing post-submission server timestamps. Non-Web coordinates retain the old 12-unit tolerance.
4. Retain existing reading-time fixed-anchor, end-of-session time flush/preemption and final progress write ordering, existing Web/EInk downloads, source backfill, and beta GitHub workflows.
5. Retain verification-first handling for dispatched but unconfirmed requests; no blind automatic resend.

## Regression test coverage
- `tools/test_progress_confirmation.lua`: 22 scenarios, including native +76 accepted, +101 rejected, foreign chapter rejected, unresolved/resolved co=0, stale cloud timestamp rejected, fresh genuine event after remote fence can submit, no new event remains fenced, and old pending cannot borrow latest event.
- `tools/test_650_beta5_event_store.lua`: real store function and disk progress merge with Reader/Home alternation `29→30→31→32`.
- Existing sync/cloud freshness, progress recovery, mixed source cache, smart reading-time and Store tests executed with system Lua 5.4 (not device LuaJIT).

## Limitations
- No Kindle runtime or live WeRead service was available. Actual latency of immediate settings flush per genuine page event and cross-process interleavings require device measurement.
- 100 UTF-16 Web coordinate units is an intentionally approximate tolerance and does not guarantee the same rendered page.
- Existing source-anchor conflicts in some books are not reworked in this release.
- KOReader-only tests requiring `setupkoenv` cannot run in the available container; one existing Store float-representation test also fails unchanged on beta.4 under the host Lua 5.4 runtime.
