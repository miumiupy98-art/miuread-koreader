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
center=read('miuread.koplugin/miuread/extension_center.lua')
localmeta=read('miuread.koplugin/miuread/local_metadata.lua')
legacy=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
excerpt=read('miuread.koplugin/miuread/book_excerpt_dialog.lua')
ch=read('CHANGELOG.md')
wf=read('.github/workflows/release-beta.yml')

ok('version = "5.9.0-beta.4"' in meta,'metadata version beta.4')
ok('VERSION = "5.9.0-beta.4"' in config,'config version beta.4')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('OPEN_SYNC_SOFT_TIMEOUT_SECONDS = 6.0' in config,'opening sync soft timeout raised to 6 seconds')
ok('## 5.9.0-beta.4' in ch,'beta.4 changelog section exists')

# Crash hotfix: persistence boundary is scalar-only and store compacts before merge.
ok('function M.snapshot(value)' in pos and 'POSITION_SNAPSHOT_FIELDS' in pos,'scalar position snapshot helper exists')
ok('function M.state_snapshot(state)' in pos,'scalar position-state snapshot helper exists')
ok('diagnostic `sources` graph' in pos,'position snapshot documents cyclic source exclusion')
ok('compact_session_row(current,keep_chapters)' in store and 'compact_session_row(incoming,keep_chapters)' in store and 'a[k]=U.merge(current,incoming)' in store,'store compacts both sides before deep merge')
ok('repair_position_state_storage' in store and 'position snapshots compacted at startup' in store,'startup self-repair for beta.1-3 position snapshots')
ok('PositionResolution.snapshot(position)' in sync and 'PositionResolution.state_snapshot(session.position_state)' in sync,'sync local snapshots use scalar persistence')
ok('_G.__MIUREAD_POSITION_RESOLUTION.snapshot(remote)' in main,'resolved remote state is scalar-only')

# Latest-wins anchor hotfix.
ok('function M.trusted_verified_anchor(session,state)' in pos,'trusted verified-anchor helper exists')
ok('self:_position_resolution_context(id)' in main and 'Freeze the pre-fetch reconciliation context' in main,'pre-fetch resolution context is frozen before remote observation')
ok('verified_anchor=context.verified_anchor,' in main,'latest-wins decision uses frozen trusted anchor only')
ok('state.verified_anchor or session.cloud_anchor' not in main,'raw cloud_anchor is not used as a verified anchor')
ok('self.sync:cloud_anchor(book_id)' not in main[main.index('function Plugin:_position_resolution_context'):main.index('function Plugin:_save_position_resolution')],'resolution context no longer falls back to observed cloud anchor')
ok('云端响应较慢，已先使用本机位置；后台继续确认' in main,'soft-timeout wording is non-alarming and explicit')

# Regression coverage.
ok((root/'tools/test_position_state_hotfix.lua').is_file(),'position-state hotfix regression exists')
hot=read('tools/test_position_state_hotfix.lua')
ok("unverified cloud observation became a trusted anchor" in hot,'unverified-anchor regression asserted')
ok("runtime sources graph crossed persistence boundary" in hot,'cyclic remote snapshot regression asserted')
storetest=read('tools/test_store_repair.lua')
ok('cyclic position_state.remote_position.sources survived save_session' in storetest,'Store save_session cycle regression asserted')
ok('lua5.1 tools/test_position_state_hotfix.lua' in wf and 'lua5.1 tools/test_store_repair.lua' in wf,'release workflow runs hotfix regressions')
ok('python3 tools/verify_590_beta4.py' in wf,'release workflow runs beta4 verifier')

# beta.3 features and PR parity retained.
ok((root/'miuread.koplugin/miuread/translation.lua').is_file() and (root/'miuread.koplugin/miuread/translation_generation.lua').is_file(),'PR #120 translation modules retained')
ok('UPDATE_AUTO_INTERVAL=12*60*60' in center and 'text="全部更新"' in center,'Extension Center UX retained')
ok('pcall(Device.input.setClipboardText,text)' in main and 'pcall(Device.input.setClipboardText, clean_text(self.context.text))' in excerpt,'#117 clipboard parity retained')
ok('local function percent_to_ratio' in legacy,'#117 percent conversion retained')
ok('decode_numeric_entities' in localmeta and 'strip_cdata' in localmeta and 'protected_title' in localmeta,'#118 metadata protections retained')
ok('mapped_percent_equivalent' not in main,'percent-equivalent success path remains absent')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
