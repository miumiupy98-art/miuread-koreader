"""beta.8 targeted contracts: freeze old sync/upload, prepare real Web source.

Offline source contracts only: not a replacement for KOReader device tests.
"""
from pathlib import Path
import unittest,re
ROOT=Path(__file__).resolve().parents[1]
def read(name):return (ROOT/name).read_text(encoding="utf-8")
MAIN="miuread.koplugin/main.lua"
SRC="miuread.koplugin/miuread/source_position.lua"
SYNC="miuread.koplugin/miuread/sync.lua"
class ProgressRebuildContract(unittest.TestCase):
    def test_version(self):
        self.assertIn('VERSION = "6.5.0-beta.8"',read('miuread.koplugin/miuread/config.lua'))
        self.assertIn('version = "6.5.0-beta.8"',read('miuread.koplugin/_meta.lua'))
        self.assertTrue(read('CHANGELOG.md').startswith('## 6.5.0-beta.8'))
    def test_web_coordinate_authority(self):
        s=read(SRC)
        self.assertIn('function M.ensureWebChapterSource(',s)
        self.assertIn('fresh_context=true',s)
        self.assertIn('validate_anchor_source(cached,anchor)',s)
        self.assertIn('validate_anchor_source(coord_html,anchor)',s)
        self.assertIn('web_coordinate_source_not_authoritative',s)
        downloader=read('miuread.koplugin/miuread/downloader.lua')
        self.assertIn('native_source_requires_web_verification',downloader)
        self.assertIn('coordinate_source_authoritative==false',downloader)
    def test_prewarm_is_worker_only_and_debounced(self):
        s=read(SYNC)
        self.assertIn('function Sync:prepare_current_web_source(',s)
        self.assertIn('self.async:run("web_source_preparation"',s)
        m=read(MAIN)
        self.assertIn('function Plugin:_schedule_current_web_source_prewarm(',m)
        self.assertIn('self:_schedule_current_web_source_prewarm(9)',m)
        self.assertIn('self:_schedule_current_web_source_prewarm(7)',m)
        block=m.split('function Plugin:_schedule_current_web_source_prewarm(',1)[1].split('function Plugin:onPageUpdate(',1)[0]
        self.assertNotIn('_submit_progress_snapshot',block)
    def test_pending_preflight_never_force_writes(self):
        m=read(MAIN)
        block=m.split('function Plugin:_submit_saved_pending_progress(',1)[1].split('function Plugin:_submit_all_saved_pending_progress(',1)[0]
        self.assertIn('web_only=true,verify_only=true',block)
        self.assertIn('trusted_verified_anchor',block)
        self.assertIn('PR.same_position(remote,position)',block)
        self.assertIn('PR.same_position(remote,anchor)',block)
        self.assertIn('parked(',block)
        self.assertNotIn('force_write=true',block)
        self.assertIn('self:_commit_progress_verified(',block)
    def test_open_reconciliation_does_not_force_kindle(self):
        block=read(MAIN).split('function Plugin:on_remote_progress(',1)[1].split('function Plugin:',1)[0]
        self.assertIn('_G.__MIUREAD_POSITION_RESOLUTION.decide',block)
        self.assertNotIn('kindle_coordinate_authoritative',block)
    def test_saved_anchor_recovery_unchanged(self):
        m=read(MAIN);s=read(SYNC)
        self.assertIn('function Plugin:_recover_pending_progress_anchor(',m)
        self.assertIn('function Sync:resolve_saved_progress_anchor(',s)
        self.assertIn('SourcePosition.locate(reader,record_snapshot,anchor,{cache_only=true})',s)
        self.assertIn('SourcePosition.locate(reader,record_snapshot,anchor,{',s)
        self.assertIn('function Plugin:_verify_progress_submission(',m)
if __name__=="__main__":unittest.main()
