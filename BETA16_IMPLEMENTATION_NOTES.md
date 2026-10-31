# MiuRead 6.5.0-beta.16 — Web source availability != text match

- EPUB downloads and installs independently, then the *same download worker* immediately processes all installed chapters.
- The installed EPUB is never rolled back for Web fetch, text comparison or cache failures.
- Web source acquisition: reuses only Web-fetched sources with account-bound content digest provenance. A text-equal unproven legacy cache gets one Web refresh. When provenance is absent, fetches once via the authoritative Web Reader and caches it, regardless of short/image-only text or text-comparison mismatch.
- The provenance sidecar includes book and chapter UID, version, account/login session, source length and MD5; matching a known source does not certify exact positions.
- Diagnostic text comparison is retained, *but does not gate source caching*. An unmatched reading XPointer still fails closed in existing sync logic.
- New statuses distinguish total cached, text mapped and mismatch diagnostics. Old installed-book background tasks use the same acquisition policy, while newly downloaded books do not enter the idle queue.
- beta.15 post-install JSON checkpoints are migrated in memory with `cached=verified`; no destructive migration is performed.
- Offline syntax and targeted tests are not a substitute for Kindle/real WeRead tests.
- No edits to progress upload/readtime/Sync core, transport, beta.5 Release workflow.

- Direct Web chapters downloaded in the current task receive the provenance marker at capture time, avoiding duplicate chapter fetch during the immediate post-install pass.
