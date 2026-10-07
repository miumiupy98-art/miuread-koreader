-- Native QR transport and existing Auth UI/persistence guards; no real account.
package.path='miuread.koplugin/?.lua;'..package.path
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,item in pairs(v) do out[k]=copy(item) end; return out
end
local function merge(a,b)
    local out=copy(a or {})
    for k,v in pairs(b or {}) do out[k]=type(v)=='table' and type(out[k])=='table' and merge(out[k],v) or copy(v) end
    return out
end
package.preload['miuread.util']=function() return {copy=copy,merge=merge,first_line=tostring,trim=tostring,utf8_truncate=function(s,n) return s:sub(1,n) end} end
package.preload['miuread.protocol']=function() return {
    escape=function(v) return tostring(v):gsub('([^%w_.%-])',function(c) return string.format('%%%02X',c:byte()) end) end,
    is_mp=function() return false end,is_mp_account=function() return false end,
    reader_url=function(id) return 'https://weread.qq.com/web/reader/'..id end,
} end
package.preload['miuread.digests']=function() return {sha256=function(input) return 'sha256:'..input end} end
package.preload['miuread.codec']=function() return {} end
local logs={}
package.preload['logger']=function() return {
    info=function(...) logs[#logs+1]=table.concat({...},' ') end,
    warn=function(...) logs[#logs+1]=table.concat({...},' ') end,
} end
package.preload['miuread.http']=function() return {
    auth_error_code=function(v) return tostring(v):match('error_code=(%-?%d+)') end,
    is_auth_error=function(v) return tostring(v):find('HTTP 401',1,true)~=nil end,
} end
package.preload['miuread.cookies']=function() return {
    session_absorb=function(jar) return copy(jar or {}) end,
    session_header=function(jar) return 'wr_skey='..tostring(jar.wr_skey or '') end,
    sanitize=copy,names=function(jar) local out={}; for k in pairs(jar) do out[#out+1]=k end; return out end,
} end
package.preload['miuread.text']=function() return {tr=function(v) return v end} end
package.preload['miuread.gesture_bridge']=function() return {} end
package.preload['device']=function() return {screen={getWidth=function() return 600 end,getHeight=function() return 800 end}} end
local Widget={}
function Widget:extend(attrs) return setmetatable(attrs or {},{__index=self}) end
function Widget:new(opts) return setmetatable(opts,{__index=self}) end
for _,name in ipairs({'qrmessage','buttondialog','inputdialog'}) do package.preload['ui/widget/'..name]=function() return Widget end end
local queue,shown={},{ }
local UI={}
function UI:scheduleIn(_,fn) queue[#queue+1]=fn end
function UI:show(widget) shown[#shown+1]=widget end
function UI:close(widget)
    if widget.dismiss_callback then widget.dismiss_callback() end
    if widget.close_callback then widget.close_callback() end
end
package.preload['ui/uimanager']=function() return UI end
local function step() local fn=assert(table.remove(queue,1),'no scheduled callback'); fn() end
local function clear_queue() queue={} end

-- Use actual Store credential equality and compare-and-swap implementation.
local file=assert(io.open('miuread.koplugin/miuread/store.lua','rb'))
local source=file:read('*a'); file:close()
local store_code=assert(source:match('(local function sanitized_auth.-)\nfunction Store:auth_revision'))
local Store=assert(loadstring('local U=require("miuread.util"); local defaults={auth={}}; local Store={}\n'
    ..store_code..'\nreturn Store'))()
local function base_auth()
    return {login_session_id='session',auth_revision=7,account={vid='alice',name='Alice'},api_key='skills-key',
        cookies={wr_vid='alice',wr_skey='web-only',wr_rt='web-refresh'},wr_ticket='web-ticket'}
end
local function new_store()
    local s=setmetatable({current=base_auth(),writes=0},{__index=Store})
    s.persisted=copy(s.current)
    function s:get() return copy(self.current) end
    function s:set(_,auth)
        self.writes=self.writes+1
        if self.fail_save then self.current=copy(self.persisted); return false,'disk full' end
        self.current=copy(auth); self.persisted=copy(auth); return true
    end
    function s:read_persisted() return copy(self.persisted) end
    function s:reload() self.current=copy(self.persisted) end
    function s:generate_login_session_id() return 'web-session-new' end
    s.db={saveSetting=function(_,_,value) s.current=copy(value) end}
    return s
end
local Client=require('miuread.shelf_client')
local Auth=require('miuread.auth')
local Api=require('miuread.api')
local Membership=require('miuread.shelf_membership')
local store=new_store()
local http={poll_code=408,gets={},posts={},present=true,delete_count=0,refresh_count=0}
function http:get_json(url,opt)
    self.gets[#self.gets+1]={url=url,opt=copy(opt)}
    if not url:find('https://weread.qq.com/',1,true) then assert(opt.retries==0 and opt.auth==false) end
    if url:find('/wxticket?',1,true) then return {signature='ticket-secret',timeStamp=12345} end
    if url:find('/connect/sdk/qrconnect?',1,true) then
        assert(url:find('appid=wxab9b71ad2b90ff34',1,true) and url:find('signature=ticket-secret',1,true))
        assert(url:find('snsapi_userinfo%2Csnsapi_timeline%2Csnsapi_friend',1,true))
        return {errcode=0,uuid='uuid-secret'}
    end
    if url:find('/connect/l/qrconnect?',1,true) then return {wx_errcode=self.poll_code,wx_code='code-secret'} end
    if url=='https://i.weread.qq.com/shelf/sync' then
        assert(opt.headers.accessToken and opt.headers.vid=='alice' and not opt.headers.Cookie)
        if self.expired_reads and self.expired_reads>0 then
            self.expired_reads=self.expired_reads-1; error('HTTP 401 [MiuReadAuth] error_code=-2012')
        end
        return self.bad_shelf and {} or {books={}}
    end
    if url:find('/web/shelf/bookIds?',1,true) then return {data={{bookId='a',onShelf=self.present and 1 or 0}}} end
    if url:find('/api/userInfo?',1,true) then return {name='Alice'} end
    if url:find('/api/skills/apikeyGet',1,true) then return {apikey='new-skills-key'} end
    error('unexpected GET')
end
function http:post_json(url,body,opt)
    self.posts[#self.posts+1]={url=url,body=copy(body),opt=copy(opt)}
    if url=='https://i.weread.qq.com/login' then
        assert(opt.auth==false and opt.redirects==0 and opt.retries==0 and opt.rate_limit_retries==0)
        assert(body.deviceType==3 and body.deviceName=='BOOX')
        assert(body.signature=='sha256:'..tostring(body.timestamp)..body.deviceId..tostring(body.random))
        if body.code then
            assert(body.code=='code-secret' and body.isAutoLogout==0 and body.isFromQrcode==1)
            assert(body.installId:match('^eink31%d+$') and #body.installId==32)
        else
            self.refresh_count=self.refresh_count+1
            assert(body.refreshToken=='native-refresh' and body.deviceId==store.current.native_shelf.deviceId)
            assert(body.kickType==1 and body.inBackground==0)
        end
        return {vid=self.wrong_account and 'bob' or 'alice',accessToken=body.code and 'native-token' or 'native-renewed',
            refreshToken='native-refresh'}
    end
    if url=='https://i.weread.qq.com/shelf/delete' then
        self.delete_count=self.delete_count+1
        assert(body.bookIds[1]=='a' and opt.headers.accessToken==store.current.native_shelf.accessToken)
        assert(opt.retries==0 and opt.redirects==0 and opt.rate_limit_retries==0)
        if self.effect~=false then self.present=false end
        if self.reject_delete then error('HTTP 401 [MiuReadAuth] error_code=-2012') end
        return {succ=1}
    end
    if url=='https://weread.qq.com/web/login/renewal' then return {succ=1},{} end
    error('unexpected POST')
end
local function host()
    local h={online_queue={},notices={}}
    function h:is_online() return true end
    function h:online(_,fn) self.online_queue[#self.online_queue+1]=fn end
    function h:toast(text) self.notices[#self.notices+1]=text end
    function h:info(text) self.notices[#self.notices+1]=text end
    function h:on_auth_success() self.completed=true end
    return h
end
local h=host()
local backend=Client.new(http,store)
local flow=Auth:new(http,store,h,backend)
assert(backend.device_id:match('^eink334691225%d+$') and #backend.device_id==32)
flow:start(); step()
assert(shown[#shown].text=='https://open.weixin.qq.com/connect/confirm?uuid=uuid-secret')
step(); http.poll_code=404; step(); http.poll_code=405; step()
assert(not flow.active and #h.online_queue==1 and store.writes==0 and http.delete_count==0)
flow:cancel(); table.remove(h.online_queue,1)()
assert(store.writes==0 and #http.posts==0,'cancelled QR result installed credentials')
clear_queue()

-- Complete a client scan through the shared Auth controller. Save only client
-- credentials into the current Web login; never perform a shelf mutation.
flow:start(); step(); http.poll_code=405; step(); table.remove(h.online_queue,1)()
assert(h.completed and store.current.native_shelf.accessToken=='native-token' and http.delete_count==0)
assert(store.current.cookies.wr_skey=='web-only' and store.current.api_key=='skills-key'
    and store.current.login_session_id=='session' and store.current.wr_ticket=='web-ticket')
assert(store.current.auth_revision==8 and store.writes==1,'native credentials did not advance credential revision')
local stale=base_auth()
assert(not store:save_auth(stale,{expected_revision=7}),'old Web task erased client authorization')
local expected=copy(store.current); store.persisted.native_shelf.accessToken='different'
assert(not flow:_persisted_auth_matches(expected),'partial client credential persistence accepted')
store.persisted=copy(store.current)

-- A failed commit can reuse the existing retry-save UI without exchanging an
-- already consumed authorization code again.
store=new_store(); backend=Client.new(http,store); h=host(); flow=Auth:new(http,store,h,backend)
store.fail_save=true
local name,err=flow:_finish({wx_code='code-secret'})
assert(not name and err and flow.pending_auth and not store.current.native_shelf)
local before=#http.posts
flow:_show_commit_retry(err); store.fail_save=false
shown[#shown].buttons[1][1].callback(); step()
assert(h.completed and store.current.native_shelf and #http.posts==before,'commit retry repeated native login exchange')
clear_queue()

store=new_store(); backend=Client.new(http,store); h=host(); flow=Auth:new(http,store,h,backend)
store.fail_save=true
name,err=flow:_finish({wx_code='code-secret'}); flow:_show_commit_retry(err)
shown[#shown].buttons[1][1].callback(); flow:cancel(); store.fail_save=false
local writes=store.writes
step()
assert(store.writes==writes and not store.current.native_shelf and not h.completed,
    'cancelled commit retry installed client credentials')
clear_queue()

-- Wrong accounts, changed sessions and invalid native shelf responses cannot
-- overwrite the user's current Web login or submit a deletion.
store=new_store(); backend=Client.new(http,store); flow=Auth:new(http,store,host(),backend)
http.wrong_account=true
assert(not pcall(flow._finish,flow,{wx_code='code-secret'}) and store.writes==0)
http.wrong_account=false; http.bad_shelf=true
assert(not pcall(flow._finish,flow,{wx_code='code-secret'}) and store.writes==0)
http.bad_shelf=false; store.current.login_session_id='changed'
local count=#http.posts
assert(not pcall(flow._finish,flow,{wx_code='code-secret'}) and #http.posts==count and store.writes==0)
store.current.login_session_id='session'
local native=copy(base_auth()); native.native_shelf={vid='alice',accessToken='native-token',refreshToken='native-refresh',deviceId=backend.device_id}
assert(backend:validate_commit(native))
store.current.account.vid='bob'
assert(not flow:_commit_auth(native,7),'commit retry crossed accounts')

-- The real removal API rejects Web-only credentials without contacting native
-- endpoints. One pre-write native renewal is allowed; a failed DELETE is not.
store=new_store(); http.present=true
local api=Api:new(http,store)
count=#http.posts
local ok,reason=pcall(api.remove_from_shelf,api,'a')
assert(not ok and tostring(reason):find('[MiuReadShelfAuthorization]',1,true) and #http.posts==count)
store.current.native_shelf={vid='alice',accessToken='native-token',refreshToken='native-refresh',deviceId=backend.device_id}
store.persisted=copy(store.current); http.expired_reads=1
local deletes,refreshes=http.delete_count,http.refresh_count
local verified=Membership.run(api,'a',false,false)
assert(verified.state=='verified',tostring(verified.state)..': '..tostring(verified.error))
assert(http.delete_count==deletes+1 and http.refresh_count==refreshes+1 and store.current.native_shelf.accessToken=='native-renewed')
assert(store.current.cookies.wr_skey=='web-only')
http.present=true; http.effect=false; http.reject_delete=true
refreshes=http.refresh_count; deletes=http.delete_count
local unknown=Membership.run(api,'a',false,false)
assert(unknown.state=='unconfirmed' and unknown.write_error:find('HTTP 401',1,true))
assert(http.refresh_count==refreshes and http.delete_count==deletes+1,'failed mutation renewed/replayed itself')
assert(Membership.run(api,'a',false,true).state=='mismatch' and http.delete_count==deletes+1)
http.effect=true; http.reject_delete=false; http.wrong_account=true; http.expired_reads=1
local previous=copy(store.current.native_shelf)
assert(Membership.run(api,'a',false,false).state=='blocked' and http.delete_count==deletes+1)
assert(store.current.native_shelf.accessToken==previous.accessToken,'wrong-account renewal replaced native credential')
http.wrong_account=false

-- Same-account Web re-login preserves the independently granted Native shelf
-- authorization; a real account switch must not carry it across accounts.
store=new_store()
store.current.native_shelf={vid='alice',accessToken='native-token',refreshToken='native-refresh',deviceId='native-device'}
store.persisted=copy(store.current)
h=host(); flow=Auth:new(http,store,h)
name=flow:_finish({webLoginVid='alice',accessToken='web-new',refreshToken='web-new-refresh'})
assert(name=='Alice' and store.current.cookies.wr_skey=='web-new'
    and store.current.api_key=='new-skills-key' and store.current.login_session_id=='web-session-new')
assert(store.current.native_shelf and store.current.native_shelf.accessToken=='native-token',
    'same-account Web QR discarded Native shelf authorization')
store=new_store()
store.current.native_shelf={vid='alice',accessToken='native-token',refreshToken='native-refresh',deviceId='native-device'}
store.persisted=copy(store.current)
h=host(); flow=Auth:new(http,store,h)
name=flow:_finish({webLoginVid='bob',accessToken='web-bob',refreshToken='web-bob-refresh'})
assert(name=='Alice' and not store.current.native_shelf,'account switch carried Native shelf authorization')
for _,line in ipairs(logs) do
    for _,secret in ipairs({'uuid-secret','code-secret','ticket-secret','native-token','native-refresh'}) do
        assert(not line:find(secret,1,true),'QR or native credential leaked into logs')
    end
end
-- Global HTTP diagnostics also redact the new QR query parameters.
file=assert(io.open('miuread.koplugin/miuread/util.lua','rb'))
source=file:read('*a'); file:close()
local redactor=assert(source:match('(function U.redact_url%(value%).-\nend)'))
local utility=assert(loadstring('local U={}\n'..redactor..'\nreturn U'))()
local safe=utility.redact_url('https://example.test?uuid=uuid-secret&signature=ticket-secret&wx_code=code-secret&accessToken=native-token&refreshToken=native-refresh')
for _,secret in ipairs({'uuid-secret','ticket-secret','code-secret','native-token','native-refresh'}) do
    assert(not safe:find(secret,1,true),'HTTP log leaked a native QR query parameter')
end
print('native shelf QR, auth commit/cancellation, account guards and pre-write renewal: PASS')
