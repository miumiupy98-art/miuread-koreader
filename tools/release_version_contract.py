"""Shared release-safe beta metadata assertions for source regression tests."""
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATTERN = r"(\d+\.\d+\.\d+-beta\.\d+)"

def assert_beta_identity(testcase):
    config = (ROOT / "miuread.koplugin/miuread/config.lua").read_text(encoding="utf-8")
    meta = (ROOT / "miuread.koplugin/_meta.lua").read_text(encoding="utf-8")
    a = re.findall(r"(?m)^\s*VERSION\s*=\s*[\"']" + PATTERN + r"[\"']", config)
    b = re.findall(r"(?m)^\s*version\s*=\s*[\"']" + PATTERN + r"[\"']", meta)
    testcase.assertEqual(len(a), 1, "config.lua must have exactly one Beta version")
    testcase.assertEqual(len(b), 1, "_meta.lua must have exactly one Beta version")
    testcase.assertEqual(a, b, "config and metadata Beta versions must match")
    expected = os.environ.get("VERSION")
    if expected:
        testcase.assertEqual(a[0], expected, "prepared Beta version must match release target")
    return a[0]
