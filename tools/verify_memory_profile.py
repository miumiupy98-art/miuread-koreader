#!/usr/bin/env python3
"""Verify the MemTotal-scaled heavy-guard memory profile.

Small-memory devices (a 256 MiB KPW2) could never present the absolute
96/72 MiB free that the old heavy-guard thresholds demanded, so downloads
were refused at start and hibernated tasks never revived. The profile is
now clamp(MemTotal * ratio, floor, cap) per threshold; the caps equal the
historical absolutes so >=512 MiB devices keep their previous behavior.

This script re-implements the clamp from the values actually present in
miuread/config.lua and checks the profile against the expected numbers for
256 MiB / 512 MiB / 1 GiB totals plus the /proc-less fallback (caps). It
also asserts the old fixed 64/40 MiB soft/critical floors and every direct
consumption site of the absolute keys are gone.

Run: python3 tools/verify_memory_profile.py
"""
import re
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "miuread.koplugin"
failures = []


def check(condition, message):
    print(("PASS " if condition else "FAIL ") + message)
    if not condition:
        failures.append(message)


def read(path):
    return path.read_text(encoding="utf-8")


config = read(PLUGIN / "miuread" / "config.lua")
runtime_pressure = read(PLUGIN / "miuread" / "runtime_pressure.lua")
download_task = read(PLUGIN / "miuread" / "download_task.lua")
main_lua = read(PLUGIN / "main.lua")

NUMBER_RE = re.compile(r"^\s*([A-Z0-9_]+)\s*=\s*([0-9][0-9 .*]*),", re.M)


def config_number(key):
    match = re.search(r"^\s*%s\s*=\s*([0-9][0-9 .*]*)," % re.escape(key), config, re.M)
    if not match:
        return None
    expression = match.group(1)
    if not re.fullmatch(r"[0-9][0-9 .*]*", expression):
        return None
    return eval(expression, {"__builtins__": {}}, {})


# name -> (ratio key, floor key, cap key)
SPECS = {
    "start_min": ("HEAVY_DOWNLOAD_START_RATIO", "HEAVY_DOWNLOAD_START_FLOOR_KB", "HEAVY_DOWNLOAD_START_MIN_KB"),
    "resume_min": ("HEAVY_DOWNLOAD_RESUME_RATIO", "HEAVY_DOWNLOAD_RESUME_FLOOR_KB", "HEAVY_DOWNLOAD_RESUME_MIN_KB"),
    "running_min": ("HEAVY_DOWNLOAD_RUNNING_RATIO", "HEAVY_DOWNLOAD_RUNNING_FLOOR_KB", "HEAVY_DOWNLOAD_RUNNING_MIN_KB"),
    "package_abort": ("HEAVY_PACKAGE_ABORT_RATIO", "HEAVY_PACKAGE_ABORT_FLOOR_KB", "HEAVY_PACKAGE_ABORT_KB"),
    "native_hibernate": ("HEAVY_NATIVE_HIBERNATE_RATIO", "HEAVY_NATIVE_HIBERNATE_FLOOR_KB", "HEAVY_NATIVE_HIBERNATE_KB"),
    "native_critical": ("HEAVY_NATIVE_CRITICAL_RATIO", "HEAVY_NATIVE_CRITICAL_FLOOR_KB", "HEAVY_NATIVE_CRITICAL_KB"),
    "cover_coexist": ("DOWNLOAD_COEXIST_RATIO", "DOWNLOAD_COEXIST_FLOOR_KB", "DOWNLOAD_COVER_COEXIST_MIN_KB"),
    "typography_hibernate": ("TYPOGRAPHY_HIBERNATE_RATIO", "TYPOGRAPHY_HIBERNATE_FLOOR_KB", "TYPOGRAPHY_HIBERNATE_MEMORY_KB"),
    "typography_critical": ("TYPOGRAPHY_CRITICAL_RATIO", "TYPOGRAPHY_CRITICAL_FLOOR_KB", "TYPOGRAPHY_CRITICAL_MEMORY_KB"),
    "soft": ("BACKGROUND_MEMORY_SOFT_RATIO", "BACKGROUND_MEMORY_SOFT_FLOOR_KB", "BACKGROUND_MEMORY_SOFT_MAX_KB"),
    "critical": ("BACKGROUND_MEMORY_CRITICAL_RATIO", "BACKGROUND_MEMORY_CRITICAL_FLOOR_KB", "BACKGROUND_MEMORY_CRITICAL_MAX_KB"),
}

# Expected profile: {total_kb or None: {name: kb}}
EXPECTED = {
    256 * 1024: {
        "start_min": 52429, "resume_min": 49807, "running_min": 41943,
        "native_hibernate": 62915, "native_critical": 36864, "cover_coexist": 65536,
        "typography_hibernate": 52429, "typography_critical": 32768,
        "soft": 65536, "critical": 40960,
        "package_abort": 26214,
    },
    512 * 1024: {
        "start_min": 98304, "resume_min": 98304, "running_min": 73728,
        "native_hibernate": 98304, "native_critical": 65536, "cover_coexist": 81920,
        "typography_hibernate": 73728, "typography_critical": 49152,
        "soft": 65536, "critical": 41943,
        "package_abort": 36864,
    },
    1024 * 1024: {
        "start_min": 98304, "resume_min": 98304, "running_min": 73728,
        "native_hibernate": 98304, "native_critical": 65536, "cover_coexist": 81920,
        "typography_hibernate": 73728, "typography_critical": 49152,
        "soft": 125829, "critical": 81920,
        "package_abort": 36864,
    },
    None: {},  # filled below from caps
}


def clamp(total_kb, ratio, floor, cap):
    if not total_kb:
        return cap
    return max(floor, min(cap, int(total_kb * ratio + 0.5)))


missing = [key for keys in SPECS.values() for key in keys if config_number(key) is None]
check(not missing, "config.lua defines every ratio/floor/cap key (missing: %s)" % ",".join(missing))

for name, (ratio_key, floor_key, cap_key) in SPECS.items():
    ratio = config_number(ratio_key)
    floor = config_number(floor_key)
    cap = config_number(cap_key)
    if ratio is None or floor is None or cap is None:
        continue
    EXPECTED[None][name] = cap
    for total_kb, expected in EXPECTED.items():
        actual = clamp(total_kb, ratio, floor, cap)
        check(actual == expected[name],
              "%s(total=%s) = %d, expected %d" % (name, total_kb or "fallback", actual, expected[name]))

# The historical absolutes must survive as caps so >=512 MiB devices keep
# their exact previous thresholds. RESUME was raised to 96 MiB by beta's
# admission unification (a resumed worker forks afresh); scaling keeps that
# intent on large devices while lowering the line on small ones.
for key, value in (("HEAVY_DOWNLOAD_START_MIN_KB", 96 * 1024),
                   ("HEAVY_DOWNLOAD_RESUME_MIN_KB", 96 * 1024),
                   ("HEAVY_DOWNLOAD_RUNNING_MIN_KB", 72 * 1024),
                   ("HEAVY_NATIVE_HIBERNATE_KB", 96 * 1024),
                   ("HEAVY_NATIVE_CRITICAL_KB", 64 * 1024),
                   ("DOWNLOAD_COVER_COEXIST_MIN_KB", 80 * 1024)):
    check(config_number(key) == value, "%s keeps the %d KiB cap" % (key, value))

# New behavior keys exist.
for key in ("MEMORY_SMALL_TIER_TOTAL_KB", "DOWNLOAD_WORKER_OOM_SCORE_ADJ",
            "DOWNLOAD_PARENT_OOM_SCORE_ADJ", "DOWNLOAD_IDLE_PUMP_SECONDS",
            "DOWNLOAD_FUSE_COOLDOWN_SECONDS", "DOWNLOAD_RESTART_BUDGET_RESET_SECONDS",
            "DOWNLOAD_MEMORY_HIBERNATE_MIN_PARK_SECONDS"):
    check(config_number(key) is not None, "config.lua defines %s" % key)

# Old fixed soft/critical floors removed from config and nothing consumes them.
check("BACKGROUND_MEMORY_SOFT_KB" not in config, "old BACKGROUND_MEMORY_SOFT_KB floor removed from config.lua")
check("BACKGROUND_MEMORY_CRITICAL_KB" not in config, "old BACKGROUND_MEMORY_CRITICAL_KB floor removed from config.lua")

# runtime_pressure owns the scaled profile.
for needle in ("compute_thresholds", "RuntimePressure.total_kb", "RuntimePressure.tier",
               "THRESHOLD_SPECS", "thresholds.soft", "thresholds.critical"):
    check(needle in runtime_pressure, "runtime_pressure.lua contains %s" % needle)
check("BACKGROUND_MEMORY_SOFT_KB" not in runtime_pressure,
      "runtime_pressure.lua no longer references the old soft floor")

# download_task consumes scaled thresholds only; no absolute-key math remains.
absolute_keys = ("HEAVY_DOWNLOAD_START_MIN_KB", "HEAVY_DOWNLOAD_RESUME_MIN_KB",
                 "HEAVY_DOWNLOAD_RUNNING_MIN_KB", "HEAVY_NATIVE_HIBERNATE_KB",
                 "HEAVY_NATIVE_CRITICAL_KB")
for source, label in ((download_task, "download_task.lua"), (main_lua, "main.lua")):
    for key in absolute_keys + ("DOWNLOAD_COVER_COEXIST_MIN_KB",):
        check(("Config.%s" % key) not in source, "%s does not consume Config.%s directly" % (label, key))

for needle in ("DownloadAdmission.check(memory,Config,from_checkpoint)",
               "DownloadAdmission.check(memory,Config,true)",
               "RuntimePressure.thresholds().running_min",
               "RuntimePressure.thresholds().native_hibernate",
               "_from_checkpoint", "book_has_partial_cache", "_park_after_restart_fuse",
               "oom_score_adj", "cooldown_until", ',"low_memory"', 'err=="low_memory"'):
    check(needle in download_task, "download_task.lua contains %s" % needle)

# The admission module keeps beta's pipeline contract (machine-readable
# low_memory, queue retry) while taking its minimum from the scaled profile.
admission = read(PLUGIN / "miuread" / "download_admission.lua")
for needle in ('pcall(require, "miuread.runtime_pressure")',
               "thresholds.resume_min", "thresholds.start_min",
               "HEAVY_DOWNLOAD_START_MIN_KB", "HEAVY_DOWNLOAD_RESUME_MIN_KB"):
    check(needle in admission, "download_admission.lua contains %s" % needle)

# main.lua: scaled native/cover lines, idle pump, telemetry.
for needle in ("thresholds().cover_coexist", "thresholds().native_critical",
               "native_thresholds.native_hibernate", "thresholds().typography_critical",
               "thresholds().typography_hibernate",
               "_download_idle_pump_ensure", "_download_idle_pump_stop",
               "MemoryProfile", "idle memory window"):
    check(needle in main_lua, "main.lua contains %s" % needle)
check("Config.TYPOGRAPHY_HIBERNATE_MEMORY_KB" not in main_lua,
      "main.lua no longer consumes the absolute typography hibernate line")
check("Config.TYPOGRAPHY_CRITICAL_MEMORY_KB" not in main_lua,
      "main.lua no longer consumes the absolute typography critical line")
downloader = read(PLUGIN / "miuread" / "downloader.lua")
for needle in ("package aborted by hibernate marker", "package aborted for memory",
               "__MIUREAD_HIBERNATE__:package", "package_abort"):
    check(needle in downloader, "downloader.lua package guard contains %s" % needle)
check("排版重整需要内存" in download_task,
      "download_task.lua differentiates typography hibernate messages")

for needle in ("first_effective_progress_at", "restart budget reset",
               "DOWNLOAD_RESTART_BUDGET_RESET_SECONDS"):
    check(needle in download_task, "download_task.lua contains %s" % needle)
check("exit_forced_stop" in main_lua,
      "main.lua parks a forced-stopped exit task as hibernated for auto-resume")

print()
if failures:
    print("memory profile verification: FAIL (%d)" % len(failures))
    sys.exit(1)
print("memory profile verification: PASS")
