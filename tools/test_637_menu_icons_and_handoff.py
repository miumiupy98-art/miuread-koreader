"""v6.5.0-beta.8 menu and sync-safety contracts."""
from pathlib import Path
import unittest,xml.etree.ElementTree as ET,re
ROOT=Path(__file__).resolve().parents[1]
def read(path):return (ROOT/path).read_text(encoding='utf-8')
class MenuAndHandoff(unittest.TestCase):
    def test_version_and_mode_migration(self):
        self.assertIn('VERSION = "6.5.0-beta.11"',read('miuread.koplugin/miuread/config.lua'))
        self.assertIn('version = "6.5.0-beta.11"',read('miuread.koplugin/_meta.lua'))
        self.assertIn('time_eink_only=false,time_route_mode="legacy"',read('miuread.koplugin/miuread/store.lua'))
    def test_time_settings_entry_and_toggle_are_distinct(self):
        main=read('miuread.koplugin/main.lua')
        outer=main.split('function Plugin:sync_settings_menu()',1)[1].split('function Plugin:sync_menu()',1)[0]
        self.assertIn('{text="阅读时长同步"',outer)
        self.assertIn('sub_item_table_func=function() return self:reading_time_menu() end',outer)
        inner=main.split('function Plugin:reading_time_menu()',1)[1].split('function Plugin:reading_time_diagnostics_menu()',1)[0]
        self.assertIn('{text="启用阅读时长同步",icon_key="power"',inner)
        self.assertIn('callback=function() self:toggle_time_sync() end',inner)
        self.assertNotIn('{text="阅读时长同步",post_text=',inner)
        self.assertIn('sub_item_table_func=function() return self:eink_authorization_menu() end',inner)
        self.assertIn('诊断与修复',inner)
        self.assertNotIn('详细诊断日志',inner)
    def test_authorization_management_and_real_check(self):
        main=read('miuread.koplugin/main.lua')
        menu=main.split('function Plugin:eink_authorization_menu()',1)[1].split('function Plugin:on_offline_readtime_uploaded(',1)[0]
        for entry in ('授权状态','扫码授权','检查授权状态','取消 E-Ink 客户端授权'):
            self.assertIn(entry,menu)
        check=main.split('function Plugin:check_eink_authorization()',1)[1].split('function Plugin:eink_authorization_menu()',1)[0]
        self.assertIn('https://i.weread.qq.com/shelf/sync',check)
        self.assertIn('_run_interactive_network',check)
        self.assertNotIn('self:check_account_status()',menu)
        self.assertIn('"已验证"',main)
    def test_reader_and_home_icon_paths(self):
        main=read('miuread.koplugin/main.lua')
        adapter=read('miuread.koplugin/miuread/plugin_menu_adapter.lua')
        self.assertIn('MenuIcons.key(label)',adapter)
        reader=main.split('function Plugin:_reader_menu_rows_from_table(',1)[1].split('function Plugin:_show_reader_menu_table(',1)[0]
        self.assertIn('icon=item.icon_key or item.icon or (not item.separator and MenuIcons.key(label))',reader)
        for path in ['miuread.koplugin/miuread/plugin_menu.lua',
                     'miuread.koplugin/miuread/plugin_settings.lua',
                     'miuread.koplugin/miuread/extension_center.lua']:
            self.assertIn('MenuIcons.key(',read(path))
    def test_menu_icons_real_files(self):
        icons=ROOT/'miuread.koplugin/resources/icons/miuread'
        mappings=read('miuread.koplugin/miuread/menu_icons.lua')
        keys=set(re.findall(r'="([a-z][a-z-]+)"',mappings))
        for key in keys:
            path=icons/(key+'.svg')
            self.assertTrue(path.is_file(),f'missing svg {key}')
            self.assertEqual(ET.parse(path).getroot().tag,'{http://www.w3.org/2000/svg}svg')
    def test_stop_waits_for_ack_without_blocking_ui(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        handoff=sync.split('function Sync:switch_smart_time_backend(',1)[1].split('function Sync:offline_time_controller()',1)[0]
        self.assertIn('self:wait_writer_barrier(seq,after_stop,12)',handoff)
        self.assertIn('if not ack then',handoff)
        self.assertIn('if self._smart_handoff~=handoff then return end',handoff)
        self.assertIn('self._smart_handoff.reconnect_requested=true',handoff)
        self.assertIn('if handoff.reconnect_requested or',handoff)
        self.assertIn('self:_stop_daemon("smart_offline:"..tostring(reason),true,0)',handoff)
        self.assertIn('self.reading_time_backend="eink"',handoff)
        self.assertIn('controller:collect(true)',handoff)
        self.assertNotIn('UIManager:scheduleIn(12',handoff)
    def test_time_stop_preserves_progress_and_web_rt_zero(self):
        sync=read('miuread.koplugin/miuread/sync.lua')
        stop=sync.split('function Sync:stop_reading_time_only(',1)[1].split('function Sync:stop(',1)[0]
        self.assertIn('self:_stop_daemon',stop)
        self.assertNotIn('self.async:cancel',stop)
        self.assertIn('return self:upload(0,',sync)
        main=read('miuread.koplugin/main.lua')
        self.assertIn('self.sync:stop_reading_time_only("reading_time_mode_changed")',main)
    def test_auth_retry_only_pending_and_wake_preempts_old_timer(self):
        out=read('miuread.koplugin/miuread/readtime_outbox.lua')
        clear=out.split('function M:clear_auth_retry(',1)[1].split('function M:unknown(',1)[0]
        self.assertIn('row.state=="pending" and row.reason=="authentication"',clear)
        self.assertNotIn('row.state="pending"',clear)
        ctrl=read('miuread.koplugin/miuread/readtime_controller.lua')
        wake=ctrl.split('function M:wake(',1)[1].split('function M:authorization_restored(',1)[0]
        self.assertIn('UI:unschedule(self.task); self.task=nil',wake)
        self.assertIn('self:schedule(2)',wake)
    def test_no_new_ledger_or_web_protocol_rewrite(self):
        root=ROOT/'miuread.koplugin/miuread'
        self.assertTrue((root/'readtime_outbox.lua').exists())
        self.assertTrue((root/'eink_readtime.lua').exists())
        self.assertTrue((root/'legacy/read_report_worker.lua').exists())
        self.assertIn('if self.active or live_reader(live_sync) or live_reader(self.sync) then return false end',read('miuread.koplugin/miuread/readtime_controller.lua'))
if __name__=='__main__':unittest.main()
