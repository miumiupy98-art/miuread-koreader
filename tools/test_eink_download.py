"""Offline native-package and routing regressions (lupa + cryptography).

Fixtures contain only synthetic text/media. No authenticated service is called.
"""
import base64
import argparse
import binascii
import json
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
import zlib
from zipfile import ZipFile

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from lupa.luajit21 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]
PASSWORD = b"synthetic-zip-password"
VID = b"1234567890"
# E-Ink 2.1.2 ChapterResp.aesDecryptKey uses unmodified UTF-8 digits.
# The phone nativeDecryptHeaderKey byte-remapping scheme is a different path.
MATERIAL = (VID * 4)[:32]
pad = 16 - len(PASSWORD) % 16
enc = Cipher(algorithms.AES(MATERIAL[:16]), modes.CBC(MATERIAL[16:])).encryptor()
ENVELOPE = base64.b64encode(enc.update(PASSWORD + bytes([pad]) * pad) + enc.finalize())
assert ENVELOPE == b"UbIHjRka9yd9dsTStdzS2t1GNgp1YTZE45HkY3jSBx0="


def encrypt_zip(data, check):
    """Independent traditional ZIP writer for stored and raw-deflate fixtures."""
    table = []
    for value in range(256):
        for _ in range(8):
            value = (value >> 1) ^ (0xEDB88320 if value & 1 else 0)
        table.append(value)
    keys = [0x12345678, 0x23456789, 0x34567890]

    def update(value):
        keys[0] = (keys[0] >> 8) ^ table[(keys[0] ^ value) & 255]
        keys[1] = ((keys[1] + (keys[0] & 255)) * 134775813 + 1) & 0xFFFFFFFF
        keys[2] = (keys[2] >> 8) ^ table[(keys[2] ^ (keys[1] >> 24)) & 255]

    for value in PASSWORD:
        update(value)
    output = bytearray()
    for value in bytes(range(11)) + bytes([check]) + data:
        temp = keys[2] | 2
        output.append(value ^ (((temp * (temp ^ 1)) >> 8) & 255))
        update(value)
    return bytes(output)


def archive(entries, method=8, descriptor=False, corrupt=False):
    local, central = bytearray(), bytearray()
    for name, data in entries:
        name = name.encode()
        crc = binascii.crc32(data)
        flags = 1 | (8 if descriptor else 0)
        compressed = zlib.compress(data)[2:-4] if method == 8 else data
        compressed = encrypt_zip(compressed, 0 if descriptor else crc >> 24)
        if corrupt:
            compressed = compressed[:-1] + bytes([compressed[-1] ^ 1])
        offset = len(local)
        local += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, 0, 0,
                             0 if descriptor else crc, 0 if descriptor else len(compressed),
                             0 if descriptor else len(data), len(name), 0) + name + compressed
        if descriptor:
            local += struct.pack("<IIII", 0x08074B50, crc, len(compressed), len(data))
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, flags, method, 0, 0,
                               crc, len(compressed), len(data), len(name), 0, 0, 0, 0, 0, offset) + name
    return bytes(local + central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), len(local), 0))


def runtime(zlib_path=None, root=None):
    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)

    def to_lua(value):
        if isinstance(value, dict):
            return lua.table_from({key.encode(): to_lua(item) for key, item in value.items()})
        if isinstance(value, list):
            return lua.table_from([to_lua(item) for item in value])
        return value.encode() if isinstance(value, str) else value

    def from_lua(value):
        if lua_type(value) == 'table':
            keys = list(value.keys())
            if keys and set(keys) == set(range(1, len(keys) + 1)):
                return [from_lua(value[index]) for index in range(1, len(keys) + 1)]
            return {from_lua(key): from_lua(item) for key, item in value.items()}
        return value.decode() if isinstance(value, bytes) else value

    def attributes(value, key=None):
        path = Path(value.decode())
        if not path.exists():
            return None
        stat = path.stat()
        result = {b'mode': b'directory' if path.is_dir() else b'file', b'size': stat.st_size, b'modification': stat.st_mtime}
        return result.get(key) if key else lua.table_from(result)

    def checked(value):
        path = Path(value.decode()).resolve()
        assert root is not None and (path == root.resolve() or path.is_relative_to(root.resolve()))
        return path

    def mkdir(value):
        checked(value).mkdir(parents=True, exist_ok=True)
        return True

    def rmdir(value):
        path = checked(value)
        assert path != root.resolve()
        path.rmdir()
        return True

    def aes_ecb(data, key):
        dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        return dec.update(data) + dec.finalize()

    def inflate(data, expected):
        result = zlib.decompress(data, -15)
        assert len(result) == expected
        return result

    lua.globals().json_encode = lambda value: json.dumps(from_lua(value), ensure_ascii=False, separators=(',', ':')).encode()
    lua.globals().json_decode = lambda value: to_lua(json.loads(value))
    lua.globals().host_attributes = attributes
    lua.globals().host_mkdir = mkdir
    lua.globals().host_rmdir = rmdir
    lua.globals().host_directory_entries = lambda value: lua.table_from([item.name.encode() for item in checked(value).iterdir()])
    lua.globals().host_free_space = lambda value: shutil.disk_usage(checked(value)).free
    lua.globals().host_split_chars = lambda value: lua.table_from([char.encode() for char in value.decode()])
    lua.globals().py_aes = aes_ecb
    lua.globals().py_inflate = inflate
    lua.globals().zlib_path = zlib_path.encode() if zlib_path else None
    lua.execute(b'''
        package.path='miuread.koplugin/?.lua;'..package.path
        package.preload['json']=function() return {encode=json_encode,decode=json_decode} end
        package.preload['util']=function() return {
            splitToChars=function(value) return host_split_chars(value) end,
            trim=function(value) return tostring(value):gsub('^%s+',''):gsub('%s+$','') end,
            splitToArray=function(value,delimiter)
                local out,from={},1
                while true do
                    local first,last=value:find(delimiter,from,true)
                    if not first then out[#out+1]=value:sub(from); return out end
                    out[#out+1]=value:sub(from,first-1); from=last+1
                end
            end,
        } end
        package.preload['logger']=function() return {info=function() end,warn=function() end,dbg=function() end} end
        package.preload['libs/libkoreader-lfs']=function() return {
            attributes=host_attributes,mkdir=host_mkdir,rmdir=host_rmdir,dir=function(path)
                local entries,index=host_directory_entries(path),0
                return function() index=index+1; return entries[index] end
            end,
        } end
        require('miuread.util').free_space=function(path) return host_free_space(path) end
        package.preload['ffi/crypto']=function() return {
            get_aes_ecb_cipher=function() return 'AES-128-ECB' end,
            evp_decrypt=function(_,input,key) return py_aes(input,key),#input end,
        } end
        if zlib_path then
            local ffi=require('ffi')
            ffi.loadlib=function(name) assert(name=='z'); return ffi.load(zlib_path) end
        else
            -- --zlib exercises the actual production FFI inflate adapter.
            require('miuread.eink_crypto').inflate=function(data,size) return py_inflate(data,size) end
        end
    ''')
    return lua


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zlib', help='Shared zlib library for testing the production FFI inflate adapter')
    args = parser.parse_args()
    import os
    os.chdir(ROOT)
    with tempfile.TemporaryDirectory(prefix="miuread-eink-") as temporary:
        folder = Path(temporary)
        lua = runtime(args.zlib, folder)
        lua.globals().fixture_root = folder.as_posix().encode()
        lua.globals().envelope = ENVELOPE
        lua.globals().vid = VID
        lua.execute(b"assert(require('miuread.eink_crypto').password(envelope,vid)=='synthetic-zip-password')")
        # Reproduce E-Ink's UTF-8 material across VID and PKCS#7 boundaries;
        # fixtures are encrypted independently of the production Lua decoder.
        password = lua.eval(b"require('miuread.eink_crypto').password")
        for account, secret in ((b"0", b"x"), (b"123456789", b"16-byte-password"),
                                (b"9876543210123456", bytes(range(32))),
                                (b"123456789012345678", b"synthetic")):
            material = bytes(account[i % len(account)] for i in range(32))
            padding = 16 - len(secret) % 16
            encryptor = Cipher(algorithms.AES(material[:16]), modes.CBC(material[16:])).encryptor()
            wrapped = base64.b64encode(encryptor.update(secret + bytes([padding]) * padding) + encryptor.finalize())
            assert password(wrapped, account) == secret
        # This is the old phone-remapped synthetic envelope, with the same VID
        # and password as the E-Ink fixture. Never silently try the other scheme.
        lua.execute(b"assert(not pcall(require('miuread.eink_crypto').password,'6HEiGf8TY2JGo/aK1XCpRbbZSGRp7aXU0Rki2d7wXXw=',vid))")
        # Keep strict validation of all padding bytes after the protocol fix.
        malformed = b"padding-test" + b"\x01\x02\x03\x04"
        encryptor = Cipher(algorithms.AES(MATERIAL[:16]), modes.CBC(MATERIAL[16:])).encryptor()
        lua.globals().invalid_padding = base64.b64encode(encryptor.update(malformed) + encryptor.finalize())
        lua.execute(b"assert(not pcall(require('miuread.eink_crypto').password,invalid_padding,vid))")
        print('E-Ink ASCII key derivation, phone-scheme rejection and strict padding: PASS')
        lua.execute(b"assert(not pcall(require('miuread.eink_crypto').password,envelope,'999')); assert(not pcall(require('miuread.eink_crypto').password,'bad!',vid))")
        lua.execute("""
            local crypto=require('miuread.eink_crypto')
            local adapter=package.loaded['ffi/crypto']
            package.loaded['ffi/crypto']={}
            local ok,err=pcall(crypto.password,envelope,vid)
            assert(not ok and tostring(err):find('E-Ink 解密组件不可用',1,true))
            package.loaded['ffi/crypto']=adapter
            assert(crypto.password(envelope,vid)=='synthetic-zip-password')
        """.encode())
        unavailable = runtime('miuread-unavailable-zlib-for-test')
        unavailable.execute("""
            local crypto=require('miuread.eink_crypto')
            for _=1,2 do
                local ok,err=pcall(crypto.inflate,'synthetic',1)
                assert(not ok and tostring(err):find('E-Ink 解压组件不可用',1,true))
            end
        """.encode())
        print('Native crypto/inflate capability diagnostics: PASS')
        read = lua.eval(b"function(path) return require('miuread.eink_archive').read(path,envelope,vid,fixture_root,{}) end")
        html = '<html><head></head><body><p id="p1">测试正文 👋</p></body></html>'.encode()
        entries = [("2.xhtml", html), ("style.css", b"p{color:black}"), ("images/a.png", b"\x89PNG\r\n\x1a\nsynthetic"), ("info.txt", b"{}")]
        for method in (0, 8):
            for descriptor in (False, True):
                path = folder / "chapter.zip"
                path.write_bytes(archive(entries, method, descriptor))
                body, style, assets = read(path.as_posix().encode())
                assert body == html and style == b"p{color:black}" and len(assets) == 1
                assert Path(assets[1][b"data_path"].decode()).read_bytes() == entries[2][1]
                print(f"Native ZIP method={method}, descriptor={descriptor}: PASS")
        bad = {
            "crc": archive(entries, method=0, corrupt=True),
            "truncated": archive(entries)[:-8],
            "traversal": archive([("../escape.xhtml", html)]),
            "duplicate": archive([("2.xhtml", html), ("2.xhtml", html)]),
            "ambiguous": archive([("2.xhtml", html), ("3.xhtml", html)]),
            "info-only": archive([("info.txt", b'{"paid":0}')]),
            "unsupported-method": archive([(name, data) for name, data in entries], method=9),
        }
        for label, data in bad.items():
            path.write_bytes(data)
            try:
                read(path.as_posix().encode())
            except Exception:
                print(f"Native ZIP rejects {label}: PASS")
            else:
                raise AssertionError(f"Accepted invalid archive: {label}")
        # A TXT chapter may use its UID without any extension.
        path.write_bytes(archive([("2", b"Synthetic text\nSecond paragraph")]))
        body, _, _ = read(path.as_posix().encode())
        assert b"Synthetic text" in body and b"Second paragraph" in body
        print("Native TXT: PASS")
        # A chapter may span multiple XHTML files. The manifest controls order,
        # independently of ZIP order and any other chapters in the package.
        first = b'<html><body><p>First native part.</p></body></html>'
        second = b'<html><body><p>Second native part.</p></body></html>'
        manifest = {'chapters': [{'chapterUid': 2, 'files': ['part-a.xhtml', 'part-b.xhtml']}]}
        parts = [('part-b.xhtml', second), ('part-a.xhtml', first), ('other.xhtml', b'<p>Unrelated chapter.</p>')]
        path.write_bytes(archive([*parts, ('info.txt', json.dumps(manifest).encode())]))
        lua.globals().package_path = path.as_posix().encode()
        lua.execute(b'''
            local body=require('miuread.eink_archive').read(package_path,envelope,vid,fixture_root,{chapter_uid='2'})
            body=require('miuread.codec').body_fragment(body)
            assert(body:find('First native part.',1,true)<body:find('Second native part.',1,true))
            assert(not body:find('Unrelated chapter.',1,true))
        ''')
        for info in ({'chapters': [{'chapterUid': 9, 'files': ['part-a.xhtml']}]},
                     {'chapters': [{'chapterUid': 2, 'files': ['missing.xhtml']}]},
                     {'chapters': [{'chapterUid': 2, 'files': ['part-a.xhtml', 'part-a.xhtml']}]},
                     {'chapters': [{'chapterUid': 2, 'files': ['part-a.xhtml']}] * 2}):
            path.write_bytes(archive([*parts, ('info.txt', json.dumps(info).encode())]))
            lua.execute(b"assert(not pcall(require('miuread.eink_archive').read,package_path,envelope,vid,fixture_root,{chapter_uid='2'}))")
        path.write_bytes(archive([('2.xhtml', html), ('info.txt', b'{invalid')]))
        lua.execute(b"assert(not pcall(require('miuread.eink_archive').read,package_path,envelope,vid,fixture_root,{}))")
        print('Native multipart manifest order and invalid-file rejection: PASS')
        # Actual Reader + Native client + archive + image-localization path.
        # The HTTP boundary supplies synthetic bytes, with no real account.
        image_html = html.replace(b'</body>', b'<img src="images/a.png"/></body>')
        path.write_bytes(archive([("2.xhtml", image_html), *entries[1:]]))

        lua.globals().py_copy = lambda value: (shutil.copyfile(path, value.decode()) and True)
        lua.execute(b'''
            local U=require('miuread.util')
            local clock=0
            package.preload['socket']=function() return {
                gettime=function() clock=clock+.01; return clock end,
                sleep=function(seconds) clock=clock+seconds end,
            } end
            package.preload['miuread.http']=function() return {
                is_auth_error=function() return false end,is_network_error=function() return false end,
                is_rate_limit_error=function(v) return tostring(v):find('[MiuReadRateLimit]',1,true)~=nil end,
            } end
            package.preload['miuread.annotation_coord']=function() return {fromDownloadedXhtml=function(v) return v end} end
            local store={temp_dir=fixture_root,auth=function() return {login_session_id='s',account={vid=vid},
                native_shelf={vid=vid,accessToken='test-token',refreshToken='test-refresh',deviceId='test-device'}} end}
            local http={}
            function http:post_json()
                self.catalogs=(self.catalogs or 0)+1
                return {data={{bookId='b',synckey=5,book={format='epub'},updated={{chapterUid=2,price=0}}}}}
            end
            function http:download_to_file(_,target,opt)
                self.packages=(self.packages or 0)+1
                assert(opt.auth==false and opt.redirects==0 and opt.headers.accessToken=='test-token')
                py_copy(target)
                return target,{encryptkey=envelope}
            end
            native_reader=require('miuread.reader'):new(http,store)
            local body,_,assets,state=native_reader:eink_chapter({bookId='b'},{chapterUid=2},'epub',{})
            assert(body:find('../images/native-1.png',1,true) and #assets==1)
            assert(state.coordinate_source_authoritative==false and state.source_channel=='eink' and state.url==nil)
            native_reader:cleanup_transient_images()
            -- Only the missing global CSS uses Web, once per download reader.
            -- Native bodies remain independent of Web coordinate authority.
            local Reader=require('miuread.reader')
            local Codec=require('miuread.codec')
            Reader.chapter_state=function() http.contexts=(http.contexts or 0)+1; return {psvts='test'} end
            Reader.shard=function(_,endpoint,_,chapter_uid)
                http.shards=(http.shards or 0)+1
                assert(endpoint=='/web/book/chapter/e_2','Native download requested a Web body')
                return 'css-fixture'
            end
            Codec.decode_parts=function(parts)
                assert(parts[1]=='css-fixture'); return 'p{color:black}'
            end
            native_http,native_store=http,store
        ''')
        path.write_bytes(archive([('2.xhtml', image_html), entries[2]]))
        lua.execute(b'''
            local U=require('miuread.util')
            local r=require('miuread.reader'):new(native_http,native_store)
            for _=1,2 do
                local _,css=r:eink_chapter({bookId='b'},{chapterUid=2},'epub',{})
                assert(css=='p{color:black}'); r:cleanup_transient_images()
            end
            assert(native_http.contexts==1 and native_http.shards==1)
        ''')
        # Exercise strict Native image handling: an unrelated image in the ZIP
        # cannot substitute for a missing img, SVG href or CSS background.
        for missing in (b'<img src="missing.png"/>', b'<svg><image href="missing.png"/></svg>',
                        b'<p style="background:url(missing.png)">Background.</p>'):
            path.write_bytes(archive([('2.xhtml', html.replace(b'</body>', missing + b'</body>')), *entries[1:]]))
            lua.execute('''
                local r=require('miuread.reader'):new(native_http,native_store)
                local ok,err=pcall(r.eink_chapter,r,{bookId='b'},{chapterUid=2},'epub',{})
                assert(not ok and tostring(err):find('E-Ink 正文图片未完整获取',1,true),tostring(err))
                assert(next(r._transient_image_roots)==nil)
            '''.encode())
        print('Native stylesheet reuse and strict image completeness: PASS')
        # Actual Downloader -> Native client -> AES/ZIP -> resource namespacing
        # -> checkpoint -> EPUB validation and installation. No network or SQLite
        # dependency is needed; the test only replaces boundary persistence.
        chapter_manifest = {'chapters': [{'chapterUid': uid, 'files': ['part-a.xhtml', 'part-b.xhtml']} for uid in (2, 3, 4)]}
        path.write_bytes(archive([('part-b.xhtml', second), ('part-a.xhtml', first.replace(b'</body>', b'<img src="images/a.png"/></body>')),
                                  *entries[1:3], ('info.txt', json.dumps(chapter_manifest).encode())]))
        lua.execute(b'''
            local U=require('miuread.util')
            local http,store=native_http,native_store
            local Reader=require('miuread.reader')
            local DB=require('miuread.download_database')
            local manifests,asset_manifests={},{}
            DB.load_manifest=function(path)
                if host_attributes(path,'mode')=='directory' then return U.copy(manifests[path]) end
            end
            DB.save_manifest=function(path,value) manifests[path]=U.copy(value); return true end
            DB.save_assets=function(path,uid,value) asset_manifests[path..'/'..uid]=U.copy(value); return true end
            DB.load_assets=function(path,uid) return U.copy(asset_manifests[path..'/'..uid]) end
            function store:book_dir() return fixture_root..'/book' end
            function store:epub_root() return fixture_root end
            function store:epub_path() return fixture_root..'/native-book.epub' end
            function store:variant() return self.record end
            function store:save_variant(_,_,value) self.record=U.copy(value) end
            function store:save_book() end
            function store:save_session() end
            function store:preferences() return {} end
            http.catalogs,http.packages,http.contexts,http.shards=0,0,0,0
            function http:close_idle_connections() self.closed=true end
            function http:post_json()
                self.catalogs=self.catalogs+1
                return {data={{bookId='b',synckey=5,book={format='epub'},updated={
                    {chapterUid=2,price=0,wordCount=1},{chapterUid=3,price=0,wordCount=1},{chapterUid=4,price=0,wordCount=1}}}}}
            end
            local r=Reader:new(http,store)
            local Downloader=require('miuread.downloader')
            local d=Downloader:new(r,{},nil,store,http)
            function d:catalog() return {format='epub',synckey=5},{
                {chapterUid=2,chapterIdx=1,title='First'},
                {chapterUid=3,chapterIdx=2,title='Second'},
                {chapterUid=4,chapterIdx=3,title='Third'}} end
            local result=d:book({bookId='b',title='Native integration',version=5},{images=true},function() end)
            assert(result.complete and result.chapter_count==3 and result.image_count==3)
            assert(d.last_transport_result.selected=='eink' and d.last_transport_result.eink_chapters==3)
            assert(result.download_transport==nil and store.record.download_transport==nil,'diagnostics leaked into book records')
            assert(not result.progress_source_complete and result.progress_source_cached_count==0)
            assert(http.catalogs==1 and http.packages==3 and http.contexts==0 and http.shards==0 and http.closed)
            assert(next(r._transient_image_roots)==nil)
            native_epub=result.file
            -- Native succeeds once, then fails. Web is limited immediately:
            -- persist the fallback before aborting, reuse the Native checkpoint
            -- and never try Native again when a new worker resumes this book.
            function store:book_dir() return fixture_root..'/fallback-book' end
            function store:epub_path() return fixture_root..'/fallback-book.epub' end
            store.record=nil
            local native_download=http.download_to_file
            local native_attempts,web_attempts=0,0
            function http:download_to_file(url,...)
                native_attempts=native_attempts+1
                if url:find('&chapters=3',1,true) then error('E-Ink ZIP synthetic failure') end
                return native_download(self,url,...)
            end
            local function web_chapter(_,_,chapter)
                web_attempts=web_attempts+1
                if web_attempts==1 then error('[MiuReadRateLimit] error_code=499 wait_seconds=300') end
                assert(tostring(chapter.chapterUid)~='2','completed Native chapter was downloaded again')
                local body='<html><body><p>Web fallback paragraph.</p></body></html>'
                return body,'p{color:black}',{},{coord_html=body,coordinate_source_authoritative=true}
            end
            local Source=require('miuread.source_position')
            local cache_source=Source.cacheChapter
            Source.cacheChapter=function(_,_,_,_,body)
                assert(body:find('Web fallback paragraph.',1,true)); return true
            end
            r=Reader:new(http,store); r.web_chapter=web_chapter
            local interrupted=Downloader:new(r,{},nil,store,http); interrupted.catalog=d.catalog
            local ok,err=pcall(interrupted.book,interrupted,{bookId='b',title='Fallback integration',version=5},{images=true})
            assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and native_attempts==2 and web_attempts==1)
            assert(interrupted.last_transport_result.stopped_channel=='web' and interrupted.last_transport_result.failure)
            r=Reader:new(http,store); r.web_chapter=web_chapter
            local resumed=Downloader:new(r,{},nil,store,http); resumed.catalog=d.catalog
            result=resumed:book({bookId='b',title='Fallback integration',version=5},{images=true})
            assert(result.complete and result.chapter_count==3 and result.image_count==1)
            assert(native_attempts==2 and web_attempts==3,'resuming replayed the failed Native route')
            assert(resumed.last_transport_result.reason=='eink_failed' and resumed.last_transport_result.web_chapters==2)
            assert(result.progress_source_cached_count==2 and not result.progress_source_complete)
            Source.cacheChapter=cache_source
            http.download_to_file=native_download
            -- A style rate limit also propagates without a fallback body read.
            r=Reader:new(http,store)
            function r:shard() error('[MiuReadRateLimit] error_code=499 wait_seconds=300') end
            limited_reader=r
        ''')
        with ZipFile(lua.globals().native_epub.decode()) as generated:
            assert generated.testzip() is None
            contents = [(name, generated.read(name)) for name in generated.namelist()]
            bodies = [data for name, data in contents if name.endswith('.xhtml') and b'First native part.' in data]
            assert len(bodies) == 3
            for body in bodies:
                assert body.index(b'First native part.') < body.index(b'Second native part.')
            assert len([name for name, _ in contents if name.endswith('.png')]) == 3
        path.write_bytes(archive([('2.xhtml', html)]))
        lua.execute(b'''
            local t=require('miuread.download_transport').new(limited_reader,{})
            local ok,err=pcall(t.chapter,t,{bookId='b'},{chapterUid=2},'epub',{})
            assert(not ok and t:result().reason=='rate_limited' and t:result().web_chapters==0)
            local U=require('miuread.util')
            local native_reader=require('miuread.reader'):new(native_http,native_store)
            local http,store=native_http,native_store
            local existing=fixture_root..'/existing-web-work'
            U.mkdir(existing)
            native_reader._transient_image_roots[existing]=true
            local ok,err=pcall(native_reader.eink_chapter,native_reader,{bookId='b'},{chapterUid=2},'epub',{
                yield=function() error('__MIUREAD_HIBERNATE__:content') end})
            assert(not ok and tostring(err):find('__MIUREAD_HIBERNATE__',1,true))
            assert(tostring(err):find('native_stage=decode',1,true))
            local count=0; for _ in pairs(native_reader._transient_image_roots) do count=count+1 end
            assert(count==1 and native_reader._transient_image_roots[existing], 'Native failure removed unrelated Web work')
            native_reader:cleanup_transient_images()
            -- Optional TXT/CSS/image fetches must not swallow a limit and
            -- continue sending requests or start another content format.
            local Reader=require('miuread.reader')
            local probe=Reader:new(http,store)
            local calls=0
            function probe:shard(path)
                calls=calls+1
                if path:find('/t_1',1,true) then error('[MiuReadRateLimit] txt') end
                return 'fixture'
            end
            local ok,err=pcall(probe._txt_once,probe,{bookId='b'},{chapterUid=2},{},{psvts='test'})
            assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and calls==2)
            local Codec=require('miuread.codec')
            local original_decode=Codec.decode_parts
            Codec.decode_parts=function() return '<html><body><p>Original text.</p></body></html>' end
            calls=0
            function probe:shard(path)
                calls=calls+1
                if path:find('/e_2',1,true) then error('[MiuReadRateLimit] css') end
                return 'fixture'
            end
            ok,err=pcall(probe._epub_once,probe,{bookId='b'},{chapterUid=2},{images=false},{psvts='test'})
            assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and calls==4)
            function probe:shard() return 'fixture' end
            local media_requests=0
            probe.http={download_to_file=function() media_requests=media_requests+1; error('[MiuReadRateLimit] image') end}
            ok,err=pcall(probe._epub_once,probe,{bookId='b'},{chapterUid=2,tar='https://res.weread.qq.com/chapter.tar'},{},{psvts='test'})
            assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and media_requests==1)
            probe:cleanup_transient_images()
            Codec.decode_parts=function() return '<html><body><p>Original.</p><img src="https://res.weread.qq.com/a.png"/><img src="https://res.weread.qq.com/b.png"/></body></html>' end
            media_requests=0
            ok,err=pcall(probe._epub_once,probe,{bookId='b'},{chapterUid=2},{},{psvts='test'})
            assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and media_requests==1)
            probe:cleanup_transient_images()
            Codec.decode_parts=original_decode
        ''')
        print("Native Reader, real EPUB installation, fallback resume and failure cleanup: PASS")
    for name in ("test_api_transports.lua", "test_diagnostic_log.lua", "test_download_transport.lua", "test_eink_client.lua", "test_shelf_client.lua", "test_reader_context.lua", "test_download_safety.lua", "test_http_keepalive.lua"):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().arg = lua.table_from({0: f"tools/{name}"})
        lua.execute((ROOT / "tools" / name).read_text(encoding="utf-8"), name=name)
    command=[sys.executable,'-B',str(ROOT / 'tools/test_eink_features.py')]
    if args.zlib:
        command.extend(['--zlib',args.zlib])
    subprocess.run(command,check=True)
    print("All offline E-Ink download regressions passed")


if __name__ == "__main__":
    main()
