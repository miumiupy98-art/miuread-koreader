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

local function load_module_methods(path, table_name, names, env)
    local file=assert(io.open(path,"rb"))
    local source=file:read("*a")
    file:close()
    for _,name in ipairs(names) do
        local start=assert(source:find("function "..table_name..":"..name.."(",1,true),name.." missing")
        local finish=source:find("\nfunction "..table_name..":",start+1,true) or #source+1
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
    page_transition_state="idle",
    page_transition_started_clock=0,
    page_transition_generation=0,
}
local READER_CLOSE={
    generation=1,
    state="idle",
}
local READER_REBUILD={
    generation=1,
    state="idle",
    internal_hint=false,
}
local READER_NATIVE_SETTING={
    label="",
}

local env={
    Plugin={},
    HOME_SESSION=HOME_SESSION,
    READER_CLOSE=READER_CLOSE,
    READER_REBUILD=READER_REBUILD,
    READER_NATIVE_SETTING=READER_NATIVE_SETTING,
    Config={
        READER_OPEN_GESTURE_GUARD_SECONDS=0.75,
        OPEN_SYNC_SOFT_TIMEOUT_SECONDS=2.5,
        CHAPTER_PREFETCH_TTL=86400,
        DOWNLOAD_INTERACTION_RESUME_DELAY=2.5,
    },
    U={
        atomic_write=function() return true end,
        copy=function(v) return v end,
    },
    LocalLibrary={
        is_resource_path=function() return false end,
        normalize=function(p) return tostring(p or "") end,
    },
    BookExcerptDialog={
        close=function() end,
    },
    HomeView={
        is_shown=function() return false end,
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
    normalized_reader_file=function(p) return p and tostring(p)~="" and tostring(p) or nil end,
    normalized_home_time=function(v) return tonumber(v) or 0 end,
    reader_close_active=function() return false end,
    reader_rebuild_active=function() return READER_REBUILD.state=="waiting" end,
    reader_native_setting_active=function() return false end,
    sync_home_session=function() end,
    home_owner=function() return nil end,
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
    "_page_transition_active",
    "_finish_page_transition",
    "_record_recent_read",
    "_abort_rebuild_candidate_on_filemanager",
    "_local_comment_enabled",
    "onReaderReady",
    "onPageUpdate",
    "onCloseDocument",
    "onFlushSettings",
},env)

local function new_plugin(opts)
    opts=opts or {}
    local raw_prefs=opts.raw_prefs
    local prefs_calls=0
    local reader_prefs_calls=0
    local state_refresh_calls=0
    local gesture_guard_calls=0
    local excerpt_calls=0
    local overlay_install_calls=0
    local overlay_refresh_calls=0
    local cloud_page_calls=0
    local recent_persisted_calls=0
    local prefetch_prune_calls=0
    local flush_calls=0
    local finalize_close_calls=0
    local rebuild_candidate_calls=0
    local last_rebuild_internal_hint=nil

    local ui_proto={tearing_down=opts.proto_tearing_down==true}
    local ui_instance=setmetatable({
        document={info={number_of_pages=100}},
        tearing_down=opts.instance_tearing_down,
    },{__index=ui_proto})

    local plugin={
        ui=ui_instance,
        store={
            _deferred_dirty=opts.deferred_dirty==true,
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
            record_recent_read=function()
                recent_persisted_calls=recent_persisted_calls+1
            end,
            flush=function(self)
                flush_calls=flush_calls+1
                self._deferred_dirty=false
                return true
            end,
        },
        sync={
            on_page=function() cloud_page_calls=cloud_page_calls+1 end,
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
        -- The real _local_comment_enabled() method is loaded from main.lua above.
        -- Only its storage dependency is stubbed, so this test exercises the actual predicate.
        _local_comment_entry=function()
            if opts.local_comment_bound==true then
                return {books={{book_id="fixture-book"}}}
            end
            return nil
        end,
        _arm_reader_gesture_guard=function()
            gesture_guard_calls=gesture_guard_calls+1
        end,
        _open_sync_begin=function() end,
        _install_book_excerpt_highlight_action=function()
            excerpt_calls=excerpt_calls+1
        end,
        _recent_authoritative_state=function() return {version=2,seq=0} end,
        _home_build_recent_snapshot=function(_,book_id,path,stamp)
            return {book_id=book_id,file=path,read_at=stamp}
        end,
        _recent_store_authoritative_state=function() end,
        _home_share_recent_read=function() end,
        _home_apply_recent_snapshot_to_home=function() end,
        _reset_chapter_navigation_context=function() end,
        _schedule_reader_toolbar_prewarm=function() return false end,
        _schedule_chapter_navigation_context=function() end,
        _schedule_chapter_prefetch=function() end,
        _teardown_thought_tap=function() end,
        _install_comment_overlay=function() overlay_install_calls=overlay_install_calls+1 end,
        _schedule_thought_prewarm=function() end,
        _schedule_comment_overlay_refresh=function() overlay_refresh_calls=overlay_refresh_calls+1 end,
        _cancel_next_comment_preload=function() end,
        _cancel_comment_range_task=function() end,
        _teardown_comment_overlay=function() end,
        _reader_rebuild_cancel=function()
            READER_REBUILD.state="idle"
            return true
        end,
        _finalize_reader_instance_close=function()
            finalize_close_calls=finalize_close_calls+1
            return true
        end,
        _start_reader_rebuild_candidate=function(_,_,_,_,internal_hint)
            rebuild_candidate_calls=rebuild_candidate_calls+1
            last_rebuild_internal_hint=internal_hint==true
            return true
        end,
        _mark_ui_preferences_flushed=function() end,
        _flush_reader_checkpoint=function() end,
        _flush_cover_index=function() end,
        _active_reader_ui=function() return nil end,
        _filemanager_instance=function() return opts.filemanager_present and {} or nil end,
        _counters=function()
            return {
                prefs_calls=prefs_calls,
                reader_prefs_calls=reader_prefs_calls,
                state_refresh_calls=state_refresh_calls,
                gesture_guard_calls=gesture_guard_calls,
                excerpt_calls=excerpt_calls,
                overlay_install_calls=overlay_install_calls,
                overlay_refresh_calls=overlay_refresh_calls,
                cloud_page_calls=cloud_page_calls,
                recent_persisted_calls=recent_persisted_calls,
                prefetch_prune_calls=prefetch_prune_calls,
                flush_calls=flush_calls,
                finalize_close_calls=finalize_close_calls,
                rebuild_candidate_calls=rebuild_candidate_calls,
                last_rebuild_internal_hint=last_rebuild_internal_hint,
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
    assert(p:_counters().overlay_refresh_calls==0,"unbound local EPUB must not refresh comment overlay")
    assert(p:_counters().cloud_page_calls==0,"unbound local EPUB must not post a cloud page event")
end

-- 2b. Bound local EPUB refreshes community comment overlay without entering cloud sync.
do
    scheduled={}
    unscheduled={}
    local p=new_plugin({
        local_comment_bound=true,
        is_weread=false,
        desktop_mode=false,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    assert(p:_local_comment_enabled()==true,"local EPUB fixture should use actual binding predicate")
    p:onPageUpdate(43)
    local c=p:_counters()
    assert(p:_reader_toolbar_cache().page==43,"bound local EPUB must update page cache")
    assert(c.overlay_refresh_calls==1,"bound local EPUB should schedule one overlay refresh")
    assert(c.cloud_page_calls==0,"bound local EPUB must not invoke WeRead page synchronization")
    assert(#scheduled==0,"bound local EPUB with toolbar off must not schedule toolbar timers")
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
    assert(p:_show_reader_quick_panel_now()==true)
    assert(p:_counters().state_refresh_calls==1,"quick panel must populate state cache when updated_at==0")
    assert(toolbar_shown==1,"quick panel should be shown")

    rawset(p.store:get("preferences"),"reader_ui",{enabled=false,plugin_mode_enabled=false})
    assert(p:_sync_reader_toolbar_hooks("disable")==false)
    assert(p._reader_toolbar_state_task==nil,"disabling toolbar must clear _reader_toolbar_state_task")
    assert(#scheduled==0,"disabling toolbar must unschedule _reader_toolbar_state_task")
end

-- 4. Local book onReaderReady in Plugin Mode with toolbar disabled skips preferences, gesture guard, device_task, and recent_read persistence
do
    scheduled={}
    unscheduled={}
    device_state_refreshes=0
    HOME_SESSION.page_transition_state="idle"
    HOME_SESSION.page_transition_started_clock=0
    local p=new_plugin({
        is_weread=false,
        desktop_mode=false,
        raw_prefs={reader_ui={enabled=true,plugin_mode_enabled=false}},
    })
    p:onReaderReady()
    local c=p:_counters()
    assert(c.prefs_calls==0,"local book onReaderReady must not call store:preferences() for open_sync_prefs")
    assert(c.gesture_guard_calls==0,"local book with toolbar disabled must not arm reader gesture guard")
    assert(#scheduled==2,"only 0.05s setup task and 1.5s prefetch prune task should be scheduled (no 1.2s page_transition timer)")

    local tasks=scheduled
    scheduled={}
    for _,item in ipairs(tasks) do item.fn() end
    c=p:_counters()
    assert(c.excerpt_calls==1,"_install_book_excerpt_highlight_action must still run on local books")
    assert(c.recent_persisted_calls==0,"_record_recent_read must skip non-WeRead books in plugin mode")
    assert(c.prefetch_prune_calls==1,"prune_hidden_prefetch must still run")
    assert(c.state_refresh_calls==0,"toolbar state refresh must not run when toolbar is disabled")
    assert(device_state_refreshes==0,"HomeData.quick_device_state(true) must not run on local book with toolbar disabled")

    -- In Desktop Mode, _record_recent_read still persists local books
    local p_desktop=new_plugin({
        is_weread=false,
        desktop_mode=true,
        raw_prefs={reader_ui={enabled=false,plugin_mode_enabled=false}},
    })
    assert(p_desktop:_record_recent_read("/mnt/us/documents/local.epub",nil,nil)==true)
    assert(p_desktop:_counters().recent_persisted_calls==1,"desktop mode must still record recent read for local books")
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
    c=p:_counters()
    assert(c.recent_persisted_calls==1,"WeRead book onReaderReady must record recent read")
    assert(device_state_refreshes==1,"WeRead book onReaderReady should refresh device state")
end

-- 6. onCloseDocument ignores metatable ReaderUI.tearing_down==true and finalizes plugin-mode native close immediately
do
    local p_native=new_plugin({
        is_weread=false,
        desktop_mode=false,
        proto_tearing_down=true,
    })
    p_native:onCloseDocument()
    local c=p_native:_counters()
    assert(c.finalize_close_calls==1,"plugin-mode native close must finalize immediately")
    assert(c.rebuild_candidate_calls==0,"plugin-mode native close must not start 18s rebuild candidate")

    local p_desktop_proto=new_plugin({
        is_weread=false,
        desktop_mode=true,
        proto_tearing_down=true,
    })
    p_desktop_proto:onCloseDocument()
    local cd=p_desktop_proto:_counters()
    assert(cd.rebuild_candidate_calls==1,"desktop mode close starts bounded rebuild candidate")
    assert(cd.last_rebuild_internal_hint==false,"prototype tearing_down=true must not set internal_hint=true")

    local p_instance_td=new_plugin({
        is_weread=false,
        desktop_mode=false,
        proto_tearing_down=true,
        instance_tearing_down=true,
    })
    p_instance_td:onCloseDocument()
    local ci=p_instance_td:_counters()
    assert(ci.rebuild_candidate_calls==1,"instance rawget tearing_down=true should start internal rebuild candidate")
    assert(ci.last_rebuild_internal_hint==true,"instance rawget tearing_down=true must set internal_hint=true")
end

-- 7. onFlushSettings skips store:flush() when closing a clean native book in Plugin Mode
do
    local p_clean=new_plugin({
        is_weread=false,
        desktop_mode=false,
        deferred_dirty=false,
    })
    p_clean:onFlushSettings()
    assert(p_clean:_counters().flush_calls==0,"clean native book in plugin mode must skip store:flush()")

    local p_dirty=new_plugin({
        is_weread=false,
        desktop_mode=false,
        deferred_dirty=true,
    })
    p_dirty:onFlushSettings()
    assert(p_dirty:_counters().flush_calls==1,"dirty store in plugin mode must still call store:flush()")
end

-- 8. DownloadTask:pause and DownloadTask:resume do not schedule timers when idle
do
    scheduled={}
    unscheduled={}
    local DownloadTask={}
    local dt_env={
        DownloadTask=DownloadTask,
        TRANSIENT_PAUSE_REASONS={
            home_interaction=true,
            reader_interaction=true,
            page_transition=true,
        },
        Config=env.Config,
        UIManager=env.UIManager,
        logger=env.logger,
    }
    setmetatable(dt_env,{__index=_G})
    load_module_methods(ROOT.."/miuread/download_task.lua","DownloadTask",{
        "_cancel_deferred_resume",
        "pause",
        "resume",
    },dt_env)

    local dt=setmetatable({
        deferred_resume_tasks={},
        pause_reasons={},
        _control_pause_path=function() return nil end,
        _merged_pause_reasons=function(self) return self.pause_reasons end,
        _write_pause_marker=function() return false end,
        _release_awake=function() end,
        _resume_now=function() return true end,
    },{__index=DownloadTask})

    assert(dt:pause("page_transition")==false,"idle DownloadTask:pause should return false for transient reason")
    assert(next(dt.pause_reasons)==nil,"idle DownloadTask:pause must not record transient pause reason")
    assert(dt:resume("page_transition")==true,"idle DownloadTask:resume should return true immediately")
    assert(#scheduled==0,"idle DownloadTask:resume must not schedule 2.5s debounce timer")
end

print("test_reader_local_book_isolation: PASS")
