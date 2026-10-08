-- Pure response, API wire and mutation recovery checks; no account required.
package.path='miuread.koplugin/?.lua;'..package.path
local function copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local out={}; seen[value]=out
    for k,v in pairs(value) do out[k]=copy(v,seen) end
    return out
end
package.preload['miuread.util']=function() return {
    copy=copy,utf8_truncate=function(s,n) return s:sub(1,n) end,first_line=tostring,
} end
package.preload['miuread.protocol']=function() return {
    SKILL_VERSION='test',escape=function(s) return tostring(s):gsub(' ','%%20') end,
    reader_url=function(id) return 'https://weread.qq.com/web/reader/'..id end,
    is_mp=function(id) return id:match('^MP_')~=nil end,
    is_mp_account=function(id) return id:match('^MP_WXS_')~=nil end,
} end
package.preload['logger']=function() return {info=function() end,warn=function() end} end
package.preload['miuread.codec']=function() return {} end
package.preload['miuread.http']=function() return {is_auth_error=function() return false end} end
local Data=require('miuread.bookstore_data')
local Api=require('miuread.api')
local Membership=require('miuread.shelf_membership')

local page=Data.page('recommend',{books={
    {bookId='a',title='A',searchIdx=11,reason='because',newRating=89},
    {bookId='a',title='A duplicate',searchIdx=12},
    {bookId='b',title='B',searchIdx=14},
},hasMore=1},10)
assert(#page.books==2 and page.next_cursor==14 and page.has_more)
assert(page.books[1].reason=='because' and page.books[1].newRating==89)
assert(not Data.page('recommend',{books={{bookId='a',searchIdx=10}},hasMore=1},10).has_more,
    'repeated cursor causes an endless next-page loop')
assert(not Data.page('recommend',{books={{bookId='a',searchIdx=11}},hasMore=0},10).has_more)
assert(not pcall(Data.page,'recommend',{},0),'malformed response became an empty successful page')
local similar=Data.page('similar',{booksimilar={sessionId='session',hasMore=1,books={
    {idx=7,book={bookInfo={bookId='c',title='C',author='Writer'}}},
}}},0)
assert(similar.books[1].bookId=='c' and similar.next_cursor==7 and similar.session_id=='session')
local cats=Data.categories({data={
    {name='rankings',categories={{CategoryId='all',title='总榜',type=0},
        {CategoryId='rising',title='飙升榜',type=0}}},
    {categories={{CategoryId='700000',title='计算机',type=0,sublist={
        {CategoryId='700001',title='编程',type=0}}}}},
    {CategoryId='1900000',title='男生小说',type=0},
    {CategoryId='all',title='duplicate'},
    {CategoryId='audio',title='Audio',type=1},
}})
assert(#cats.ranks==2 and #cats.categories==2)
assert(cats.categories[1].children[1].id=='700001')
assert(Data.shelf_state({data={{bookId='a',onShelf=0}}},'a',false)==false)
assert(Data.shelf_state({data={{bookId='a',onShelf=true}}},'a',false)==true)
assert(Data.shelf_state({data={}},'a',false)==nil)
assert(Data.shelf_state({books={}},'a',true)==false)
assert(Data.shelf_state({},'a',true)==nil)
assert(Data.shelf_state({books={{bookInfo={bookId='a'}}}},'a',true))

local posts,gets,shelf_reads={}, {},0
local membership={data={{bookId='a',onShelf=0}}}
local shelf={books={}}
local native_shelf={books={}}
local http={}
function http:get_json(url,opt)
    gets[#gets+1]={url=url,opt=copy(opt)}
    if url:find('/web/shelf/bookIds?',1,true) then
        if membership=='error' then error('web auth failed') end
        return copy(membership)
    end
    if url=='https://i.weread.qq.com/shelf/sync' then
        if type(native_shelf)=='string' then error(native_shelf) end
        return copy(native_shelf)
    end
    return {data={}}
end
function http:post_json(url,body,opt)
    posts[#posts+1]={url=url,body=copy(body),opt=copy(opt)}
    if body.api_name=='/shelf/sync' then shelf_reads=shelf_reads+1; return copy(shelf) end
    return {succ=1}
end
local credential={api_key='fake-key',account={vid='alice'},cookies={wr_vid='alice',wr_skey='web-token'},
    native_shelf={vid='alice',accessToken='client-token',refreshToken='client-refresh',deviceId='device'}}
local api=Api:new(http,{auth=function() return credential end})
api:recommend_books(12,20)
assert(posts[#posts].body.api_name=='/book/recommend' and posts[#posts].body.maxIdx==12)
api:similar_books('a',7,20,'session')
local similar_wire=posts[#posts].body
assert(similar_wire.count==20 and similar_wire.maxIdx==7 and similar_wire.sessionId=='session')
api:store_categories(); assert(gets[#gets].opt.auth==false)
api:category_books('all',20,true)
assert(gets[#gets].url:find('?rank=1&maxIndex=20',1,true))
api:category_books('700001',0,false)
assert(gets[#gets].url:find('?rank=0&maxIndex=0',1,true))
assert(not pcall(api.category_books,api,'../bad',0,true))
assert(api:book_on_shelf('a')==false and shelf_reads==0)
assert(gets[#gets].opt.retries==0 and gets[#gets].opt.headers['Cache-Control']:find('no-store',1,true))
membership='error'; shelf={books={{bookInfo={bookId='a'}}}}
assert(api:book_on_shelf('a')==true and shelf_reads==1,'failed GET incorrectly proved absence')
membership={data={}}; shelf={books={}}
assert(api:book_on_shelf('a')==false and shelf_reads==2)
shelf={}; assert(not pcall(api.book_on_shelf,api,'a'))
api:add_to_shelf('a')
local write=posts[#posts]
assert(write.url=='https://weread.qq.com/web/shelf/add' and write.body.bookIds[1]=='a')
assert(write.opt.auth and write.opt.redirects==0 and write.opt.retries==0 and write.opt.rate_limit_retries==0)
assert(not pcall(api.add_to_shelf,api,'MP_WXS_1'))
api:remove_from_shelf('a')
write=posts[#posts]
assert(write.url=='https://i.weread.qq.com/shelf/delete' and write.body.bookIds[1]=='a')
assert(write.opt.auth==false and write.opt.redirects==0 and write.opt.retries==0
    and write.opt.rate_limit_retries==0 and write.opt.rate_limit_fail_fast)
assert(write.opt.headers.vid=='alice' and write.opt.headers.accessToken=='client-token'
    and write.opt.headers.Cookie==nil,'native removal omitted client credentials or borrowed Web cookies')
local preflight=gets[#gets]
assert(preflight.url=='https://i.weread.qq.com/shelf/sync' and preflight.opt.auth==false)
assert(preflight.opt.redirects==0 and preflight.opt.retries==0 and preflight.opt.rate_limit_retries==0)
for _,key in ipairs({'vid','accessToken','baseapi','appver','basever','osver','channelId','User-Agent'}) do
    assert(preflight.opt.headers[key]==write.opt.headers[key] and write.opt.headers[key],
        'native read/write profile differs: '..key)
end
assert(write.opt.headers.basever==write.opt.headers.appver and write.opt.headers['User-Agent']:find('wr_eink',1,true))
membership={data={{bookId='a',onShelf=1}}}
for _,response in ipairs({'HTTP 401: {"errcode":-2011}',{}}) do
    native_shelf=response
    local count=#posts
    local ok,err=pcall(api.remove_from_shelf,api,'a')
    assert(not ok and tostring(err):find('[MiuReadShelfPreflight]',1,true) and #posts==count,
        'rejected/malformed native read permitted a deletion')
    local rejected=Membership.run(api,'a',false,false)
    assert(rejected.state=='blocked' and rejected.stage=='credentials' and #posts==count,
        'real API preflight rejection became an uncertain write')
end
native_shelf={books={}}
assert(not pcall(api.remove_from_shelf,api,'MP_WXS_1'))
assert(not pcall(api.remove_from_shelf,api,''))
credential.native_shelf=nil
local before=#posts
assert(not pcall(api.remove_from_shelf,api,'a') and #posts==before,'missing credential permitted removal')
credential.native_shelf={vid='alice',accessToken='renewed-token',refreshToken='refresh',deviceId='device'}
credential.account.vid=''
api:remove_from_shelf('a')
assert(posts[#posts].opt.headers.vid=='alice','empty account vid ignored cookie identity')
assert(posts[#posts].opt.headers.accessToken=='renewed-token','removal captured an obsolete token')


-- Reads may use the existing login recovery path; the shelf POST must not.
credential={api_key='expired',account={vid='alice'},cookies={wr_skey='expired'},
    native_shelf={vid='alice',accessToken='client-token',refreshToken='refresh',deviceId='device'}}
local attempts,repaired,web_reads,web_repaired=0,0,0,0
package.loaded['miuread.http'].is_auth_error=function(err)
    return tostring(err):find('authentication expired',1,true)~=nil
end
local repair_http={}
function repair_http:post_json(url,body,opt)
    attempts=attempts+1
    if body.bookIds or credential.api_key=='expired' then error('authentication expired') end
    assert(opt.headers.Authorization=='Bearer renewed')
    return {books={}}
end
function repair_http:get_json(url)
    if url=='https://i.weread.qq.com/shelf/sync' then return {books={}} end
    web_reads=web_reads+1
    if web_reads==1 then error('authentication expired') end
    return {data={{bookId='a',onShelf=0}}}
end
local repair_reader={
    repair_login_session=function() repaired=repaired+1; credential.api_key='renewed' end,
    _recover_login_session=function() web_repaired=web_repaired+1; return true end,
}
local repair_api=Api:new(repair_http,{auth=function() return credential end},repair_reader)
assert(type(repair_api:recommend_books(0,20).books)=='table' and attempts==2 and repaired==1)
assert(repair_api:book_on_shelf('a')==false and web_reads==2 and web_repaired==1)
assert(not pcall(repair_api.add_to_shelf,repair_api,'a'))
assert(attempts==3 and repaired==1 and web_repaired==1,'shelf write invoked credential recovery/replay')
assert(not pcall(repair_api.remove_from_shelf,repair_api,'a'))
assert(attempts==4 and repaired==1 and web_repaired==1,'shelf removal invoked credential recovery/replay')
package.loaded['miuread.http'].is_auth_error=function() return false end

local writes,reads=0,0
local sequence={}
local fake={}
function fake:book_on_shelf()
    reads=reads+1
    local v=sequence[reads]
    if v=='error' then error('read timeout') end
    return v
end
function fake:add_to_shelf()
    writes=writes+1; self.last_target=true
    if self.lose_reply then error('POST timeout') end
end
function fake:remove_from_shelf()
    if self.block_native then error('[MiuReadShelfPreflight] HTTP 401') end
    writes=writes+1; self.last_target=false
    if self.lose_reply then error('POST timeout') end
end
for _,desired in ipairs({true,false}) do
    reads,writes=0,0; sequence={not desired,desired}; fake.lose_reply=false
    assert(Membership.run(fake,'a',desired,false).state=='verified' and writes==1 and fake.last_target==desired)
    reads,writes=0,0; sequence={desired}
    assert(Membership.run(fake,'a',desired,false).already and writes==0)
    reads,writes=0,0; sequence={not desired,desired}; fake.lose_reply=true
    assert(Membership.run(fake,'a',desired,false).state=='verified' and writes==1,'lost reply ignored successful readback')
    reads,writes=0,0; sequence={not desired,'error',not desired}
    assert(Membership.run(fake,'a',desired,false).state=='unconfirmed' and writes==1,'ambiguous POST replayed')
    reads,writes=0,0; sequence={not desired}
    local mismatch=Membership.run(fake,'a',desired,true)
    assert(mismatch.state=='mismatch' and mismatch.present==not desired and writes==0)
    reads,writes=0,0; sequence={'error'}
    assert(Membership.run(fake,'a',desired,false).state=='blocked' and writes==0,'unverified preflight permitted a POST')
    reads,writes=0,0; sequence={'error'}
    assert(Membership.run(fake,'a',desired,true).state=='unconfirmed' and writes==0,'read failure discarded an older uncertain write')
    reads,writes=0,0; sequence={}
    assert(Membership.run(fake,'a',desired,false).state=='blocked' and writes==0)
    reads,writes=0,0; sequence={not desired,'error','error'}; fake.lose_reply=true
    local unknown=Membership.run(fake,'a',desired,false)
    assert(unknown.state=='unconfirmed' and unknown.write_error:find('POST timeout',1,true)
        and unknown.read_error:find('read timeout',1,true) and unknown.error==unknown.write_error,
        'readback overwrote the original mutation error')
end
reads,writes=0,0; sequence={true}; fake.block_native=true
local blocked=Membership.run(fake,'a',false,false)
assert(blocked.state=='blocked' and blocked.stage=='credentials' and blocked.present and writes==0)
fake.block_native=false
assert(not pcall(Membership.run,fake,'a',nil,false),'missing target defaulted to a destructive write')
print('bookstore data, API and shelf mutation: PASS')
