package.path='miuread.koplugin/?.lua;'..package.path
package.preload['logger']=function() return {info=function() end,warn=function() end} end
local function copy(v) if type(v)~='table' then return v end; local o={}; for k,x in pairs(v) do o[k]=copy(x) end; return o end
package.preload['miuread.util']=function() return {copy=copy} end
local error_file=assert(io.open('miuread.koplugin/miuread/http.lua','rb'))
local error_source=error_file:read('*a'); error_file:close()
local error_helpers=assert(loadstring('local RATE_LIMIT_MARKER="[MiuReadRateLimit]"\n'
    ..assert(error_source:match('(local function auth_error_code%(value%).-\nend)'))..'\n'
    ..assert(error_source:match('(local function is_rate_limit_error%(value%).-\nend)'))..'\n'
    ..assert(error_source:match('(local function rate_limit_details%(value%).-\nend)'))..'\n'
    ..'return {is_rate_limit_error=is_rate_limit_error,rate_limit_details=rate_limit_details}'))()
package.preload['miuread.http']=function() return {
    is_auth_error=function(v) return tostring(v):find('MiuReadAuth',1,true)~=nil end,
    auth_error_message=function(code) return '[MiuReadAuth] error_code='..code end,
    is_rate_limit_error=error_helpers.is_rate_limit_error,rate_limit_details=error_helpers.rate_limit_details,
} end
local Client=require('miuread.eink_client')
local store={value={login_session_id='s',account={vid='123'},native_shelf={vid='123',accessToken='secret',refreshToken='refresh',deviceId='device'}}}
function store:auth() return copy(self.value) end
local http={catalogs=0,downloads=0}
function http:post_json(url,body,opt)
    assert(url=='https://i.weread.qq.com/book/chapterInfos' and body.bookIds[1]=='b')
    for _,field in ipairs({'synckeys','updateTimes','maxfreeIdx'}) do
        assert(type(body[field])=='table' and #body[field]==1 and body[field][1]==0,'full catalog request missing '..field)
    end
    assert(opt.auth==false and opt.redirects==0 and opt.headers.vid=='123' and not opt.headers.Cookie and not opt.headers.Authorization)
    self.catalogs=self.catalogs+1
    return {data={{bookId='b',synckey=456,book={format='epub'},updated={{chapterUid=2,price=0},{chapterUid=3,price=10,paid=0}}}}}
end
function http:download_to_file(url,path,opt)
    self.downloads=self.downloads+1
    assert(url:find('&bookVersion='..tostring(self.expected_version or 456),1,true)
        and (url:find('&chapters=2',1,true) or url:find('&chapters=0%2C2',1,true)))
    assert(url:find('stopAutoPayWhenBNE=1',1,true) and opt.redirects==0 and opt.auth==false and opt.retries==0)
    assert(opt.headers.accessToken==store.value.native_shelf.accessToken and not opt.headers.Cookie)
    if self.auth_failures and self.auth_failures>0 then
        self.auth_failures=self.auth_failures-1
        return path,{},nil,{preview='{"errCode":-2012}'}
    end
    if self.raw_error then return path,{},nil,{preview=self.raw_error} end
    return path,{EncryptKey='test-envelope'}
end
local c=Client.new(http,store)
local path,envelope,vid=c:download({bookId='b'},{chapterUid=2},'test.zip',{})
assert(path=='test.zip' and envelope=='test-envelope' and vid=='123')
c:download({bookId='b'},{chapterUid=2},'test.zip',{})
assert(http.catalogs==1 and http.downloads==2)
assert(not pcall(c.download,c,{bookId='b'},{chapterUid=3},'test.zip',{}))
assert(not pcall(c.download,c,{bookId='b'},{chapterUid=9},'test.zip',{}))
assert(http.downloads==2,'unknown/unpaid chapters must not reach download endpoint')
assert(not pcall(c.download,c,{bookId='b'},{chapterUid=2},'test.zip',{web_catalog_version=999}))
assert(http.downloads==2,'different catalog versions must not reach download endpoint')
-- An expired Native token gets one controlled refresh and one read retry.
local refreshed=0
require('miuread.shelf_client').refresh=function(_,target)
    assert(target==store); refreshed=refreshed+1
    target.value.native_shelf.accessToken='renewed'
    return require('miuread.shelf_client').credentials(target:auth())
end
http.auth_failures=1
c:download({bookId='b'},{chapterUid=2},'test.zip',{})
assert(refreshed==1 and http.downloads==4)
http.auth_failures=2
assert(not pcall(c.download,c,{bookId='b'},{chapterUid=2},'test.zip',{}))
assert(refreshed==2 and http.downloads==6,'persistent expiry must stop after one renewal')
http.raw_error='{"errCode":-2014}'
local ok,err=pcall(c.download,c,{bookId='b'},{chapterUid=2},'test.zip',{})
assert(not ok and tostring(err):find('MiuReadRateLimit',1,true))
assert(error_helpers.rate_limit_details(err).code==-2014
    and error_helpers.rate_limit_details(err).native_stage=='chapter_download')
-- If the one permitted token renewal itself hits a service restriction, keep
-- that typed error and do not replay the original native read.
local reads=0
require('miuread.shelf_client').refresh=function()
    error('[MiuReadRateLimit] native_stage=refresh error_code=499 wait_seconds=300',0)
end
ok,err=pcall(c.authorized,c,function()
    reads=reads+1
    error('[MiuReadAuth] error_code=-2012')
end)
assert(not ok and reads==1 and tostring(err):find('[MiuReadRateLimit]',1,true)
    and tostring(err):find('native_stage=refresh',1,true))
-- A limited Native request must identify the failed step and never fall back
-- to Web. Run the actual transport and client together, with no live HTTP.
local clock=0
package.preload['socket']=function() return {gettime=function() return clock end,sleep=function() end} end
local Transport=require('miuread.download_transport')
for _,stage in ipairs({'catalog','chapter_download','refresh'}) do
    for _,cached in ipairs({false,true}) do
        local calls={catalog=0,chapter=0,refresh=0,web=0}
        local raw='[MiuReadRateLimit]'..(cached and ' [MiuReadLocalCooldown]' or '')
            ..' error_code=499 wait_seconds=300 private-response-token'
        local native_http={}
        function native_http:post_json(_,body)
            calls.catalog=calls.catalog+1
            assert(body.synckeys[1]==0 and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
            if stage=='catalog' then error(raw) end
            return {data={{bookId='b',synckey=456,book={format='epub'},updated={{chapterUid=2,price=0}}}}}
        end
        function native_http:download_to_file()
            calls.chapter=calls.chapter+1
            if stage=='refresh' then error('[MiuReadAuth] error_code=-2012') end
            error(raw)
        end
        require('miuread.shelf_client').refresh=function()
            calls.refresh=calls.refresh+1; error(raw)
        end
        local native=Client.new(native_http,store)
        local reader={store=store}
        function reader:chapter()
            calls.web=calls.web+1; clock=clock+2
            return '<p>raw</p>','css',{}, {coord_html='<p>raw</p>'}
        end
        function reader:eink_chapter(book,chapter,_,options) return native:download(book,chapter,'test.zip',options) end
        local transport=Transport.new(reader,{})
        transport:configure('epub')
        local passed,failure=pcall(transport.chapter,transport,{bookId='b'},{chapterUid=2},'epub',{})
        local result=transport:result()
        assert(not passed and calls.web==0 and calls.catalog==1 and calls.chapter==(stage=='catalog' and 0 or 1))
        assert(calls.refresh==(stage=='refresh' and 1 or 0),'rate-limited reads must not renew credentials')
        assert(result.web_chapters==0 and result.eink_chapters==0)
        assert(result.native_stage==stage and result.limit_code==499 and result.wait_seconds==300 and result.local_cooldown==cached)
        assert(result.stopped_channel=='eink' and result.stopped_phase=='download')
        assert(not tostring(failure):find('private-response-token',1,true),'raw rate-limit response leaked through client')
    end
end
http.raw_error=nil; http.auth_failures=0; http.expected_version=789
c:download({bookId='b',version=789},{chapterUid=2},'test.zip',{})
assert(http.downloads==8,'Native bookVersion must follow the book version rather than a catalog sync cursor')
store.value.native_shelf=nil
assert(not pcall(c.download,c,{bookId='b'},{chapterUid=2},'test.zip',{}))
assert(http.downloads==8,'missing authorization must not send a download request')
print('eink client: PASS')
