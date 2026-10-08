from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
source=(root/'miuread.koplugin/miuread/source_position.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
translation=(root/'miuread.koplugin/miuread/translation.lua').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.12"' in config,'config version beta.12')
ok('version = "5.9.0-beta.12"' in meta,'metadata version beta.12')
ok(ch.startswith('## 5.9.0-beta.12'),'beta.12 changelog is first')

# beta.11 user-facing sync behavior remains.
a0=main.find('function Plugin:_home_action_entries()')
a1=main.find('function Plugin:_home_alerts()',a0)
actions=main[a0:a1]
ok('self:_sync_home_pending({source="home_quick"})' in actions,'Home quick shared recovery retained')
ok('_home_sync_summary(true)' not in actions,'Home quick remains independent of summary preflight')
ok('function Plugin:_sync_progress_full_recovery' in main,'shared progress helper retained')
ok('self:_sync_home_pending({source="sync_status_all"})' in main,'sync status source retained')
ok('self:_sync_home_pending({source="progress_issues"})' in main,'progress issues source retained')
ok('HomeData.quick_device_state(true,true)' in main,'active online probe retained')
ok('require_online=true' in main,'wake online readiness retained')

# Exact source network recovery must bypass the cache that already failed.
ok('local refresh_uid = tostring(options.force_refresh_uid or \"\")' in source,'source force-refresh UID exists')
ok('options.force_refresh == true and (refresh_uid == \"\" or refresh_uid == uid)' in source,'source refresh is targeted to requested chapter')
ok('if not force_refresh then' in source,'source caches are guarded by force-refresh')
ok('reason=force_source_refresh' in source,'cache bypass is diagnosable')
ok('SourcePosition.locate(reader, record_snapshot, anchor,{cache_only=false,force_refresh=true,force_refresh_uid=tostring(anchor.chapter_uid or \"\")})' in sync,
   'network recovery forces fresh source fetch')
ok('source_kind=network_refresh' in source,'fresh source fetch remains logged')

# Writer completion fix keeps single-writer safety.
ok('local function subprocess_done(pid)' in sync,'subprocess completion helper exists')
ok('FFIUtil.isSubProcessDone,pid,false' in sync,'KOReader subprocess completion API used')
p0=sync.find('function Sync:preempt_reading_time_for_progress')
p1=sync.find('function Sync:_cancel_record_retry()',p0)
preempt=sync[p0:p1]
ok('subprocess_done(pid) or not process_alive(pid)' in preempt,'preempt treats completed child as stopped')
ok('finish(false,"time_writer_preempt_timeout")' in preempt,'timeout guard remains fail-safe')
ok('state="time_writer_detached"' not in preempt,'immediate detach remains absent')
ok('signal_process,pid,9' in preempt,'SIGKILL fallback retained')

# beta.10 translation/release protections remain.
ok('require("miuread.util")' not in '\n'.join(translation.splitlines()[:20]),'translation top-level remains runtime-independent')
ok('local function trim(value)' in translation,'translation local trim retained')
ok('local book_id=trim(meta.book_id)' in translation,'numeric bookId path retained')
ok('lua5.1 tools/test_beta10_translation_dependency_contract.lua' in workflow,'translation dependency contract retained')
ok('lua5.1 tools/test_beta12_sync_contract.lua' in workflow,'release workflow runs beta.12 contract')
ok('python3 tools/verify_590_beta12.py' in workflow,'release workflow runs beta.12 verifier')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'release tests still run before tag creation')
ok('line.startswith(heading + " — ")' in workflow,'changelog parser still accepts em dash')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
