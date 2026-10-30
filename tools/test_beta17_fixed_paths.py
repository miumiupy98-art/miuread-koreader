"""beta.17 regression contracts. Run with `python -m unittest discover -s tools`."""
import re
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent/'miuread.koplugin'

def src(path): return (ROOT/path).read_text(encoding='utf-8')

class Beta17Contracts(unittest.TestCase):
    def test_all_book_surfaces_have_real_hold_callbacks(self):
        main=src('main.lua')
        self.assertEqual(main.count('on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end'),2)
        self.assertIn('on_hold=function(book,anchor) self:_home_hold_book(book,anchor) end',main)
        self.assertIn('function Plugin:_home_hold_book(book,anchor)',main)
        self.assertNotIn('Home shelf books intentionally have no long-press action',main)
        self.assertIn('hold_callback and function(anchor) hold_callback(book, anchor) end or nil',src('miuread/home_view.lua'))
        shelf=src('miuread/full_shelf_view.lua')
        self.assertIn('on_hold and function(anchor) on_hold(book, anchor) end or nil',shelf)
        self.assertIn('self._hold_handled=true',shelf)

    def test_kindle_authority_and_recovery(self):
        main=src('main.lua')
        recovery=main.split('function Plugin:_submit_saved_pending_progress(',1)[1].split('function Plugin:_submit_all_saved_pending_progress(',1)[0]
        self.assertNotIn('self.sync:remote(book_id',recovery)
        self.assertIn('force_write=true',recovery)
        self.assertIn('self:_progress_snapshot_current(book_id,position)',recovery)
        self.assertIn('self:_submit_progress_snapshot(book_id,position',recovery)
        # A valid Kindle coordinate no longer always wins on automatic open:
        # verified newer cloud read-events may be adopted after live mapping.
        self.assertNotIn('reason="kindle_coordinate_authoritative"',main)
        self.assertIn('self.sync:resolve_local_progress(function(local_position,local_err,meta)',main)
        self.assertIn('self:on_remote_progress(id,localp,remote,automatic==true,local_position)',main)
        self.assertIn('upload_state=="remote_newer_pending"',main)
        self.assertIn('self:_verify_progress_submission(',main)
        worker=src('miuread/legacy/read_report_worker.lua')
        self.assertIn('validate_terminal_progress(book,position)',worker)

    def test_time_report_independent_from_kindle_progress(self):
        sync=src('miuread/sync.lua')
        svc=src('miuread/read_report_service.lua')
        worker=src('miuread/legacy/read_report_worker.lua')
        self.assertIn('and options.progress_only~=true then',sync)
        self.assertIn('position_safe = time_only or',sync)
        self.assertIn('(not time_only and (control.position_safe',svc)
        self.assertIn('next_due = run_report(control, elapsed, false, "interval")',svc)
        time_block=worker.split('if reading_time_compat then',1)[1].split('local accepted, result',1)[0]
        self.assertIn('local anchor=type(job.cloud_anchor)=="table" and job.cloud_anchor or {}',time_block)
        self.assertIn('observed_at>=session_started-2',time_block)
        self.assertNotIn('refresh_remote_anchor(client,book_id,book)',time_block)
        self.assertNotIn('estimate_position(book,progress_ratio)',time_block)
        self.assertIn('meta={request_dispatched=false}',time_block)

    def test_comments_cross_source_and_retry(self):
        api=src('miuread/api_web.lua')
        parser=src('miuread/annotations.lua')
        main=src('main.lua')
        self.assertIn('join_review_responses(value,agent,batch)',api)
        self.assertIn('entries==0',api)
        self.assertIn('_miu_uncertain_ranges',api)
        self.assertIn('mark_batch_completed(batch)',parser)
        self.assertIn('ignored malformed/extra entries',parser)
        self.assertIn('status.status=="cached" or status.status=="empty"',main)
        self.assertIn('function Plugin:_comment_fetch_mode_menu(',main)
        self.assertIn('self:_fetch_current_chapter_comments(true,back_callback)',main)
        self.assertIn('self:_fetch_current_chapter_comments(true,back_callback)',main)

    def test_other_ux_regressions(self):
        self.assertIn('label:find("插件状态",1,true)',src('miuread/extension_center.lua'))
        self.assertIn('page_sections[#page_sections+1]',src('miuread/reader_control_center.lua'))

if __name__=='__main__': unittest.main()
