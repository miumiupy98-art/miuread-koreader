#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(__file__).resolve().parents[1]
checks=[]
def ok(cond,msg): checks.append((bool(cond),msg))
def read(p): return (root/p).read_text(encoding="utf-8")
meta=read("miuread.koplugin/_meta.lua")
config=read("miuread.koplugin/miuread/config.lua")
main=read("miuread.koplugin/main.lua")
pos=read("miuread.koplugin/miuread/position_resolution.lua")
ch=read("CHANGELOG.md")
wf=read(".github/workflows/release-beta.yml")
ok('version = "5.9.0-beta.2"' in meta,"metadata version beta.2")
ok('VERSION = "5.9.0-beta.2"' in config,"config version beta.2")
ok('SCHEMA = 136' in config,"schema remains 136")
ok('## 5.9.0-beta.2' in ch,"beta.2 changelog section uses release heading")
ok('prior.updated_at or session.progress_upload_verified_at or session.progress_decided_at' in main,"technical snapshot does not manufacture freshness")
ok('prior.updated_at or prior.captured_at or session.progress_upload_verified_at' not in main,"old captured_at freshness fallback absent")
ok('local_pos and local_pos.updated_at or 0' in main,"shelf resolver uses event freshness only")
ok('function M.prefer_nonstale_remote' in pos,"nonstale remote selector exists")
ok('stored_remote_newer' in pos,"provably stale remote guard exists")
ok('stale cloud observation ignored' in main,"stale cloud response diagnostic")
ok('prefer_nonstale_remote' in main,"stale guard wired into runtime")
ok('python3 tools/verify_590_beta2.py' in wf,"release workflow runs beta2 verifier")
ok('CHANGELOG.md 使用了一级版本标题' in wf,"release workflow gives actionable changelog heading error")
# Preserve beta.1 invariants.
for needle,msg in [
 ('正在同步最新阅读位置…','opening sync surface'),
 ('late_remote_after_user_interaction','late remote interaction guard'),
 ('_show_position_undo','position undo'),
 ('POSITION_CLOCK_SKEW_GRACE_SECONDS','clock skew guard'),
 ('remote_exact_coordinate_missing_local_safe','exact remote target required'),
 ('mapped_percent_equivalent','old percent-equivalent marker absent')]:
    if needle=='mapped_percent_equivalent': ok(needle not in main,msg)
    else: ok(needle in main or needle in config,msg)
failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL'),m)
print(f"checks={len(checks)} failures={len(failed)}")
if failed: sys.exit(1)
