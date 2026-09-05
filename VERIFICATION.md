# 5.8.0-beta.8 verification

Scope: cumulative beta.7 performance/lifecycle fixes plus the InkStain recommendation catalogue addition. #71/#86/#87/#90 behavior remains otherwise unchanged.

Checks performed in the build environment:

- Lua load/compile syntax: 134/134 files passed with `texluac -p`.
- Implementation assertions: 55/55 passed.
- BackgroundScheduler behavior harness: PASS (park creates no timer; RuntimePressure low-priority defer becomes park; active worker no longer self-polls; release event schedules the next wake).
- Schema remains 128.

- Curated catalogue: `miumiupy98-art/inkstain.koplugin` resolves exactly once, is `recommended=true`, `featured=true`, and belongs to `reading_tools`, so it appears in both “精选推荐” and “阅读增强”.
- InkStain remains on the generic `standard` installer path; no plugin-specific installer branch was introduced.
- CHANGELOG beta.8/beta.7/beta.6 headings use `##`, matching the release-beta workflow parser.
- Release package hygiene: no `.md`/`.epub`/`.log` or runtime settings files remain under `miuread.koplugin`; `PERFORMANCE_IMPLEMENTATION.md` is kept at repository root only.
- `release-beta.yml` now prints the exact forbidden path(s) instead of only a generic validation error.
- Release workflow preflight simulation: version/channel/CHANGELOG parser PASS; plugin-package hygiene PASS; generated release package integrity and forbidden-file checks PASS (256 ZIP entries).
- Frozen core file hashes match beta.5 for extension installer/center, download task, unified library, annotation sync, updater, and book-delete service.
- Broken-pipe handling is deliberately diagnostic/defensive at the MiuRead hook lifecycle level; KOReader input-core code is not modified because the supplied logs do not prove that MiuRead owns the broken pipe.
- CRE stylesheet-cache behavior is instrumented with EPUB size/mtime; KOReader CRE is not modified without proof that MiuRead rewrites the file.

Device/network behavior still requires real Kindle/Kobo testing. No claim is made here that the target latency, battery improvement, Broken-pipe root cause, or CRE cache stability has already been proven on hardware.
