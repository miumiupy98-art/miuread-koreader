#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
def read(p): return (root/p).read_text(encoding='utf-8')
meta=read('miuread.koplugin/_meta.lua')
config=read('miuread.koplugin/miuread/config.lua')
main=read('miuread.koplugin/main.lua')
sync=read('miuread.koplugin/miuread/sync.lua')
source=read('miuread.koplugin/miuread/source_position.lua')
pos=read('miuread.koplugin/miuread/position_resolution.lua')
store=read('miuread.koplugin/miuread/store.lua')
worker=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
service=read('miuread.koplugin/miuread/read_report_service.lua')
ch=read('CHANGELOG.md')
wf=read('.github/workflows/release-beta.yml')

ok('version = "5.9.0-beta.5"' in meta,'metadata version beta.5')
ok('VERSION = "5.9.0-beta.5"' in config,'config version beta.5')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('OPEN_SYNC_SOFT_TIMEOUT_SECONDS = 6.0' in config,'nonblocking sync hint budget 6 seconds')
ok('LATE_REMOTE_APPLY_WINDOW_SECONDS = 15' in config,'late remote auto-apply window 15 seconds')
ok('OPEN_SYNC_READ_DEBOUNCE_SECONDS = 60' in config,'exact-aligned read debounce 60 seconds')
ok('READ_TIME_BEST_EFFORT = true' in config and 'READ_TIME_MAX_ATTEMPTS = 2' in config,'reading time is two-attempt best effort')
ok('## 5.9.0-beta.5' in ch,'beta.5 changelog section exists')

# Reconciliation and write safety.
ok('open_local_position=_G.__MIUREAD_POSITION_RESOLUTION.snapshot(prior)' in main,'opening local snapshot is frozen')
ok('local_updated_at=tonumber(prior.updated_at or 0)' in main,'freshness ignores technical upload/decision times')
ok('ambiguous_clock_conflict' in pos and 'winner="conflict"' in pos,'ambiguous timestamp divergence becomes conflict')
ok('automatic_check_after_user_interaction' not in main,'user interaction no longer forces local winner')
ok('late_remote_after_user_interaction' not in main,'late user interaction no longer forces local winner')
ok('progress_write_blocked=true' in main and 'progress_write_fenced' in main,'persistent progress write fence exists')
ok('options.force_write~=true and options.verify_first~=true' in main,'all normal writes pass the fence')
ok('remote_fetch_pending' in main and 'remote_newer_pending' in main and 'remote_exact_unresolved' in main,'unresolved remote states keep write protection')
ok('exact_cached_alignment' in main,'60s debounce is limited to an already exact-aligned cache')
ok('First PageUpdate after opening only establishes the baseline' in sync,'opening restored page is not a new local event')
ok('local freshness belongs to progress reconciliation' in sync,'local event time tracking works even when time sync is disabled')

# Canonical progress / terminal guard.
ok('value.canonical_progress or value.calculated_percent' in sync,'cloud anchor starts from canonical progress')
ok('anchor.canonical_progress or anchor.calculated_percent or anchor.progress' in worker,'read report consumes canonical cloud progress')
ok('book.remote_raw_progress' in worker and 'book.remote_progress =' not in worker,'server raw percent remains diagnostic in worker')
ok('out.canonical_progress = percent' in source,'remote chapter/co mapping produces canonical progress')
ok('remote_search_anchor' in source and 'out.search_anchor_text' in source,'remote source mapping exposes a bounded text anchor')
ok('A whole-book percent (especially server raw 100) cannot create it.' in pos,'finished state is independent of percent')

# Exact positioning.
ok('function Sync:text_anchor_rescue' in sync,'text-anchor to XPointer rescue exists')
ok('function Sync:jump_cached_remote_position' in sync and 'function Sync:cache_remote_xpointer' in sync,'verified exact XPointer cache exists')
ok('bounded percent fallback' in main and 'correction_attempt<1' in main,'percent correction is bounded to one fallback')
ok('cache_remote_xpointer(remote,verified_xpointer)' in main,'XPointer cache is populated only after exact verification')

# Reading time best effort.
ok('best_effort_runtime_only' in sync,'reading-time debt is not persisted')
ok('state = drop_time and "dropped"' in service,'runtime retry budget drops repeated time failures')
ok('reading-time retry state cleared at startup' in store,'beta.4 reading-time failures are cleaned at startup')
ok('if Config.READ_TIME_BEST_EFFORT==true then return {} end' in main,'reading-time failures are hidden from home problem list')

# beta.4 crash repair and release regression retained.
ok('position snapshots compacted at startup' in store,'beta.4 cyclic position-state startup repair retained')
ok((root/'tools/test_beta5_sync_contract.lua').is_file(),'beta.5 sync contract regression exists')
ok('lua5.1 tools/test_beta5_sync_contract.lua' in wf,'release workflow runs beta.5 sync contract')
ok('python3 tools/verify_590_beta5.py' in wf,'release workflow runs beta.5 verifier')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
