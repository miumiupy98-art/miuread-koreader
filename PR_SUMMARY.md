# GitHub Pull Request — MiuRead v6.5.0-beta.27

## Title
feat: support local EPUB WeRead comments, chapter mapping, and thought replies (v6.5.0-beta.27)

## Summary
- Add **local EPUB → WeRead book** binding via book search or explicit `bookId`. Store multiple book associations per local EPUB, with unlink and manual chapter assignment.
- Match remote chapters by normalized local TOC heading; allow **multiple remote chapters per local TOC entry**. Provide explicit cached-quote assisted matching when at least two distinct excerpts are found in the current local chapter.
- Reuse existing MiuRead comment fetch Worker, shared `ThoughtDatabase`/SQLite and reader comment overlay. Project excerpts into **the local EPUB's own XPointer positions** without modifying source EPUB bytes; keep local position cache namespaced by EPUB fingerprint, remote book, chapter, local TOC index.
- Add read-only `/web/review/single` replies to the existing native thought popup's action menu; disk-cache normalized replies for 30 minutes, with offline reuse.
- Wire `chapter_public_reviews` to the unified API and query a bounded chapter public feed if an explicit comment fetch returns no underlines. Use this in both reader-triggered and download-with-comments flows.
- Add the same comment navigation from the built-in KOReader plugin menu. Preserve the normal cloud reader, readtime reporting, sync, downloader core, schema **136**, GitHub Actions and auto-tag workflow.

## Principal files changed
- `miuread.koplugin/main.lua` — reader UI actions, local binding and range-fetch entry points, overlay lifecycle, replies callback.
- `miuread.koplugin/miuread/local_book_binding.lua` **new** — persistent EPUB fingerprint, multi-book bindings, manual maps and local location cache.
- `miuread.koplugin/miuread/local_chapter_map.lua` **new** — TOC normalization, title matching, quote evidence and XPointer bounds.
- `miuread.koplugin/miuread/review_replies.lua` **new** — reply normalization and disk caching.
- `miuread.koplugin/miuread/api.lua`, `api_web.lua`, `annotations.lua` — supplementary public reviews and individual thought replies.
- `miuread.koplugin/miuread/comment_locator.lua`, `comment_sync.lua`, `downloader.lua`, `thought_native_popup.lua`, `plugin_menu.lua` — minimal calls/integration and UI menu.
- `miuread.koplugin/miuread/config.lua`, `miuread.koplugin/_meta.lua`, `CHANGELOG.md`, `README.md` — bump version and document usage.
- `tools/test_local_comments_beta27.lua`, `tools/test_imported_public_comments.lua`, `tools/test_beta27_integration_contract.py` **new** — offline regression and structure checks.

## Validation
- Lua parser (`texlua loadfile`): 180 plugin Lua files, **0 parse failures**.
- `tools/test_local_comments_beta27.lua`: **PASS** (bind/persist, multiple books, manual/title/quote matching, separate location caches, reply parser/cache).
- `tools/test_imported_public_comments.lua`: **PASS** (empty underlines fallback, dedupe, network errors and normal range parsing).
- Existing EPUB, readtime and release automation tests: **PASS** when compatible with available test runtime.
- `tools/test_beta27_integration_contract.py`: **PASS** (version, wiring and no changes to Actions/automatic release configuration).
- Real WeRead server calls, end-to-end Kindle/KOReader gestures, E-Ink redraw, and release workflows in GitHub are **NOT YET VERIFIED**.

## Caveats / QA required
- Private WeRead uploads may not expose public reviews; an empty feed is not proof no reviews exist, nor an exhaustive list of all historical replies.
- Different text editions/translations might be readable in the comment list but **not** have precise in-text markers. Current implementation supports reflowable EPUB and TOC-based chapters.
- Test actual search, association, chapter fetch, inline mark taps, reply dialog and pause/recovery on hardware before production publication.
- KOReader LuaJIT/Linux runtime is not fully replicated by the available `texlua` runner; two legacy suites requiring LuaJIT (`bit` and Lua 5.1 `setfenv`) were not counted as passing under the normal test invocation.

## Release and issue handling
- Proposed release: **v6.5.0-beta.27**.
- No `.github/workflows` or release issue auto-close configuration changes in this PR.
- Do not close #135 based on these unit tests; its prior real-device verification requirement remains.
