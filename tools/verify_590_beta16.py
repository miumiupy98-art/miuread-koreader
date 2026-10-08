from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
store=(root/'miuread.koplugin/miuread/store.lua').read_text(encoding='utf-8')
worker=(root/'miuread.koplugin/miuread/legacy/read_report_worker.lua').read_text(encoding='utf-8')
service=(root/'miuread.koplugin/miuread/read_report_service.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.16"' in config,'config version beta.16')
ok('version = "5.9.0-beta.16"' in meta,'metadata version beta.16')
ok(ch.startswith('## 5.9.0-beta.16'),'beta.16 changelog is first')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('local READ_REPORT_SERVICE_VERSION = 30' in sync,'read-report service version 30')

for token in ['progress_state_reset_beta16','beta16_one_shot_clean_state','row.progress_epoch=previous_epoch+1',
              '"cloud_anchor"','"remote_wire_anchor"','"pending_progress"','"position_state"',
              '"local_position_snapshot"','"legacy_report_context"','"report_context"']:
    ok(token in store,'store reset contains '+token)
ok('local_display_progress' not in store[store.find('local PROGRESS_SYNC_RESET_KEYS={'):store.find('local function emergency_compact_sessions')],
   'startup reset preserves local display progress')
ok('function Store:reset_progress_sync_state' in store,'manual/store reset API exists')
ok('self.store:reset_progress_sync_state(id,"manual_book_progress_reset",true)' in main,'manual book reset uses shared reset API')

start=sync.find('function Sync:_write_daemon_control'); end=sync.find('function Sync:_schedule_daemon_poll',start)
control=sync[start:end]
ok('local cloud_anchor=book_id' not in control,'daemon no longer loads canonical cloud anchor')
ok('cloud_anchor_chapter_uid=' not in control,'daemon no longer persists cloud uid')
ok('cloud_anchor_chapter_offset=' not in control,'daemon no longer persists cloud co')
ok('remote_wire_chapter_uid=wire_anchor and wire_anchor.chapter_uid or nil' in control,'daemon retains wire uid')
ok('remote_wire_chapter_offset=wire_anchor and wire_anchor.chapter_offset or nil' in control,'daemon retains wire co')
start=sync.find('function Sync:set_cloud_anchor'); end=sync.find('function Sync:remote(',start); cloudsetter=sync[start:end]
ok('self:_write_daemon_control' not in cloudsetter,'canonical CloudAnchor never writes daemon control')
ok('cloud_anchor_chapter_uid=' not in cloudsetter and 'cloud_anchor_chapter_offset=' not in cloudsetter,'canonical anchor fields cannot leak to daemon')

ok('local refreshed=refresh_remote_anchor(client, book_id, book)' in worker,'beta15 fresh GET before time write retained')
ok('fresh cloud reading position unavailable for reading-time report' in worker,'fresh GET failure blocks time POST')
ok('position_override = normalize_cloud_anchor(job.cloud_anchor, book)' not in worker,'cached parent anchor path remains removed')
start=service.find('local report_job = {'); end=service.find('local attempted_at = os.time()',start); report=service[start:end]
ok('control.remote_wire_chapter_uid' in report,'service uses remote wire uid')
ok('control.cloud_anchor_chapter_uid' not in report,'service does not use old cloud uid')

ok('if snapshot_epoch~=current_epoch then return false end' in main,'progress epoch stale guard retained')
ok('stale verification ignored' in main,'verification stale guard retained')
ok('remote_chapter_resolved' in main,'beta14 soft mismatch retained')
ok('lua5.1 tools/test_beta16_sync_contract.lua' in workflow,'beta16 contract in release workflow')
ok('python3 tools/verify_590_beta16.py' in workflow,'beta16 verifier in release workflow')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'tests run before tag creation')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
