"""beta.5 release-gate contract for e-ink one-line notices and comment menu."""
from pathlib import Path
import unittest

BASE = Path(__file__).resolve().parents[1]
PLUGIN = BASE / 'miuread.koplugin'

def src(path):
    return (PLUGIN / path).read_text(encoding='utf-8')

class Beta5Notices(unittest.TestCase):
    def test_comment_menu_exact_items_and_actions(self):
        main = src('main.lua')
        body = main.split('function Plugin:_comment_fetch_mode_menu(', 1)[1].split('function Plugin:_show_reader_comment_center', 1)[0]
        labels = ['当前章节', '指定章节范围', '更新当前章节', '更新指定范围']
        offsets = [body.index('label="' + label + '"') for label in labels]
        self.assertEqual(offsets, sorted(offsets))
        self.assertNotIn('自选范围（默认）', body)
        self.assertIn('select_range(false)', body)
        self.assertIn('select_range(true)', body)
        self.assertIn('_fetch_current_chapter_comments(false,back_callback)', body)
        self.assertIn('_fetch_current_chapter_comments(true,back_callback)', body)
        self.assertIn('opaque_fullscreen=true', body)
        # The range editor still defaults to at most ten chapters and shares one picker.
        self.assertIn('local last=math.min(#rows,first+9)', main)
        self.assertIn('function Plugin:_choose_comment_range(force,back_callback)', main)

    def test_all_sync_notice_events_have_monochrome_icons(self):
        main = src('main.lua')
        toast = src('miuread/status_toast.lua')
        icon_files = {p.stem for p in (PLUGIN/'resources/icons/miuread').glob('*.svg')}
        names = {'reading':'refresh', 'read_ok':'check', 'read_failed':'warning',
                 'uploaded':'upload', 'time_started':'progress',
                 'comments_done':'check','comments_failed':'warning'}
        for event, icon in names.items():
            self.assertIn(event+' = {icon="'+icon+'"', main)
            self.assertIn(icon,icon_files)
        for clause in ('single_line=true', 'title=""', 'icon_key=notice.icon',
                       'self:_sync_notice("time_started")','self:_sync_notice("reading"',
                       'self:_sync_notice("read_ok")','self:_sync_notice("read_failed")',
                       'self:_sync_notice("uploaded")'):
            self.assertIn(clause,main)
        self.assertIn('TextWidget:new{',toast)
        self.assertIn('truncate_with_ellipsis = true',toast)
        self.assertIn('HorizontalGroup:new{',toast)
        self.assertIn('Ui.icon(icon_key,',toast)
        self.assertIn('single_line = opts.single_line == true',toast)
        self.assertIn('repaint_uncovered(old_dimen)',toast)
        self.assertNotIn('self:toast("本次阅读时间已开始同步",3)',main)

    def test_no_sync_algorithm_changes_implicitly_required(self):
        main=src('main.lua')
        self.assertIn('if self._time_sync_first_notice_shown==true or not self:_time_first_success_notice_enabled()',main)
        self.assertIn('if status and (status.recovery_probe==true or tonumber(status.elapsed_seconds or 0)<=0)',main)
        self.assertIn('return self:_start_comment_range(book,{row},1,1,force==true)',main)
        self.assertIn('runtime.async:run("comment_range_chapter"',main)
        self.assertIn('self:_submit_progress_snapshot(',main)

if __name__ == '__main__': unittest.main()
