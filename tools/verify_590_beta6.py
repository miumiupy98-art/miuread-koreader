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
store=read('miuread.koplugin/miuread/store.lua')
pos=read('miuread.koplugin/miuread/position_resolution.lua')
worker=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
source=read('miuread.koplugin/miuread/source_position.lua')
wf=read('.github/workflows/release-beta.yml')
ch=read('CHANGELOG.md')

ok('version = "5.9.0-beta.6"' in meta,'metadata version beta.6')
ok('VERSION = "5.9.0-beta.6"' in config,'config version beta.6')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('## 5.9.0-beta.6' in ch,'beta.6 changelog section exists')

# Regression recovery: fence is runtime-only, old durable locks are repaired.
ok('self._progress_write_fences' in main,'runtime progress fence exists')
ok('progress_write_blocked=true' not in main,'main no longer persists write fence')
ok('scope=session' in main,'fence logs identify session scope')
ok('beta.5 progress fences recovered at startup' in store,'startup repairs beta.5 durable fences')
ok('progress_upload_state="pending_send"' in store and 'progress_submission_phase="unsent"' in store,'beta.5 fenced records become UNSENT')

# UNSENT must re-check remote before submit.
start=main.index('function Plugin:_submit_saved_pending_progress')
end=main.index('function Plugin:_submit_all_saved_pending_progress',start)
recovery=main[start:end]
ok('self.sync:remote(book_id' in recovery,'UNSENT recovery fetches remote first')
ok('PR.decide{' in recovery,'UNSENT recovery runs freshness resolver')
ok(recovery.index('self.sync:remote(book_id') < recovery.index('self:_submit_progress_snapshot(book_id'),'remote check occurs before submit')
ok('remote_newer_local_unsent_dropped' in recovery,'stale UNSENT local write is dropped when cloud is newer')
ok('freshness_conflict' in recovery,'ambiguous UNSENT recovery stays deferred')
ok('force_write=true' in recovery,'resolver-authorized local recovery can submit after preflight')

# Runtime graph must be scalarized before async IPC.
ok('PositionResolution.snapshot(remote)' in sync,'remote mapping scalarizes runtime graph')
ok('remote.sources.*' in sync,'cycle regression is documented at IPC boundary')

# Local read event is independent from precise mapping.
ok('local_read_event_at=math.max' in sync,'close/suspend persist independent local read event')
ok('session.local_read_event_at' in main,'resolver consumes independent local read event')
ok('durable_event=tonumber(session.local_read_event_at or 0)' in sync,'snapshot freshness uses local read event when mapping later succeeds')

# Remote mapping failure should not poison the book; fallback remains verify-gated.
ok('remote native mapping unavailable; using verified-jump fallback' in main,'native mapping failure falls back to verified jump')
ok('apply_remote(remote)' in main,'raw remote can seed fallback navigation')
ok('remote_exact_unresolved' in main,'current reconciliation still protects against an unverified remote jump')
ok('write_fenced:' in main and 'parked=unsent' in main,'blocked write is parked as UNSENT rather than verify-only')

# Independent beta.5 fixes retained.
ok('automatic_check_after_user_interaction' not in main,'user interaction no longer forces local winner')
ok('value.canonical_progress or value.calculated_percent' in sync,'canonical cloud progress remains preferred')
ok('anchor.canonical_progress or anchor.calculated_percent or anchor.progress' in worker,'read report still uses canonical cloud progress')
ok('out.canonical_progress = percent' in source,'remote chapter/co mapping still derives canonical progress')
ok('position snapshots compacted at startup' in store,'beta.4 cyclic snapshot repair retained')
ok('READ_TIME_BEST_EFFORT = true' in config,'reading time remains best effort')

ok((root/'tools/test_beta6_sync_contract.lua').is_file(),'beta.6 sync contract test exists')
ok('lua5.1 tools/test_beta6_sync_contract.lua' in wf,'release workflow runs beta.6 contract test')
ok('python3 tools/verify_590_beta6.py' in wf,'release workflow runs beta.6 verifier')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
