from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
service=(root/'miuread.koplugin/miuread/read_report_service.lua').read_text(encoding='utf-8')
worker=(root/'miuread.koplugin/miuread/legacy/read_report_worker.lua').read_text(encoding='utf-8')
source=(root/'miuread.koplugin/miuread/source_position.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.15"' in config,'config version beta.15')
ok('version = "5.9.0-beta.15"' in meta,'metadata version beta.15')
ok(ch.startswith('## 5.9.0-beta.15'),'beta.15 changelog is first')
ok('local READ_REPORT_SERVICE_VERSION = 29' in sync,'read-report service version 29')

ok('function Sync:remote_wire_anchor' in sync,'remote wire getter exists')
ok('function Sync:set_remote_wire_anchor' in sync,'remote wire setter exists')
ok('self:set_remote_wire_anchor(book_id,remote,"remote_observed_wire",true)' in sync,'remote observation refreshes wire anchor')
ok('remote_wire_chapter_uid=wire_anchor and wire_anchor.chapter_uid or nil' in sync,'daemon has wire uid')
ok('remote_wire_chapter_offset=wire_anchor and wire_anchor.chapter_offset or nil' in sync,'daemon has wire co')
ok('remote_wire_protocol_progress=wire_anchor and wire_anchor.protocol_progress or nil' in sync,'daemon has wire pr')

start=service.find('local report_job = {'); end=service.find('local attempted_at = os.time()',start)
report=service[start:end]
ok('control.remote_wire_chapter_uid' in report,'service time writer reads wire uid')
ok('control.remote_wire_chapter_offset' in report,'service time writer reads wire co')
ok('control.remote_wire_protocol_progress' in report,'service time writer reads wire pr')
ok('control.cloud_anchor_chapter_uid' not in report,'service time writer does not read old cloud uid')
ok('control.cloud_anchor_chapter_offset' not in report,'service time writer does not read old cloud co')

ok('anchor.protocol_progress or anchor.raw_progress or anchor.raw_percent' in worker,'worker accepts wire protocol/raw progress')
ok('or book.remote_raw_progress' in worker,'worker refresh fallback accepts remote raw progress')
ok('local refreshed=refresh_remote_anchor(client, book_id, book)' in worker,'every compat time write refreshes server anchor')
ok('fresh cloud reading position unavailable for reading-time report' in worker,'failed fresh GET blocks time POST')
ok('position_override = normalize_cloud_anchor(job.cloud_anchor, book)' not in worker,'worker does not trust cached parent anchor for compat time write')
ok('local anchor=self:remote_wire_anchor(book_id)' in sync,'safe retry uses wire anchor')

for state in ['state=call_failed','state=invalid_return','state=zero_hits','state=hits_outside_chapter','state=multiple_hits','state=unique_hit']:
    ok(state in sync,'text anchor diagnostic '+state)
ok('document.findAllText,document,query,true,3,40,false,flags' in sync,'standard text search call')
ok('document.findAllText,document,query,true,3,40)' in sync,'compat text search fallback')
ok('return false,"text_anchor_search_failed"' not in sync,'generic swallowed text search error removed')

# Retain previous progress safety.
ok('remote_chapter_resolved' in main,'beta.14 same-chapter soft state retained')
ok('_restore_position_rollback("remote exact verification failed"' in main,'hard rollback retained')
ok('options.force_refresh == true and (refresh_uid == "" or refresh_uid == uid)' in source,'source force refresh retained')
ok('FFIUtil.isSubProcessDone,pid,false' in sync,'subprocess completion fix retained')

ok('lua5.1 tools/test_beta15_sync_contract.lua' in workflow,'release workflow runs beta.15 contract')
ok('python3 tools/verify_590_beta15.py' in workflow,'release workflow runs beta.15 verifier')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'tests still run before tag creation')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
