"""Current interaction/layout source contracts; excludes device E-Ink validation."""
from pathlib import Path
import re, unittest

ROOT=Path(__file__).resolve().parents[1]
PLUGIN=ROOT/'miuread.koplugin'
def read(p): return (PLUGIN/p).read_text(encoding='utf-8')

class UIContract(unittest.TestCase):
    def test_release_versions_match(self):
        meta=re.search(r'version\s*=\s*"([^"]+)"',read('_meta.lua'))
        config=re.search(r'VERSION\s*=\s*"([^"]+)"',read('miuread/config.lua'))
        self.assertRegex(meta.group(1), r'^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$')
        self.assertEqual(meta.group(1),config.group(1))

    def test_text_box_has_explicit_bounded_height(self):
        component=read('miuread/ui_components.lua')
        region=component.split('function Ui.textbox(',1)[1].split('function Ui.icon(',1)[0]
        self.assertIn('TextBoxWidget:new{',region)
        self.assertIn('height = bounded_height',region)
        self.assertIn('if opts.natural_height == true then bounded_height = nil end',region)
        self.assertIn('height_overflow_show_ellipsis',region)
        self.assertIn('return Ui.align(child, width, layout_h',region)

    def test_reader_list_bounded_and_page_not_fixed_to_four(self):
        reader=read('miuread/reader_list_dialog.lua')
        self.assertIn('possible_slots',reader)
        self.assertIn('math.min(requested_page_size, possible_slots)',reader)
        self.assertIn('Ui.textbox(',reader)
        self.assertIn('on_page_change',reader)

    def test_control_center_paging_keeps_navigation_in_frame(self):
        center=read('miuread/reader_control_center.lua')
        self.assertIn('capacity = math.max(1',center)
        self.assertIn('math.floor(row_budget / math.max(1,item_h)) - 2',center)
        self.assertIn('keep_open=true',center)
        self.assertIn('if item.keep_open == true',center)
        self.assertIn('self._section_page',center)

    def test_comment_display_never_implies_network_fetch(self):
        main=read('main.lua')
        self.assertIn('label="查看本章评论"',main)
        self.assertIn('label="我的评论收藏"',main)
        self.assertIn('self._opening_cached_comment',main)
        self.assertIn('label="获取/更新当前章节评论"',main)

    def test_book_and_download_menu_actions_not_removed(self):
        main=read('main.lua')
        self.assertIn('text="已下载书籍"',main)
        self.assertIn('text="插件下载任务"',main)
        self.assertIn('text="下载扩展"',main)
        self.assertIn('text="任务类型"',main)
        variant=read('miuread/book_local_files_dialog.lua')
        self.assertIn('高级文件管理',variant)
        self.assertIn('仅删除',variant)
        self.assertIn('删除书籍（清理本机全部关联数据）',variant)

    def test_version_and_about_and_ux(self):
        code=read('main.lua')
        self.assertIn('检查更新',code)
        self.assertIn('许可证：AGPL-3.0-only',code)
        self.assertIn('主页顶栏',code)
        self.assertIn('确认同步',code)

    def test_data_ownership_preserved(self):
        delete=read('miuread/book_delete_service.lua')
        self.assertNotIn('ThoughtFavorites.remove', delete)
        self.assertIn('upload_only=true',read('main.lua'))
        self.assertIn('merge_chapter(',read('miuread/thought_database.lua'))

if __name__=='__main__': unittest.main()
