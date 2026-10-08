from pathlib import Path
import re, sys
root=Path(__file__).resolve().parents[1]
main=(root/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
sync=(root/'miuread.koplugin/miuread/sync.lua').read_text(encoding='utf-8')
config=(root/'miuread.koplugin/miuread/config.lua').read_text(encoding='utf-8')
meta=(root/'miuread.koplugin/_meta.lua').read_text(encoding='utf-8')
workflow=(root/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
ch=(root/'CHANGELOG.md').read_text(encoding='utf-8')
checks=[]
def ok(cond,msg):
    checks.append((bool(cond),msg))

ok('VERSION = "5.9.0-beta.7"' in config,'config version beta.7')
ok('version = "5.9.0-beta.7"' in meta,'metadata version beta.7')
ok('POSITION_CLOCK_SKEW_GRACE_SECONDS = 30' in config,'clock-skew grace reduced to 30s')
ok('function Sync:preempt_reading_time_for_progress' in sync,'progress-priority preemption API exists')
ok('policy=drop_unconfirmed_time_tail' in sync,'preemption explicitly drops only unconfirmed time tail')
ok('progress priority forced time-writer stop' in sync,'preemption has bounded hard-stop fallback')
ok('preempt_reading_time_for_progress("reading_end_progress_priority"' in main,'reading-end final progress invokes preemption')
ok('final progress parked behind time writer' not in main,'old time-writer parking path removed')
ok('time_writer_busy' not in main[main.find('function Plugin:_reading_end_sync'):main.find('function Plugin:show_local_annotation_sync_status')], 'reading-end no longer fails as time_writer_busy')
ok('source="home_quick"' in main and 'source="home_panel"' in main,'home sync surfaces share unified recovery entry')
ok('与主页同步使用同一恢复流程' in main,'progress failure screen exposes unified retry-all')
ok('正在优先处理 ' in main and '本阅读进度' in main,'manual Home Sync is progress-first')
ok('阅读位置冲突' in main and '未自动覆盖' in main,'open/manual conflict has explicit user feedback')
ok('云端进度检查未完成' in main,'terminal cloud-check failure is surfaced after soft timeout')
ok('检测到较新云端进度' in main,'late newer-remote result is surfaced')
ok('## 5.9.0-beta.7' in ch,'beta.7 changelog section exists')
ok('lua5.1 tools/test_beta7_sync_contract.lua' in workflow,'release workflow runs beta.7 contract')
ok('python3 tools/verify_590_beta7.py' in workflow,'release workflow runs beta.7 verifier')
failed=[m for c,m in checks if not c]
for c,m in checks: print(('PASS' if c else 'FAIL')+': '+m)
print(f'checks={len(checks)} failures={len(failed)}')
if failed: sys.exit(1)
