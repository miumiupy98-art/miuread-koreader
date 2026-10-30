import json
from pathlib import Path
import re
import unittest

ROOT=Path(__file__).resolve().parents[1]

class ReleaseInventory(unittest.TestCase):
    def test_every_beta_lua_test_is_accounted_for(self):
        workflow=(ROOT/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
        executed=set(re.findall(r'(?:lua5\.1|luajit) tools/(test_[^\s]+\.lua)',workflow))
        all_tests={p.name for p in (ROOT/'tools').glob('test_*.lua')}
        excluded=json.loads((ROOT/'tools/release_test_inventory.json').read_text(encoding='utf-8'))['beta_release_lua_exclusions']
        self.assertEqual(all_tests - executed,set(excluded))
        self.assertTrue(all(isinstance(reason,str) and len(reason)>=30 for reason in excluded.values()))
        self.assertFalse(set(excluded) & executed)

if __name__=='__main__':unittest.main()
