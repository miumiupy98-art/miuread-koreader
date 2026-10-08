from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
store=(root/'miuread.koplugin/miuread/store.lua').read_text(encoding='utf-8')
worker=(root/'miuread.koplugin/miuread/legacy/read_report_worker.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
reader=(root/'miuread.koplugin/miuread/reader.lua').read_text(encoding='utf-8')
source=(root/'miuread.koplugin/miuread/source_position.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.18"' in config,'config version beta.18')
ok('version = "5.9.0-beta.18"' in meta,'metadata version beta.18')
ok(ch.startswith('## 5.9.0-beta.18'),'beta.18 changelog is first')
ok('SCHEMA = 136' in config,'schema remains 136')
ok('local READ_REPORT_SERVICE_VERSION = 30' in sync,'read-report v30 retained')

# beta.18 targeted source-context isolation.
ok('{images=false, fresh_context=true}' in source,'progress source requests fresh reader context')
ok('reader_context=fresh' in source,'fresh-context diagnostic exists')
ok(reader.count('opt.translation==true or opt.fresh_context==true')==3,'fresh_context reaches all chapter state acquisition paths')
ok('self:state(book_id,chapter_uid,keepalive,true)' in reader,'fresh context fetches target chapter Reader page')
ok('READER_CONTEXT_MAX_AGE' in reader and 'local cached=self._reader_context' in reader,'ordinary download context reuse retained')
ok('forward_16' not in source,'anchor algorithm unchanged in beta.18')

# beta.17 lifecycle and ghost-write safety retained.
ok('if disk_epoch>memory_epoch then' in store,'beta.17 epoch-authoritative merge retained')
ok('function Plugin:_adopt_remote_progress_issue' in main,'beta.17 remote-authority action retained')
ok('function Plugin:_force_local_progress_issue' in main,'beta.17 local-authority action retained')
ok('local refreshed=refresh_remote_anchor(client, book_id, book)' in worker,'fresh GET before time write retained')
ok('position_override = normalize_cloud_anchor(job.cloud_anchor, book)' not in worker,'cached canonical anchor remains forbidden')

ok('lua5.1 tools/test_beta18_progress_source_context.lua' in workflow,'beta18 contract in release workflow')
ok('python3 tools/verify_590_beta18.py' in workflow,'beta18 verifier in release workflow')
test_step=workflow.find('- name: Run Lua syntax checks and release regression verifier')
tag_step=workflow.find('- name: Ensure release tag')
ok(test_step>=0 and tag_step>=0 and test_step<tag_step,'tests run before tag creation')

failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
