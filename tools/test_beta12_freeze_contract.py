"""Beta.12 non-Release regression: verified stable beta.11 progress/time surface."""
import hashlib, json, re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
FROZEN=json.loads((ROOT/'tools/BETA11_FROZEN_HASHES.json').read_text())
MAIN=(ROOT/'miuread.koplugin/main.lua').read_text()
for name,digest in FROZEN.items():
    if name.startswith('miuread.koplugin/'):
        blob=(ROOT/name).read_bytes()
    else:
        match=re.search(r'^function Plugin:'+re.escape(name)+r'\(.*?\n(?=function Plugin:|return Plugin|\Z)',MAIN,re.S|re.M)
        assert match,name
        blob=match.group().encode('utf-8')
    assert hashlib.sha256(blob).hexdigest()==digest,name
FLOW=(ROOT/'.github/workflows/release-beta.yml').read_text()
assert 'Run Lua syntax checks and release regression verifier' not in FLOW
assert 'test_beta17_sync_contract.lua' not in FLOW
assert 'MIUREAD_PUBLISHED_BETA_TAGS' in FLOW
assert 'release_notes:' not in FLOW
assert 'workflow_dispatch:' in FLOW
assert (ROOT/'miuread.koplugin/miuread/legacy_coordinate_backfill.lua').exists()
assert 'VERSION = "6.5.0-beta.12"' in (ROOT/'miuread.koplugin/miuread/config.lua').read_text()
assert '6.5.0-beta.12' in (ROOT/'miuread.koplugin/_meta.lua').read_text()
print('PASS beta.12 frozen progress/readtime sources + beta.5 Release workflow contract')
