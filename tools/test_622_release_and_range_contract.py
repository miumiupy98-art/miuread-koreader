"""6.2.0-beta.3 source-level safety and UI regression gates."""
import unittest
from pathlib import Path
R=Path(__file__).resolve().parent.parent

def read(x):return (R/x).read_text(encoding='utf-8')

class Beta2Contracts(unittest.TestCase):
    def test_one_session_position_cache(self):
        w=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
        a=w.split('local protocol_time_only = job.time_only',1)[1].split('local accepted, result',1)[0]
        self.assertIn('local anchor=type(job.cloud_anchor)=="table" and job.cloud_anchor or {}',a)
        self.assertIn('observed_at>=session_started-2',a)
        self.assertNotIn('refresh_remote_anchor(client,book_id,book)',a)
        self.assertIn('if not position_override then',a)
        self.assertIn('position_override=normalize_cloud_anchor(saved,{})',a)
        self.assertIn('book.session_time_anchor_session=session_id',a)
        self.assertNotIn('client:get_progress(',a)
        self.assertIn('skip_agent_progress',w)
        self.assertIn('"session_time_anchor", "session_time_anchor_session"',w)
        p=read('miuread.koplugin/miuread/legacy_adapter_worker.lua')
        self.assertIn('reading_time_session_id = tostring(job.reading_time_session_id or "")',p)
        r=read('miuread.koplugin/miuread/read_report_service.lua')
        self.assertIn('reading_time_session_id=tostring(current_job.reading_time_session_id or "")',r)
        self.assertIn('if result.accepted and type(result.legacy_context) == "table"',r)
    def test_best_effort_has_no_persisted_replay(self):
        s=read('miuread.koplugin/miuread/sync.lua')
        self.assertRegex(s,r'local READ_REPORT_SERVICE_VERSION = (?:3[3-9]|[4-9][0-9])')
        start=s.index('function Sync:_start_daemon(');end=s.index('function Sync:',start+20)
        a=s[start:end]
        self.assertIn('local carry_elapsed=0',a)
        self.assertIn('历史阅读时间补报已关闭',s)
        self.assertNotIn('self:_load_readtime_recovery(',a)
        self.assertIn('self:_save_safe_pending_state(book_id,0,core_hash)',a)
        self.assertIn('READ_TIME_BEST_EFFORT = true',read('miuread.koplugin/miuread/config.lua'))
        r=read('miuread.koplugin/miuread/read_report_service.lua')
        self.assertIn('carry_remaining=0',r)
    def test_single_line_notice(self):
        m=read('miuread.koplugin/main.lua')
        self.assertIn('self:_sync_notice("time_started")',m)
        self.assertIn('text="本次阅读时间已开始同步"',m)
        self.assertNotIn('status_toast("阅读时间同步成功","本次阅读时间已开始同步"',m)
        self.assertIn('_time_sync_first_notice_shown==true',m)
    def test_comment_range_worker_and_ui(self):
        m=read('miuread.koplugin/main.lua')
        self.assertIn('label="指定章节范围"',m)
        self.assertNotIn('label="自选范围（默认）"',m)
        self.assertIn('function Plugin:_choose_comment_range(force,back_callback)',m)
        self.assertIn('function Plugin:_comment_range_next(runtime)',m)
        self.assertIn('disable_fallback=true',m)
        self.assertIn('runtime.async:run("comment_range_chapter"',m)
        self.assertIn('on_pause=function(pause)',m)
        self.assertIn('on_background=function()',m)
        self.assertIn('on_cancel=function()',m)
        self.assertIn('status.status=="cached" or status.status=="empty"',m)
        self.assertIn('self:_sync_notice(runtime.failed>0 and "comments_failed" or "comments_done")',m)
        self.assertIn('return self:_start_comment_range(book,{row},1,1,force==true)',m)
        ui=read('miuread.koplugin/miuread/comment_progress.lua')
        self.assertIn('function Compact:set_state(state)',ui)
        self.assertIn('current).."/"..tostring(total)',ui)
        self.assertIn('covers_fullscreen=false',ui)
    def test_existing_progress_and_release_guards(self):
        m=read('miuread.koplugin/main.lua')
        self.assertIn('return allow_verified==true and verified==seq and latest==seq',m)
        self.assertIn('verify_error=="account_changed"',m)
        self.assertIn('self:_show_current_chapter_comments(scope,reopen)',m)
        self.assertIn('annotations=false',m)
        for name in ('release.yml','release-beta.yml'):
            w=read('.github/workflows/'+name)
            self.assertIn('workflow_dispatch:',w)
            self.assertIn('push:',w)
            self.assertIn('tags:',w)
if __name__=='__main__':unittest.main()
