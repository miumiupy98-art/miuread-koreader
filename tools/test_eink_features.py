"""Offline E-Ink notes and translation transactions through production modules.

Only HTTP and SQLite persistence are replaced. All fixtures are synthetic.
"""
import argparse
import json
from pathlib import Path
import tempfile
import sys
from zipfile import ZipFile

sys.dont_write_bytecode = True
from test_eink_download import ROOT, ENVELOPE, VID, archive, runtime


def source(uid, translated=False, web=False):
    uid = int(uid)
    prefix = '<p>Web prefix with different offsets.</p>' if web else ''
    original = f'<p id="p{uid}">Before 👋 TARGET sentence {uid}.</p>'
    translation = f'<p id="p{uid}" class="wr-translation">第 {uid} 章译文。</p>' if translated else ''
    return f'<html><head><title>Chapter {uid}</title></head><body>{prefix}{original}{translation}</body></html>'.encode()


SETUP = r'''
local U=require('miuread.util')
local Json=require('miuread.json')
local Coord=require('miuread.annotation_coord')
local PosMap=require('miuread.annotations.posmap')
package.preload['socket']=function() return {sleep=function() end,gettime=os.time} end
package.preload['miuread.http']=function() return {
    is_auth_error=function(v) return tostring(v):find('[MiuReadAuth]',1,true)~=nil end,is_network_error=function() return false end,
    is_forbidden_error=function() return false end,
    is_rate_limit_error=function(v) return tostring(v):find('[MiuReadRateLimit]',1,true)~=nil end,
    rate_limit_details=function(v)
        if tostring(v):find('[MiuReadRateLimit]',1,true) then return {code=499,wait_seconds=300} end
    end,
} end
local DB=require('miuread.download_database')
local manifests,assets,notes={},{},{}
DB.load_manifest=function(path) if host_attributes(path,'mode')=='directory' then return U.copy(manifests[path]) end end
DB.save_manifest=function(path,value) manifests[path]=U.copy(value); return true end
DB.save_assets=function(path,uid,value) assets[path..'/'..uid]=U.copy(value); return true end
DB.load_assets=function(path,uid) return U.copy(assets[path..'/'..uid]) end
DB.save_annotation=function(path,uid,key,value) notes[path..'/'..uid..'/'..key]=U.copy(value); return true end
DB.load_annotation=function(path,uid,key) return U.copy(notes[path..'/'..uid..'/'..key]) end
local ThoughtDB=require('miuread.thought_database')
ThoughtDB.path=function() return fixture_root..'/thoughts.sqlite3' end
ThoughtDB.save_chapter=function(_,_,uid,groups)
    thought_groups=thought_groups or {}; thought_groups[tostring(uid)]=U.copy(groups)
    return {groups=#groups}
end
local Source=require('miuread.source_position')
Source.cacheChapter=function(_,_,_,_,body)
    assert(body:find('Web prefix',1,true),'Native content was used as a Web coordinate source')
    return true
end
store={temp_dir=fixture_root,preferences=function() return {} end,auth=function() return {
    login_session_id='synthetic-session',account={vid=vid},
    native_shelf={vid=vid,accessToken='synthetic-token',refreshToken='synthetic-refresh',deviceId='synthetic-device'}} end}
function store:book_dir() return fixture_root..'/book' end
function store:epub_root() return fixture_root end
function store:epub_path() return fixture_root..'/book.epub' end
function store:variant(_,kind) return self.records and self.records[kind] end
function store:save_variant(_,kind,value) self.records=self.records or {}; self.records[kind]=U.copy(value) end
function store:save_book() end
function store:save_session() end
http={native_packages=0,web_bodies=0,web_api=0,native_api=0,enabled=false,ready={},urls={}}
local function validate(options)
    assert(options.auth==false and options.redirects==0 and options.retries==0)
    assert(options.keepalive==true,'Native requests lost per-download connection reuse')
    assert(options.headers.accessToken=='synthetic-token' and not options.headers.Cookie and not options.headers.Authorization)
end
local function range(uid,web)
    local html=py_source(uid,http.enabled,web)
    return assert(PosMap.locate(Coord.build(html),'TARGET sentence '..tostring(uid)))
end
local function underlines(uid,web)
    if scenario=='alignment' and not web then return {underlines={{range='0-3'}}} end
    return {underlines={{range=range(uid,web),
        markText=scenario~='no_quotes' and ('TARGET sentence '..tostring(uid)) or nil,reviewCount=1}}}
end
local function reviews(batch,web)
    local rows={}
    for _,item in ipairs(batch) do rows[#rows+1]={range=item.range,pageReviews={{review={
        reviewId='synthetic-review',content=web and 'Web thought' or 'Native thought',author={nick='Reader'}}}}} end
    return {reviews=rows}
end
function http:get_json(url,options)
    validate(options); self.native_api=self.native_api+1; self.urls[#self.urls+1]=url
    if url:find('/book/underlines?',1,true) then
        if scenario=='notes_limit' then error('[MiuReadRateLimit] error_code=499 wait_seconds=300') end
        if scenario=='cancel' then error('download cancelled') end
        return underlines(url:match('chapterUid=(%d+)'),false)
    elseif url:find('/pay/memberCardSummary?',1,true) then
        if scenario=='translation_limit' then error('[MiuReadRateLimit] error_code=499 wait_seconds=300') end
        if scenario=='translation_unavailable' then error('HTTP 404') end
        return {isPaying=scenario=='member_required' and 0 or 1}
    elseif url:find('/trans/pdfepub?',1,true) then
        assert(url:find('transType=epubTranslate',1,true))
        self.enabled=url:find('transFormat=epubTranslate',1,true)~=nil
        return {succ=true}
    end
    error('Unexpected Native GET: '..url)
end
function http:post_json(url,body,options)
    validate(options); self.native_api=self.native_api+1
    if url:find('/book/chapterInfos',1,true) then
        self.native_catalogs=(self.native_catalogs or 0)+1
        if scenario=='catalog_fallback_resume' and not self.resuming then error('HTTP 404') end
        return {data={{bookId='b',synckey=5,book={format='epub',version=5},updated={
            {chapterUid=2,price=0,wordCount=100},{chapterUid=3,price=0,wordCount=100},{chapterUid=4,price=0,wordCount=100}}}}}
    elseif url:find('/book/readreviews',1,true) then
        assert(body.cht2sMode=='' and #body.reviews<=30)
        if scenario=='notes_unavailable' or scenario=='web_limit' then error('HTTP 404') end
        return reviews(body.reviews,false)
    end
    error('Unexpected Native POST: '..url)
end
function http:json(options)
    validate(options); self.native_api=self.native_api+1
    assert(options.url=='https://i.weread.qq.com/en/bookread' and options.method=='POST')
    assert(options.body:find('"texts":[]',1,true))
    local body=Json.decode(options.body)
    assert(body.freeTrial==0 and #body.read>=1 and #body.read<=2)
    if scenario=='hibernate' then error('__MIUREAD_HIBERNATE__:translation') end
    local ready={}
    for _,item in ipairs(body.read) do
        self.ready[tostring(item.uid)]=true
        ready[#ready+1]={uid=item.uid,translateVersion=7}
    end
    return {stopPoll=1,curStatus=ready}
end
function http:download_to_file(url,path,options)
    validate(options); self.native_packages=self.native_packages+1
    local chapters=url:match('chapters=([^&]+)')
    assert((self.native_packages==1)==(chapters:find('0%%2C')~=nil),'public resources were not fetched exactly once')
    local uid=tonumber(chapters:match('(%d+)$'))
    local translated=self.enabled and self.ready[tostring(uid)] and scenario~='translation_body_missing'
    py_package(path,uid,translated==true,chapters:find('0%%2C')~=nil)
    return path,{EncryptKey=envelope}
end
function http:close_idle_connections() self.closed=true end
api={}
function api:review_batches(ranges) return require('miuread.api').review_batches(self,ranges) end
function api:catalog()
    http.web_catalogs=(http.web_catalogs or 0)+1
    return {book={format='epub'},format='epub',synckey=5,updated={
        {chapterUid=2,title='First',wordCount=100},{chapterUid=3,title='Second',wordCount=100},
        {chapterUid=4,title='Third',wordCount=100}}}
end
function api:underlines(_,uid)
    http.web_api=http.web_api+1
    if (scenario=='web_limit' or scenario=='web_cached_resume' or scenario=='catalog_fallback_resume') and not http.resuming then
        error('[MiuReadRateLimit] error_code=499 wait_seconds=300')
    end
    if scenario=='web_refresh_limit' then
        if not http.renewed then error('[MiuReadAuth] error_code=-2012') end
        error('[MiuReadRateLimit] error_code=499 wait_seconds=300')
    end
    return underlines(uid,true)
end
function api:readreviews(_,_,batch) http.web_api=http.web_api+1; return reviews(batch,true) end
function api:translation_member_summary() http.web_api=http.web_api+1; return {isPaying=true} end
function api:toggle_translate(_,enabled) http.web_api=http.web_api+1; http.enabled=enabled; return {succ=true} end
function api:en_read(_,_,read)
    http.web_api=http.web_api+1
    local ready={}; for _,item in ipairs(read) do ready[#ready+1]={uid=item.uid,translateVersion=7} end
    return {stopPoll=true,curStatus=ready}
end
local Reader=require('miuread.reader')
local Downloader=require('miuread.downloader')
local Annotations=require('miuread.annotations')
function new_downloader()
    local r=Reader:new(http,store)
    function r:web_chapter(_,chapter,_,options)
        http.web_bodies=http.web_bodies+1
        local body=py_source(chapter.chapterUid,options.translation==true,true)
        return body,'p{color:black}',{},{coord_html=body,content_format='epub'}
    end
    function r:_recover_login_session() http.renewed=true; return true end
    local d=Downloader:new(r,api,Annotations:new(api),store,http)
    function d:catalog() return {format='epub',synckey=5},{
        {chapterUid=2,chapterIdx=1,title='First',wordCount=100},
        {chapterUid=3,chapterIdx=2,title='Second',wordCount=100},
        {chapterUid=4,chapterIdx=3,title='Third',wordCount=100}} end
    return d
end
book={bookId='b',title='Native features',version=5}
'''


def run_case(folder, scenario, zlib_path):
    lua = runtime(zlib_path, folder)
    lua.globals().fixture_root = folder.as_posix().encode()
    lua.globals().envelope, lua.globals().vid = ENVELOPE, VID
    lua.globals().scenario = scenario.encode()
    lua.globals().py_source = source

    def write_package(path, uid, translated, resources):
        name = f'{uid}.xhtml'
        entries = [(name, source(uid, translated))]
        if resources:
            entries += [('0.xhtml', b'<html><body><p>Resource chapter excluded.</p></body></html>'),
                        ('style.css', b'p{line-height:1.7}')]
        entries += [('info.txt', json.dumps({'chapters': [{'chapterUid': uid, 'files': [name]}]}).encode())]
        Path(path.decode()).write_bytes(archive(entries))

    lua.globals().py_package = write_package
    lua.execute(SETUP.encode())
    if scenario == 'notes':
        lua.execute(b'''
            -- Web control errors may not retry a UID representation or continue
            -- through the Skill Gateway after Native has fallen back.
            local Api=require('miuread.api')
            for _,name in ipairs({'underlines','readreviews'}) do
                local requests,agent=0,0
                local h={get_json=function() requests=requests+1; error('[MiuReadRateLimit] error_code=499') end,
                    post_json=function() requests=requests+1; error('[MiuReadRateLimit] error_code=499') end}
                local a=Api:new(h,store)
                function a:call() agent=agent+1; error('unexpected Agent fallback') end
                local ok,err=pcall(a[name],a,'b','2',{{range='1-5',count=30,maxIdx=0,synckey=0}})
                assert(not ok and tostring(err):find('[MiuReadRateLimit]',1,true) and requests==1 and agent==0)
            end
        ''')
    translation = scenario.startswith('translation') or scenario in ('combined', 'member_required', 'hibernate')
    notes = not translation or scenario == 'combined'
    lua.globals().want_notes = notes
    lua.execute(b"d=new_downloader()")
    if scenario in ('native_catalog', 'catalog_fallback_resume'):
        lua.execute(b'd.catalog=nil')
    if translation:
        lua.execute(b'''
            -- Keep a real existing EPUB to exercise staged replacement and its
            -- preserved original, as the reader's translation action requires.
            base=d:book(book,{images=true,annotations=want_notes})
            original_bytes=assert(require('miuread.util').read_file(base.file,true))
            -- Reuse the reader across jobs: catalog/resource/mode caches must
            -- not outlive a download or skip chapter 0 on the next run.
            http.native_packages,http.web_bodies,http.web_api,http.native_api=0,0,0,0
            http.closed=false
        ''')
    lua.globals().want_translation = translation
    lua.execute(b'''
        options={images=true,annotations=want_notes}
        if scenario=='web_cached_resume' or scenario=='web_refresh_limit' then options.channel='web' end
        if want_translation then
            options.generate_translation_uid='2'; options.translation_batch_size='all'; options.translation_mode='bilingual'
        end
        passed,result=pcall(d.book,d,book,options)
        assert(http.closed and next(d.reader._transient_image_roots)==nil)
        if want_translation then assert(require('miuread.util').read_file(base.file,true)==original_bytes) end
    ''')
    if scenario == 'web_limit':
        lua.execute(b'''
            assert(not passed and http.native_packages==1 and http.web_api==1 and http.web_bodies==1)
            assert(d.last_transport_result.stopped_channel=='web' and d.last_transport_result.failure)
            http.resuming=true; d=new_downloader()
            passed,result=pcall(d.book,d,book,options)
            assert(http.native_packages==1,'resuming replayed a failed Native annotation route')
        ''')
    if scenario == 'web_cached_resume':
        lua.execute(b'''
            assert(not passed and http.native_packages==0 and http.web_bodies==1)
            http.resuming=true; options.channel=nil
            passed,result=pcall(d.book,d,book,options)
            assert(passed,tostring(result))
            assert(http.native_packages==3,'pending Web body was reused with Native annotation coordinates')
        ''')
    if scenario == 'catalog_fallback_resume':
        lua.execute(b'''
            assert(not passed and http.native_catalogs==1 and http.native_packages==0)
            http.resuming=true; d=new_downloader(); d.catalog=nil
            passed,result=pcall(d.book,d,book,options)
            assert(passed,tostring(result))
            assert(http.native_catalogs==1 and http.web_catalogs==2,'resume probed Native before restoring its Web route')
        ''')
    if scenario == 'web_refresh_limit':
        lua.execute(b'''
            assert(not passed,'Web annotation rate limit after renewal was swallowed')
            assert(http.web_bodies==1 and http.web_api==2,'requests continued after renewal hit a limit')
            assert(d.last_transport_result.reason=='rate_limited' and d.last_transport_result.stopped_channel=='web')
        ''')
        print(f'E-Ink {scenario}: PASS', flush=True)
        return
    limited = scenario in ('notes_limit', 'translation_limit', 'member_required', 'cancel', 'hibernate')
    if limited:
        lua.execute(b'''
            assert(not passed,'control error unexpectedly produced a book: '
                ..tostring(d.last_transport_result.reason))
            assert(http.web_api==0 and http.web_bodies==0,'control error fell back to Web')
            if scenario=='member_required' then assert(tostring(result):find('[MiuReadTranslationMemberRequired]',1,true))
            elseif scenario=='cancel' then assert(tostring(result):find('download cancelled',1,true))
            elseif scenario=='hibernate' then assert(tostring(result):find('__MIUREAD_HIBERNATE__',1,true))
            else
                assert(d.last_transport_result.reason=='rate_limited' and d.last_transport_result.limit_code==499)
                assert(d.last_transport_result.stopped_phase==(want_translation and 'translation' or 'annotations'))
            end
        ''')
    else:
        lua.execute(b'''
            assert(passed,tostring(result))
            assert(result.complete and result.chapter_count==3)
            if want_translation then
                assert(result.pending_install and result.translation_batch_summary.available==3)
                local profile=assert(require('miuread.translation').inspect(result.pending_file))
                assert(profile.blocks==3 and profile.separable)
            end
            if scenario=='notes' or scenario=='combined' or scenario=='no_quotes' or scenario=='web_cached_resume' or scenario=='native_catalog' then
                local resumed_web=scenario=='web_cached_resume' and 1 or 0
                assert(http.native_packages==3 and http.web_api==resumed_web and http.web_bodies==resumed_web,
                    tostring(d.last_transport_result.reason)
                    ..' packages='..http.native_packages..' web_api='..http.web_api..' web_bodies='..http.web_bodies)
                assert(d.last_transport_result.eink_chapters==3 and not result.progress_source_complete)
                assert(thought_groups['2'][1].texts[1].content=='Native thought')
                if scenario=='native_catalog' then assert(http.native_catalogs==1 and not http.web_catalogs) end
            else
                assert(d.last_transport_result.reason=='eink_failed' and http.web_bodies==3)
            end
            if scenario=='notes_unavailable' then
                assert(http.native_packages==1 and http.web_api==6,'partial Native annotations leaked into Web checkpoints')
            end
            if scenario=='translation_body_missing' then assert(http.native_packages==1) end
        ''')
        output = lua.globals().result[b'pending_file'] or lua.globals().result[b'file']
        with ZipFile(output.decode()) as generated:
            assert generated.testzip() is None
            bodies = [generated.read(name) for name in generated.namelist() if name.endswith('.xhtml') and 'TARGET'.encode() in generated.read(name)]
            assert len(bodies) == 3
            assert all(b'Resource chapter excluded.' not in body for body in bodies)
            if notes:
                assert all(b'data-miu-range=' in body and b'miu-thought-link' in body for body in bodies)
            if translation:
                assert all(b'wr-translation' in body for body in bodies)
    print(f'E-Ink {scenario}: PASS', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zlib')
    args = parser.parse_args()
    import os
    os.chdir(ROOT)
    with tempfile.TemporaryDirectory(prefix='miuread-native-features-') as temporary:
        for scenario in ('native_catalog', 'catalog_fallback_resume', 'web_cached_resume', 'web_refresh_limit', 'notes', 'no_quotes', 'combined', 'notes_unavailable', 'alignment', 'notes_limit', 'web_limit',
                         'translation_unavailable', 'translation_body_missing', 'translation_limit',
                         'member_required', 'cancel', 'hibernate'):
            folder = Path(temporary) / scenario
            folder.mkdir()
            run_case(folder, scenario, args.zlib)


if __name__ == '__main__':
    main()
