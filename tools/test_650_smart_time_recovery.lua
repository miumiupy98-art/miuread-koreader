-- Behavioral regression tests against production Store and Sync method bodies.
-- Uses isolated in-memory identities, no real WeRead requests or KOReader UI.
local function read(path)
    local f=assert(io.open(path,'rb'))
    local text=f:read('*a');f:close();return text
end
local store_src=read('miuread.koplugin/miuread/store.lua')
local sync_src=read('miuread.koplugin/miuread/sync.lua')
local function extract(source,beg,en)
    local i=assert(source:find(beg,1,true),beg)
    local j=assert(source:find(en,i+#beg,true),en)
    return source:sub(i,j-1)
end
local function copy(v)
    if type(v)~='table' then return v end
    local x={};for k,a in pairs(v) do x[k]=copy(a) end;return x
end
local function merge(a,b)
    local r=copy(a or {})
    for k,v in pairs(b or {}) do
        if type(v)=='table' and type(r[k])=='table' then r[k]=merge(r[k],v)
        else r[k]=copy(v) end
    end
    return r
end
U={merge=merge,copy=copy,read_file=function() return '{}' end,
    first_line=function(v) return tostring(v or '') end}
local notices={}
logger={info=function(...) notices[#notices+1]={...} end,warn=function(...) notices[#notices+1]={...} end}
defaults={auth={auth_revision=0}}
Store={}
assert(load(extract(store_src,'local function sanitized_auth(value)','function Store:clear_native_shelf_auth()')))()
local store={raw={login_session_id='login-a',auth_revision=28,
    account={vid='vid-a'},cookies={wr_skey='skey-a'},native_shelf={accessToken='token-a',refreshToken='rt-a',deviceId='d'}}}
setmetatable(store,{__index=Store})
function store:get() return copy(self.raw) end
function store:preferences() return {sync={time_enabled=true}} end
function store:set(k,value) assert(k=='auth'); self.raw=copy(value); return true end
store.db={saveSetting=function(_,k,v) assert(k=='auth');store.raw=copy(v) end}
assert(store:auth_revision()==28 and store:web_auth_revision()==28)
local native_only=store:auth();native_only.native_shelf.accessToken='token-b'
assert(store:save_auth(native_only)==true)
assert(store:auth_revision()==29 and store:web_auth_revision()==28,
    'Native-only renewal must not invalidate Web clock identity')
local unchanged=store:auth();assert(store:save_auth(unchanged)==true)
assert(store:web_auth_revision()==28 and store:auth_revision()==29)
local web_changed=store:auth(); web_changed.cookies.wr_skey='skey-b'
assert(store:save_auth(web_changed)==true)
assert(store:auth_revision()==30 and store:web_auth_revision()==29,
    'Real Web cookie change must invalidate Web worker identity')
local old=store:auth();old.cookies.wr_skey='obsolete'
assert(store:save_auth(old,{expected_revision=28})==false,'global CAS must stay strict')
local login_changed=store:auth(); login_changed.login_session_id='login-b'; login_changed.account.vid='vid-b'
assert(store:save_auth(login_changed,{replace_login=true})==true)
assert(store:web_auth_revision()==30 and store:auth_revision()==31,
    'Account switches must invalidate both identity versions')

-- Reinstall a controlled authentication state for sync tests.
store.raw={login_session_id='login-a',auth_revision=29,web_auth_revision=29,
    account={vid='vid-a'},cookies={wr_skey='skey-a'}}
Sync={}
assert(load(extract(sync_src,'function Sync:_rebind_web_readtime_identity(status,current_auth,current_revision)',
    'function Sync:_schedule_daemon_poll(delay)')))()
assert(load(extract(sync_src,'function Sync:switch_smart_time_backend(online,reason)',
    'function Sync:offline_time_controller()')))()
Json={decode=function() return {generation=1,controller_token='control-1',
    login_session_id='login-a',auth_revision=28,account_vid='vid-a',
    book_id='book-a',core_map_hash='map',state='waiting'} end}
local written,starts,segments={}, {}, 0
local daemon={active=true,generation=1,login_session_id='login-a',account_vid='vid-a',
    book_id='book-a',core_map_hash='map',paths={status='/status'}}
local subject={daemon=daemon,store=store,controller_token='control-1',
    reading_time_backend='web',current={book={book_id='book-a'}}}
setmetatable(subject,{__index=Sync})
function subject:reading_time_mode() return 'smart' end
function subject:web_readtime_disabled() return false end
function subject:_ensure_reading_time_ids(a,b) if b then segments=segments+1 end end
function subject:start(reason)
    starts[#starts+1]=reason
    self.daemon.generation=self.daemon.generation+1
    self.daemon.active=true
    self.daemon.identity_stale=false
    return true
end
function subject:_write_daemon_control(active) written[#written+1]=active;return true end
subject.host={ui={document={}},is_online=function()return true end}
process_alive=function() return true end
-- Same user, Web revision changed: rebind worker, no identity-stale stop.
subject:_import_daemon_status(false)
assert(#starts==1 and starts[1]=='web_auth_rebind', 'Web auth rotation should rebind once')
assert(not subject.daemon.identity_stale and subject.daemon.active)
assert(segments==0,'Active Web clock must preserve the current segment')
subject:_import_daemon_status(false)
assert(#starts==1,'Old-generation status must not trigger duplicate rebind')
-- Existing Web route must check whether its worker is actually active.
subject.daemon.active=false
assert(subject:switch_smart_time_backend(true,'network_connected'))
assert(starts[#starts]=='smart_web_service_recovery' and segments==1,
    'An inactive Web worker needs a NEW clock segment')
assert(subject:switch_smart_time_backend(true,'network_connected'))
assert(#starts==2,'A healthy worker must not be restarted')
-- Account change: never rebind or recover the old login's worker.
local forbidden={daemon={active=true,generation=1,login_session_id='login-a',account_vid='vid-a',book_id='book-a',
    core_map_hash='map',paths={status='/status'}},controller_token='control-1',reading_time_backend='web',
    current={book={book_id='book-a'}},store={auth=function()return {login_session_id='login-b',
        auth_revision=31,web_auth_revision=30,account={vid='vid-b'},cookies={wr_skey='new'}} end,
        preferences=function()return {sync={time_enabled=true}} end},
    host={ui={document={}}}}
setmetatable(forbidden,{__index=Sync})
function forbidden:web_readtime_disabled()return false end
function forbidden:_write_daemon_control(active) assert(active==false);return true end
function forbidden:start() error('Cross-account Web rebind forbidden') end
forbidden:_import_daemon_status(false)
forbidden:_import_daemon_status(false)
assert(forbidden.daemon.identity_stale==true and forbidden.daemon.active==false,
    'Cross-account stale worker must be quarantined')
print('PASS 6.5.0-beta.3: Native token isolation, global CAS, Web rebind, worker recovery, account isolation')
