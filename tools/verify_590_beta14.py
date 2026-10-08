from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
source=(root/'miuread.koplugin/miuread/source_position.lua').read_text(encoding='utf-8')
library=(root/'miuread.koplugin/miuread/library.lua').read_text(encoding='utf-8')
home=(root/'miuread.koplugin/miuread/home_view.lua').read_text(encoding='utf-8')
store=(root/'miuread.koplugin/miuread/store.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.14"' in config,'config version beta.14')
ok('version = "5.9.0-beta.14"' in meta,'metadata version beta.14')
ok(ch.startswith('## 5.9.0-beta.14'),'beta.14 changelog is first')

# beta.12 reliability fixes retained.
ok('options.force_refresh == true and (refresh_uid == "" or refresh_uid == uid)' in source,'targeted source refresh retained')
ok('SourcePosition.locate(reader, record_snapshot, anchor,{cache_only=false,force_refresh=true,force_refresh_uid=tostring(anchor.chapter_uid or "")})' in sync,'fresh source recovery retained')
ok('FFIUtil.isSubProcessDone,pid,false' in sync,'subprocess completion fix retained')

# beta.13 architecture must not leak into beta.14.
ok('[MiuRead][ProgressPreflight]' not in main,'preflight positioning removed')
ok('remote_preflight_unverified' not in main,'preflight failure state removed')
ok('idle refresh book=' not in main,'active exact-cache resolver removed')

# Old successful jump/rescue path + new failure boundary.
ok('text anchor rescue started' in main,'text-anchor rescue retained')
ok('bounded percent fallback' in main,'bounded percent fallback retained')
ok('remote_chapter_resolved' in main,'same-chapter soft mismatch state exists')
ok('failure_kind=="soft"' in main,'soft mismatch does not enter hard rollback branch')
ok('_restore_position_rollback("remote exact verification failed"' in main,'hard mismatch rollback retained')
ok('_open_sync_user_interacted==true' in main,'late remote user-interaction guard retained')

# UI progress is independent from exact cloud coordinate success.
ok('function Plugin:_save_local_display_progress' in main,'local display progress helper exists')
ok('_save_local_display_progress(book_id,display_progress,xpointer_snapshot' in main,'reading-end stores local display progress before exact mapping')
ok('local_coordinate_unresolved' in main,'coordinate-unresolved state exists')
ok('progress=remote_progress_known and tonumber(remote_progress_value) or nil' in library,'unknown remote progress remains nil')
ok('阅读进度 —' in home,'unknown hero progress renders dash')
ok('"local_display_progress","local_display_progress_at"' in store,'local display fields persisted')
ok('"last_verified_exact_position","pending_unresolved_position"' in store,'passive exact/unresolved fields persisted')

# Release pipeline should target this contract/verifier.
ok('lua5.1 tools/test_beta14_sync_contract.lua' in workflow,'release workflow runs beta.14 contract')
ok('python3 tools/verify_590_beta14.py' in workflow,'release workflow runs beta.14 verifier')

test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'tests still run before tag creation')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
