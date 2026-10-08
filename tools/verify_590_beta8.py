from pathlib import Path
import hashlib, sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
api=(root/'miuread.koplugin/miuread/api.lua').read_text(encoding='utf-8')
gen=(root/'miuread.koplugin/miuread/translation_generation.lua').read_text(encoding='utf-8')
translation=(root/'miuread.koplugin/miuread/translation.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
sync_bytes=(root/'miuread.koplugin/miuread/sync.lua').read_bytes()
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
ok('VERSION = "5.9.0-beta.8"' in config,'config version beta.8')
ok('version = "5.9.0-beta.8"' in meta,'metadata version beta.8')
ok('## 5.9.0-beta.8' in ch,'beta.8 changelog exists')
ok('self:_home_complete_refresh(true)' in main,'Home Refresh invokes complete refresh')
ok('if key~="refresh" then entry.hold_callback=hold_for(key,entry.label) end' in main,'Refresh hold menu removed')
ok('if key=="refresh" then return {' not in main,'legacy Refresh hold actions removed')
candidate=main[main.find('function Plugin:_reader_translation_candidate'):main.find('function Plugin:_reader_translation_profile')]
ok('book_id~=""' in candidate and 'match("^CB_")' not in candidate,'translation UI accepts valid numeric WeRead ids')
webcall=api[api.find('function Api:_translation_web_call'):api.find('function Api:translation_member_summary')]
ok('translation book id missing' in webcall,'translation API keeps invalid-id guard')
ok('translation requires an imported book' not in webcall and 'match("^CB_")' not in webcall,'translation API no longer hard-rejects non-CB ids')
ok('当前书籍暂不支持微信读书官方翻译' in gen,'official unsupported response has a safe message')
ok('match("^CB_")' not in translation,'local translation inspection accepts numeric book ids')
ok('lua5.1 tools/test_beta8_home_translation_contract.lua' in workflow,'release workflow runs beta.8 contract')
ok('python3 tools/verify_590_beta8.py' in workflow,'release workflow runs beta.8 verifier')
# beta.7 sync.lua must be byte-identical in beta.8.
ok(hashlib.sha256(sync_bytes).hexdigest()=='ed10bf4829d4bdc3034117b703333bcff9b5d802594baa29da6fb07cbd41cd5c','beta.7 sync core is byte-identical')
failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
