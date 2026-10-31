# MiuRead 6.5.0-beta.11 — Automatic pre-install Web coordinate retry

## Baseline and unchanged behavior
- Based on user beta.9 -> beta.10, **not** the outdated 6.3.0 branch.
- Reader time upload/worker ownership, progress network POST, verification, remote selection and pending-progress recovery retained. The seven protected progress functions are SHA-256 checked unchanged.
- New EPUB installation still occurs ONLY after every readable included chapter passes `download_source_gate` verification. Old installed EPUBs are not rewritten.

## New durable coordinate retry
- `miuread/download_coordinate_retry.lua` keeps a small persistent queue of failed pre-install coordinate tasks in Store (`download_coordinate_retry_v1`). This is independent of reading-progress pending and the one-slot user download queue.
- On coordinate failure, chapter checkpoints remain; a matching retry job is scheduled in the background. Also imports a single beta.10 `coordinate_pending` failed download at startup when available.
- When network + account + awake + Home (not actively reading) + idle download machinery permit, it re-enters the *existing* downloader with `_from_checkpoint=true`; successfully cached and validated chapters are reused, only missing/mismatched Web sources are fetched.
- User-queued jobs take priority. Automatic retries do not start while reading, asleep, logging out, memory-busy or without Wi-Fi. They do NOT change EPUB contents, progress POST, or reading-time reporting.
- Retry backoff: transient 45 s / 135 s / 405 s / 1215 s / up to 1 h; HTTP 429 10–60 min; auth 5 min while matching account identity; deterministic text mismatch one 10-min retry then `needs_attention` (no endless repeated Web calls).
- Jobs bound to login session + account VID; switching accounts will not send old-account retries. Manual new download of the same book replaces its stale retry entry; completed books remove the matching queued entry.
- Keeps at most 12 queued coordinate jobs; does not include Web cookies, tokens or saved cloud progress.

## Limits
- Automatic recovery requires plugin loaded and device awake/online; it is not a guaranteed remote push service when KOReader is closed or Kindle asleep.
- New book/downloads only. Previously installed E-Ink EPUBs are not scanned for whole-book backfill.
- A source/book edition that cannot be mapped deterministically is marked needs_attention after a bounded retry rather than repeatedly consuming bandwidth.
- Real Kindle/WeRead tests not run in this environment.
