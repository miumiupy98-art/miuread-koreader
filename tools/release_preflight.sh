#!/usr/bin/env bash
# Shared local/CI smoke gate; no tag, release, branch or OTA mutation.
set -euo pipefail
channel="${1:-}"
if [[ "$channel" != beta && "$channel" != stable ]]; then
  echo "usage: bash tools/release_preflight.sh beta|stable" >&2
  exit 2
fi
python3 -m unittest discover -s tools -p 'test_release_integrity.py'
python3 -m unittest discover -s tools -p 'test_release_workflows.py'
python3 -m unittest discover -s tools -p 'test_release_inventory.py'
python3 -m unittest discover -s tools -p 'test_beta_tag_workspace.py'
for engine in lua5.1 luajit; do
  "$engine" tools/test_shelf_progress.lua
  "$engine" tools/test_641_progress_recovery_behavior.lua
  "$engine" tools/test_position_resolution.lua
  "$engine" tools/test_finished_status.lua
  "$engine" tools/test_progress_confirmation.lua
  "$engine" tools/test_readtime_live_dispatch.lua
done
if [[ "$channel" == beta ]]; then
  lua5.1 tools/test_beta8_sync_behavior.lua
  luajit tools/test_beta8_sync_behavior.lua
  lua5.1 tools/test_beta17_sync_contract.lua
  python3 tools/verify_600_beta1.py
fi
python3 tools/build_package.py --channel "$channel" --output "dist/preflight-$channel.zip"
python3 - <<'PYINNER'
import zipfile
from pathlib import Path
from os import environ
# Build already verifies the ZIP members against source content.
for p in Path('dist').glob('preflight-*.zip'):
    with zipfile.ZipFile(p) as archive:
        assert archive.testzip() is None
        names=archive.namelist()
        assert 'miuread.koplugin/main.lua' in names
        assert not any(x.startswith('miuread.koplugin/native/') for x in names)
print('PASS: unified release preflight ZIP')
PYINNER
