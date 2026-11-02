local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
local ROOT=TOOL_DIR.."/../miuread.koplugin"
package.path=TOOL_DIR.."/?.lua;"..ROOT.."/?.lua;"..package.path

local function load_plugin_methods(root, names, env)
    local file=assert(io.open(root.."/main.lua","rb"))
    local source=file:read("*a")
    file:close()
    for _,name in ipairs(names) do
        local start=assert(source:find("function Plugin:"..name.."(",1,true),name.." missing")
        local finish=source:find("\nfunction Plugin:",start+1,true) or #source+1
        local fn=assert(loadstring(source:sub(start,finish-1),name))
        setfenv(fn,env)
        fn()
    end
end

local scheduled={}
local unscheduled={}
local device_state_refreshes=0
local toolbar_shown=0

local HOME_SESSION={
    reader_session_generation=1,
    suspended=false,
}
local READER_CLOSE={
    generation=1,
    state="idle",
}

local env={
    Plugin={},
    HOME_SESSION=HOME_SESSION,
    READER_CLOSE=READER_CLOSE,
    Config={
        READER_OPEN_GESTURE_GUARD_SECONDS=0.75,
        OPEN_SYNC_SOFT_TIMEOUT_SECONDS=2.5,
        CHAPTER_PREFETCH_TTL=86400,
    },
    U={
        atomic_write=function() return true end,
    },
    logger={
        info=function() end,
        warn=function() end,
        err=function() end,
        dbg=function() end,
    },
    ReaderToolbar={
        invalidate=function() end,
        close=function() end,
        show=function(options)
            toolbar_shown=toolbar_shown+1
            return {options=options}
        end,
    },
    HomeData={
        quick_device_state=function(force)
            if force==true then device_state_refreshes=device_state_refreshes+1 end
            return {}
        end,
    },
    UIManager={
        scheduleIn=function(_,delay,fn)
            scheduled[#scheduled+1]={delay=delay,fn=fn}
        end,
        unschedule=function(_,fn)
            unscheduled[#unscheduled+1]=fn
            for i=#scheduled,1,-1 do
                if scheduled[i].fn==fn then
                    table.remove(scheduled,i)
                end
            end
        end,
        nextTick=function(_,fn)
            scheduled[#scheduled+1]={delay=0,fn=fn}
        end,
    },
    monotonic_wall_time=function() return 100 end,
    normalized_reader_file=function(p) return tostring(p or "") end,
    reader_close_active=function() return false end,
}
setmetatable(env,{__index=_G})

load_plugin_methods(ROOT,{
    "_reader_toolbar_mode",
    "_reader_toolbar_enabled",
    "_reader_panel_active",
    "_reader_toolbar_cache",
    "_reset_reader_toolbar_state_cache",
    "_schedule_reader_toolbar_state_refresh",
    "_show_reader_quick_panel_now",
    "_sync_reader_toolbar_hooks",
    "onReaderReady",
    "onPageUpdate",
},env)

local function new_plugin(opts)
    opts=opts or {}
    local raw_prefs=opts.raw_prefs
    local prefs_calls=0
    local reader_prefs_calls=0
    local state_refresh_calls=0
    local gesture_guard_calls=0
    local excerpt_calls=0
    local recent_read_calls=0
    local prefetch_prune_calls=0

    local plugin={
        ui={document={info={number_of_pages=100}}},
        store={
            get=function(_,key,default)
                if key=="preferences" then return raw_prefs end
                return default
            end,
            preferences=function()
                prefs_calls=prefs_calls+1
                return raw_prefs or {sync={auto_latest_position=true,pull_on_open=true}}
            end,
            prune_hidden_prefetch=function()
                prefetch_prune_calls=prefetch_prune_calls+1
                return 0
            end,
            file_record_fast=function() return nil end,
            identify_file=function() return nil end,
        },
        sync={
            on_page=function() end,
            on_reader_ready=function() end,
        },
        _home_enabled=function() return opts.desktop_mode==true end,
        _reader_preferences=function()
            reader_prefs_calls=reader_prefs_calls+1
            raw_prefs=raw_prefs or {}
            raw_prefs.reader_ui=raw_prefs.reader_ui or {
                enabled=opts.desktop_enabled~=false,
                plugin_mode_enabled=opts.plugin_enabled==true,
            }
            return raw_prefs.reader_ui,raw_prefs
        end,
        _refresh_reader_toolbar_state_cache=function(self,page)
            state_refresh_calls=state_refresh_calls+1
            local cache=self:_reader_toolbar_cache()
            if tonumber(page) then cache.page=tonumber(page) end
            cache.updated_at=123456
            return true
        end,
        _reader_background_idle=function() return true end,
        _mark_reader_busy=function() end,
        _record_performance=function() end,
        _reader_quick_panel_options=function() return {title="Test"} end,
        _uninstall_reader_toolbar_hooks=function() return true end,
        _reader_toolbar_hook_token=function() return "tok" end,
        _install_reader_menu_bridge=function() end,
        _install_reader_quick_panel_zone=function() end,
        _input_lifecycle=function() end,
        _current_document_path=function() return opts.path or "/mnt/us/documents/local.epub" end,
        _reader_rebuild_ready_state=function() return false,opts.preserve_session==true end,
        _reader_session_classify_ready=function() end,
        _cancel_reader_close_settle=function() end,
        _close_reader_recovery_surface=function() end,
        _close_home_for_reader=function() end,
        _ensure_reader_transition_guard=function() end,
        _reader_session_is_weread=function() return opts.is_weread==true end,
        _reader_session_kind=function() return opts.is_weread and "weread" or "local" end,
        _arm_reader_gesture_guard=function(_,seconds,reason)
            gesture_guard_calls=gesture_guard_calls+1
        end,
        _open_sync_begin=function() end,
        _finish_page_transition=function() end,
        _install_book_excerpt_highlight_action=function()
            excerpt_calls=excerpt_calls+1
        end,
        _record_recent_read=function()
            recent_read_calls=recent_read_calls+1
        end,
        _reset_chapter_navigation_context=function() end,
        _schedule_reader_toolbar_prewarm=function() return false end,
        _schedule_chapter_navigation_context=function() end,
        _schedule_chapter_prefetch=function() end,
        _teardown_thought_tap=function() end,
        _install_comment_overlay=function() end,
        _schedule_thought_prewarm=function() end,
        _schedule_comment_overlay_refresh=function() end,
        _counters=function()
            return {
                prefs_calls=prefs_calls,
                reader_prefs_calls=reader_prefs_calls,
                state_refresh_calls=state_refresh_calls,
                gesture_guard_calls=gesture_guard_calls,
                excerpt_calls=excerpt_calls,
                recent_read_calls=recent_read_calls,
                prefetch_prune_calls=prefetch_prune_calls,
            }
        end,
    }
    return setmetatable(plugin,{__index=env.Plugin})
end

-- 1. _reader_toolbar_enabled fast path avoids _reader_preferences when initialized
do
    local p=new_plugin({
        desktop_mode=false,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    assert(p:_reader_toolbar_enabled()==false,"plugin mode toolbar should be disabled")
    assert(p:_reader_toolbar_enabled()==false,"plugin mode toolbar second check")
    assert(p:_counters().reader_prefs_calls==0,"_reader_preferences should not be called when reader_ui is initialized")

    local p_uninit=new_plugin({
        desktop_mode=true,
        desktop_enabled=true,
        raw_prefs={},
    })
    assert(p_uninit:_reader_toolbar_enabled()==true,"desktop mode toolbar should initialize and return true")
    assert(p_uninit:_counters().reader_prefs_calls==1,"_reader_preferences should be called once when uninitialized")
    assert(p_uninit:_reader_toolbar_enabled()==true,"subsequent check should use fast path")
    assert(p_uninit:_counters().reader_prefs_calls==1,"_reader_preferences should not be called again after init")
end

-- 2. Toolbar disabled: onPageUpdate updates cache.page in memory but schedules 0 timers
do
    scheduled={}
    unscheduled={}
    local p=new_plugin({
        desktop_mode=false,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    p:onPageUpdate(42)
    assert(p:_reader_toolbar_cache().page==42,"onPageUpdate must still update cache.page in memory")
    assert(#scheduled==0,"toolbar state refresh timer must not be scheduled when toolbar is disabled")
    assert(p:_counters().state_refresh_calls==0,"state cache must not be refreshed when toolbar is disabled")
end

-- 3. Toolbar enabled: _sync_reader_toolbar_hooks schedules refresh, and _show_reader_quick_panel_now populates on demand
do
    scheduled={}
    unscheduled={}
    toolbar_shown=0
    local p=new_plugin({
        desktop_mode=true,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    assert(p:_sync_reader_toolbar_hooks("test")==true)
    assert(#scheduled==1 and p._reader_toolbar_state_task~=nil,"enabled toolbar should schedule initial state refresh")
    -- Before the scheduled timer fires, opening the quick panel populates the state cache immediately
    assert(p:_show_reader_quick_panel_now()==true)
    assert(p:_counters().state_refresh_calls==1,"quick panel must populate state cache when updated_at==0")
    assert(toolbar_shown==1,"quick panel should be shown")

    -- Disabling toolbar unschedules pending state task
    rawset(p.store:get("preferences"),"reader_ui",{enabled=false,plugin_mode_enabled=false})
    assert(p:_sync_reader_toolbar_hooks("disable")==false)
    assert(p._reader_toolbar_state_task==nil,"disabling toolbar must clear _reader_toolbar_state_task")
    assert(#scheduled==0,"disabling toolbar must unschedule _reader_toolbar_state_task")
end

-- 4. Local book onReaderReady with toolbar disabled skips store:preferences(), gesture guard, and device_task
do
    scheduled={}
    unscheduled={}
    device_state_refreshes=0
    local p=new_plugin({
        is_weread=false,
        desktop_mode=false,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    p:onReaderReady()
    local c=p:_counters()
    assert(c.prefs_calls==0,"local book onReaderReady must not call store:preferences() for open_sync_prefs")
    assert(c.gesture_guard_calls==0,"local book with toolbar disabled must not arm reader gesture guard")

    -- Execute all scheduled tasks (0.05s setup task + 1.5s prefetch prune task)
    local tasks=scheduled
    scheduled={}
    for _,item in ipairs(tasks) do item.fn() end
    c=p:_counters()
    assert(c.excerpt_calls==1,"_install_book_excerpt_highlight_action must still run on local books")
    assert(c.recent_read_calls==1,"_record_recent_read must still run on local books")
    assert(c.prefetch_prune_calls==1,"prune_hidden_prefetch must still run")
    assert(c.state_refresh_calls==0,"toolbar state refresh must not run when toolbar is disabled")
    assert(device_state_refreshes==0,"HomeData.quick_device_state(true) must not run on local book with toolbar disabled")
end

-- 5. WeRead book onReaderReady still arms gesture guard and schedules HomeData.quick_device_state(true)
do
    scheduled={}
    unscheduled={}
    device_state_refreshes=0
    local p=new_plugin({
        is_weread=true,
        desktop_mode=false,
        raw_prefs={
            reader_ui={enabled=true,plugin_mode_enabled=false},
            sync={auto_latest_position=true,pull_on_open=true},
        },
    })
    p:onReaderReady()
    local c=p:_counters()
    assert(c.prefs_calls==1,"WeRead book onReaderReady should read sync preferences")
    assert(c.gesture_guard_calls==1,"WeRead book onReaderReady should arm reader gesture guard")

    local tasks=scheduled
    scheduled={}
    for _,item in ipairs(tasks) do item.fn() end
    assert(device_state_refreshes==1,"WeRead book onReaderReady should refresh device state")
end

print("test_reader_local_book_isolation: PASS")
