from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/'miuread.koplugin/main.lua').read_text()
class HomeMenuTests(unittest.TestCase):
    def test_sync_tap_hold_same_menu(self):
        area=MAIN.split('function Plugin:_home_action_entries()',1)[1].split('function Plugin:_home_alerts()',1)[0]
        self.assertIn('return self:_home_sync_management_menu(anchor)',area)
        self.assertIn('if key=="sync" then return self:_home_sync_management_menu(anchor) end',area)
        menu=MAIN.split('function Plugin:_home_sync_management_menu(',1)[1].split('function Plugin:_home_action_entries()',1)[0]
        for label in ('立即同步','同步状态','同步设置'): self.assertIn(label,menu)
        self.assertIn('_sync_home_pending({source="home_quick"})',menu)
    def test_unified_action_menu(self):
        area=MAIN.split('function Plugin:_home_action_entries()',1)[1].split('function Plugin:_home_alerts()',1)[0]
        self.assertIn('return self:_show_standalone_menu(',area)
        self.assertNotIn('cache_key="home_action_functions_"',area)
        self.assertIn('_home_action_edit_actions',area)
    def test_native_lockscreen(self):
        self.assertIn('text="KOReader 原生锁屏"',MAIN)
        mode=MAIN.split('function Plugin:_home_use_koreader_lockscreen()',1)[1].split('function Plugin:home_lockscreen_settings_menu()',1)[0]
        self.assertIn('_toggle_home_lockscreen()',mode)
        self.assertIn('_show_native_koreader_menu()',mode)
        self.assertNotIn('screensaver_type=',mode)
if __name__=='__main__': unittest.main()
