"""Checks the actual source and release wiring of Home notes choice."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/'miuread.koplugin/main.lua').read_text(encoding='utf-8')
WORKFLOW=(ROOT/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')

class HomeDownloadChoice(unittest.TestCase):
    def test_both_notes_entry_paths_use_home_sheet(self):
        part=MAIN[MAIN.index('function Plugin:_home_variant_download_action('):MAIN.index('function Plugin:_home_open_book(')]
        self.assertEqual(part.count('{home_sheet=true}'),2)
        self.assertIn('annotations=annotations==true',part)
        self.assertIn('b4_content_only_options(',part)

    def test_all_modes_avoid_legacy_blank_dialog(self):
        part=MAIN[MAIN.index('function Plugin:choose_download_mode('):MAIN.index('function Plugin:choose_download(')]
        self.assertIn('return ActionSheet.show{',part)
        self.assertNotIn('dialog=ButtonDialog:new{title="下载方式"',part)
        self.assertIn('return ActionSheet.show{',part)
        self.assertIn('columns=1',part)
        self.assertIn('callback=function() start(true) end',part)
        self.assertIn('callback=function() start(false) end',part)
        self.assertIn('callback=function() end',part)

    def test_icons_exist_and_ci_runs_lua_simulation(self):
        icons=ROOT/'miuread.koplugin/resources/icons/miuread'
        for name in ('cloud','download','close'):
            self.assertTrue((icons/f'{name}.svg').is_file(),name)
        self.assertIn("test_632_home_download_choice.lua",WORKFLOW)
        self.assertIn("test_632_home_download_choice.py",WORKFLOW)

if __name__=='__main__': unittest.main()
