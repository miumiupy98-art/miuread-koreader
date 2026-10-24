-- Exercise the public facade and real Native/Web request adapters without an account.
package.path='miuread.koplugin/?.lua;'..package.path
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function escape(v) return tostring(v):gsub('([^%w_.%-])',function(c) return string.format('%%%02X',c:byte()) end) end
package.preload['miuread.util']=function() return {copy=copy,first_line=tostring,utf8_len=function(s) return #s end,
    utf8_truncate=function(s) return s end} end
package.preload['miuread.protocol']=function() return {
    SKILL_VERSION='fixture',escape=escape,reader_url=function(id) return 'https://weread.qq.com/web/reader/'..id end,
    is_mp=function(id) return tostring(id):match('^MP_') end,is_mp_account=function() return false end,
    query=function(params)
        local rows={}; for k,v in pairs(params) do rows[#rows+1]=k..'='..escape(v) end
        table.sort(rows); return table.concat(rows,'&')
    end,
} end
package.preload['miuread.codec']=function() return {b64encode=function(v) return 'b64:'..v end} end
package.preload['logger']=function() return {info=function() end,warn=function() end,dbg=function() end} end
package.preload['miuread.http']=function() return {
    is_rate_limit_error=function(v) return tostring(v):find('[MiuReadRateLimit]',1,true) end,
    rate_limit_details=function(v) if tostring(v):find('[MiuReadRateLimit]',1,true) then return {code=499} end end,
    is_auth_error=function(v) return tostring(v):find('[MiuReadAuth]',1,true) end,
    auth_error_code=function(v) return tonumber(tostring(v):match('error_code=(%-?%d+)')) end,
} end
local Api=require('miuread.api')
local store={prefs={},account={login_session_id='session',account={vid='123'},api_key='fixture',
    native_shelf={vid='123',deviceId='fixture-device',accessToken='fixture-token',refreshToken='fixture-refresh'}}}
function store:preferences() return self.prefs end
function store:auth() return copy(self.account) end
local requests={}
local http={}
local function record(method,url,options,body)
    requests[#requests+1]={method=method,url=url,options=copy(options),body=copy(body)}
    local native=url:find('https://i.weread.qq.com/',1,true) and not url:find('/agent/',1,true)
    if native then
        assert(options.auth==false and options.headers.accessToken=='fixture-token')
        assert(not options.headers.Cookie and not options.headers.Authorization and options.retries==0 and options.rate_limit_retries==0)
        assert(options.redirects==0 and options.rate_limit_fail_fast)
        if http.native_error then error(http.native_error,0) end
    end
    return native
end
function http:get_json(url,options)
    local native=record('GET',url,options)
    if not native then
        if self.web_error or self.cookie_error then error(self.web_error or self.cookie_error,0) end
        if url:find('/memberCardSummary',1,true) then return {isPaying=true} end
        if url:find('/getProgress',1,true) then return {progress=42} end
        return {data={}}
    end
    if self.malformed then return {} end
    if url:find('/shelf/sync',1,true) then return {books={{bookId='b'}},archive={},mp={}} end
    if url:find('/book/info?',1,true) then return {bookId='b',title='Fixture',format='epub'} end
    if url:find('/book/getProgress?',1,true) then
        return self.progress_response or {bookId='b',book={progress=42,chapterUid=2,updateTime=123}}
    end
    if url:find('/book/readinfo?',1,true) then return {finishedBookIndex=0} end
    if url:find('/book/detailinfo?',1,true) then return {booksimilar={books={},hasMore=0}} end
    if url:find('/market/categories?',1,true) then
        return {updated={{categoryId=url:find('ranklist=1',1,true) and 'all' or '1',title='Fixture'}}}
    end
    if url:find('/market/category?',1,true) then return {updated={{bookInfo={bookId='b',title='Fixture'},searchIdx=21}},hasMore=0} end
    if url:find('/readdata/detail?',1,true) then return {readStat={},totalReadTime=60} end
    if url:find('/book/bookmarklist?',1,true) then return {updated={}} end
    if url:find('/review/list?',1,true) then return {reviews={}} end
    if url:find('/review/single?',1,true) then return {review={reviewId='r'}} end
    if url:find('/book/underlines?',1,true) then return {underlines={}} end
    if url:find('/user/notebooks?',1,true) then return {books={{sort=3},{sort=2},{sort=1}}} end
    return {books={},hasMore=0}
end
function http:post_json(url,body,options)
    local native=record('POST',url,options,body)
    if not native then
        if self.web_error then error(self.web_error,0) end
        if url:find('/agent/gateway',1,true) then
            if body.api_name=='/book/getprogress' then return {bookId='b',progress=36} end
            return {books={},hasMore=0}
        end
        return {succ=true}
    end
    if url:find('/chapterInfos',1,true) then return {data={{bookId='b',book={format='epub'},synckey=1,updated={}}}} end
    if url:find('/book/readreviews',1,true) then return {reviews={}} end
    if url:find('/review/like',1,true) then assert(body.isUnlike==0 or body.isUnlike==1,'Native like flag must be an integer') end
    if self.write_error then error(self.write_error,0) end
    if self.invalid_write_result then return false end
    return {succ=true}
end
local api=Api:new(http,store)
local function count_web()
    local count=0
    for _,request in ipairs(requests) do
        if request.url:find('/web/',1,true) or request.url:find('/agent/',1,true) then count=count+1 end
    end
    return count
end
assert(api:shelf()._api_channel=='eink')
assert(api:shelf_stream()._miuread_stream.source=='eink_full')
local before_light=#requests
api:shelf_stream({allow_full_fallback=false})
assert(requests[before_light+1].url:find('/web/shelf/sync?',1,true),'bounded shelf read fetched a Native full snapshot')
requests={}
assert(api:book_on_shelf('b')==true and api:book_on_shelf('other')==false)
assert(api:book('b').title=='Fixture' and api:catalog('b').bookId=='b')
assert(api:chapters('b').bookId=='b')
assert(api:search('two words',12,10)._api_channel=='eink')
assert(api:recommend_books(5,10).books and api:similar_books('b',4,10,'session').booksimilar)
assert(api:store_categories().data and api:category_books('1',20,true).books)
assert(api:reading_stats('weekly',0).totalReadTime==60)
assert(#api:notebooks(1,3).books==1 and api:notebooks(1,3).books[1].sort==2)
assert(api:bookmark_list('b').updated and api:review_list_mine('b',0,20).reviews)
assert(api:review_single('r').review.reviewId=='r')
assert(api:underlines('b',2)._annotation_source=='eink' and api:readreviews('b',2,{{range='1-2'}}).reviews)
assert(api:progress('b')._progress_source=='eink' and api:book_read_info('b').finishedBookIndex==0)
assert(count_web()==0,'Native reads unexpectedly used Web/Skills')

-- One public policy applies to normal failures, malformed replies and empty lists.
local before=#requests
assert(#api:search('empty').books==0 and #requests==before+1)
http.malformed=true
assert(api:search('malformed')._api_channel=='web')
http.malformed=false
http.native_error='HTTP 404'
local scoped=api:scope()
assert(scoped:search('fallback')._api_channel=='web')
local after=#requests
assert(scoped:book('b')._api_channel=='web' and #requests==after+1)
assert(requests[#requests].url:find('/agent/gateway',1,true))
http.native_error=nil
local web_view=api:for_channel('web')
http.web_error='[MiuReadRateLimit] error_code=499'
assert(not pcall(web_view.web_progress,web_view,'b'))
http.web_error=nil
assert(web_view:web_progress('b').progress==42,'a completed action poisoned the persistent Web view')
http.web_error='[MiuReadAuth] error_code=-2012'
local recovering=Api:new(http,store,{_recover_login_session=function()
    return false,'[MiuReadRateLimit] error_code=499'
end}):for_channel('web'):scope()
local start=#requests
local ok,limited=pcall(recovering.web_progress,recovering,'b')
assert(not ok and tostring(limited):find('[MiuReadRateLimit]',1,true) and #requests==start+1,
    'Web recovery hid a rate limit or replayed the request')
local second_stage=Api:new(http,store,{repair_login_session=function() return true end,
    _recover_login_session=function() return false,'[MiuReadRateLimit] error_code=499' end}):for_channel('web'):scope()
start=#requests
ok,limited=pcall(second_stage.progress_sources,second_stage,'b')
assert(not ok and tostring(limited):find('[MiuReadRateLimit]',1,true) and #requests==start+2,
    'second-stage Web recovery hid a rate limit or replayed the request')
http.web_error=nil
start=#requests
local sources=web_view:progress_sources('b')
assert(requests[start+1].url:find('/agent/gateway',1,true) and requests[start+2].url:find('/web/book/getProgress',1,true),
    'precise synchronization lost its independent progress observations')
assert(sources.agent.progress==36 and sources.web.progress==42)
start=#requests
assert(web_view:progress('b').progress==42 and #requests==start+1,
    'ordinary Web progress bypassed the cookie source or read both sync observations')
http.cookie_error='HTTP 404'; start=#requests
assert(web_view:progress('b').progress==36 and #requests==start+2,'Web progress lost its legacy read fallback')
http.cookie_error='[MiuReadRateLimit] error_code=499'; start=#requests
assert(not pcall(web_view.progress,web_view,'b') and #requests==start+1,'limited Web progress used the gateway')
http.cookie_error=nil
http.progress_response={bookId='other',book={progress=42}}
start=#requests
assert(api:progress('b').progress==42 and #requests==start+2,'another book\'s Native progress suppressed Web fallback')
http.progress_response={bookId='b',book={chapterUid=2}}
start=#requests
assert(api:progress('b').progress==42 and #requests==start+2,'missing Native percentage suppressed Web fallback')
http.progress_response=nil
local Auth=require('miuread.shelf_client')
local old_refresh,refreshes=Auth.refresh,0
Auth.refresh=function() refreshes=refreshes+1; error('unexpected renewal') end
http.native_error='[MiuReadAuth] error_code=-2012'
assert(api:progress('b',{no_auth_recovery=true})._api_channel=='web' and refreshes==0)
http.native_error=nil; Auth.refresh=old_refresh
assert(api:book('b')._api_channel=='eink','an independent action inherited a previous fallback')
for _,control in ipairs({'[MiuReadRateLimit] error_code=499','download cancelled','__MIUREAD_HIBERNATE__:api'}) do
    http.native_error=control; scoped=api:scope(); local web=count_web()
    assert(not pcall(scoped.search,scoped,'control') and count_web()==web)
    after=#requests
    assert(not pcall(scoped.book,scoped,'b') and #requests==after,'scoped control error continued requesting')
end
http.native_error=nil

-- The global preference applies to each independent operation.
store.prefs.api_transport='web'
assert(api:book('b')._api_channel=='web')
store.prefs.api_transport='auto'
assert(api:book('b')._api_channel=='eink')
store.prefs={}
assert(api:web_progress('b')._api_channel=='web','authoritative Web progress was routed through Native')

-- A preflight failure may switch; a sent write must never switch or replay.
local mutations={
    function(a) return a:add_to_shelf('b') end,
    function(a) return a:mark_book_finished('b',true) end,
    function(a) return a:like_review('r',true) end,
    function(a) return a:remove_bookmark('mark') end,
    function(a) return a:remove_review({reviewId='r'}) end,
}
for _,mutate in ipairs(mutations) do
    before=#requests; assert(mutate(api).succ and #requests==before+2)
    local web=count_web()
    http.write_error='network request failed: lost response'
    assert(not pcall(mutate,api) and #requests==before+4 and count_web()==web,'uncertain Native write replayed through Web')
    http.write_error=nil
    http.invalid_write_result=true; before=#requests
    assert(not pcall(mutate,api) and #requests==before+2 and count_web()==web,
        'unrecognized Native write result was accepted or replayed')
    http.invalid_write_result=nil
end
http.native_error='HTTP 404'; before=#requests
assert(api:add_to_shelf('b')._api_channel=='web' and #requests==before+2)
http.native_error=nil

-- Coordinate writes default to Web. An explicitly Native coordinate view can
-- use the Native plaintext contract, never the Web Base64 representation.
local payload={bookId='b',chapterUid=2,range='1-3',markText='text',bookVersion=1,type=1}
before=#requests
api:add_bookmark(payload)
assert(#requests==before+1 and requests[#requests].body.markText=='b64:text')
api:for_channel('eink'):add_bookmark(payload)
assert(requests[#requests].body.markText=='text' and requests[#requests].url:find('/book/addBookmark',1,true))
local web=count_web()
http.native_error='HTTP 404'
assert(not pcall(function() api:for_channel('eink'):add_bookmark(payload) end) and count_web()==web,
    'Native coordinate write fell back to Web')
http.native_error=nil
local saved=store.account.native_shelf; store.account.native_shelf=nil; before=#requests
assert(not pcall(function() api:for_channel('eink'):add_bookmark(payload) end) and #requests==before,
    'unauthorized Native coordinates reached Web')
store.account.native_shelf=saved
local Transport=require('miuread.api_transport')
local route=Transport.new(store)
route:invoke('unsupported',nil,function() return true end)
assert(route.selected=='web')
route:invoke('next',function() error('unsupported route was not pinned') end,function() return true end)
local pinned=api:for_channel('eink'):scope()
http.native_error='HTTP 404'; local web=count_web()
assert(not pcall(pinned.category_books,pinned,'native-category',20,false) and count_web()==web,
    'source-bound category IDs or cursors crossed to Web')
http.native_error=nil
local reader_a={web_catalog=function() return {bookId='a'} end}
local reader_b={web_catalog=function() return {bookId='b'} end}
local original=Api:new(http,store,reader_a):for_channel('web')
local bound=Api.bind(original,reader_b):for_channel('web')
assert(bound:catalog('b').bookId=='b' and original.web_backend.reader==reader_a and original:catalog('a').bookId=='a',
    'binding a scoped reader mutated a different API view')
for _,name in ipairs({'annotation_coord','annotations.posmap','annotations.range','local_annotation_database','thought_database','json','config'}) do
    local module=name
    package.preload['miuread.'..module]=function() return {} end
end
local Sync=require('miuread.annotation_sync')
assert(Sync:new(api,{},store).api.coordinate_source=='web')
local f=assert(io.open('miuread.koplugin/main.lua','rb')); local source=f:read('*a'); f:close()
local helper=assert(source:match('(local function interactive_child_store.-)\nfunction Plugin:_interactive_child_store'))
local factory=assert(loadstring(helper..'\nreturn interactive_child_store'))
setfenv(factory,setmetatable({U={copy=copy}},{__index=_G}))
local child=factory()(store:auth(),'data','temp','web')
assert(child:preferences().api_transport=='web' and Api:new(http,child):book('b')._api_channel=='web',
    'background worker ignored the parent channel preference')
-- Run the actual search worker: the parent may change settings while it waits,
-- and refreshed child credentials must return through the normal auth merge.
local search=assert(source:match('(function Plugin:search%(q%).-)\nfunction Plugin:_variant_exists'))
local Plugin={}
local worker={available=function() return true end,busy=function() return false end}
function worker:run(_,fn,done) self.fn,self.done=fn,done; return true end
local ui={show=function() end,close=function() end}
local env=setmetatable({Plugin=Plugin,U={copy=copy},interactive_child_store=factory(),
    UIManager=ui,ButtonDialog={new=function(_,value) return value end},normalize=function(v) return v end,
    _=function(v) return v end},{__index=_G})
local chunk=assert(loadstring(search)); setfenv(chunk,env); chunk()
local plugin=setmetatable({store=store,search_async=worker},{__index=Plugin})
function plugin:require_login() return true end
function plugin:is_online() return true end
function plugin:list() end
function plugin:info(value) error(value) end
function plugin:_friendly_remote_error(value) return tostring(value) end
function plugin:_apply_interactive_auth(value) self.applied_auth=value end
local Http=require('miuread.http'); Http.new=function() return http end
store.prefs.api_transport='web'; plugin:search('manual Web'); store.prefs.api_transport='auto'; start=#requests
worker.done({ok=true,value=worker.fn()})
assert(#requests==start+1 and requests[#requests].url:find('/agent/gateway',1,true),
    'search worker ignored its captured Web preference')
Auth.refresh=function(_,child_store)
    http.native_error=nil
    local current=child_store:auth(); current.api_key='refreshed'; assert(child_store:save_auth(current))
    return current.native_shelf
end
plugin:search('renewal'); http.native_error='[MiuReadAuth] error_code=-2012'
worker.done({ok=true,value=worker.fn()})
assert(plugin.applied_auth and plugin.applied_auth.auth.api_key=='refreshed' and store.account.api_key=='fixture',
    'search lost a child credential refresh or wrote through the parent store')
Auth.refresh=old_refresh
print('unified API: Native reads, Web fallback, scoped controls, preferences and non-replaying writes PASS')
