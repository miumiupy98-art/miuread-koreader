# MiuRead 6.5.0-beta.15 — EPUB-first, same-task Web-source completion

- Based on beta.14. The pre-install `download_source_gate` was removed from the download path; the gate module is retained for older code/tests.
- EPUB package, complete-chapter/resource validation, safe install and book-record saving remain in `Downloader:_save()`.
- Immediately after `_save`, the *same* worker calls `post_install_web.run`: it reads actual installed XHTML with `legacy_coordinate_backfill.perform`, verifies/fetches Web source per chapter and caches accepted results. No scheduling on the home idle queue for the newly downloaded book.
- Failed/short/image-only chapters are recorded, do not block the installed EPUB, and are never marked as safely mapped. All other chapters continue unless a transient network/auth/rate-limit error occurs.
- A task-specific durable snapshot stores current chapter, completed/failed counts and installed EPUB record. Hibernate restart checks task id, account, EPUB file size/mtime, book ID, EPUB task ID and chapter count, and resumes Web completion without rebuilding the EPUB.
- Existing old-book background backfill and beta.14 progress-manager entry remain unchanged.
- Existing progress upload/readtime implementations, sync.lua, download_transport.lua and beta.5 release workflow are byte-identical to beta.14.
- `post_install_web_status` (and its sidecar checkpoint) records Web-source verification after installation. The installed EPUB metadata keeps `progress_source_complete=false` because it is immutable after installation; precise cloud co remains separately verified at reading time.

Limitations: Kindle and live WeRead network not tested here; short/image-only chapters and real anchoring conflicts remain nonfatal Web-source issues. A simulated unit test does not prove real EPUB coverage.
