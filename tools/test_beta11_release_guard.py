#!/usr/bin/env python3
"""Prevent CI regressions when adding a legitimate release verifier."""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[1]
class ReleaseGuardTest(unittest.TestCase):
    def test_both_verifiers(self):
        s=(ROOT/'tools/verify_600_beta1.py').read_text()
        self.assertIn("required_verifiers={'verify_600_beta1.py','verify_memory_profile.py'}",s)
        self.assertNotIn("==['verify_600_beta1.py']",s)
    def test_ci_executes_both(self):
        s=(ROOT/'.github/workflows/release-beta.yml').read_text()
        self.assertIn('python3 tools/verify_600_beta1.py',s)
        self.assertIn('python3 tools/verify_memory_profile.py',s)
        self.assertIn('python3 tools/test_beta11_download_resume.py',s)
        self.assertIn('lua5.1 tools/test_beta11_download_resume_policy.lua',s)
        self.assertIn('luajit tools/test_beta11_download_resume_policy.lua',s)
        self.assertIn('lua5.1 tools/test_beta11_resume_coordinator.lua',s)
        self.assertIn('luajit tools/test_beta11_resume_coordinator.lua',s)
    def test_changelog_paths_unchanged(self):
        s=(ROOT/'.github/workflows/release-beta.yml').read_text()
        self.assertIn('  push:',s)
        self.assertIn('  workflow_dispatch:',s)
        self.assertIn('python3 tools/prepare_beta_release.py --version "$VERSION" --notes "$RELEASE_NOTES_INPUT"',s)
        self.assertIn('python3 tools/ensure_beta_tag_changelog.py',s)
        self.assertNotIn('git push --force',s)
if __name__=='__main__':unittest.main()
