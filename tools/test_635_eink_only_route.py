"""6.3.0-beta.6 compatibility: verify E-Ink-only policy at every Web elapsed-time entry.

Source contracts complement the actual Worker test in test_beta17_worker_and_comments.lua.
No account, network or live WeRead credentials are involved.
"""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[1]
def read(path): return (ROOT/path).read_text(encoding='utf8')
class EinkOnlyRoute(unittest.TestCase):
    def test_opt_in_upgrade_and_metadata(self):
        store=read('miuread.koplugin/miuread/store.lua')
        self.assertIn('time_eink_only=false',store)
        config=read('miuread.koplugin/miuread/config.lua')
        self.assertIn('VERSION = "6.5.0-beta.10"',config)
        self.assertIn('version = "6.5.0-beta.10"',read('miuread.koplugin/_meta.lua'))
    def test_web_is_forbidden_at_scheduling_and_control(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        self.assertIn('function Sync:web_readtime_disabled()',sync)
        self.assertIn('if self:web_readtime_disabled() then\n        self.state="paused"',sync)
        daemon=sync.split('function Sync:_start_daemon(reason)',1)[1].split('function Sync:',1)[0]
        self.assertIn('if self:web_readtime_disabled()',daemon)
        control=sync.split('function Sync:_write_daemon_control(',1)[1].split('function Sync:',1)[0]
        self.assertIn('web_time_disabled = self:web_readtime_disabled()',control)
        self.assertIn('control.active=false',control)
        self.assertIn('control.flush_seq=nil',control)
        self.assertIn('READ_REPORT_SERVICE_VERSION = 33',sync)
    def test_web_time_blocked_but_progress_zero_unmodified(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        upload=sync.split('function Sync:upload(elapsed, callback, options)',1)[1].split('function Sync:',1)[0]
        self.assertIn('(tonumber(elapsed) or 0)>0',upload)
        self.assertIn('options.time_only==true',upload)
        self.assertIn('web_time_disabled = self:web_readtime_disabled()',upload)
        progress=sync.split('function Sync:upload_progress_only(',1)[-1] if 'function Sync:upload_progress_only(' in sync else sync
        self.assertIn('progress_only=true',progress)
        self.assertIn('return self:upload(0,',progress)
        worker=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
        self.assertIn('job.web_time_disabled==true',worker)
        self.assertIn('request_dispatched=false',worker)
        adapter=read('miuread.koplugin/miuread/legacy_adapter_worker.lua')
        self.assertIn('web_time_disabled = job.web_time_disabled==true',adapter)
        service=read('miuread.koplugin/miuread/read_report_service.lua')
        self.assertIn('control.web_time_disabled==true or current_job.web_time_disabled==true',service)
        self.assertIn('elseif (control.web_time_disabled==true or current_job.web_time_disabled==true) then',service)
    def test_eink_upload_independent_of_api_transport(self):
        ctrl=read('miuread.koplugin/miuread/readtime_controller.lua')
        send=ctrl.split('function M:send()',1)[1].split('function M:',1)[0]
        self.assertIn('local eink_allowed=mode=="eink" or mode=="smart"',send)
        self.assertIn('if not eink_allowed and require("miuread.api_transport").new(self.store).selected~="eink"',send)
        self.assertIn('if not self.host:is_online()',send) if 'if not self.host:is_online()' in send else self.assertIn('not host:is_online()',send)
        self.assertIn('self.queue:pending(',send)
        self.assertIn('self.worker:run(',send)
    def test_switch_requires_new_book_and_no_tail(self):
        main=read('miuread.koplugin/main.lua')
        toggle=main.split('function Plugin:set_reading_time_mode(',1)[1].split('function Plugin:toggle_eink_only_readtime()',1)[0]
        self.assertIn('self.store:save_preferences(prefs)',toggle)
        self.assertIn('self.sync:stop_reading_time_only("reading_time_mode_changed")',toggle)
        self.assertIn('self.sync.reading_time_backend="eink_restart_required"',toggle)
        self.assertIn('self.sync:wake_offline_reading_time()',toggle)
        sync=read('miuread.koplugin/miuread/sync.lua')
        self.assertIn('self.reading_time_backend="eink"',sync)
        self.assertIn('self.reading_time_backend=nil',sync)
        self.assertIn('if self.reading_time_backend=="eink_restart_required" then',sync)
        self.assertIn('if explicit_elapsed==0 then daemon.final_flush_pending=false end',sync)
    def test_account_status_reader_is_bounded_list(self):
        main=read('miuread.koplugin/main.lua')
        account=main.split('function Plugin:show_account_status()',1)[1].split('function Plugin:on_auth_success(',1)[0]
        self.assertIn('return self:_show_miuread_menu("账号状态",rows,{page_size=7})',account)
        self.assertNotIn('ButtonDialog:new',account)
        for label in ('重新检查状态','重新扫码登录','E-Ink 客户端授权','退出登录','待同步','待确认','上传方式'):
            self.assertIn(label,account)
        self.assertIn('self.sync:offline_time_controller():summary()',account)
        self.assertIn('sub_item_table_func=function() return self:eink_authorization_menu() end',account)
    def test_release_workflow_contains_actual_gate(self):
        w=read('.github/workflows/release-beta.yml')
        self.assertIn('test_635_eink_only_route.py',w)
        self.assertIn('test_beta17_worker_and_comments.lua',w)
if __name__=='__main__': unittest.main()
