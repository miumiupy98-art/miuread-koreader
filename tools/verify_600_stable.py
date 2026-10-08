#!/usr/bin/env python3
"""Static release boundary checks; not a substitute for runtime/device testing."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
def read(path): return (root / path).read_text(encoding="utf-8")
config = read("miuread.koplugin/miuread/config.lua")
meta = read("miuread.koplugin/_meta.lua")
main = read("miuread.koplugin/main.lua")
store = read("miuread.koplugin/miuread/store.lua")
sync = read("miuread.koplugin/miuread/sync.lua")
beta = read(".github/workflows/release-beta.yml")
stable = read(".github/workflows/release.yml")
changelog = read("CHANGELOG.md")
checks = {
    "stable version in config": bool(re.search(r'\bVERSION\s*=\s*"6\.0\.0"', config)),
    "stable version in metadata": 'version = "6.0.0"' in meta,
    "schema 136": 'SCHEMA = 136' in config,
    "stable release channel": 'UPDATE_CHANNEL = "stable"' in config,
    "stable channel label": 'UPDATE_CHANNEL_LABEL = "正式通道"' in config,
    "stable update manifest": bool(re.search(r'UPDATE_MANIFEST\s*=\s*"[^"\n]*/stable-channel/update.json"', config)),
    "beta channel remains selectable": 'beta = {' in config and 'beta-channel/update-beta.json' in config,
    "6.0.0 changelog": '## 6.0.0 - Stable Release' in changelog,
    "stable release workflow": 'Release stable full package' in stable and 'RELEASE_CHANNEL: stable' in stable,
    "beta release workflow": 'Release beta full package' in beta and 'RELEASE_CHANNEL: beta' in beta,
    "progress recovery": 'Progress Recovery Capsule' in changelog and 'progress_epoch' in store,
    "native progress safety": 'READ_REPORT_SERVICE_VERSION = 30' in sync,
    "clipboard fix": 'Device.input.setClipboardText,text' in main,
    "bookstore module": (root / 'miuread.koplugin/miuread/bookstore.lua').is_file(),
    "shelf client module": (root / 'miuread.koplugin/miuread/shelf_client.lua').is_file(),
    "finished status module": (root / 'miuread.koplugin/miuread/finished_status.lua').is_file(),
    "translation support": (root / 'miuread.koplugin/miuread/translation_generation.lua').is_file(),
    "no Git conflict markers": not any(x in config for x in ('<<<<<<< HEAD','>>>>>>> origin/main')),
    "stable package excludes native sources": 'or (relative.parts and relative.parts[0] == "native")' in stable,
    "stable package tests native exclusion": 'forbidden_prefixes = {"miuread.koplugin/native/"}' in stable,
}
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {label}")
if not all(checks.values()):
    sys.exit(1)
print(f"All {len(checks)} release boundary checks passed (static only).")
