from pathlib import Path
import os
import re
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
store=(root/'miuread.koplugin/miuread/store.lua').read_text(encoding='utf-8')
auth=(root/'miuread.koplugin/miuread/auth.lua').read_text(encoding='utf-8')
worker=(root/'miuread.koplugin/miuread/legacy/read_report_worker.lua').read_text(encoding='utf-8')
precise=(root/'miuread.koplugin/miuread/precise_position.lua').read_text(encoding='utf-8')
source=(root/'miuread.koplugin/miuread/source_position.lua').read_text(encoding='utf-8')
posmap=(root/'miuread.koplugin/miuread/annotations/posmap.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
# Historical invariants must remain valid after each new release. Do not pin
# the *current* version to the original 6.0.0-beta.1 baseline.
config_versions = re.findall(r'(?m)^\s*VERSION\s*=\s*["\'](\d+\.\d+\.\d+-beta\.\d+)["\']', config)
meta_versions = re.findall(r'(?m)^\s*version\s*=\s*["\'](\d+\.\d+\.\d+-beta\.\d+)["\']', meta)
current_version = config_versions[0] if len(config_versions) == 1 else None
ok(len(config_versions) == 1 and len(meta_versions) == 1 and config_versions == meta_versions,
   'beta config and plugin metadata contain matching versions')
expected_version = os.environ.get('VERSION')
ok(current_version is not None and (not expected_version or current_version == expected_version),
   'beta version matches the release target when supplied')
changelog_head = re.search(r'(?m)^## (\d+\.\d+\.\d+-beta\.\d+)(?:\s+-\s+.*|\s+—\s+.*)?$', ch)
ok(current_version is not None and changelog_head is not None and changelog_head.group(1) == current_version,
   'newest changelog entry matches current beta version')
ok('## 6.0.0-beta.1' in ch, 'original 6.0.0-beta.1 changelog retained')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('SOURCE_ANCHOR_WORDS = {24, 16, 12}' in precise,'beta19 multi-anchor sizes retained')
ok('anchor_candidates = anchor_candidates' in precise,'beta19 captured anchor set retained')
ok('local function anchor_variants(anchor)' in source,'beta19 source anchor variants retained')
ok('anchor_coordinate_conflict' in source,'beta19 coordinate-conflict fail closed retained')
ok('{images=false, fresh_context=true}' in source,'beta18 fresh source context retained')
ok('function PosMap.locateSource' in posmap,'beta19 source-only normalization retained')
ok('reliable_text_anchor_landing' in main,'beta19 reliable cloud text landing retained')
ok('function Plugin:_normalize_exact_progress_snapshot' in main,'exact snapshot normalizer')
ok('safe=true,coordinate_safe=true,precise=true' in main,'passive exact safety flags')
ok('progress_exact_snapshot_repair_591b1' in store,'beta19 exact snapshot migration repair')
ok('progress_upload_state="pending_send"' in store,'repair restores unsent exact pending_send')
ok('anchor=U.copy(anchor)' in sync,'ReadingEnd source failure returns immutable anchor')
ok('pending_unresolved_position=row' in main and 'source_anchor=type(source_anchor)=="table"' in main,'durable recovery capsule')
ok('function Sync:resolve_saved_progress_anchor' in sync,'Home saved-anchor resolver')
ok('function Plugin:_recover_pending_progress_anchor' in main,'Home saved-anchor recovery pipeline')
ok('can_recover_anchor=anchor_only and saved_anchor~=nil' in main,'anchor recovery classified as executable action')
ok('local_coordinate_unresolved=true' in main,'unresolved state included in failure FSM')
ok('can_clear_stale=replayable~=true and not (anchor_only and saved_anchor~=nil)' in main,'recoverable anchors not stale')
ok('text="恢复精确位置"' in main,'manual anchor recovery action')
ok('lightweight service exited after requested stop' in sync,'ReadReport requested stop is informational')
ok('local refreshed,web_error,web_error_kind=refresh_remote_anchor(client, book_id, book)' in worker,'ReadReport fresh GET cloud guard retained')
ok('remote_wire_anchor' in sync,'remote wire anchor retained')
ok('POSITION_CLOCK_SKEW_GRACE_SECONDS = 30' in config,'30s clock skew guard retained')
ok('lua5.1 tools/test_591_beta1_progress_recovery.lua' in workflow,'new recovery contract in release workflow')
ok('python3 tools/verify_600_beta1.py' in workflow,'beta.4 verifier in release workflow')
ok('python3 tools/verify_590_beta19.py' not in workflow,'release workflow no longer runs version-pinned beta19 verifier')

# 6.0.0-beta.1 preservation checks for #123 + #126.
bookstore=(root/'miuread.koplugin/miuread/bookstore.lua').read_text(encoding='utf-8')
shelf_client=(root/'miuread.koplugin/miuread/shelf_client.lua').read_text(encoding='utf-8')
finished=(root/'miuread.koplugin/miuread/finished_status.lua').read_text(encoding='utf-8')
shelf_progress=(root/'miuread.koplugin/miuread/shelf_progress.lua').read_text(encoding='utf-8')
api=(root/'miuread.koplugin/miuread/api_web.lua').read_text(encoding='utf-8')
ok('function Api:add_to_shelf' in api and 'function Api:remove_from_shelf' in api,'#123 shelf add/remove API retained')
ok('function Api:book_read_info' in api and 'function Api:mark_book_finished' in api,'#126 finished-status API retained')
ok('similar' in bookstore and 'recommend' in bookstore,'#123 bookstore recommendation paths retained')
ok('native_shelf' in shelf_client,'#123 native shelf authorization retained')
ok('function FinishedStatus:request' in finished and 'function FinishedStatus:reconcile' in finished,'#126 durable finished-status queue retained')
ok('function M.fetch' in shelf_progress and 'function M.display' in shelf_progress,'#126 shelf progress presentation sync retained')
ok('lua5.1 tools/test_finished_status.lua' in workflow and 'luajit tools/test_finished_status.lua' in workflow,'finished-status regression runs in both Lua engines')
ok('lua5.1 tools/test_shelf_progress.lua' in workflow and 'luajit tools/test_shelf_progress.lua' in workflow,'shelf-progress regression runs in both Lua engines')


# 6.0 beta baseline lean-build checks.
dead_methods = [
    "_home_stream_prefetch_page", "_home_local_inline_title", "_home_local_empty_text",
    "_home_local_shelf_tabs", "_toggle_home_local_shelf_view", "_home_library_filter_count",
    "_home_refresh_current_network_metadata", "_show_home_download_popup", "_show_home_sync_popup",
    "_show_home_search_popup", "_home_refresh_recent_history", "_book_has_cache",
    "_reprocess_home_sync_failures", "_local_progress_choice_matches", "_set_home_lockscreen_style",
    "_inkstain_enabled", "_inkstain_active",
]
ok(all(name not in main for name in dead_methods),'17 unreferenced private legacy methods removed')
ok('(relative.parts and relative.parts[0] == "native")' in workflow,'release package excludes native build source')
ok('forbidden_prefixes = {"miuread.koplugin/native/"}' in workflow,'release verifier rejects native build source')
verifiers=sorted((root/'tools').glob('verify_*.py'))
required_verifiers={'verify_600_beta1.py','verify_memory_profile.py'}
legacy_verifiers={'verify_590_beta19.py','verify_590_beta18.py'}
ok(required_verifiers.issubset({p.name for p in verifiers}),
   'current baseline and memory-profile verifiers are retained')
ok(not (legacy_verifiers & {p.name for p in verifiers}),
   'obsolete historical verifier scripts remain pruned')
native_dir=root/'miuread.koplugin/native'
ok((native_dir/'miucodec.cpp').is_file() and (native_dir/'build.sh').is_file(),'native build source retained in source repository')
stillness=root/'miuread.koplugin/miuread/book_excerpt_card/assets/cards/stillness'
backgrounds=sorted(stillness.glob('bg_*.jpg'))
ok(len(backgrounds)==10,'all 10 stillness backgrounds retained')
ok(sum(p.stat().st_size for p in backgrounds) < 450000,'stillness backgrounds compressed below 450 KB')
ok('AuthCompare' not in main and 'AuthBridge' not in main,'one-off auth diagnostic code absent from production main')


# 6.0 beta baseline polish checks.
ok('new_auth.native_shelf=Util.copy(old_auth.native_shelf)' in auth,'same-account Web re-login preserves Native shelf authorization')
ok('new_vid==old_vid and native_vid==new_vid' in auth,'Native shelf authorization preservation is account-scoped')
ok('function Store:clear_native_shelf_auth()' in store,'Native shelf authorization can be revoked independently')
ok('E-Ink 客户端授权' in main and '取消 E-Ink 客户端授权' in main,'account status exposes Native shelf authorization state and revoke action')
ok('微信读书 · 书城' in bookstore and '总榜 · 飙升 · 新书 · 热门' in bookstore,'bookstore root copy polished without structural rewrite')
ok('第 "..tostring(spec.page or 1).." 页' in bookstore and 'label="上一页"' in bookstore,'bookstore pagination copy normalized')
ok('if elapsed_ms>=250 then' in store and 'if elapsed_ms>=250 or reason=="set:auth" then' in store,'successful StorePerf logging is rate-limited by cost/relevance')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
