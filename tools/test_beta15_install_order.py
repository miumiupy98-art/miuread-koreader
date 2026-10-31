from pathlib import Path
import hashlib,re
base=Path(__file__).resolve().parent.parent
old=Path('/mnt/data/beta14_work/miuread-koreader')
plugin=base/'miuread.koplugin'
d=(plugin/'miuread/downloader.lua').read_text()
seg=d[d.index('function Downloader:_book_once'):d.index('function Downloader:book')]
assert 'local record = self:_save(' in seg
assert 'Post.begin(self.store,record,book,opt)' in seg
assert 'pcall(Post.run,self.store,record,book,self.reader,opt' in seg
assert seg.index('local record = self:_save(')<seg.index('Post.begin(self.store,record,book,opt)')<seg.index('pcall(Post.run,self.store,record,book,self.reader,opt')
assert 'Gate.prepare(' not in seg
assert 'install blocked' not in seg
assert 'Web 定位仍未全部验证' not in seg
assert 'resource' in d.lower() and 'EpubInstaller.validate' in d and 'EpubInstaller.install' in d
assert 'PostInstall.resume(self.store,book,opt)' in seg
post=(plugin/'miuread/post_install_web.lua').read_text()
assert 'Legacy.perform' in post
assert 'state.next_index=index+1' in post
assert 'state.failed=state.failed+1' in post
assert 'if not result_ok then result={ok=false' in post
assert 'same_account' in post and 'identity_ok' in post
assert 'require("miuread.source_position")' not in post and 'No progress/readtime/POST APIs' in post
assert 'download cancelled' in post and '__MIUREAD_HIBERNATE__' in post
assert 'process_one(' not in post
for name in ['miuread/sync.lua','miuread/readtime_controller.lua','miuread/download_transport.lua','miuread/source_position.lua','miuread/wr_co.lua','miuread/legacy_coordinate_backfill.lua']:
    if name.endswith('legacy_coordinate_backfill.lua'):continue
    assert (plugin/name).read_bytes()==(old/'miuread.koplugin'/name).read_bytes(),name
assert (base/'.github/workflows/release-beta.yml').read_bytes()==(old/'.github/workflows/release-beta.yml').read_bytes()
assert (plugin/'miuread/config.lua').read_text().find('VERSION = "6.5.0-beta.16"')>=0
assert (plugin/'_meta.lua').read_text().find('version = "6.5.0-beta.16"')>=0
print('PASS beta16 retained install before Web, no gate, resume, frozen sync/readtime/transport/release')
