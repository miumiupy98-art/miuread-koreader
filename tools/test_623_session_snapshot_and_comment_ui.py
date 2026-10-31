"""Regression gates for 6.2.0-beta.3 on-device failures (source contracts)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def content(name):
    return (ROOT / name).read_text(encoding='utf-8')

class SnapshotAndUiRegression(unittest.TestCase):
    def test_open_web_source_is_not_agent_reconciliation_winner(self):
        sync = content('miuread.koplugin/miuread/sync.lua')
        self.assertIn('self:set_remote_wire_anchor(book_id,web,"remote_observed_wire",true)', sync)
        self.assertNotIn('self:set_remote_wire_anchor(book_id,remote,"remote_observed_wire",true)', sync)
        self.assertIn('remote_wire_fetched_at=anchor.fetched_at', sync)
        self.assertIn('remote_wire_fetched_at=wire_anchor and wire_anchor.fetched_at', sync)
        self.assertRegex(sync,r'local READ_REPORT_SERVICE_VERSION = (?:3[3-9]|[4-9][0-9])')

    def test_web_tuple_reaches_real_legacy_time_writer(self):
        service = content('miuread.koplugin/miuread/read_report_service.lua')
        adapter = content('miuread.koplugin/miuread/legacy_adapter_worker.lua')
        worker = content('miuread.koplugin/miuread/legacy/read_report_worker.lua')
        self.assertIn('cloud_anchor = time_only and',service)
        for field in ('chapter_uid','chapter_idx','chapter_offset','protocol_progress','fetched_at','book_id'):
            self.assertIn(field+'=',service)
        self.assertIn('cloud_anchor = copy(job.cloud_anchor or {})',adapter)
        time = worker.split('local protocol_time_only = job.time_only',1)[1].split('local accepted, result',1)[0]
        self.assertIn('local anchor=type(job.cloud_anchor)=="table" and job.cloud_anchor or {}',time)
        self.assertIn('source=="web_cookie"',time)
        self.assertIn('same_book and from_web and fresh',time)
        self.assertIn('catalog_idx~=nil and catalog_idx==idx',time)
        self.assertIn('book.session_time_anchor_session=session_id',time)
        self.assertNotIn('refresh_remote_anchor(client,book_id,book)',time)
        self.assertIn('meta={request_dispatched=false}',time)
        self.assertIn('validate_terminal_progress(book,position)',worker)

    def test_comment_pages_no_native_unbounded_list(self):
        main = content('miuread.koplugin/main.lua')
        dialog = content('miuread.koplugin/miuread/reader_settings_dialog.lua')
        progress = content('miuread.koplugin/miuread/download_progress.lua')
        region = main.split('function Plugin:_comment_chapter_list_menu',1)[1].split('function Plugin:_show_reader_comment_center',1)[0]
        self.assertNotIn('self:list(',region)
        self.assertIn('local page_size=8',region)
        self.assertGreaterEqual(region.count('opaque_fullscreen=true'),3)
        for action in ('指定章节范围','更新指定范围','当前章节','更新当前章节'):
            self.assertIn(action,region)
        self.assertIn('self.covers_fullscreen=self.opts.opaque_fullscreen==true', dialog)
        self.assertIn('LineWidget:new{background=Blitbuffer.COLOR_WHITE',dialog)
        self.assertIn('dialog.covers_fullscreen and dialog.dimen or dialog.frame_dimen',dialog)
        compact = content('miuread.koplugin/miuread/comment_progress.lua')
        self.assertIn('local dialog=CommentProgress:new{',main)
        self.assertIn('self.popup_dimen=Geom:new',compact)
        self.assertIn('covers_fullscreen=false',compact)
        self.assertIn('stop_events_propagation=false',compact)
        self.assertNotIn('LineWidget:new{background=Blitbuffer.COLOR_WHITE',compact)
        self.assertNotIn('comment_opaque=true',main)

    def test_version_and_release_triggers(self):
        config = content('miuread.koplugin/miuread/config.lua')
        meta = content('miuread.koplugin/_meta.lua')
        version=re.search(r'VERSION\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+)"',config)
        self.assertIsNotNone(version)
        self.assertIn('version = "'+version.group(1)+'"',meta)
        workflow=content('.github/workflows/release-beta.yml')
        self.assertIn('workflow_dispatch:',workflow)
        self.assertIn('tags:',workflow)
        self.assertIn('test_beta17_worker_and_comments.lua',workflow)

if __name__ == '__main__':
    unittest.main()
