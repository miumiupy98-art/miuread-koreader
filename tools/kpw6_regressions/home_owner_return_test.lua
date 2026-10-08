-- Usage: luajit tools/kpw6_regressions/home_owner_return_test.lua miuread.koplugin/main.lua
-- Home may be retained by a different plugin instance than the ReaderUI that
-- closes. Returning must thaw that retained owner and route Home callbacks to it.
local f=assert(io.open(assert(arg[1]))); local source=f:read('*a'); f:close()
local owner,interaction,lifecycle,shown,power
local notices,requests,applied,recent=0,0,0,0
local close={generation=1,state='document_closed',requested_clock=0}
local session={home_restore_generation=1}
local env={Plugin={},READER_CLOSE=close,HOME_SESSION=session,Config={},
    logger={info=function() end,warn=function() end},
    PowerState={state=function() return power end},
    home_owner=function() return owner end,
    persist_home_session=function() end,sync_home_session=function() end,
    reader_close_active=function() return false end,
    HomeView={is_shown=function() return shown end,current=function() return {} end,
        raise=function() end,unpark=function(_,opts) interaction=opts.on_interaction end},
    UIManager={setDirty=function() end,scheduleIn=function() end},
    require=function(name)
        assert(name=='apps/filemanager/filemanager'); return {instance={}}
    end,
}
setmetatable(env,{__index=_G})
for _,name in ipairs({'_complete_reader_close','_restore_home_after_reader_close',
    '_home_background_blocked','_home_clear_lockscreen_visual_hold','_home_refresh_remote'}) do
    local a=assert(source:find('function Plugin:'..name..'(',1,true))
    local b=assert(source:find('\nfunction Plugin:',a+1,true))
    local chunk=assert(loadstring(source:sub(a,b-1))); setfenv(chunk,env); chunk()
end
local function host()
    local h={_desktop_frozen=true,_home_background_stopped_for_reader=true,
        _home_lockscreen_visual_hold=true,
        _reader_close_snapshot=function() return {lifecycle=lifecycle,filemanager={}} end,
        _reader_lifecycle_state=function() return lifecycle end,
        _active_reader_ui=function() return lifecycle~='closed' and {} or nil end,
        _page_transition_active=function() return false end,
        _home_enabled=function() return true end,
        _ensure_reader_transition_guard=function() end,_close_miuread_transients=function() end,
        _set_foreground=function() end,_set_navigation_state=function() end,
        _close_reader_recovery_surface=function() end,_release_reader_transition_guard=function() end,
        _finish_page_transition=function() end,_resume_pending_post_reader_work=function() end,
        _record_performance=function() end,_background_log_state=function() end,_clear_reader_return=function() close.state='idle' end,
        _home_note_interaction=function(self) self.interacted=true end,
        _home_apply_recent_snapshot_to_home=function() recent=recent+1 end,
        _home_enter_post_reader_priority_window=function(self,seconds) self.priority=seconds end,
        _resume_home_preferences_flush=function(self,delay) self.flush_delay=delay end,
        _home_schedule_clock=function() end,
        _lightweight_enabled=function() return false end,logged_in=function() return true end,
        is_online=function() return true end,toast=function() notices=notices+1 end,
        shelf_async={available=function() return true end},
        library={cached=function() return {},{},0 end},
        _background_claim=function() return 1 end,_background_release=function() end,
        _home_apply_remote_cache_snapshot=function() applied=applied+1 end,
        _refresh_shelf_async=function(_,callback)
            requests=requests+1; callback({{bookId='new'}},{},nil); return true
        end,
    }
    return setmetatable(h,{__index=env.Plugin})
end
local function reset()
    lifecycle='closed';shown=true;power='NORMAL';interaction=nil
    notices=0;requests=0;applied=0;recent=0
    close.state='document_closed';session.home_restore_active=false
    owner=host()
    return host()
end
local function verify_refresh(h,label)
    assert(not h:_home_background_blocked(),label..': retained Home owner remains blocked')
    assert(h._home_background_stopped_for_reader==false,label..': next reader entry cannot stop Home work')
    assert(h.priority==4,label..': first-frame priority barrier is on wrong instance')
    assert(h.flush_delay and h.flush_delay>=4,label..': deferred Home preferences not resumed')
    interaction(true,'tap'); assert(h.interacted,label..': interaction still targets closed Reader owner')
    assert(h:_home_refresh_remote(true,true),label..': refresh did not start')
    assert(requests==1 and notices==2 and applied==1,label..': refresh request/result/toasts missing')
    assert(h._home_remote_refreshing==false,label..': refresh remains busy after completion')
end
local reader=reset()
assert(reader:_complete_reader_close(1,'test'))
verify_refresh(owner,'separate instances')
assert(recent==1)
reader=reset(); owner=reader
assert(reader:_complete_reader_close(1,'test'))
verify_refresh(owner,'same instance')
reader=reset(); owner=nil
assert(reader:_complete_reader_close(1,'test'))
verify_refresh(reader,'missing retained owner')
for _,state in ipairs({'active','closing'}) do
    reader=reset();lifecycle=state
    assert(not reader:_complete_reader_close(1,'test'))
    assert(owner._desktop_frozen and owner._home_lockscreen_visual_hold and not interaction,
        'Home thawed before native Reader closed')
end
reader=reset()
assert(not reader:_complete_reader_close(2,'stale'))
assert(owner._desktop_frozen and not interaction,'stale close thawed Home')
reader=reset();close.state='idle'
assert(reader:_restore_home_after_reader_close(1,1))
verify_refresh(owner,'fallback reveal')
reader=reset();close.state='idle';session.suspended=true
assert(not reader:_restore_home_after_reader_close(1,1))
assert(owner._desktop_frozen and not interaction,'suspend guard bypassed')
session.suspended=false
reader=reset();close.state='idle'
assert(not reader:_restore_home_after_reader_close(1,2))
assert(owner._desktop_frozen and not interaction,'stale reveal thawed Home')
reader=reset();close.state='idle';lifecycle='active'
assert(not reader:_restore_home_after_reader_close(1,1))
assert(owner._desktop_frozen and not interaction,'fallback bypassed active Reader')
print('HOME_OWNER_RETURN_AND_REFRESH_OK: 10 lifecycle scenarios')
