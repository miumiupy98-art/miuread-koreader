"""Offline integration contract checks; does not replace a KOReader/WeRead end-to-end run."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUG = ROOT / 'miuread.koplugin'

class Beta27ContractTest(unittest.TestCase):
    def test_version_and_modules(self):
        self.assertIn('6.5.0-beta.27', (PLUG / '_meta.lua').read_text())
        self.assertIn('6.5.0-beta.27', (PLUG / 'miuread/config.lua').read_text())
        for name in ('local_book_binding', 'local_chapter_map', 'review_replies'):
            self.assertTrue((PLUG / f'miuread/{name}.lua').is_file(), name)

    def test_menu_hooks_and_worker_reuse(self):
        main = (PLUG / 'main.lua').read_text()
        menu = (PLUG / 'miuread/plugin_menu.lua').read_text()
        self.assertIn('function Plugin:_local_book_search_dialog', main)
        self.assertIn('function Plugin:_local_chapter_map_menu', main)
        self.assertIn('function Plugin:_show_comment_replies', main)
        self.assertIn('return self:_start_comment_range(target.book', main)
        self.assertIn('comment_sync:load(target.bookId,target.chapterUid)', main)
        self.assertIn('on_replies=function(comment)', main)
        self.assertIn('公开评论与本地 EPUB 关联', menu)

    def test_source_not_rewritten_and_apis_registered(self):
        locator = (PLUG / 'miuread/comment_locator.lua').read_text()
        api = (PLUG / 'miuread/api.lua').read_text()
        self.assertIn('record.local_document==true', locator)
        self.assertIn('record.location_get()', locator)
        self.assertIn('record.location_save(written)', locator)
        self.assertIn('chapter_public_reviews={phase="annotations",web_only=true}', api)
        self.assertIn('review_comments={phase="annotations",web_only=true}', api)

if __name__ == '__main__':
    unittest.main()
