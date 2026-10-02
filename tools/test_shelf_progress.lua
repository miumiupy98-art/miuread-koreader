-- Run from the repository root: lua5.1 tools/test_shelf_progress.lua
local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local U={copy=copy,clamp=clamp,trim=function(s) return tostring(s or ''):match('^%s*(.-)%s*$') end}
local Protocol={is_mp=function(id) return id=='mp' end,is_mp_account=function() return false end}
package.preload['logger']=function() return {info=function() end,warn=function() end} end
package.preload['miuread.protocol']=function() return Protocol end
package.preload['miuread.codec']=function() return {} end
package.preload['miuread.download_result']=function() return {} end
package.preload['miuread.util']=function() return U end
local Progress=require('miuread.shelf_progress')
local Library=require('miuread.library')

assert(Progress.parse({data={bookId='a',progress=1}},'a').percent==1)
assert(Progress.parse({books={{bookId='b',progress=88},{bookId='a',readingProgress=.42,updateTime=1700000000000}}},'a').percent==.42)
assert(Progress.parse({bookId='b',data={progress=88}},'a')==nil)
assert(Progress.parse({error='offline'},'a')==nil)
assert(Progress.percent(0/0)==nil and Progress.percent(math.huge)==nil)
local cycle={}; cycle.data=cycle; assert(Progress.parse(cycle,'a')==nil)

-- Keep actual reader API normalization consistent with the shelf percentage.
local sync_file=assert(io.open(ROOT..'miuread/sync.lua','rb'))
local sync_source=sync_file:read('*a'); sync_file:close()
local sync_start=assert(sync_source:find('local function progress_from_node(',1,true))
local sync_stop=assert(sync_source:find('\nlocal function response_progress(',sync_start,true))
local sync_chunk=assert(loadstring(sync_source:sub(sync_start,sync_stop-1)..'\nreturn progress_from_node'))
setfenv(sync_chunk,setmetatable({U=U},{__index=_G}))
local reader_progress=sync_chunk()
assert(reader_progress({bookId='a',progress=.5},'a').percent==.5,'reader expanded sub-1% cloud progress')
assert(reader_progress({bookId='a',progress=1},'a').percent==1)

local calls=0
local api={
    web_progress=function(_,id,opt)
        calls=calls+1
        assert(id=='a' and opt.no_auth_recovery and opt.retries==0)
        error('expired cookie')
    end,
    progress=function(_,id,opt)
        calls=calls+1; assert(id=='a' and opt.timeout[2]==5)
        return {data={bookId='a',progress=36}}
    end,
    chapters=function() error('shelf must not fetch chapters') end,
    book=function() error('shelf must not download books') end,
}
assert(Progress.fetch(api,'a').percent==36 and calls==2)
api.web_progress=function() return {progress=0} end
api.progress=function() error('valid zero must not fall through') end
assert(Progress.fetch(api,'a').percent==0)

local pending={progress_local_percent=68,progress_epoch=2,progress_latest_sequence=9,progress_verified_sequence=8,
    pending_progress={progress=68,progress_sequence=9,progress_epoch=2}}
assert(Progress.display({cloud_progress=32},pending).progress==68,'unsent Kindle progress was lost')
local outdated=copy(pending); outdated.progress_local_percent=11
assert(Progress.display({cloud_progress=32},outdated).progress==68,'older session hid the pending snapshot')
assert(Progress.display({cloud_progress=32},{progress_local_percent=11,verified_local_percent=11}).progress==32,
    'stale local progress hid newer phone progress')
assert(Progress.display({cloud_progress=0},{progress_local_percent=11}).progress==0,'cloud zero was replaced')
assert(Progress.display({cloud_progress=32,cloud_finished=true},pending).finished,'phone finished flag was lost')
assert(Progress.display({cloud_progress=32}, {progress_local_percent=11,progress_verified_sequence=8,
    pending_progress={progress_sequence=8}}).progress==32,'verified pending snapshot overrode cloud')
assert(Progress.display({cloud_progress=32}, {progress_local_percent=11,progress_latest_sequence=9,
    progress_verified_sequence=8}).progress==32,'orphaned sequence hid phone progress')
local reset=copy(pending); reset.progress_epoch=3
assert(Progress.display({cloud_progress=32},reset).progress==32,'reset transaction hid phone progress')
assert(Progress.display({cloud_progress=32}, {progress_local_percent=68,
    pending_progress={progress=68,progress_sequence=1,progress_epoch=1}}).progress==68,
    'legacy session with the default epoch lost its pending write')

local cache={books={},raw_books={}}
local store={sessions={}}
local cache_flushes=0
function store:shelf_cache() return copy(cache) end
function store:save_shelf_cache(v) cache_flushes=cache_flushes+1; cache=copy(v); return true end
function store:preferences() return {shelf_filter={enabled=false}} end
function store:save_preferences() return true end
function store:get(key,default) return key=='sessions' and self.sessions or copy(default) end
function store:set_deferred(key,value) if key=='shelf_cache' then cache=copy(value) end end
function store:auth() return {login_session_id='login',api_key='key'} end
local lib=Library:new({}, {}, store)
local rows=lib:_apply_stream_response{books={{bookId='a',finishReading=1},{bookInfo={bookId='b',finishReading=1},progress=15}},archive={}}
assert(rows[1].finished and rows[2].finished,'finishReading was ignored')
assert(not lib:account_row(rows[1],nil).downloaded,'cloud-only book became downloaded')
local flushes=cache_flushes
lib:apply_shelf_progress{a={percent=57,updated_at=10,fetched_at=20},b={percent=15,fetched_at=20}}
assert(cache.books[1].progress==57 and cache.books[1].finished)
assert(cache_flushes==flushes,'presentation batch flushed the entire settings file')
local changed,accepted=lib:apply_shelf_progress{a={percent=11,updated_at=9,fetched_at=21}}
assert(not changed and accepted.a==nil and cache.books[1].progress==57,'older cloud response regressed the cache')
rows=lib:_apply_stream_response{books={{bookId='a',finishReading=0},{bookId='b',finishReading=1}},archive={}}
assert(rows[1].progress==57 and not rows[1].finished,'refresh lost percentage or retained removed finished mark')
assert(rows[1].progress_fetched_at==nil,'manual shelf refresh did not renew progress')
assert(Progress.display(lib:account_row(rows[1],{progress=88}),{}).progress==57)
local generated=lib:generated_rows(rows,{},{{bookId='b',progress=2}}, {},true)
assert(generated[1].finished and generated[1].progress==15,'local shelf lost cloud finished state')
store.sessions.b=pending
generated=lib:generated_rows(rows,{},{{bookId='b',progress=68}}, {},true)
assert(generated[1].progress==68 and generated[1].finished,'device shelf lost unsent local progress')
store.sessions.b=nil
rows=lib:_apply_stream_response{books={{bookId='a',progress=0,finishReading=0}},archive={}}
assert(lib:account_row(rows[1],{progress=88}).progress==0,'explicit unread state was replaced')
rows=lib:_apply_stream_response{books={{bookId='a',progress=.5}},archive={}}
assert(rows[1].progress==.5,'sub-1% shelf percentage was expanded to a ratio')

-- Exercise the actual Home orchestration without KOReader widgets or network.
local file=assert(io.open(ROOT..'main.lua','rb')); local source=file:read('*a'); file:close()
local Plugin={}
local shown,offline,available,busy=true,false,true,false
local view={opts={shelf_books={}}}
local updated={}
local HomeView={is_shown=function() return shown end,current=function() return view end,
    update_book=function(id) updated[id]=true end,update_hero=function() end}
local scheduled={}
local UIManager={scheduleIn=function(_,_,fn) scheduled[#scheduled+1]=fn end}
local function child_store(auth)
    return {auth=function() return auth end,snapshot=function() return auth,false end}
end
local worker={}
function worker:available() return available end
function worker:busy() return self.callback~=nil end
function worker:run(_,fn,cb) self.fn=fn; self.callback=cb; return true end
function worker:finish()
    local cb=self.callback; self.callback=nil
    cb({ok=true,value=self.fn()})
end
function worker:cancel() self.callback=nil end
local network_calls={}
local child_api={web_progress=function(_,id) network_calls[#network_calls+1]=id; return {bookId=id,progress=45} end}
local env=setmetatable({Plugin=Plugin,HomeView=HomeView,UIManager=UIManager,U=U,Protocol=Protocol,
    ShelfProgress=Progress,UnifiedLibrary={canonical_source=function(b) return b.source end},
    interactive_child_store=child_store,Http={new=function() return {} end},Api={new=function() return child_api end}},
    {__index=_G})
local function load_method(name)
    local start=assert(source:find('function Plugin:'..name..'(',1,true))
    local stop=source:find('\nfunction Plugin:',start+1,true) or #source
    local chunk=assert(loadstring(source:sub(start,stop-1))); setfenv(chunk,env); chunk()
end
load_method('_home_schedule_progress'); load_method('_home_apply_shelf_progress')
local p=setmetatable({store=store,library=lib,home_progress_async=worker,_shelf_refresh_generation=1,
    _home_unified_all={},_home_unified_raw={},_home_cloud_page_cache={},
    _home_section_revisions={shelf=2,device=4,recent=6}}, {__index=Plugin})
function p:_active_reader_ui() return false end
function p:_home_background_blocked() return false end
function p:_home_ui_busy() return busy end
local idle_resumes=0
function p:_home_resume_visible_work_after_idle() idle_resumes=idle_resumes+1 end
function p:logged_in() return true end
function p:_network_radio_hint() return not offline end
function p:_background_claim() return 1 end
function p:_background_release() end
function p:_apply_interactive_auth() end
function p:_shelf_status_text(b) return b.finished and 'finished' or tostring(b.progress) end
function p:_home_mutate_book_rows(id,fn)
    for _,b in ipairs(view.opts.shelf_books) do if b.bookId==id then fn(b) end end
end
local function book(id,source_name) return {bookId=id,source=source_name or 'weread',downloaded=false} end
view.opts.shelf_books={book('a'),book('b'),book('c'),book('mp'),book('local','local')}
p._home_unified_raw.shelf=view.opts.shelf_books
assert(p:_home_schedule_progress() and #network_calls==0,'network ran in the UI thread')
worker:finish()
assert(#network_calls==2 and view.opts.shelf_books[1].progress==45 and not view.opts.shelf_books[1].downloaded)
assert(updated.a and updated.b,'cards were not updated')
assert(p._home_section_revisions.shelf==2 and p._home_section_revisions.device==4
    and p._home_section_revisions.recent==6,'progress update invalidated every shelf section')
updated.a,updated.b=nil,nil
local revision=p._home_section_revisions.shelf
p:_home_apply_shelf_progress{a={percent=45,fetched_at=os.time()+1},b={percent=45,fetched_at=os.time()+1}}
assert(not updated.a and not updated.b and revision==p._home_section_revisions.shelf,
    'unchanged percentages rebuilt cards and invalidated cached pages')
assert(p:_home_schedule_progress()); worker:finish()
assert(#network_calls==3 and network_calls[3]=='c','query was not bounded to visible WeRead books')
assert(not p:_home_schedule_progress(),'fresh page was fetched again')

view.opts.shelf_books={book('d')}; offline=true
assert(not p:_home_schedule_progress(),'offline refresh started network work')
offline=false; available=false
assert(not p:_home_schedule_progress(),'worker fell back to blocking network')
available=true
assert(p:_home_schedule_progress())
p._shelf_refresh_generation=2; worker:finish()
assert(view.opts.shelf_books[1].progress==nil,'stale shelf response was applied')
assert(p:_home_schedule_progress())
p._home_progress_generation=1; worker:finish()
assert(view.opts.shelf_books[1].progress==nil,'cancelled page response was applied')
assert(p:_home_schedule_progress())
function store:auth() return {login_session_id='other',api_key='key'} end
worker:finish()
assert(view.opts.shelf_books[1].progress==nil,'different account received old progress')

-- Cloud verification can complete while the shelf read is still in flight.
function store:auth() return {login_session_id='login',api_key='key'} end
view.opts.shelf_books={book('verified')}
assert(p:_home_schedule_progress())
store.sessions.verified={verified_at=os.time(),progress_verified_sequence=9}
view.opts.shelf_books[1].progress=69
worker:finish()
assert(view.opts.shelf_books[1].progress==69,'in-flight shelf read overwrote a verified reader upload')

-- Failure must retain the last percentage and avoid an immediate retry loop.
function store:auth() return {login_session_id='login',api_key='key'} end
child_api.web_progress=function() error('offline') end
view.opts.shelf_books={book('e')}; view.opts.shelf_books[1].progress=20
assert(p:_home_schedule_progress()); worker:finish()
assert(view.opts.shelf_books[1].progress==20 and not p:_home_schedule_progress())

-- Input takes priority over both starting and applying presentation reads.
child_api.web_progress=function(_,id) return {bookId=id,progress=45} end
view.opts.shelf_books={book('busy')}; busy=true
assert(not p:_home_schedule_progress(),'progress query started during interaction')
busy=false; assert(p:_home_schedule_progress()); busy=true
worker:finish()
assert(view.opts.shelf_books[1].progress==nil and idle_resumes==1,'result repainted while the user was interacting')
busy=false
assert(p:_home_schedule_progress()); worker:finish()
assert(view.opts.shelf_books[1].progress==45,'query did not resume after interaction')

-- Exercise the actual gesture/page path with an in-flight presentation read.
load_method('_home_note_interaction'); load_method('_background_cancel_worker')
load_method('_home_cancel_visible_page_work'); load_method('_home_change_page')
env.Config={}; env.monotonic_wall_time=os.clock; env.logger=require('logger')
env.Time={now=os.time}
function p:_home_clear_lockscreen_visual_hold() end
function p:_home_bump_interaction_generation() end
view.opts.shelf_books={book('turn')}
assert(p:_home_schedule_progress())
local late=worker.callback
local released=0
p.background_scheduler={active={key='home_progress'},set_foreground_barrier=function() end,
    force_release=function(self) self.active=nil; released=released+1 end,cancel_key=function() end}
p:_home_note_interaction(false,'page-next')
assert(not worker:busy() and released==1,'gesture left presentation query competing with a page turn')
local home={page_by_section={shelf=1}}
p._home_active_section='shelf'; p._home_sections={shelf={rows={}}}
function p:_home_preferences() return home,{} end
function p:_home_page_limit() return 8 end
function p:_home_preview_page(_,_,page) return {},page,2 end
function p:_save_home_preferences_deferred() end
local rendered=false
function p:_home_apply_section() rendered=true; assert(not worker:busy()); return true end
assert(p:_home_change_page(1) and home.page_by_section.shelf==2 and rendered,'page turn waited for progress query')
late({ok=true,value={updates={turn={percent=99}}}})
assert(view.opts.shelf_books[1].progress==nil,'retired page query overwrote the new page')

-- Verify the manual Refresh button still drives the cloud-shelf refresh path.
load_method('_home_manual_refresh')
local manual=false
function p:_home_refresh_remote(force,user) manual=force and user; return true end
function p:_home_scan_local() end
p._home_active_section='shelf'; p:_home_manual_refresh(); assert(manual)

-- A successful shelf refresh must wake presentation reads and pending uploads.
load_method('_refresh_shelf_async')
env.monotonic_wall_time=os.clock
env.logger={info=function() end,warn=function() end}
local retained,resumed,recovered=false,0,0
local refresh=setmetatable({api={shelf=function() return {} end},library={
    _apply_stream_response=function() return {},{},false,retained end}}, {__index=Plugin})
function refresh:is_online() return true end
function refresh:_mark_auth_channel_ok() end
function refresh:_consume_shelf_filter_recovery_notice() end
function refresh:_handle_large_shelf_group_hint_refresh() end
function refresh:_active_reader_ui() return false end
function refresh:_home_resume_visible_work_after_idle() resumed=resumed+1 end
function refresh:_schedule_home_progress_recovery() recovered=recovered+1 end
function refresh:_pump_finished_status() end
assert(refresh:_refresh_shelf_async(nil,true)); table.remove(scheduled)()
assert(resumed==1 and recovered==1,'shelf refresh did not resume both sync directions')
retained=true
assert(refresh:_refresh_shelf_async(nil,true)); table.remove(scheduled)()
assert(resumed==1 and recovered==1,'unusable shelf response retriggered progress reads')

-- A coordinate recovery followed by an upload must resume after the cooldown,
-- instead of silently dropping the continuation scheduled 1.8 seconds later.
load_method('_schedule_home_progress_recovery')
local clock,stage,uploaded=100,'coordinates',false
env.os={time=function() return clock end}
local timers={}
UIManager.scheduleIn=function(_,delay,fn) timers[#timers+1]={delay=delay,fn=fn} end
UIManager.unschedule=function() end
env.logger={info=function() end}
local recovery=setmetatable({}, {__index=Plugin})
function recovery:_active_reader_ui() return false end
function recovery:logged_in() return true end
function recovery:_network_radio_hint() return not offline end
function recovery:_clear_verified_progress_ghosts() end
function recovery:_progress_sync_issue_items()
    return stage=='coordinates' and {{can_recover_coordinate=true}} or {{can_send=true}}
end
function recovery:_recover_all_pending_progress_coordinates(_,done) stage='upload'; done() end
function recovery:_submit_all_saved_pending_progress(_,done) uploaded=true; done() end
local function tick()
    local timer=table.remove(timers,1); assert(timer)
    clock=clock+timer.delay; timer.fn()
end
recovery:_schedule_home_progress_recovery(2.4); tick(); tick()
assert(not uploaded and #timers==1,'cooldown continuation was lost')
tick(); assert(uploaded,'coordinate recovery never reached pending upload')
timers={}; offline=true
recovery:_schedule_home_progress_recovery(2.4); tick()
assert(#timers==0,'offline recovery kept scheduling network work')
offline=false; env.os=nil

-- Replay checks the phone first, so an offline Kindle transaction cannot
-- silently overwrite reading done on the phone while it was disconnected.
load_method('_submit_recovered_progress_snapshot')
local replay_session={progress_epoch=1,cloud_anchor={chapter_uid='8',chapter_offset=100}}
local remote_callback,submitted,submission_options,replay_error,choice_cleared
local replay=setmetatable({sync={}}, {__index=Plugin})
function replay:_persisted_sessions() return {a=replay_session} end
replay.store={save_session=function(_,_,update) for k,v in pairs(update) do replay_session[k]=v end end}
function replay.sync:remote(_,done,opt)
    assert(opt.detached and opt.raw_coordinate and opt.update_cloud_anchor==false)
    remote_callback=done
end
function replay:_progress_snapshot_current() return true end
function replay:_remote_matches(remote,position)
    return not remote.conflict and remote.chapter_uid==position.chapter_uid and remote.offset==position.offset
end
function replay:_save_pending_progress(_,position,reason,state)
    replay_session.pending_progress=copy(position); replay_session.progress_sync_state=state
end
function replay:_save_progress_state(_,state) replay_session.progress_sync_state=state end
function replay:_clear_progress_resolution() choice_cleared=true end
function replay:_submit_progress_snapshot(_,_,options) submitted=true; submission_options=options end
local replay_position={chapter_uid='8',offset=200,progress=20,captured_at=100}
local function check_replay(remote)
    submitted=false; choice_cleared=false; replay_error=nil; submission_options=nil
    replay:_submit_recovered_progress_snapshot('a',replay_position,{},function(_,_,err) replay_error=err end)
    assert(not submitted,'upload started before the cloud read')
    remote_callback(remote)
end
check_replay({chapter_uid='8',offset=100,updated_at=120,percent=10})
assert(submitted,'unchanged phone position blocked a safe replay')
check_replay({chapter_uid='8',offset=300,updated_at=120,percent=30})
assert(not submitted and replay_error=='remote_position_changed' and choice_cleared)
assert(replay_session.progress_upload_state=='conflict','phone change did not block automatic replay')
check_replay({chapter_uid='8',offset=200,updated_at=120,percent=20})
assert(submitted and submission_options.verify_first,'already accepted position was sent again')
check_replay({conflict=true,percent=20})
assert(not submitted,'disagreeing cloud sources were overwritten')
check_replay(nil)
assert(not submitted and replay_session.progress_sync_state=='waiting_network','failed read dispatched the pending write')
replay_session.cloud_anchor=nil
check_replay({chapter_uid='8',offset=100,updated_at=90,percent=10})
assert(not submitted,'device clock ordering allowed replay without a cloud baseline')
check_replay({chapter_uid='8',offset=300,updated_at=120,percent=30})
assert(not submitted,'legacy replay overwrote a newer cloud position')
check_replay({chapter_uid='8',offset=100,percent=10})
assert(not submitted,'unknown cloud ordering allowed automatic replay')
function replay:_progress_snapshot_current() return false end
check_replay({chapter_uid='8',offset=100,updated_at=90,percent=10})
assert(not submitted and replay_error=='superseded','stale recovery uploaded a replaced transaction')
function replay:_progress_snapshot_current() return true end

-- Confirmed cloud selection invalidates the old pending transaction, so its
-- callback cannot later upload the position the user just discarded.
load_method('_use_remote_position')
replay_session.pending_progress=copy(replay_position)
replay_session.progress_epoch=1
function replay.sync:jump_remote() return true end
function replay.sync:resolve_local_progress(done) done({chapter_uid='8',offset=300,progress=30}); return true end
function replay.sync:set_cloud_anchor() end
function replay.sync:mark_verified() end
function replay.sync:end_progress_sync() end
function replay:status_toast() end
timers={}
replay:_use_remote_position('a',20,{chapter_uid='8',offset=300,percent=30})
table.remove(timers,1).fn()
assert(replay_session.progress_epoch==2 and replay_session.pending_progress==false,
    'cloud selection retained the old local transaction')
load_method('_home_all_books_apply')
function p:_home_book_time() return 0 end
function p:_home_all_books_state() return {source='all',status='finished',sort='title'} end
local states={book('complete'),book('reading'),book('unread')}
states[1].cloud_finished=true; states[1].progress=0; states[2].progress=20; states[3].progress=0
assert(#p:_home_all_books_apply(states)==1,'finished filter ignored the phone completion flag')
function p:_home_all_books_state() return {source='all',status='unread',sort='title'} end
assert(#p:_home_all_books_apply(states)==1,'finished book appeared as unread')
function p:_home_all_books_state() return {source='all',status='reading',sort='title'} end
assert(#p:_home_all_books_apply(states)==1,'finished book appeared as reading')

-- Updating one book invalidates only inactive rendered layers containing it.
file=assert(io.open(ROOT..'miuread/home_view.lua','rb')); local widget_source=file:read('*a'); file:close()
local widget_start=assert(widget_source:find('function HomeWidget:updateBook(',1,true))
local widget_stop=assert(widget_source:find('\nfunction ',widget_start+1,true))
local HomeWidget={}
local widget_chunk=assert(loadstring(widget_source:sub(widget_start,widget_stop-1)))
setfenv(widget_chunk,setmetatable({HomeWidget=HomeWidget},{__index=_G})); widget_chunk()
local freed={}
local function layer(name) return {free=function() freed[name]=true end} end
local active,affected,unrelated=layer('active'),layer('affected'),layer('unrelated')
local layers={active={layer=active,slots={a={}}},affected={layer=affected,slots={a={}}},
    unrelated={layer=unrelated,slots={c={}}}}
local widget=setmetatable({_section_layer=active,_section_layer_cache=layers,_section_book_slots={}},
    {__index=HomeWidget})
widget:updateBook('a')
assert(layers.active and layers.unrelated and not layers.affected and freed.affected
    and not freed.active and not freed.unrelated,'book update discarded unrelated or active rendered layers')
widget:updateBook('missing'); assert(layers.unrelated,'unknown book discarded a cached layer')

-- Reading verification updates the cloud cache without erasing an independent
-- phone finishReading flag, even when the reader is below 100%.
file=assert(io.open(ROOT..'miuread/store.lua','rb')); source=file:read('*a'); file:close()
local start=assert(source:find('function Store:update_cached_progress(',1,true))
local stop=assert(source:find('\nfunction Store:',start+1,true))
local Store={}; local chunk=assert(loadstring(source:sub(start,stop-1)))
setfenv(chunk,setmetatable({Store=Store,U=U,ShelfProgress=Progress},{__index=_G})); chunk()
cache={raw_books={{bookId='a',progress=15,cloud_finished=true}},books={{bookId='a',progress=15,cloud_finished=true}}}
Store.update_cached_progress(store,'a',68)
assert(cache.books[1].cloud_progress==68 and cache.books[1].finished and cache.books[1].progress_fetched_at>0)
print('shelf progress: PASS')
