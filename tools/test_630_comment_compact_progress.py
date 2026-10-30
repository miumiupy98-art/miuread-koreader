"""6.3.0-beta.1: explicit non-modal compact comment download controls."""
from pathlib import Path
import re
import unittest
BASE=Path(__file__).resolve().parents[1]
def read(path):return (BASE/path).read_text(encoding='utf-8')
class CompactCommentProgress(unittest.TestCase):
    def test_progress_draws_only_small_frame_and_keeps_page_turns(self):
        u=read('miuread.koplugin/miuread/comment_progress.lua')
        self.assertIn('covers_fullscreen=false',u)
        self.assertIn('stop_events_propagation=false',u)
        self.assertIn('self.frame.overlap_offset={x,y}',u)
        self.assertIn('self.popup_dimen=Geom:new{x=x,y=y,w=size.w,h=size.h}',u)
        self.assertIn('UIManager:setDirty(self,"ui",self.popup_dimen)',u)
        self.assertIn('UIManager:setDirty("all","ui",region)',u)
        self.assertNotIn('LineWidget:new',u)
        self.assertNotIn('self.comment_opaque',u)
        self.assertNotIn('Screen:getHeight() * 0.60',u)
        self.assertIn('self.progress=ProgressWidget:new{',u)
        self.assertIn('local fraction=total>0',u)
        self.assertIn('if signature==self._last_signature then return end',u)
        self.assertNotIn('state.chapter',u)
        self.assertIn('state.comments',u)
        self.assertNotIn('state.failed',u)
    def test_each_action_uses_real_icon_and_real_task_callback(self):
        u=read('miuread.koplugin/miuread/comment_progress.lua')
        m=read('miuread.koplugin/main.lua')
        icons=BASE/'miuread.koplugin/resources/icons/miuread'
        for name in ('minimize','pause','play','close','comment'):
            self.assertTrue((icons/(name+'.svg')).is_file(),name)
        self.assertIn('self:_button("minimize","后台"',u)
        self.assertIn('self:_button(self.paused and "play" or "pause",self.paused and "继续" or "暂停"',u)
        self.assertIn('self:_button("close","取消"',u)
        self.assertIn('if self.on_background then self.on_background() end',u)
        self.assertIn('if self.on_pause then self.on_pause(self.paused~=true) end',u)
        self.assertIn('if self.on_cancel then self.on_cancel() end',u)
        self.assertIn('if runtime.dialog then runtime.dialog:close("background") end',m)
        self.assertIn('on_cancel=function() self:_cancel_comment_range_task("user",false) end',m)
        self.assertIn('runtime.paused=pause==true',m)
        self.assertIn('if runtime.paused==true or runtime.async:busy() then return end',m)
        self.assertIn('if not runtime.paused and not runtime.async:busy() then',m)
        self.assertNotIn('local resuming=runtime.paused==true',m)
        self.assertNotIn('runtime.paused=false\n    local dialog=CommentProgress',m)
    def test_task_entry_and_worker_contract_preserved(self):
        m=read('miuread.koplugin/main.lua')
        menu=m.split('function Plugin:_comment_fetch_mode_menu(',1)[1].split('function Plugin:_show_reader_comment_center',1)[0]
        center=m.split('function Plugin:_show_reader_comment_center(',1)[1].split('function Plugin:_reader_font_label',1)[0]
        self.assertIn('label="评论获取任务"',menu)
        self.assertIn('label="评论获取任务"',center)
        for item in ('获取/更新当前章节评论','获取/更新指定章节范围','自动预载下一章评论'):
            self.assertIn('label="'+item+'"',menu)
        self.assertIn('runtime.async:run("comment_range_chapter"',m)
        self.assertIn('self.comment_sync:status(runtime.book_id,uid)',m)
        self.assertIn('runtime.async:cancel(reason or "cancelled")',m)
        self.assertIn('self:_sync_notice(runtime.failed>0 and "comments_failed" or "comments_done")',m)
        self.assertNotIn('comment_opaque=true',m)
        self.assertIn('local CommentProgress=require("miuread.comment_progress")',m)
    def test_release_version_and_gate(self):
        # The compact UI was introduced in beta.1 and must survive later
        # 6.3 releases; never hard-code the current release to beta.1.
        meta=read('miuread.koplugin/_meta.lua')
        conf=read('miuread.koplugin/miuread/config.lua')
        m=re.search(r'version\s*=\s*"(6\.3\.2-beta\.(\d+))"',meta)
        self.assertIsNotNone(m)
        self.assertGreaterEqual(int(m.group(2)),1)
        self.assertIn('VERSION = "'+m.group(1)+'"',conf)
        self.assertIn('## '+m.group(1),read('CHANGELOG.md'))
        wf=read('.github/workflows/release-beta.yml')
        self.assertIn('test_630_comment_compact_progress.py',wf)
        self.assertIn('workflow_dispatch:',wf)
        self.assertIn('tags:',wf)
        self.assertIn('lua5.1 tools/test_630_comment_compact_ui.lua',wf)
        self.assertIn('luajit tools/test_630_comment_compact_ui.lua',wf)
if __name__=='__main__':unittest.main()
