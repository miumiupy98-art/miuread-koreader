"""Direct Tag releases may supply versions without editing source metadata."""
import tempfile
import unittest
from pathlib import Path
from prepare_beta_release import prepare
from check_beta_release_identity import check

class TagWorkspace(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup)
        self.root=Path(t.name)
        (self.root/'miuread.koplugin/miuread').mkdir(parents=True)
        (self.root/'miuread.koplugin/miuread/config.lua').write_text('VERSION = "6.3.2-beta.3",\n')
        (self.root/'miuread.koplugin/_meta.lua').write_text('version = "6.3.2-beta.3",\n')
        (self.root/'CHANGELOG.md').write_text('# Changelog\n\n## 6.3.2-beta.3\n\n- prior\n')
    def test_unprepared_tag_version_is_generated_without_git_mutations(self):
        self.assertTrue(prepare(self.root,'6.3.6-beta.1','',tag_workspace=True))
        self.assertTrue(check(self.root,'6.3.6-beta.1'))
        log=(self.root/'CHANGELOG.md').read_text()
        self.assertIn('## 6.3.6-beta.1',log)
        self.assertIn('## 6.3.2-beta.3',log)
        self.assertFalse(prepare(self.root,'6.3.6-beta.1','',tag_workspace=True))
    def test_existing_release_notes_take_priority(self):
        (self.root/'CHANGELOG.md').write_text('# Changelog\n\n## 6.3.6-beta.1\n\n- hand written\n\n## 6.3.2-beta.3\n\n- prior\n')
        prepare(self.root,'6.3.6-beta.1','',tag_workspace=True)
        self.assertIn('- hand written',(self.root/'CHANGELOG.md').read_text())
        self.assertTrue(check(self.root,'6.3.6-beta.1'))
    def test_matching_tag_preserves_existing_header_and_prose(self):
        original='# Changelog\n\n## 6.3.2-beta.3 — Notes\n\n- manual text\n\nAdditional context.\n'
        (self.root/'CHANGELOG.md').write_text(original)
        self.assertFalse(prepare(self.root,'6.3.2-beta.3','',tag_workspace=True))
        self.assertEqual((self.root/'CHANGELOG.md').read_text(),original)

    def test_manual_release_still_rejects_inconsistent_existing_notes(self):
        (self.root/'CHANGELOG.md').write_text('## 6.3.6-beta.1\n\n- premature\n')
        with self.assertRaisesRegex(ValueError,'已存在'):
            prepare(self.root,'6.3.6-beta.1','')

if __name__=='__main__':unittest.main()
