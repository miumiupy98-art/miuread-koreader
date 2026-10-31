"""Beta.12 non-Release regression: verified stable beta.11 progress/time surface."""
import hashlib, json, re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
FROZEN=json.loads((ROOT/'tools/BETA11_FROZEN_HASHES.json').read_text())
MAIN=(ROOT/'miuread.koplugin/main.lua').read_text()
# beta.14 explicitly changes the download-only Web source gate; do not
# misclassify that intentional change as a reading-progress/time regression.
CHANGED_DOWNLOAD_ONLY={'miuread.koplugin/miuread/download_source_gate.lua'}
for name,digest in FROZEN.items():
    if name in CHANGED_DOWNLOAD_ONLY:
        assert (ROOT/name).is_file(), name
        continue
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
version=re.search(r'\bVERSION\s*=\s*"(6\.5\.0-beta\.\d+)"', (ROOT/'miuread.koplugin/miuread/config.lua').read_text())
meta_version=re.search(r'\bversion\s*=\s*"(6\.5\.0-beta\.\d+)"', (ROOT/'miuread.koplugin/_meta.lua').read_text())
assert version is not None and meta_version is not None and version.group(1)==meta_version.group(1), "plugin version metadata mismatch"
print('PASS beta.12 frozen progress/readtime sources + beta.5 Release workflow contract')
