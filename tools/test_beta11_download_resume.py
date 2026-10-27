#!/usr/bin/env python3
"""Regression contracts for beta.11 resume/packaging fixes."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
task=(root/'miuread.koplugin/miuread/download_task.lua').read_text()
main=(root/'miuread.koplugin/main.lua').read_text()
downloader=(root/'miuread.koplugin/miuread/downloader.lua').read_text()
assert 'return false,"cooldown_active"' in task
assert 'local parked_reason="memory_pressure"' in task
assert 'DOWNLOAD_MEMORY_HIBERNATE_MIN_PARK_SECONDS' in task
assert 'book_has_partial_cache' in task
assert 'requested_checkpoint and cache_present' in task
assert 'hibernate_reason=parked_reason' in task
assert '_download_idle_pump_ensure' in main
assert '_download_idle_pump_stop' in main
assert 'function Plugin:_schedule_hibernated_download_resume' in main
# Only one resume scheduler and no additional background sampler loop.
assert main.count('self._hibernated_download_resume_task=task')==1
assert 'UIManager:scheduleIn(math.max(15,tonumber(Config.DOWNLOAD_IDLE_PUMP_SECONDS)' not in main
assert 'package_guard(true)' in downloader
assert 'pcall(EpubInstaller.validate,temp_path,validation_options)' in downloader
assert 'if not validation_call_ok then\n        os.remove(temp_path)' in downloader
for forbidden in ('submit_progress(', 'upload_local_progress('):
    assert forbidden not in downloader, forbidden
print('beta11 download resume contracts: PASS')
