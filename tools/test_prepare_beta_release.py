#!/usr/bin/env python3
"""Regression tests for the manual beta-release metadata preparer."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_beta_release import prepare  # noqa: E402


class PrepareBetaReleaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "miuread.koplugin/miuread").mkdir(parents=True)
        self.config = self.root / "miuread.koplugin/miuread/config.lua"
        self.meta = self.root / "miuread.koplugin/_meta.lua"
        self.changelog = self.root / "CHANGELOG.md"
        self.config.write_text('local C = {\n  VERSION = "6.0.0-beta.1",\n  UPDATE_CHANNEL = "beta",\n}\n', encoding="utf-8")
        self.meta.write_text('return {\n    version = "6.0.0-beta.1",\n}\n', encoding="utf-8")
        self.changelog.write_text('## 6.0.0-beta.1 - Baseline\n\n- 基线\n', encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_auto_cleans_identical_historical_sections_for_manual_release(self):
        previous = self.changelog.read_text()
        self.changelog.write_text(previous + "\n# Changelog\n\n" + previous)
        self.assertTrue(prepare(self.root, "6.0.1-beta.2", "修复发布准备"))
        log = self.changelog.read_text()
        self.assertEqual(log.count("# Changelog"),1)
        self.assertEqual(log.count("## 6.0.0-beta.1"),1)
        self.assertEqual(log.count("## 6.0.1-beta.2"),1)
        self.assertFalse(prepare(self.root, "6.0.1-beta.2", "修复发布准备"))

    def test_conflicting_history_fails_without_modifying_files(self):
        self.changelog.write_text("# Changelog\n\n## 6.0.0-beta.1\n- first\n## 6.0.0-beta.1\n- different\n")
        before=[p.read_bytes() for p in (self.config,self.meta,self.changelog)]
        with self.assertRaisesRegex(ValueError, "Conflicting changelog"):
            prepare(self.root,"6.0.1-beta.2","note")
        self.assertEqual(before,[p.read_bytes() for p in (self.config,self.meta,self.changelog)])

    def test_prepares_and_preserves_history(self):
        changed = prepare(self.root, "6.0.1-beta.2", "修复书架刷新 | 保留阅读进度")
        self.assertTrue(changed)
        self.assertIn('VERSION = "6.0.1-beta.2"', self.config.read_text())
        self.assertIn('version = "6.0.1-beta.2"', self.meta.read_text())
        log = self.changelog.read_text()
        self.assertTrue(log.startswith("## 6.0.1-beta.2 - Beta Update\n"))
        self.assertIn("- 修复书架刷新\n- 保留阅读进度", log)
        self.assertIn("## 6.0.0-beta.1 - Baseline", log)

    def test_rerun_is_idempotent(self):
        prepare(self.root, "6.0.1-beta.2", "修复书架刷新")
        before = [f.read_bytes() for f in (self.config, self.meta, self.changelog)]
        self.assertFalse(prepare(self.root, "6.0.1-beta.2", "修复书架刷新"))
        self.assertEqual(before, [f.read_bytes() for f in (self.config, self.meta, self.changelog)])

    def test_prepared_unpublished_version_notes_may_be_edited(self):
        prepare(self.root, "6.0.1-beta.2", "修复书架刷新")
        self.assertTrue(prepare(self.root, "6.0.1-beta.2", "不同的更新说明 | 保留进度保护"))
        log = self.changelog.read_text()
        self.assertIn("- 不同的更新说明\n- 保留进度保护", log)
        self.assertNotIn("- 修复书架刷新", log)
        self.assertEqual(log.count("## 6.0.1-beta.2"), 1)
        self.assertFalse(prepare(self.root, "6.0.1-beta.2", "不同的更新说明 | 保留进度保护"))

    def test_prepared_version_without_changelog_fails_closed(self):
        self.config.write_text(self.config.read_text().replace("6.0.0-beta.1", "6.0.1-beta.2"))
        self.meta.write_text(self.meta.read_text().replace("6.0.0-beta.1", "6.0.1-beta.2"))
        with self.assertRaisesRegex(ValueError, "缺少对应版本条目"):
            prepare(self.root, "6.0.1-beta.2", "修复")

    def test_version_can_skip_beta_numbers(self):
        prepare(self.root, "6.0.0-beta.10", "跳过中间测试版本")
        self.assertIn('VERSION = "6.0.0-beta.10"', self.config.read_text())
        self.assertIn('## 6.0.0-beta.10', self.changelog.read_text())

    def test_moves_existing_target_record_to_top(self):
        self.changelog.write_text(
            '# Changelog\n\n## 6.0.0-beta.2 - Older\n\n- earlier\n\n'
            '## 6.0.0-beta.1 - Baseline\n\n- 基线\n')
        self.config.write_text(self.config.read_text().replace('6.0.0-beta.1', '6.0.0-beta.2'))
        self.meta.write_text(self.meta.read_text().replace('6.0.0-beta.1', '6.0.0-beta.2'))
        prepare(self.root, '6.0.0-beta.2', 'new notes')
        out = self.changelog.read_text()
        self.assertTrue(out.startswith('# Changelog\n\n## 6.0.0-beta.2'))
        self.assertEqual(out.count('## 6.0.0-beta.2'), 1)
        self.assertIn('## 6.0.0-beta.1', out)

    def test_heading_in_middle_is_moved_without_losing_history(self):
        old = self.changelog.read_text()
        self.changelog.write_text(old + '\n# Changelog\n\n## Unreleased\n\n- long lived notes\n')
        prepare(self.root, '6.0.0-beta.8', 'new beta')
        out = self.changelog.read_text()
        self.assertTrue(out.startswith('# Changelog\n\n## 6.0.0-beta.8'))
        self.assertEqual(out.count('# Changelog'), 1)
        self.assertIn('## Unreleased', out)
        self.assertIn('- long lived notes', out)
        self.assertIn('## 6.0.0-beta.1', out)

    def test_rejects_rollback_and_invalid_version(self):
        with self.assertRaisesRegex(ValueError, "版本回退"):
            prepare(self.root, "5.9.0-beta.1", "回退")
        with self.assertRaisesRegex(ValueError, "无效的 Beta"):
            prepare(self.root, "not-a-version", "无效")

    def test_optional_notes_generate_default_entry(self):
        self.assertTrue(prepare(self.root, "6.0.1-beta.2", "  "))
        self.assertIn("- 版本更新与维护", self.changelog.read_text())
        self.assertFalse(prepare(self.root, "6.0.1-beta.2", ""))

    def test_rejects_mismatched_versions(self):
        self.meta.write_text('return {\n    version = "6.0.0-beta.2",\n}\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "源码版本"):
            prepare(self.root, "6.0.1-beta.2", "修复")

    def test_preserves_changelog_top_heading(self):
        self.changelog.write_text('# Changelog\n\n' + self.changelog.read_text(), encoding="utf-8")
        prepare(self.root, "6.0.1-beta.2", "修复")
        self.assertTrue(self.changelog.read_text().startswith('# Changelog\n\n## 6.0.1-beta.2'))


if __name__ == "__main__":
    unittest.main()
