"""Regression for on-device 2026-10-30 opening sync and comment UI.

Logs showed saved chapter 38 == Web chapter 38 even though ReaderUI was
showing chapter 35; later an automatic Web chapter 62 was ignored by a
hard-coded local-coordinate override. No network requests in these tests.
"""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT/path).read_text(encoding="utf-8")


class LiveOpenPosition(unittest.TestCase):
    def test_automatic_and_manual_read_real_reader_before_remote_decision(self):
        main=read("miuread.koplugin/main.lua")
        region=main.split("function Plugin:ensure_read_report_progress(reason,automatic)",1)[1].split("function Plugin:manual_sync()",1)[0]
        self.assertNotIn("self:on_remote_progress(id,localp,remote,true,frozen_local)",region)
        self.assertIn("self.sync:resolve_local_progress(function(local_position,local_err,meta)",region)
        self.assertIn("self:on_remote_progress(id,localp,remote,automatic==true,local_position)",region)
        self.assertLess(region.index("self.sync:resolve_local_progress(function(local_position,local_err,meta)"),
                        region.index("self.sync:remote(id,function(remote,remote_err)"))
        self.assertIn('self:_finish_auto_position_check(id,"live position aligned")',region)
        self.assertIn('if automatic==true then self:_set_progress_write_fence(id,"remote_fetch_pending") end',region)

    def test_newer_remote_is_not_forced_to_local(self):
        main=read("miuread.koplugin/main.lua")
        region=main.split("function Plugin:on_remote_progress(",1)[1].split("function Plugin:show_sync_status(",1)[0]
        self.assertNotIn("kindle_coordinate_authoritative",region)
        self.assertIn('if winner=="remote" then',region)
        self.assertIn("self:_use_remote_position(id,localp,resolved_remote",region)
        self.assertIn('if automatic and (user_moved or (open_age>0 and open_age>window)) then',region)
        self.assertIn('if winner=="aligned" then',region)
        self.assertIn('if winner=="conflict" then',region)
        self.assertNotIn('self:upload_local_progress(',region)

    def test_reader_toolbar_does_not_call_pending_writes_failures(self):
        main=read("miuread.koplugin/main.lua")
        status=main.split('function Plugin:_progress_status_label()',1)[1].split('function Plugin:show_sync_background_status()',1)[0]
        self.assertIn('if pending or state=="waiting_network"',status)
        self.assertIn('return "待同步确认"',status)
        self.assertIn('state=="upload_failed"',status)
        summary=main.split('function Plugin:_reader_sync_summary()',1)[1].split('function Plugin:_reader_battery_label()',1)[0]
        self.assertIn('self:_progress_status_label()',summary)
        self.assertIn('return "同步待处理",false',summary)
        self.assertNotIn('or label:find("暂不处理",1,true) then return "同步失败"',summary)

    def test_comment_progress_has_one_outer_outline_and_nonmodal_touch(self):
        ui=read("miuread.koplugin/miuread/comment_progress.lua")
        self.assertIn('local frame_border=math.max(1,Screen:scaleBySize(1))',ui)
        self.assertIn('bordersize=frame_border',ui)
        self.assertIn('color=Blitbuffer.COLOR_BLACK',ui)
        self.assertIn('local content_w=outer_w-2*(pad+frame_border)',ui)
        self.assertIn('covers_fullscreen=false',ui)
        self.assertIn('stop_events_propagation=false',ui)
        buttons=ui.split('function Compact:_button(',1)[1].split('function Compact:_build()',1)[0]
        self.assertNotIn('FrameContainer:new',buttons)
        self.assertIn('self.frame.overlap_offset={x,y}',ui)

if __name__=='__main__':
    unittest.main()
