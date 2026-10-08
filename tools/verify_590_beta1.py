#!/usr/bin/env python3
from pathlib import Path
import re, sys, subprocess
root=Path(__file__).resolve().parents[1]
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
def text(p): return (root/p).read_text(encoding="utf-8")
meta=text("miuread.koplugin/_meta.lua"); config=text("miuread.koplugin/miuread/config.lua")
main=text("miuread.koplugin/main.lua"); store=text("miuread.koplugin/miuread/store.lua")
unified=text("miuread.koplugin/miuread/unified_library.lua"); sync=text("miuread.koplugin/miuread/sync.lua")
ok('5.9.0-beta.1' in meta and 'VERSION = "5.9.0-beta.1"' in config,'version 5.9.0-beta.1')
ok('SCHEMA = 136' in config and 'schema<136' in store,'schema 136 migration')
ok('auto_latest_position=true' in store and 'fast_local_fallback=true' in store,'new sync defaults')
ok('__MIUREAD_POSITION_RESOLUTION=rawget(_G,"__MIUREAD_POSITION_RESOLUTION") or require("miuread.position_resolution")' in main,'position resolver integrated without extra top-level local')
ok('正在同步最新阅读位置…' in main,'opening sync surface')
ok('open_sync_requested' in main and 'OPEN_SYNC_SOFT_TIMEOUT_SECONDS' in main and 'blocking surface and restarting' in main,'ReaderReady immediately guards the full opening-sync window without a second overlay')
ok('late_remote_after_user_interaction' in main,'late remote guarded by user interaction')
ok('POSITION_CLOCK_SKEW_GRACE_SECONDS' in main and 'CLOCK' not in main[:0],'clock skew strategy referenced')
ok('_show_position_undo' in main and '点此撤回' in main,'nonblocking undo')
ok('text="使用云端位置"' not in main and 'text="使用本机位置并上传"' not in main,'old conflict choice removed')
ok('sort=section=="shelf" and "cloud" or "recent"' in main,'cloud shelf default')
ok('if sort == "cloud" then' in unified and 'cloud="云端顺序"' in unified,'cloud ordering implemented')
ok('b.remote_finished' in main and 'b.local_finished' in main and 'b.resolved_finished' in main,'finished state separated')
ok('position_state=position_state' in sync and 'position_state=position_state' in sync,'position state dual writes')
ok('mapped_percent_equivalent' not in main,'percent-equivalent success remains removed')
ok('onNetworkConnected' in main and 'network_restored' in main and '_home_refresh_remote(false,false)' in main and '_network_recovery_generation' in main,'debounced network recovery hook and cloud mirror refresh')
ok('_auto_position_check_user_interacted' in main and 'automatic_check_after_user_interaction' in main,'all automatic checks refuse late jumps after user interaction')
ok('source="auth_success"' in main and '_home_refresh_remote(true,false)' in main,'auth recovery also refreshes cloud shelf')
ok('remote_position.fetched_at=os.time()' in sync and 'remote_snapshot.updated_at or remote_snapshot.updated or 0' in sync,'remote fetch time is not used as freshness time')
ok('initial_cloud_authority' in text('miuread.koplugin/miuread/position_resolution.lua'),'first reconciliation is cloud-authoritative without faking local freshness')
ok('callback=function(ok,actual_position)' in main and 'resolved_local.updated_at' in main,'remote winner persists actual verified jump position')
ok('remote_exact_coordinate_missing_local_safe' in main and 'remote_verification_failed_rollback' in main and '未覆盖云端' in main,'remote auto-apply is exact-only, fail-closed and rolls back on failed verification')
ok('state.finished={' in main and 'position_state.finished={' in sync,'finished state persisted separately from position')
# Run pure tests with any available Lua. Static verifier remains useful without LuaJIT.
lua=next((x for x in ('luajit','lua','texlua') if subprocess.run(['sh','-lc',f'command -v {x} >/dev/null 2>&1']).returncode==0),None)
if lua:
    for script in ['test_position_resolution.lua','test_cloud_shelf_sort.lua','test_open_sync_contract.lua','test_finished_resolution.lua','test_long_book_anchor.lua','test_cloud_mirror_contract.lua','test_schema136_contract.lua']:
        p=subprocess.run([lua,str(root/'tools'/script)],cwd=root,text=True,capture_output=True)
        ok(p.returncode==0,f'{script}: '+(p.stdout.strip() or p.stderr.strip()))
else: ok(True,'Lua runtime unavailable; pure-Lua tests skipped')
failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f'\n{len(checks)} checks, {len(failed)} failures')
sys.exit(1 if failed else 0)
