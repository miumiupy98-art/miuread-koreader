"""Keep the beta.8 smart router and enforce compact display / callback ownership."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
def read(path):return (ROOT/path).read_text(encoding='utf8')
class ReadingTimeOwnership(unittest.TestCase):
    def test_ui_is_channel_only_and_has_no_upload_side_effect(self):
        main=read('miuread.koplugin/main.lua')
        f=main.split('function Plugin:_reading_time_status_label()',1)[1].split('function Plugin:_sync_current_book_label()',1)[0]
        for value in ('return "Web"','return "Eink"','return "未启用"','return "—"'):
            self.assertIn(value,f)
        self.assertNotIn('last_upload',f)
        self.assertNotIn('self.sync:start',f)
        self.assertNotIn('self.sync:stop',f)
        public=main.split('function Plugin:reading_time_status_label()',1)[1].split('function Plugin:reading_time_unknown_menu(',1)[0]
        self.assertIn('return self:_reading_time_status_label()',public)
        self.assertIn('post_text=self:_reading_time_status_label()',main)
    def test_finalizer_keeps_original_writer_and_session(self):
        main=read('miuread.koplugin/main.lua')
        sync=read('miuread.koplugin/miuread/sync.lua')
        self.assertIn('local time_writer_ownership={',main)
        self.assertIn('end,false,time_writer_ownership)',main)
        block=sync.split('function Sync:preempt_reading_time_for_progress(',1)[1].split('function Sync:_cancel_record_retry()',1)[0]
        self.assertIn('ownership=ownership or {',block)
        self.assertIn('self.reading_time_segment_id~=ownership.segment',block)
        self.assertIn('preempt_reading_time_for_progress(reason,callback,true,ownership)',block)
        self.assertIn('callback(false,{state="writer_owner_changed"',block)
    def test_delayed_recovery_refuses_replacement_daemon(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        block=sync.split('function Sync:_restart_unhealthy_daemon(',1)[1].split('function Sync:_attach_existing_daemon(',1)[0]
        self.assertIn('if self.daemon~=nil',block)
        self.assertIn('self.reading_time_session_id~=old_session',block)
        self.assertIn('self.reading_time_segment_id~=old_segment',block)
        self.assertIn('tonumber(owner.pid)~=old_pid',block)
    def test_resumption_waits_for_critical_finalizer(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        fn=sync.split('function Sync:resume_after_reading_end()',1)[1].split('function Sync:quiesce_for_exit(',1)[0]
        self.assertIn('if self.host._reading_end_finalizer_active==true then',fn)
        self.assertLess(fn.index('if self.host._reading_end_finalizer_active==true then'),fn.index('self:start("resume")'))
        self.assertLess(fn.index('self:_ensure_reading_time_ids(false,true)'),fn.index('self:start("resume")'))
        resume=sync.split('function Sync:on_resume(_slept)',1)[1].split('function Sync:resume_after_reading_end()',1)[0]
        self.assertLess(resume.index('if self.host and (self.host._reading_end_sync_active'),resume.index('self:_ensure_reading_time_ids(false,true)'))
    def test_original_smart_barrier_and_protocol_are_retained(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        handoff=sync.split('function Sync:switch_smart_time_backend(',1)[1].split('function Sync:offline_time_controller()',1)[0]
        self.assertIn('if self.reading_time_backend==target then return true end',handoff)
        self.assertIn('self:wait_writer_barrier(seq,after_stop,12)',handoff)
        self.assertIn('controller:collect(true)',handoff)
        self.assertIn('self:start("smart_network_online")',handoff)
if __name__=='__main__':unittest.main()
