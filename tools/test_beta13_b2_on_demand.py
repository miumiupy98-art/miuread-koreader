#!/usr/bin/env python3
"""B2 source contracts; run with python3 -m unittest tools/test_beta13_b2_on_demand.py"""
from pathlib import Path
import unittest

BASE = Path(__file__).resolve().parents[1] / 'miuread.koplugin'
def source(path):
    return (BASE / path).read_text(encoding='utf-8')


class CommentB2(unittest.TestCase):
    def test_identities(self):
        import re
        meta = re.search(r'version\s*=\s*"([^"]+)"', source('_meta.lua'))
        config = re.search(r'VERSION\s*=\s*"([^"]+)"', source('miuread/config.lua'))
        self.assertIsNotNone(meta)
        self.assertIsNotNone(config)
        self.assertEqual(meta.group(1), config.group(1))
        self.assertRegex(meta.group(1), r'^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$')

    def test_no_epub_writes_or_auto_download_in_new_module(self):
        module = source('miuread/comment_sync.lua')
        self.assertIn('function CommentSync:fetch(', module)
        self.assertIn('function CommentSync:status(', module)
        self.assertIn('function CommentSync:load(', module)
        self.assertIn('ThoughtDatabase.record_fetch', module)
        self.assertIn('ThoughtDatabase.load_checkpoint', module)
        for forbidden in ('Annotations:apply(', '.epub', 'download_task', 'write_file', 'remove_bookmark', 'remove_review'):
            self.assertNotIn(forbidden, module)

    def test_status_and_atomic_checkpoint(self):
        db = source('miuread/thought_database.lua')
        self.assertIn('SQLiteStore.transaction(conn,function()', db)
        self.assertIn('cursor=? WHERE chapter_uid=?', db)
        self.assertIn('ThoughtDatabase.record_error', db)
        self.assertIn('ThoughtDatabase.load_checkpoint', db)
        self.assertIn('merge_chapter(conn,chapter_uid,groups or {})', db)

    def test_reader_menu_has_explicit_requests(self):
        main = source('main.lua')
        self.assertIn('self.comment_sync=require("miuread.comment_sync"):new(self.api,self.store,self.annotations)', main)
        self.assertIn('label="获取/更新指定章节范围"', main)
        self.assertIn('label="获取/更新当前章节评论"', main)
        self.assertIn('self:_fetch_current_chapter_comments(true,back_callback)', main)
        self.assertIn('select_range(true)', main)
        self.assertNotIn('label="自选范围（默认）"', main)
        self.assertIn('label="自动预载下一章评论"', main)
        self.assertIn('label="查看本章评论"', main)
        self.assertIn('return self:_start_comment_range(book,{row},1,1,force==true)', main)
        self.assertIn('title="本章评论"', main)
        self.assertIn('function Plugin:_offer_current_chapter_comments()', main)
        self.assertIn('function Plugin:_show_current_chapter_comments(', main)
        self.assertIn('请先打开觅阅下载的微信读书章节', main)
        self.assertNotIn('self.comment_sync:fetch(', main[:main.index('function Plugin:_reader_comment_status_label')])

    def test_incomplete_batches_not_marked_as_empty(self):
        parser = source('miuread/annotations.lua')
        self.assertIn('missing review list', parser)
        self.assertIn('mark_batch_completed(batch)', parser)
        self.assertIn('missing review list', parser)
        self.assertIn('local requested={}', parser)
        self.assertIn('options.force_refresh~=true and previous.underline_request_ok', parser)

    def test_deletion_and_personal_data_not_regressed(self):
        main = source('main.lua')
        self.assertIn('preferences=prefs,limit=200,upload_only=true', main)
        self.assertIn('self:_annotation_sync_preferences()', main)
        delete = source('miuread/book_delete_service.lua')
        self.assertNotIn('ThoughtFavorites.remove', delete)
        self.assertTrue((BASE.parent / '.github/workflows/release-beta.yml').exists())

if __name__ == '__main__':
    unittest.main()
