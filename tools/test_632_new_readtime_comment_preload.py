from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
def source(name): return (ROOT/name).read_text(encoding="utf-8")
class NextRelease(unittest.TestCase):
    def test_time_gate_blocks_live_eink_sessions(self):
        ctrl=source("miuread.koplugin/miuread/readtime_controller.lua")
        send=ctrl.split("function M:send()",1)[1].split("function M:summary()",1)[0]
        self.assertIn("if self.active or (live_sync and live_sync.current)",send)
        self.assertIn("or (self.sync and self.sync.current) then return false end",send)
    def test_manual_comment_priority_and_preload(self):
        main=source("miuread.koplugin/main.lua")
        self.assertIn("self:_cancel_next_comment_preload(\"manual priority\")",main)
        self.assertIn('comment_auto_preload==true',main)
        self.assertIn('if not (ctx and ctx.state=="NEXT" and ctx.catalog_complete==true)',main)
        self.assertIn('async:run("comment_next_preload"',main)
        self.assertIn('self:_cancel_next_comment_preload("document close")',main)
    def test_comment_progress_controls(self):
        ui=source("miuread.koplugin/miuread/comment_progress.lua")
        self.assertIn('已保存 ',ui)
        self.assertIn('self.detail_label:setText(detail)',ui)
        self.assertIn('self.on_pause',ui)
        self.assertIn('self.on_cancel',ui)
    def test_beta_identity(self):
        config=source("miuread.koplugin/miuread/config.lua")
        self.assertIn('VERSION = "6.3.2-beta.3"',config)
        self.assertIn('UPDATE_CHANNEL = "beta"',config)
if __name__=="__main__": unittest.main()
