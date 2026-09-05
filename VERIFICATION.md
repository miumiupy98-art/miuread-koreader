# 5.8.0-beta.7 verification

Scope: cumulative beta.6 Home fixes plus #87/#90 Reader lifecycle, ReadReport, power and memory containment. #71 exit/download protection remains intact.

Checks performed in the build environment:

- Lua load/compile syntax: 134/134 files passed with `texluac -p`.
- Implementation assertions: 55/55 passed.
- BackgroundScheduler behavior harness: PASS (park creates no timer; RuntimePressure low-priority defer becomes park; active worker no longer self-polls; release event schedules the next wake).
- Schema remains 128.
- Frozen core file hashes match beta.5 for extension installer/center, download task, unified library, annotation sync, updater, and book-delete service.
- Broken-pipe handling is deliberately diagnostic/defensive at the MiuRead hook lifecycle level; KOReader input-core code is not modified because the supplied logs do not prove that MiuRead owns the broken pipe.
- CRE stylesheet-cache behavior is instrumented with EPUB size/mtime; KOReader CRE is not modified without proof that MiuRead rewrites the file.

Device/network behavior still requires real Kindle/Kobo testing. No claim is made here that the target latency, battery improvement, Broken-pipe root cause, or CRE cache stability has already been proven on hardware.
