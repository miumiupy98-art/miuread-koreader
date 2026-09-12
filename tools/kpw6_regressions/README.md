# KPW6 UI and resume regressions

These tests cover UI network preflight, resolver recovery, report timing across
suspend, Home preference persistence, and popup metadata reuse. Fixtures do not
contain accounts, reading history, or device settings. Like actions are mocked.

Copy the repository to `/tmp/miuread-reviewed` on a KOReader device, then run from
the KOReader directory (where `setupkoenv.lua` and `luajit` are available):

```sh
./luajit /tmp/miuread-reviewed/tools/kpw6_regressions/network_test.lua /tmp/miuread-reviewed/miuread.koplugin
./luajit /tmp/miuread-reviewed/tools/kpw6_regressions/service_test.lua /tmp/miuread-reviewed/miuread.koplugin
./luajit /tmp/miuread-reviewed/tools/kpw6_regressions/fork_test.lua /tmp/miuread-reviewed/miuread.koplugin
./luajit /tmp/miuread-reviewed/tools/kpw6_regressions/navigation_test.lua /tmp/miuread-reviewed/miuread.koplugin/main.lua
./luajit /tmp/miuread-reviewed/tools/kpw6_regressions/popup_context_test.lua /tmp/miuread-reviewed/miuread.koplugin/main.lua
```

The first and third tests target Kindle/glibc. The fork test performs DNS lookups
for `weread.qq.com`, but does not call authenticated APIs. Run one instance at a
time. The navigation and popup tests also run under standalone Lua 5.1/LuaJIT.

Verified on KPW6 with beta22:

- Five regression scripts pass, including navigation after a pending real
  setting, stale timers, persistence failure/retry, and empty document paths.
- `python tools/verify_beta22.py`: 292 checks pass.
- Existing `test_online_comment_likes.lua`, `test_extension_download.lua`,
  `test_extension_install.lua`, `test_store_shared.lua`, and
  `test_readtime_recovery.lua` pass. On KOReader, the installer test needs
  `package.loaded.lfs = require('libs/libkoreader-lfs')` after `setupkoenv`.
- Original popup metadata preparation took 426–435 ms; matched-document reuse
  took 0.085–0.170 ms. Subsequent user popup logs recorded 20–49 ms.
- Original navigation-triggered full settings writes took 2.18–2.32 seconds;
  five user section-switch samples after deferring navigation writes took
  355–991 ms, measured through section application with a monotonic clock.

These timings do not include the final physical e-ink refresh. Simulated suspend
and real fork tests do not prove stability after a long real deep-sleep cycle.
Navigation positions remain in memory until a lifecycle save or another settings
write; an abnormal process exit can lose the latest tab/page selection. Reading
progress persistence is unchanged.

## Reader return follow-up (2026-09-12)

`full_refresh_test.lua <plugin>/main.lua` checks Home with a closed Reader,
active Reader footer refresh, a closing Reader, and listener failure fallback.
`../test_store_shared.lua` also covers unchanged close saves, nested mutations,
deletions, malformed disk repair, newer externally verified progress and write
failure recovery. Run `../test_store_repair.lua` for compaction/recovery checks.

On a KPW6 using a private copy of the actual 2.8 MB settings file on `/mnt/us`,
three changed-save samples fell from 1872–1908 ms to 1041–1097 ms; three unchanged
saves fell from 1845–1872 ms to 159–251 ms. Every saved value was compared after
loading the output. These isolated save timings do not measure end-to-end Home
return or physical e-ink refresh. All settings writes remain synchronous;
serialization order alone changes, and unchanged saves compare against a fresh
validated disk read after merging newer progress and applying compaction.

## Combined optimization review follow-up

Deferred Home navigation is now marked in the shared Store. A reload overlays
only the pending active tab and per-tab pages onto the newly loaded preferences;
worker library/progress data and unrelated settings still come from disk. A
successful save (including an unchanged save) clears the overlay. Failed writes
retain it for retry. Opening downloads or receiving a background result therefore
does not reset the current navigation or require an extra foreground save.

Regression coverage includes worker-result reloads, unrelated disk preferences,
nested mutations/deletions, decimal round trips, failure/reload/retry and overlay
release after both changed and unchanged saves. The combined review passed 292
static checks and 14 device test scripts. The live fork/DNS script could not
complete because host lookup failed; a fresh LuaSocket process without MiuRead
also failed the same lookup. This is a blocked live-network check, not a pass.

## Small follow-up for remaining return latency

Settings now use the same Lua literals/number formatting as KOReader dump with
compact whitespace; cycles, unusual keys and unsupported values fall back to the
existing serializer. Loading, validation, atomic replacement, backups and pending
navigation handling remain in place. On the same device/settings copy, three
changed saves measured 1008–1097 ms before and 727–779 ms after, with full value
round-trip comparison; file size fell from about 2.8 MB to 1.2 MB.

When native ReaderUI:onClose has returned and the reader is fully gone with a
parked Home available, restoration runs immediately through the existing guarded
completion path. Incomplete/failed closes and missing Home retain the old settle
and recovery path. This avoids due background callbacks getting ahead of the
Home restoration timer; it does not skip document saving or close cleanup.

`compact_settings_test.lua <plugin>/miuread/store.lua` covers escaping, sparse
keys, booleans, aliases and native fallback. `reader_return_test.lua
<plugin>/main.lua` covers completed/unfinished/failed close, missing Home and
stale generations. This round passed all 17 device scripts, including live fork
DNS, plus 292 static checks. Save benchmarks exclude UI/physical display time;
end-to-end targets still require real interaction samples.
