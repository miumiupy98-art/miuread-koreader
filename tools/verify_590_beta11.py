from pathlib import Path
import hashlib, sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
translation=(root/'miuread.koplugin/miuread/translation.lua').read_text(encoding='utf-8')
sync_bytes=(root/'miuread.koplugin/miuread/sync.lua').read_bytes()
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
ok('VERSION = "5.9.0-beta.11"' in config,'config version beta.11')
ok('version = "5.9.0-beta.11"' in meta,'metadata version beta.11')
ok(ch.startswith('## 5.9.0-beta.11'),'beta.11 changelog is first')

# Manual sync convergence.
a0=main.find('function Plugin:_home_action_entries()')
a1=main.find('function Plugin:_home_alerts()',a0)
actions=main[a0:a1]
ok('self:_sync_home_pending({source="home_quick"})' in actions,'Home quick enters shared recovery')
ok('_home_sync_summary(true)' not in actions,'Home quick no longer depends on summary preflight')
ok('function Plugin:_sync_progress_full_recovery' in main,'shared progress helper exists')
ok('[MiuRead][SyncAction] progress recovery begin' in main,'shared progress begin logged')
ok('[MiuRead][SyncAction] progress recovery end' in main,'shared progress end logged')
ok('self:_sync_home_pending({source="sync_status_all"})' in main,'Sync Status all retry source-tagged')
ok('self:_sync_home_pending({source="progress_issues"})' in main,'progress issue retry source-tagged')
r0=main.find('function Plugin:_sync_home_pending(options)')
r1=main.find('function Plugin:sync_settings_menu()',r0)
recovery=main[r0:r1]
manual_start=recovery.find('-- beta.11: every explicit Sync entry')
manual=recovery[manual_start:] if manual_start>=0 else ''
gate=manual.find('[MiuRead][SyncAction] gate')
login=manual.find('if not logged_in then')
radio=manual.find('if radio==false then')
manual_run=manual.find('return phase_progress()')
ok(manual_start>=0 and min(gate,login,radio,manual_run)>=0 and gate<login<radio<manual_run,'manual login/radio gates precede recovery')
ok('local started=self:_sync_progress_full_recovery(source,true' in recovery,'phase_progress uses shared helper')
ok('正在确认阅读进度同步状态' in recovery,'manual zero-summary progress verification retained')

# Wake network readiness.
ok('local require_online=options.require_online==true' in main,'network wait supports online gate')
ok('HomeData.quick_device_state(true,true)' in main,'network wait probes online state')
ok('if state.online==true then return true end' in main,'explicit online state accepted')
ok('state.connected==true and phase=="connected" and elapsed>=minimum+2' in main,'stable connected fallback has grace')
ok('self:_wait_for_network("reader-progress-online"' in main,'reader progress uses shared online waiter')
ok('source=network_restored' in main and 'source=resume_recheck' in main,'wake sources are diagnosable')
ok('[MiuRead][ResumeSync] waiting_network' in main and '[MiuRead][ResumeSync] reconcile_started' in main,'wake wait/reconcile diagnostics exist')

# beta10 translation/release fixes remain.
ok('require("miuread.util")' not in '\n'.join(translation.splitlines()[:20]),'translation top-level remains independent of miuread.util')
ok('local function trim(value)' in translation,'translation pure Lua trim retained')
ok('local book_id=trim(meta.book_id)' in translation,'translation inspect uses local trim')
ok('not_imported_book' not in translation,'non-CB bookId support retained')
ok('lua5.1 tools/test_beta10_translation_dependency_contract.lua' in workflow,'beta.10 translation contract retained')
ok('lua5.1 tools/test_beta11_sync_contract.lua' in workflow,'release workflow runs beta.11 sync contract')
ok('python3 tools/verify_590_beta11.py' in workflow,'release workflow runs beta.11 verifier')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'release tests still run before tag creation')
ok('line.startswith(heading + " — ")' in workflow,'release changelog parser accepts em dash headings')

# Low-level sync engine intentionally unchanged from beta10/beta8.
hashv=hashlib.sha256(sync_bytes).hexdigest()
ok(hashv=='ed10bf4829d4bdc3034117b703333bcff9b5d802594baa29da6fb07cbd41cd5c','sync core byte-identical to beta10/beta8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
ok('finish(false,"time_writer_preempt_timeout")' in sync,'time-writer timeout guard retained')
ok('state="time_writer_detached"' not in sync,'alternate immediate-detach strategy not adopted')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
