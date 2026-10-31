"""Beta.10 non-regression contracts; hashes are from user-provided beta.9 main.lua."""
from pathlib import Path
import hashlib,re,unittest
ROOT=Path(__file__).resolve().parents[1]
def read(p):return (ROOT/p).read_text(encoding="utf8")
BASE_HASHES={'_submit_saved_pending_progress': 'e827d9499af80d933369e39f8f2117a1ad4bc745d71d062a1e97baa7c3882d45', '_commit_progress_verified': '997e7ef5647bc2c88bd90788e47a20ca06e8e2756e60446b870df761c5f0d496', '_verify_progress_submission': '0c08a90c91706e35de8e5dfade010ab1f704988554bae912e4f6e4d4ed0d0661', '_submit_progress_snapshot': '9bc9426b46dcb07018304bb5b87609ef1cfd11f612b3d2ed7b9eada011226153', 'on_remote_progress': 'd66069b0bfd6f6d1fa3abf057fbd99b6a570476ac21f3ddcfc78a5a67bba14a6', '_reading_end_sync': '23663f025429fdfe23692bb83e6434f37b5530b1fb73254d0a24998a33f22c92', '_save_pending_progress': '7b297e9c00222c740f9ac29f2e06337c9eb32cf1cd92d42e81eb5ae9ca7463af'}
class Beta10Contract(unittest.TestCase):
    def test_frozen_progress_functions(self):
        source=read('miuread.koplugin/main.lua')
        for name,expected in BASE_HASHES.items():
            m=re.search(r'function Plugin:'+re.escape(name)+r'\(',source)
            self.assertIsNotNone(m,name)
            end=re.search(r'\nfunction Plugin:',source[m.end():])
            block=source[m.start():m.end()+end.start() if end else len(source)]
            self.assertEqual(hashlib.sha256(block.encode()).hexdigest(),expected,name)
    def test_download_gate_before_epub_install(self):
        source=read('miuread.koplugin/miuread/downloader.lua')
        self.assertTrue('Gate.prepare({' in source or 'pcall(Gate.prepare,{' in source)
        self.assertLess(source.index('pcall(Gate.prepare,{' if 'pcall(Gate.prepare,{' in source else 'Gate.prepare({'),source.index('local record = self:_save(book, chapters',source.index('pcall(Gate.prepare,{' if 'pcall(Gate.prepare,{' in source else 'Gate.prepare({')))
        self.assertIn('not ready or ready.complete~=true or ready.verified~=ready.expected',source)
        self.assertIn('[MiuReadWebCoordinatePending]',source)
        self.assertIn('source_verification_anchors',read('miuread.koplugin/miuread/download_source_gate.lua'))
    def test_reader_time_and_comment_ports(self):
        main=read('miuread.koplugin/main.lua')
        sync=read('miuread.koplugin/miuread/sync.lua')
        store=read('miuread.koplugin/miuread/store.lua')
        self.assertIn('function Store:web_auth_revision()',store)
        self.assertIn('auth.web_auth_revision or auth.auth_revision',sync)
        self.assertIn('function Plugin:_schedule_next_comment_preload(',main)
        self.assertIn('function Plugin:_home_sync_management_menu(',main)
        self.assertIn('function M.validateDownloadChapter(',read('miuread.koplugin/miuread/source_position.lua'))
        self.assertIn('coordinate = 300, package = 300',read('miuread.koplugin/miuread/config.lua'))
    def test_no_download_progress_post(self):
        gate=read('miuread.koplugin/miuread/download_source_gate.lua')
        for forbidden in ['upload_progress_only(', '_submit_progress_snapshot(', 'force_write=true', 'post_progress(', 'on_remote_progress(']:
            self.assertNotIn(forbidden,gate)
    def test_no_premature_download_complete(self):
        task=read('miuread.koplugin/miuread/download_task.lua')
        self.assertIn('stage == "coordinate"',task)
        self.assertIn('percent = 0.94 + 0.02',task)
        self.assertIn('percent = 0.96 + 0.03',task)
        main=read('miuread.koplugin/main.lua')
        self.assertIn('Web 定位待补全',main)
        self.assertIn('coordinate_pending',main)
if __name__=='__main__':unittest.main()
