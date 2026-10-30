"""Prevent the Beta preflight from silently omitting Lua release checks."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]

class ReleaseLuaSuiteSync(unittest.TestCase):
    def test_preflight_matches_publishing_lua_tests(self):
        workflow = (ROOT / '.github/workflows/release-beta.yml').read_text(encoding='utf-8')
        gate = workflow.split('- name: Run Lua syntax checks and release regression verifier', 1)[1].split('- name: Verify E-Ink archives', 1)[0]
        commands = re.findall(r'^          ((?:lua5\.1|luajit) tools/test_[\w-]+\.lua)\s*$', gate, re.M)
        script = (ROOT / 'tools/run_beta_release_lua_suite.sh').read_text(encoding='utf-8')
        run_commands = re.findall(r'^((?:lua5\.1|luajit) tools/test_[\w-]+\.lua)\s*$', script, re.M)
        self.assertGreater(len(commands), 60)
        self.assertEqual(run_commands, commands)
        preflight = (ROOT / '.github/workflows/release-check.yml').read_text(encoding='utf-8')
        self.assertIn('bash tools/run_beta_release_lua_suite.sh', preflight)
        self.assertIn("if: env.RELEASE_CHANNEL == 'beta'", preflight)

if __name__ == '__main__':
    unittest.main()
