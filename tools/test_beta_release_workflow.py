#!/usr/bin/env python3
"""Ensure beta releases have one entry point and deterministic tag provenance."""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/release-beta.yml'


class BetaReleaseWorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = WORKFLOW.read_text(encoding='utf-8')

    def test_tag_and_manual_trigger(self):
        event_section = self.s.split('permissions:', 1)[0]
        self.assertIn('  workflow_dispatch:', event_section)
        self.assertIn('  push:', event_section)
        self.assertIn('    tags:', event_section)
        self.assertIn('v*.*.*-beta.*', event_section)
        self.assertIn("github.event_name == 'push' && github.ref || 'beta'", self.s)

    def test_tag_is_immutable_and_uses_tagged_source(self):
        self.assertIn('Tag 必须指向 beta 分支历史中的提交', self.s)
        self.assertIn('GITHUB_SHA', self.s)
        self.assertIn('Tag 中的源码版本', self.s)
        self.assertIn("if: github.event_name == 'workflow_dispatch'", self.s)
        self.assertNotIn('git push --force', self.s)

    def test_required_ui_inputs(self):
        header = self.s.split('permissions:', 1)[0]
        self.assertIn('      version:', header)
        self.assertIn('      release_notes:', header)
        self.assertEqual(header.count('        required: true'), 1)
        self.assertIn('        required: false', header)

    def test_prepare_before_validation(self):
        self.assertLess(self.s.index('name: Prepare beta release metadata'),
                        self.s.index('name: Read and validate beta identity'))
        self.assertIn('tools/prepare_beta_release.py --version "$VERSION" --notes "$RELEASE_NOTES_INPUT"', self.s)

    def test_git_commit_before_tag(self):
        self.assertLess(self.s.index('name: Commit prepared beta version and changelog'),
                        self.s.index('name: Ensure release tag'))
        self.assertIn('git push origin HEAD:beta', self.s)
        self.assertIn('git push origin "refs/tags/$RELEASE_TAG"', self.s)
        self.assertNotIn('git push --force', self.s)

    def test_only_beta_branch(self):
        self.assertIn('"refs/heads/beta"', self.s)
        self.assertIn('手动发布请在 Run workflow 中选择 beta 分支', self.s)

    def test_tag_conflict_fails_closed(self):
        self.assertIn('EXISTING_TAG_SHA', self.s)
        self.assertIn('不能重新修改该标签的版本文件', self.s)
        self.assertIn('不要从过期提交发布', self.s)

    def test_release_notes_optional_before_processing(self):
        self.assertNotIn('缺少手动发布的更新说明', self.s)
        self.assertIn("python3 -m unittest discover -s tools -p 'test_prepare_beta_release.py'", self.s)


if __name__ == '__main__':
    unittest.main()
