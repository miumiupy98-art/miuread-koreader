"""Source and integration contracts for beta.11; no live Kindle claims."""
import unittest,hashlib,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE_HASHES={'_submit_saved_pending_progress': 'e827d9499af80d933369e39f8f2117a1ad4bc745d71d062a1e97baa7c3882d45', '_commit_progress_verified': '997e7ef5647bc2c88bd90788e47a20ca06e8e2756e60446b870df761c5f0d496', '_verify_progress_submission': '0c08a90c91706e35de8e5dfade010ab1f704988554bae912e4f6e4d4ed0d0661', '_submit_progress_snapshot': '9bc9426b46dcb07018304bb5b87609ef1cfd11f612b3d2ed7b9eada011226153', 'on_remote_progress': 'd66069b0bfd6f6d1fa3abf057fbd99b6a570476ac21f3ddcfc78a5a67bba14a6', '_reading_end_sync': '23663f025429fdfe23692bb83e6434f37b5530b1fb73254d0a24998a33f22c92', '_save_pending_progress': '7b297e9c00222c740f9ac29f2e06337c9eb32cf1cd92d42e81eb5ae9ca7463af'}
SOURCE_FILE_HASHES={'miuread.koplugin/miuread/sync.lua': 'd7d5cae7abbf69f09e28b4efe85d0caa3641883b068a029ce63794483d876323', 'miuread.koplugin/miuread/readtime_controller.lua': '4d92caf01181f5dc90f81202d17fbb4b5dd8988bcc1201c93024a79304e6909c', 'miuread.koplugin/miuread/download_task.lua': '21f45677c93b57047c95fb25cc5300ad1bf553c7b08c7567e050b01baace8a27', 'miuread.koplugin/miuread/download_source_gate.lua': 'd01ed6b104badaf75c6d771d7fc30b960416d1d68bab007cfab78b2d098ed114', 'miuread.koplugin/miuread/source_position.lua': '3d30a7ef5849dee81784da1714eecaf3aaae1d29b5158c381a5dbaa9066bd223'}
def read(p):return (ROOT/p).read_text(encoding='utf8')
class Beta11Contracts(unittest.TestCase):
    def test_frozen_progress_functions(self):
        source=read('miuread.koplugin/main.lua')
        
        funcs=['_submit_saved_pending_progress','_commit_progress_verified','_verify_progress_submission','_submit_progress_snapshot','on_remote_progress','_reading_end_sync','_save_pending_progress']
        for name in funcs:
            def extract(text):
                m=re.search(r'function Plugin:'+re.escape(name)+r'\(',text)
                self.assertIsNotNone(m)
                end=re.search(r'\nfunction Plugin:',text[m.end():])
                return text[m.start():m.end()+end.start() if end else len(text)]
            self.assertEqual(hashlib.sha256(extract(source).encode()).hexdigest(),BASE_HASHES[name],name)
    def test_readtime_files_unchanged(self):
        for p in ['miuread.koplugin/miuread/sync.lua','miuread.koplugin/miuread/readtime_controller.lua','miuread.koplugin/miuread/download_task.lua','miuread.koplugin/miuread/download_source_gate.lua','miuread.koplugin/miuread/source_position.lua']:
            self.assertEqual(hashlib.sha256((ROOT/p).read_bytes()).hexdigest(),SOURCE_FILE_HASHES[p],p)
    def test_retry_isolated_and_persistent(self):
        source=read('miuread.koplugin/miuread/download_coordinate_retry.lua')
        self.assertIn('download_coordinate_retry_v1',source)
        self.assertIn('store:set(KEY,rows)',source)
        self.assertIn('row.status="needs_attention"',source)
        self.assertIn('result._from_checkpoint=true',source)
        self.assertIn('result._coordinate_auto_retry=true',source)
        for forbidden in ['upload_progress_only(', 'post_progress(', 'force_write=true','_submit_progress_snapshot(']: self.assertNotIn(forbidden,source)
    def test_gate_precedes_install_and_transient_tagging(self):
        source=read('miuread.koplugin/miuread/downloader.lua')
        self.assertIn('pcall(Gate.prepare,{',source)
        self.assertLess(source.index('pcall(Gate.prepare,{'),source.index('local record = self:_save(book, chapters'))
        self.assertIn('[MiuReadWebCoordinatePending]',source)
    def test_lifecycle_guard_and_queued_priority(self):
        main=read('miuread.koplugin/main.lua')
        for key in ['function Plugin:_coordinate_retry_pump(', 'self:_active_reader_ui()', 'PowerState.state()~="NORMAL"', 'or #(self.store:download_queue() or {})>0', 'Retry.defer(', 'self:_schedule_coordinate_retry("startup")', 'self:_schedule_coordinate_retry("device_resumed")', 'self:_schedule_coordinate_retry("download_finished")']:
            self.assertIn(key,main)
        self.assertIn('state.error_kind~="coordinate_pending"',main)
        self.assertIn('if coordinate_pending then\n            if #self.store:download_queue()>0 then',main)
    def test_version(self):
        self.assertIn('6.5.0-beta.11',read('miuread.koplugin/miuread/config.lua'))
        self.assertIn('6.5.0-beta.11',read('miuread.koplugin/_meta.lua'))
if __name__=='__main__': unittest.main()
