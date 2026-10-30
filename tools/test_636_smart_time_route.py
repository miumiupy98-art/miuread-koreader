"""v6.3.0-beta.6 automated source contracts for Web/E-Ink smart time handoff."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
def read(n):return (R/n).read_text(encoding="utf-8")
class SmartTimeRoute(unittest.TestCase):
    def test_mode_default_upgrade_and_version(self):
        s=read("miuread.koplugin/miuread/store.lua")
        self.assertIn('time_eink_only=false,time_route_mode="legacy"',s)
        sync=read("miuread.koplugin/miuread/sync.lua")
        self.assertIn('prefs.time_eink_only==true or prefs.time_route_mode=="eink"',sync)
        self.assertIn('prefs.time_route_mode=="smart"',sync)
        self.assertIn('VERSION = "6.3.2-beta.3"',read("miuread.koplugin/miuread/config.lua"))
        self.assertIn('version = "6.3.2-beta.3"',read("miuread.koplugin/_meta.lua"))
    def test_switch_does_not_replay_web_time(self):
        sync=read("miuread.koplugin/miuread/sync.lua")
        handoff=sync.split('function Sync:switch_smart_time_backend(',1)[1].split('function Sync:',1)[0]
        self.assertIn('self:_stop_daemon("smart_offline:"..tostring(reason),true,0)',handoff)
        self.assertIn('self.reading_time_backend="eink"',handoff)
        self.assertIn('controller:collect(true)',handoff)
        self.assertIn('self.reading_time_backend="web"',handoff)
        self.assertIn('if not ok then',handoff)
        self.assertIn('controller:start(self,self.current)',handoff)
        self.assertIn('if self.host.on_readtime_route_change',handoff)
        self.assertIn('mode=="smart" and self.reading_time_backend=="eink"',sync)
    def test_closed_web_worker_cannot_flush_new_eink_time(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        for method in ('_stop_daemon_fast','_stop_daemon'):
            snippet=sync.split('function Sync:'+method+'(',1)[1].split('function Sync:',1)[0]
            self.assertIn('local request_flush=daemon.book_id and daemon.active==true',snippet)
            self.assertIn('and not self:web_readtime_disabled()',snippet)
            self.assertIn('self.reading_time_backend~="eink_restart_required"',snippet)
    def test_queue_sends_only_after_reader_close_in_smart_mode(self):
        ctrl=read('miuread.koplugin/miuread/readtime_controller.lua')
        self.assertIn('if self.active then self:schedule(60)',ctrl)
        self.assertIn('UI:scheduleIn(delay or 60,task)',ctrl)
        send=ctrl.split('function M:send()',1)[1].split('function M:summary()',1)[0]
        self.assertIn('if self.active or (live_sync and live_sync.current)',send)
        self.assertIn('local eink_allowed=mode=="eink" or mode=="smart"',send)
        self.assertIn('if not eink_allowed and require("miuread.api_transport").new(self.store).selected~="eink"',send)
        self.assertIn('value.state=="confirmed"',send)
        self.assertIn('host:on_offline_readtime_uploaded(batch.seconds)',send)
    def test_reauthorization_only_resets_auth_cooldown(self):
        outbox=read('miuread.koplugin/miuread/readtime_outbox.lua')
        method=outbox.split('function M:clear_auth_retry(',1)[1].split('function M:unknown(',1)[0]
        self.assertIn('if control.reason=="authentication" then',method)
        self.assertIn('row.state=="pending" and row.reason=="authentication"',method)
        self.assertNotIn('data.items=',method)
        ctrl=read('miuread.koplugin/miuread/readtime_controller.lua')
        self.assertIn('self.queue:clear_auth_retry(vid,os.time())',ctrl)
        self.assertIn('if self.task then UI:unschedule(self.task);self.task=nil end',ctrl)
        bookstore=read('miuread.koplugin/miuread/bookstore.lua')
        self.assertIn(':authorization_restored(plugin)',bookstore)
    def test_ui_mode_and_authorization_actions(self):
        main=read('miuread.koplugin/main.lua')
        self.assertIn('function Plugin:reading_time_mode_menu()',main)
        self.assertIn('function Plugin:set_reading_time_mode(mode)',main)
        self.assertIn('function Plugin:confirm_eink_authorization()',main)
        self.assertIn('callback=function() self:confirm_eink_authorization() end',main)
        self.assertIn('function Plugin:_schedule_smart_readtime_route(online,reason)',main)
        self.assertIn('self:_schedule_smart_readtime_route(true,"network_connected")',main)
        self.assertIn('self:_schedule_smart_readtime_route(false,"network_disconnected")',main)
        self.assertIn('UIManager:scheduleIn(4,function()',main)
        self.assertIn('self.sync:stop_reading_time_only("reading_time_mode_changed")',main)
        self.assertIn('已切换至 E-Ink 离线计时，记录本地保存，联网后补传',main)
        self.assertIn('网络已恢复，Web 阅读时间同步已启动',main)
    def test_precise_progress_kept_independent(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        self.assertIn('return self:upload(0,',sync)
        worker=read('miuread.koplugin/miuread/legacy/read_report_worker.lua')
        self.assertIn('job.web_time_disabled==true',worker)
        self.assertIn('request_dispatched=false',worker)
    def test_ci_gate(self):
        workflow=read('.github/workflows/release-beta.yml')
        self.assertIn('test_636_smart_time_route.py',workflow)
if __name__=='__main__':unittest.main()
