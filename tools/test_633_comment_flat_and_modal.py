"""6.3.0-beta.3: compact ink bar and no native blank-grid download prompts."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
def read(p):return (R/p).read_text(encoding='utf-8')
class Beta633(unittest.TestCase):
    def test_flat_ink_button_keep_tap_area(self):
        t=read('miuread.koplugin/miuread/comment_progress.lua')
        button=t.split('function Compact:_button(',1)[1].split('function Compact:_build()',1)[0]
        self.assertIn('TapBox:new{dimen=Geom:new{w=width,h=height}',button)
        self.assertIn('CenterContainer:new{dimen=Geom:new{w=width,h=height}',button)
        self.assertNotIn('FrameContainer:new',button)
        self.assertIn('self:_button("minimize","后台"',t)
        self.assertIn('bordersize=frame_border',t)
        self.assertIn('color=Blitbuffer.COLOR_BLACK',t)
        self.assertNotIn('FrameContainer:new',button)
        self.assertIn('Ui.icon("comment"',t)
        self.assertIn('math.min(4,Screen:scaleBySize(3))',t)
        self.assertIn('old_region',t)
        self.assertIn('UIManager:setDirty("all","ui",Geom:new',t)
    def test_download_choices_reader_and_home_same_family(self):
        m=read('miuread.koplugin/main.lua')
        f=m.split('function Plugin:choose_download_mode(',1)[1].split('function Plugin:choose_download(',1)[0]
        self.assertEqual(f.count('return ActionSheet.show{'),2)
        self.assertNotIn('ButtonDialog:new',f)
        for text in ('后台下载','留在当前页面下载','退出阅读后下载','下载方式 · 正文与公开想法'):
            self.assertIn(text,f)
        self.assertIn('self:_queue_download(b,opt,open_after,{defer_until_reader_closed=true',f)
        self.assertIn('b4_content_only_options(opt)',f)
    def test_preflight_notices_preserved_without_native_dialog(self):
        t=read('miuread.koplugin/main.lua').split('function Plugin:_download_preflight(',1)[1].split('-- Preserve explicit edition choice.',1)[0]
        for term in ('low_battery','low_storage','self:_set_notice_enabled','self:show_downloads()', 'free<64*1024*1024','free<256*1024*1024'):
            self.assertIn(term,t)
        self.assertNotIn('ButtonDialog:new',t)
        self.assertIn('ActionSheet.show{',t)
    def test_fallback_page_bounded_and_not_native_blank_grid(self):
        s=read('miuread.koplugin/miuread/action_sheet.lua')
        f=s.split('local function show_fallback(',1)[1].split('local ActionSheet = {}',1)[0]
        self.assertIn('ReaderSettingsDialog.show',f)
        self.assertNotIn('ButtonDialog:new',f)
        self.assertIn('菜单暂时无法显示',f)
        self.assertIn('if #rows>=MAX_PRIMARY_ACTIONS then break end',f)
    def test_release_gate_and_metadata(self):
        from re import search
        config=read('miuread.koplugin/miuread/config.lua')
        version=search(r'VERSION\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+)"',config)
        self.assertIsNotNone(version)
        self.assertIn('version = "'+version.group(1)+'"',read('miuread.koplugin/_meta.lua'))
        self.assertIn('## '+version.group(1),read('CHANGELOG.md'))
        self.assertIn('## 6.3.0-beta.3',read('CHANGELOG.md'))
        w=read('.github/workflows/release-beta.yml')
        self.assertIn('test_633_comment_flat_and_modal.py',w)
        self.assertIn('test_633_download_choices.lua',w)
        self.assertIn('test_633_action_sheet_fallback.lua',w)
if __name__=='__main__':unittest.main()
