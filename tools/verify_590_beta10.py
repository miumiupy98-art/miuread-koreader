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
ok('VERSION = "5.9.0-beta.10"' in config,'config version beta.10')
ok('version = "5.9.0-beta.10"' in meta,'metadata version beta.10')
ok(ch.startswith('## 5.9.0-beta.10'),'beta.10 changelog is first')
# Home quick path: force fresh summary, then same recovery entry.
a0=main.find('function Plugin:_home_action_entries()')
a1=main.find('function Plugin:_home_alerts()',a0)
actions=main[a0:a1]
ok('local refreshed=self:_home_sync_summary(true)' in actions,'Home quick Sync forces fresh summary')
ok('self:_sync_home_pending({source="home_quick"})' in actions,'Home quick Sync enters shared recovery')
ok('[MiuRead][SyncAction] summary refreshed' in actions,'Home quick refresh is logged')
# Shared recovery diagnostics.
r0=main.find('function Plugin:_sync_home_pending(options)')
r1=main.find('function Plugin:sync_settings_menu()',r0)
recovery=main[r0:r1]
ok('local source=tostring(options.source or (manual and "manual_unspecified" or "background"))' in recovery,'recovery preserves caller source')
ok('[MiuRead][SyncAction] start' in recovery,'recovery start logged')
ok('[MiuRead][SyncAction] progress snapshot' in recovery,'progress action snapshot logged')
ok('[MiuRead][SyncAction] finish' in recovery,'recovery finish logged')
ok('log_progress_snapshot("manual_preflight",progress_items)' in recovery,'manual progress preflight logged')
ok('self:_sync_home_pending({source="sync_status_all"})' in main,'Sync Status all retry source-tagged')
ok('self:_sync_home_pending({source="progress_issues"})' in main,'progress issue retry source-tagged')
ok('lua5.1 tools/test_beta8_home_translation_contract.lua' in workflow,'beta.8 Home/translation regression retained')
ok('lua5.1 tools/test_beta9_home_sync_contract.lua' in workflow,'release workflow retains beta.9 sync contract')
ok('lua5.1 tools/test_beta10_translation_dependency_contract.lua' in workflow,'release workflow runs beta.10 translation dependency contract')
ok('python3 tools/verify_590_beta10.py' in workflow,'release workflow runs beta.10 verifier')
ok('require("miuread.util")' not in '\n'.join(translation.splitlines()[:20]), 'translation module top-level stays independent of miuread.util')
ok('local function trim(value)' in translation, 'translation provides pure Lua trim helper')
ok('local book_id=trim(meta.book_id)' in translation, 'translation inspect uses local trim')
ok('translation_book_identity_missing' in translation, 'empty translation book identity is rejected')
ok('not_imported_book' not in translation, 'translation inspect does not restore CB_ gating')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'release tests run before tag creation')
ok('line.startswith(heading + " — ")' in workflow,'release changelog parser accepts em dash headings')
# beta.9 intentionally does not modify the lower-level sync engine.
ok(hashlib.sha256(sync_bytes).hexdigest()=='ed10bf4829d4bdc3034117b703333bcff9b5d802594baa29da6fb07cbd41cd5c','beta.8 sync core is byte-identical')
failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
