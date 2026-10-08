from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
store=(root/'miuread.koplugin/miuread/store.lua').read_text(encoding='utf-8')
worker=(root/'miuread.koplugin/miuread/legacy/read_report_worker.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.17"' in config,'config version beta.17')
ok('version = "5.9.0-beta.17"' in meta,'metadata version beta.17')
ok(ch.startswith('## 5.9.0-beta.17'),'beta.17 changelog is first')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('local READ_REPORT_SERVICE_VERSION = 30' in sync,'read-report v30 retained')

# Generation-authoritative reset and merge.
for token in ['progress_state_reset_beta17','beta17_epoch_authoritative_clean_state',
              '"pending_unresolved_position"','"local_read_event_at"','row.progress_epoch=previous_epoch+1']:
    ok(token in store,'beta17 reset contains '+token)
ok('local disk_epoch=math.max(1,tonumber(disk_row.progress_epoch or 1) or 1)' in store,'disk epoch read in merge')
ok('local memory_epoch=math.max(1,tonumber(memory_row.progress_epoch or 1) or 1)' in store,'memory epoch read in merge')
ok('if disk_epoch>memory_epoch then' in store,'newer disk generation dominates stale memory')
ok('PROGRESS_EPOCH_CONTROL_FIELDS' in store,'epoch control field set exists')
ok('stale progress generation suppressed' in store,'generation suppression diagnostic exists')
ok('or (tonumber(disk_row.progress_epoch or 1) or 1)>1 then' in store,'reset-only disk rows survive missing memory session')
reset=store[store.find('local PROGRESS_SYNC_RESET_KEYS={'):store.find('local function emergency_compact_sessions')]
ok('local_display_progress' not in reset,'reset still preserves local display progress')

# Conflict lifecycle.
ok('authority_conflict=pending_reason:find("^write_fenced:conflict:")~=nil' in main,'authority conflict classification exists')
ok('local can_send=can_replay and not authority_conflict' in main,'authority conflict cannot auto-send')
ok('local can_verify=can_replay and not can_send and not authority_conflict' in main,'authority conflict cannot auto-verify loop')
ok('local can_resubmit=not authority_conflict' in main,'authority conflict cannot auto-resubmit')
ok('requires_choice=authority_conflict' in main,'issue exposes choice-required state')
ok('function Plugin:_adopt_remote_progress_issue' in main,'remote-authority action exists')
ok('function Plugin:_force_local_progress_issue' in main,'local-authority action exists')
ok('function Plugin:_discard_stale_progress_issue' in main,'stale-record discard exists')
ok('self.store:reset_progress_sync_state(book_id,"user_adopt_remote_authority",true)' in main,'remote choice advances generation and clears transaction')
ok('progress_sync_state="remote_baseline"' in main,'remote choice establishes clean baseline')
ok('force_write=true' in main[main.find('function Plugin:_force_local_progress_issue'):main.find('function Plugin:_show_progress_sync_issue_detail')], 'explicit local choice uses force write')
ok('exact_native_coordinate_required' in main,'local authority requires exact native wr_data_co')
ok('remote=remote_snapshot,position_state=state,remote_checked_at=os.time()' in main,'remote authority restores scalar fresh baseline after reset')
ok('snapshot_epoch~=current_epoch' in main,'local authority rejects stale generation')
ok('{text="以云端为准"' in main,'UI offers remote authority')
ok('{text="以本机为准"' in main,'UI offers local authority')
ok('{text="清除失效记录"' in main,'UI can delete non-replayable stale record')

# Ghost-write safety retained.
ok('local refreshed=refresh_remote_anchor(client, book_id, book)' in worker,'fresh GET before time write retained')
ok('fresh cloud reading position unavailable for reading-time report' in worker,'GET failure still blocks time POST')
ok('position_override = normalize_cloud_anchor(job.cloud_anchor, book)' not in worker,'cached canonical anchor remains forbidden')

ok('lua5.1 tools/test_beta17_sync_contract.lua' in workflow,'beta17 contract in release workflow')
ok('python3 tools/verify_590_beta17.py' in workflow,'beta17 verifier in release workflow')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'tests run before tag creation')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
