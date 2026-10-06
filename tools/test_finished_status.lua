-- Run from the repository root: lua5.1 tools/test_finished_status.lua
local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local U={copy=copy,first_line=function(s) return tostring(s) end}
local Protocol={is_mp=function(id) return id=='mp' end,is_mp_account=function(id) return id=='mp-account' end,
    escape=function(id) return id end,reader_url=function(id) return 'https://weread.qq.com/web/reader/'..id end}
package.preload['miuread.util']=function() return U end
package.preload['miuread.protocol']=function() return Protocol end
package.preload['miuread.codec']=function() return {} end
package.preload['miuread.http']=function() return {is_auth_error=function(err) return tostring(err):find('auth expired',1,true)~=nil end} end
package.preload['logger']=function() return {info=function() end,warn=function() end} end
local Finished=require('miuread.finished_status')
local Progress=require('miuread.shelf_progress')
local Api=require('miuread.api')
local clock=1000
local real_time=os.time; os.time=function() return clock end

assert(Finished.parse({finishedBookIndex=0},'a')==false)
assert(Finished.parse({data={bookId='a',finishedBookIndex=5}},'a')==true)
assert(Finished.parse({bookId='b',data={finishedBookIndex=5}},'a')==nil)
assert(Finished.parse({finishedBookCount=12},'a')==nil)
assert(Finished.parse({finishedBookIndex=-1},'a')==nil)
assert(Finished.parse({finishedBookIndex=0/0},'a')==nil)
assert(Finished.parse({finishedBookIndex=math.huge},'a')==nil)
local cycle={}; cycle.data=cycle; assert(Finished.parse(cycle,'a')==nil)
assert(not Progress.is_finished({cloud_finished=false,progress=100,finished=true}))
assert(Progress.display({cloud_finished=false,cloud_progress=100},{}).finished==false)
assert(Progress.is_finished({finished_pending=true,cloud_finished=false,progress=2}))
assert(not Progress.is_finished({finished_pending=false,cloud_finished=true,progress=100}))

local function store(disk)
    local s={data=copy(disk or {}),disk=copy(disk or {}),vid='user',cache={raw_books={{bookId='a',progress=33}},books={}}}
    function s:auth() return {account={vid=self.vid},login_session_id='session',api_key='key'} end
    function s:get(key,default) return self.data[key] or copy(default) end
    function s:set(key,value)
        self.saves=(self.saves or 0)+1
        self.data[key]=value
        if self.fail_save then return false end
        self.disk[key]=copy(value); return true
    end
    function s:set_deferred(key,value) self.data[key]=value end
    function s:shelf_cache() return self.cache end
    function s:save_shelf_cache(value) self.cache=value; return true end
    return s
end
local function worker()
    local w={}
    function w:available() return true end
    function w:busy() return self.callback~=nil end
    function w:run(label,fn,cb)
        if self.fail_write_start and label=='finished-status-write' then return false end
        assert(not self:busy(),'concurrent finished writers')
        self.fn,self.callback=fn,cb; return true
    end
    function w:finish()
        local fn,cb=self.fn,self.callback; assert(cb)
        self.fn,self.callback=nil,nil
        local ok,value=pcall(fn); cb(ok and {ok=true,value=value} or {ok=false,error=value})
    end
    function w:cancel() self.fn,self.callback=nil,nil end
    return w
end
local remote,offline,effect,post_error=false,false,true,false
local writes,reads,renewals=0,0,0
local http={}
function http:get_json(url,opt)
    reads=reads+1
    assert(url:find('/web/book/readInfo?',1,true) and url:find('finishedBookIndex=1',1,true))
    assert(opt.auth and opt.retries==0 and opt.headers['Cache-Control']:find('no-store',1,true))
    if offline then error('offline') end
    return {finishedBookIndex=remote and 5 or 0}
end
function http:post_json(url,body,opt)
    writes=writes+1
    assert(url=='https://weread.qq.com/web/book/markStatus','case-sensitive web endpoint')
    assert(body.bookId=='a' and body.status==4 and opt.auth and opt.retries==0 and opt.rate_limit_retries==0)
    assert(body.finishInfo==(body.isCancel==0 and 1 or 0))
    assert(body.progress==nil and body.chapterUid==nil and body.co==nil,'marking changed reading coordinates')
    if effect then remote=body.isCancel==0 end
    if post_error then error('auth expired') end
    return {succ=1}
end
local api=Api:new(http,{}, {_recover_login_session=function() renewals=renewals+1; return true end})
local function make_request(mode,id,desired)
    return function()
        if mode=='write' then pcall(api.mark_book_finished,api,id,desired) end
        local ok,data=pcall(api.book_read_info,api,id)
        local result={}; if ok then result.finished=Finished.parse(data,id) end
        return result
    end
end
local changes={}
local function changed(id,phase) changes[#changes+1]=phase end
local s,w=store(),worker()
local status=Finished:new(s,w)
assert(Finished:new(s,worker())==status,'reader and home created separate owners')
local session={chapter=7,co=12345,progress=33}
s.data.sessions={a=copy(session)}
local baseline=status:snapshot()
assert(status:request('a',true))
assert(status:overlay({bookId='a',progress=33}).finished_pending==true)
assert(status:pump(make_request,changed)); w:finish()
assert(status:entry('a').phase=='verifying' and w:busy(),'write did not commit its uncertainty first')
w:finish()
assert(status:entry('a').phase=='verified' and writes==1 and remote)
assert(s.cache.raw_books[1].progress==33 and s.cache.raw_books[1].cloud_finished==true)
assert(s.data.sessions.a.chapter==7 and s.data.sessions.a.co==12345 and s.data.sessions.a.progress==33)
local old_shelf={bookId='a',cloud_finished=false,progress=33}
status:reconcile({old_shelf},baseline)
assert(old_shelf.finished and status:entry('a').phase=='verified','late shelf read undid mark')
local fresh=status:snapshot()
status:reconcile({{bookId='a',cloud_finished=false}},fresh)
assert(status:entry('a').phase=='observed','later phone change could never replace local mark')

-- A shelf refresh retires all acknowledged intents with one settings save.
local batch_store=store({finished_status={}})
local batch=Finished:new(batch_store)
local batch_rows={}
for i=1,12 do
    local id=tostring(i)
    batch_store.data.finished_status[id]={account='user',desired=true,sequence=1,
        phase='verified',requested_at=clock,retry_at=0}
    batch_rows[i]={bookId=id,cloud_finished=false}
end
batch_store.disk=copy(batch_store.data)
batch:reconcile(batch_rows,batch:snapshot())
assert(batch_store.saves==1,'shelf reconciliation flushed settings per book')
for _,row in ipairs(batch_rows) do
    assert(not row.finished and batch_store.disk.finished_status[row.bookId].phase=='observed',
        'batched reconciliation lost a phone change')
end
batch:reconcile(batch_rows,batch:snapshot())
assert(batch_store.saves==1,'unchanged shelf reconciliation saved settings')

-- A failed batch flush preserves every confirmed local intent in memory and on disk.
for _,entry in pairs(batch_store.data.finished_status) do entry.phase='verified' end
batch_store.disk=copy(batch_store.data)
batch_store.fail_save=true
batch:reconcile(batch_rows,batch:snapshot())
for _,row in ipairs(batch_rows) do
    assert(row.finished and batch:entry(row.bookId).phase=='verified'
        and batch_store.disk.finished_status[row.bookId].phase=='verified',
        'failed batch flush retired a confirmed intent')
end

remote=true
assert(status:request('a',false)); assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(not remote and status:entry('a').phase=='verified')
local cancelled=status:overlay({bookId='a',cloud_progress=100,cloud_finished=true})
assert(not Progress.display(cancelled,{}).finished,'100% made cancellation impossible')
local before=writes
assert(status:request('a',false)); assert(status:pump(make_request,changed)); w:finish()
assert(writes==before and status:entry('a').phase=='verified','already matching state was written again')

-- Offline preflight persists, then resumes after restarting the plugin.
offline=true
assert(status:request('a',true)); assert(status:pump(make_request,changed)); w:finish()
assert(status:entry('a').phase=='queued' and writes==before)
s=store(s.disk); w=worker(); status=Finished:new(s,w)
assert(not status:pump(make_request,changed) and status:retry_delay()==60)
assert(status:next_due(true)=='a','manual refresh could not bypass offline cooldown')
offline=false; clock=clock+61
assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(status:entry('a').phase=='verified' and remote)

-- A positive HTTP acknowledgement is not proof that the phone changed.
effect=false
assert(status:request('a',false)); assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(status:entry('a').phase=='verifying')
before=writes; clock=clock+61
assert(status:pump(make_request,changed)); w:finish()
clock=clock+5
assert(status:pump(make_request,changed)); w:finish()
assert(writes==before and status:entry('a').phase=='unconfirmed','ambiguous write was automatically replayed')
clock=clock+61
assert(status:retry_delay()==nil and not status:pump(make_request,changed),'unconfirmed state kept polling forever')
assert(status:pump(make_request,changed,nil,true)); w:finish()
assert(writes==before,'manual shelf verification replayed the POST')
effect=true
assert(status:request('a',false)); assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(not remote and status:entry('a').phase=='verified','explicit retry did not work')

-- Transport/authentication failure may occur after the server has committed.
post_error=true
assert(status:request('a',true)); assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(remote and status:entry('a').phase=='verified' and renewals==0,'POST was replayed during authentication recovery')
post_error=false
assert(status:request('a',false)); assert(status:pump(make_request,changed)); w:finish()
local running=w.fn; running() -- server committed; parent result not delivered yet
status:cancel('suspend')
s=store(s.disk); w=worker(); status=Finished:new(s,w)
before=writes; clock=clock+61
assert(status:pump(make_request,changed)); w:finish()
assert(status:entry('a').phase=='verified' and writes==before,'interrupted POST was repeated')

-- A new intent and an account change invalidate old callbacks.
assert(status:request('a',true)); assert(status:pump(make_request,changed)); w:finish()
assert(status:request('a',false)); w:finish()
assert(status:entry('a').phase=='queued' and status:entry('a').desired==false)
assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(not remote and status:entry('a').phase=='verified')
assert(status:request('a',true)); assert(status:pump(make_request,changed))
s.vid='other'; before=writes; w:finish()
assert(status:entry('a')==nil and writes==before,'previous account reached write stage')
s.vid='user'

-- Failed persistence or spawning never produces an untracked cloud write.
s.fail_save=true; before=writes
assert(not status:request('a',false))
assert(status:entry('a').desired==true,'failed flush changed live intent')
s.fail_save=false
assert(status:request('a',true)); w.fail_write_start=true
assert(status:pump(make_request,changed)); w:finish()
assert(status:entry('a').phase=='queued' and writes==before)
w.fail_write_start=false; clock=clock+61
assert(status:pump(make_request,changed)); s.fail_save=true; w:finish()
assert(not w:busy() and writes==before,'write started without durable phase')
s.fail_save=false
assert(status:entry('a').phase=='queued','unsent operation became verify-only after a failed save')
clock=clock+61
assert(status:pump(make_request,changed)); w:finish(); w:finish()
assert(status:entry('a').phase=='verified' and remote,'unsent operation could not recover after storage failure')
assert(status:request('a',true))
assert(not status:request('mp',true) and not status:request('mp-account',false))

-- Exercise actual menu callbacks, including cloud-only books and queued retry.
local file=assert(io.open(ROOT..'main.lua','rb')); local source=file:read('*a'); file:close()
local Plugin={}
local env=setmetatable({Plugin=Plugin,U=U,Protocol=Protocol,ShelfProgress=Progress},{__index=_G})
local name='_finished_status_action'
local start=assert(source:find('function Plugin:'..name..'(',1,true))
local stop=assert(source:find('\nfunction Plugin:',start+1,true))
local chunk=assert(loadstring(source:sub(start,stop-1))); setfenv(chunk,env); chunk()
local plugin=setmetatable({store=s,finished_status=status},{__index=Plugin})
function plugin:logged_in() return true end
function plugin:_request_finished_status(book,desired) self.requested={id=book.bookId,desired=desired} end
function plugin:list(_,items) self.items=items end
local action=plugin:_finished_status_action({bookId='a'})
action.callback(); plugin.items[1].callback(); assert(plugin.requested.desired==true)
plugin.items[2].callback(); assert(plugin.requested.desired==false)
status:reconcile({{bookId='a',cloud_finished=false}},nil)
local entry=copy(status:entry('a')); entry.phase='verified'; entry.desired=false; status:_save('a',entry)
s.cache.raw_books[1]={bookId='a',progress=100,cloud_finished=false}
action=plugin:_finished_status_action({bookId='a'})
assert(action.text=='标记为已读完'); action.callback(); assert(plugin.requested.desired==true)
assert(plugin:_finished_status_action({bookId='mp'})==nil)

-- Run the actual plugin worker builder, including its isolated child API.
local function load_method(method)
    local first=assert(source:find('function Plugin:'..method..'(',1,true))
    local last=assert(source:find('\nfunction Plugin:',first+1,true))
    local fn=assert(loadstring(source:sub(first,last-1))); setfenv(fn,env); fn()
end
env.FinishedStatus=Finished
env.HOME_SESSION={}
env.Http={new=function() return http end}
env.Reader={new=function() return {} end}
env.Api=Api
env.logger=require('logger')
env.interactive_child_store=function(auth)
    return {snapshot=function() return auth,false end}
end
load_method('_pump_finished_status')
plugin.store=store(); w=worker(); plugin.finished_status=Finished:new(plugin.store,w)
function plugin:_network_radio_hint() return true end
function plugin:_schedule_finished_status() end
function plugin:_finished_status_changed(id,phase) changed(id,phase) end
function plugin:_apply_interactive_auth() end
remote=false
assert(plugin.finished_status:request('a',true))
assert(plugin:_pump_finished_status()); w:finish(); w:finish()
assert(plugin.finished_status:entry('a').phase=='verified' and remote)

-- Reader callbacks repaint through the current home owner after closing a book.
load_method('_finished_status_changed')
load_method('_schedule_finished_status')
local home=setmetatable({finished_status=plugin.finished_status},{__index=Plugin})
env.home_owner=function() return home end
env.HomeView={is_shown=function() return true end,update_book=function() end}
local repaint,notice,pumped
function home:_home_mutate_book_rows(id,apply)
    local row={bookId=id}; apply(row); repaint=row.finished
end
function home:_shelf_status_text() return '' end
function home:_active_reader_ui() return nil end
function home:_notify_home_data_changed() notice=true end
function home:toast() end
function home:_pump_finished_status() pumped=true end
plugin._finished_status_changed=nil
plugin:_finished_status_changed('a','verified')
assert(repaint==true and notice,'reader callback missed the active home owner')
env.UIManager={scheduleIn=function(_,_,task) env.scheduled=task end,unschedule=function() end}
plugin._schedule_finished_status=nil
plugin:_schedule_finished_status(2); env.scheduled()
assert(pumped,'retry ran through a retired reader instance')
plugin:_schedule_finished_status(2); plugin:_schedule_finished_status(nil)
assert(plugin.finished_status.task==nil,'empty queue retained a timer')

-- Authentication renewal can replay a GET, never the status POST.
local get=http.get_json
local expired=true
http.get_json=function(self,url,opt)
    if expired then expired=false; error('auth expired') end
    return get(self,url,opt)
end
assert(Finished.parse(api:book_read_info('a'),'a')==true and renewals==1)
before=writes
assert(not pcall(api.mark_book_finished,api,'mp',true))
assert(not pcall(api.mark_book_finished,api,'a',1))
assert(writes==before)

os.time=real_time
print('finished status: PASS')
