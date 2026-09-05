local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local dump=require("dump")
local Config=require("miuread.config")
local Json=require("miuread.json")
local DownloadDatabase=require("miuread.download_database")
local U=require("miuread.util")
local Cookies=require("miuread.cookies")
local logger=require("logger")
local Store={}; Store.__index=Store
local function generate_login_session_id()
    return tostring(os.time()).."-"..tostring(math.random(100000,999999))
end
local defaults={
 schema=Config.SCHEMA,
 auth={login_session_id="",auth_revision=0,api_key="",cookies={},wr_ticket="",wr_wrpa="",ticket_updated_at=0,
     account={name="",vid="",logged_at=0},
     health={state="unknown",last_checked_at=0,last_ok_at=0,last_error_at=0,
         last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,
         channels={
             shelf={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             progress={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             download={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             annotations={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             read_report={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
         }}},
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,download_notice_enabled=false,download_complete_notice=true,download_reader_warning=true,download_reader_policy="ask",chapter_prefetch_enabled=true,chapter_continuous_enabled=true,download_dir="",shelf_section="account",account_shelf_kind="books",shelf_filter={enabled=false,archives={},archive_keys={}},home_ui={enabled=false,layout_version=24,layout_style="desk",show_weread_stats=true,show_local_stats=true,display_size="standard",ui_font_mode="default",ui_font_face="",local_entry_root="",local_entry_version=1,local_browse_version=3,lockscreen_style="frame",lockscreen_last_native_style="frame",page_by_section={},source_order={"shelf","device","recent"},visible_sections={shelf=true,device=true,recent=true},library_layout_version=1,library_membership={},library_filters={shelf={source="all",kind="all",locality="all",sort="recent"},device={source="all",kind="all",locality="all",sort="recent"}},weread_group="all",action_items={refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false,extensions=false},action_order={"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot","extensions"},action_layout_version=4,panel_items={wifi=true,bluetooth=false,rotate=true,screenshot=true,full_refresh=true,downloads=false,sync=false,miuread_settings=false,koreader_settings=true,koreader_file_manager=false,return_koreader=true,quit=false,restart=true,sleep=true,reboot=false,poweroff=false},panel_order={"wifi","bluetooth","rotate","screenshot","full_refresh","downloads","sync","miuread_settings","koreader_settings","koreader_file_manager","return_koreader","quit","restart","sleep","reboot","poweroff"},panel_layout_version=5,more_expanded=false,network_metadata_user_set=false,network_metadata=true},reader_ui={enabled=true,plugin_mode_enabled=false,show_title=false,show_status=false,show_recent=false,recent_actions={},edge_guard_enabled=true,edge_guard_percent=15,quick_layout_version=11,quick_items={toc=true,progress=true,search=true,back=true,font=true,spacing=true,page=true,comments=true,bookmark=true,highlight=true,thought=true,sync=true},quick_order={"toc","progress","search","back","font","spacing","page","comments","bookmark","highlight","thought","sync"}},notices={reader_download=true,low_battery=true,low_storage=true,full_refresh=true,lockscreen=true,mode_switch=true,mode_environment=true},mode_intro={pending_mode="plugin",pending_reason="first_install",last_confirmed_mode="",confirmed_at=0},memory_mode={enabled=false,previous_known=false,previous_ratio=false},performance_mode={enabled=false,auto_detect=true,last_prompt_at=0,reminders_disabled=false},time_display={mode="device",zone="Asia/Shanghai",offset_minutes=480},thoughts={enabled=true,font_size=22,font_face="",follow_body_font=false,width_ratio=0.90,height_ratio=0.55,display_mode="native_compact_rounded"},annotation_sync={enabled=false,review_visibility="private",highlight_style=1,highlight_color=0,close_upload_enabled=true},update={manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},sync={time_enabled=true,progress_enabled=true,progress_mode="close",success_notice_enabled=false,error_notice_enabled=true,manual_only=false,auto_upload=false,pull_on_open=true,check_resume=false,require_verified=false,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300}},
 library={},sessions={},shelf_cache={raw_books={},raw_mp={},books={},mp={},groups={updated_at=0,authoritative=false,list={},book_groups={}},effective_scope={mode="all",fingerprint="all",updated_at=0},updated_at=0,stream={enabled=false,ids={},hydrated_ids={},total=0,source="",updated_at=0}},cover_index={},cover_guard={active=false,started_at=0,stage="",version=""},update_state={},
 pending_installs={},last_cleanup_result={},read_report_consumed={},recent_reads={version=1,items={}},
 prefetch_cache={},
}
local function invalidate_report_contexts_table(sessions)
    sessions=type(sessions)=="table" and sessions or {}
    local changed=0
    local clear_keys={
        "legacy_report_context","report_context","psvts","pclts","token","reader_url",
        "context_updated_at","report_login_session_id","verification_login_session_id",
        "remote","remote_sources","remote_checked_at","remote_web_error","remote_agent_error",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
        "progress_upload_verified_at","progress_upload_source","progress_upload_at","progress_upload_percent",
        "last_response_summary","last_http_code","last_http_length","last_payload_public","last_path",
        "last_stage","last_error","last_attempts",
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            for _,key in ipairs(clear_keys) do
                if session[key]~=nil then session[key]=nil; changed=changed+1 end
            end
            if tonumber(session.consecutive_failures or 0)~=0 then session.consecutive_failures=0; changed=changed+1 end
            if tonumber(session.pending_report_seconds or 0)~=0 then session.pending_report_seconds=0; changed=changed+1 end
        end
    end
    return sessions,changed
end
local function invalidate_same_account_contexts_table(sessions)
    sessions=type(sessions)=="table" and sessions or {}
    local changed=0
    local clear_keys={
        "legacy_report_context","report_context","psvts","pclts","token","reader_url",
        "context_updated_at","report_login_session_id","verification_login_session_id",
        "remote","remote_sources","remote_checked_at","remote_web_error","remote_agent_error",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "last_response_summary","last_http_code","last_http_length","last_payload_public","last_path",
        "last_stage","last_error","last_attempts",
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            for _,key in ipairs(clear_keys) do
                if session[key]~=nil then session[key]=nil; changed=changed+1 end
            end
            if tonumber(session.consecutive_failures or 0)~=0 then session.consecutive_failures=0; changed=changed+1 end
        end
    end
    return sessions,changed
end
local function invalidate_upload_health_table(auth)
    auth=U.merge(defaults.auth,auth or {})
    auth.health.notice_pending=false
    auth.health.last_error_channel=""
    local cookies=type(auth.cookies)=="table" and auth.cookies or {}
    if tostring(auth.api_key or "")~="" or next(cookies)~=nil then
        auth.health.state="unknown"
        for _,channel in ipairs({"progress","read_report"}) do
            local row=auth.health.channels[channel] or {}
            auth.health.channels[channel]={
                state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                last_ok_at=tonumber(row.last_ok_at or 0) or 0,
            }
        end
    end
    return auth
end
local function settings_payload(data,path)
    -- Match KOReader LuaSettings:flush(): settings files are executable Lua
    -- chunks that must return the serialized table. dump() itself only emits
    -- the table expression, so writing it directly would create an invalid
    -- settings file beginning with "{".
    return "-- "..tostring(path or "").."\nreturn "..dump(data,nil,true).."\n"
end

local function settings_payload_valid(payload)
    local loader,err=loadstring(tostring(payload or ""))
    if not loader then return false,err end
    local ok,value=pcall(loader)
    if not ok then return false,value end
    if type(value)~="table" then return false,"settings payload did not return a table" end
    return true
end

local function settings_file_data(path)
    if not path or lfs.attributes(path,"mode")~="file" then return nil,"missing" end
    local size=U.file_size(path) or 0
    if size<=0 then return nil,"empty" end
    local loader,err=loadfile(path)
    if not loader then return nil,err end
    local ok,value=pcall(loader)
    if not ok then return nil,value end
    if type(value)~="table" then return nil,"settings file did not return a table" end
    return value
end

local function settings_file_valid(path)
    local value,err=settings_file_data(path)
    return type(value)=="table",err
end

local function restore_settings_file(path,backup_path)
    if not path then return false end
    local exists=lfs.attributes(path,"mode")=="file"
    local valid,reason=settings_file_valid(path)
    if valid then return false end
    -- Prefer the newest valid recovery generation instead of a fixed suffix
    -- order. A very old .old file must not win merely because a newer backup
    -- happens to use another name.
    local candidates={path..".previous",backup_path,path..".old"}
    local valid_candidates={}
    for _,candidate in ipairs(candidates) do
        local backup_ok=settings_file_valid(candidate)
        if backup_ok then
            local attr=lfs.attributes(candidate) or {}
            valid_candidates[#valid_candidates+1]={path=candidate,modified=tonumber(attr.modification or 0) or 0}
        end
    end
    table.sort(valid_candidates,function(a,b) return a.modified>b.modified end)
    for _,entry in ipairs(valid_candidates) do
        local candidate=entry.path
        local restored,restore_error=U.copy_file(candidate,path)
        if restored then
            logger.warn("[MiuRead][Store] damaged settings restored",
                "source=",tostring(candidate),"reason=",tostring(reason),"modified=",tostring(entry.modified))
            return true,candidate
        end
        logger.warn("[MiuRead][Store] settings restore failed",tostring(restore_error))
    end
    if exists then
        local corrupt=path..".corrupt-"..tostring(os.time())
        local moved=os.rename(path,corrupt)
        logger.warn("[MiuRead][Store] damaged settings isolated",
            "file=",tostring(moved and corrupt or path),"reason=",tostring(reason))
    else
        logger.warn("[MiuRead][Store] settings missing and no valid backup","file=",tostring(path))
    end
    return true,nil
end

local function refresh_settings_backup(path,backup_path)
    local source=lfs.attributes(path)
    local backup=lfs.attributes(backup_path)
    if type(source)~="table" then return false end
    local needed=type(backup)~="table"
        or tonumber(source.size or -1)~=tonumber(backup.size or -2)
        or (tonumber(source.modification or 0)-tonumber(backup.modification or 0))>=300
    if not needed then return false end
    local copied,copy_error=U.copy_file(path,backup_path)
    if not copied then logger.warn("[MiuRead][Store] settings backup failed",tostring(copy_error)) end
    return copied==true
end

local function public_documents_root(data_dir)
    local kindle_documents = "/mnt/us/documents"
    if lfs.attributes(kindle_documents,"mode")=="directory" then
        return kindle_documents .. "/MiuRead"
    end
    local ok, home = pcall(function() return DataStorage:getDataDir() end)
    if ok and type(home)=="string" and home~="" then
        return home .. "/MiuRead"
    end
    return data_dir .. "/books"
end

function Store:new(options)
    options=options or {}
    local data=options.data_dir or (DataStorage:getFullDataDir().."/"..Config.DATA_DIR)
    U.mkdir(data); U.mkdir(data.."/books"); U.mkdir(data.."/mp"); U.mkdir(data.."/covers"); U.mkdir(data.."/temp"); U.mkdir(data.."/updates"); U.mkdir(data.."/prefetch")
    local settings_path=options.settings_path or (DataStorage:getSettingsDir().."/miuread.lua")
    local settings_backup_path=settings_path..".miuread-backup"
    local restored_settings_source=nil
    if options.isolated~=true then
        local _,source=restore_settings_file(settings_path,settings_backup_path)
        restored_settings_source=source
    end
    local o=setmetatable({
        data_dir=data,
        cache_books_dir=data.."/books",
        mp_dir=data.."/mp",
        default_books_dir=public_documents_root(data),
        covers_dir=data.."/covers",
        temp_dir=data.."/temp",
        updates_dir=data.."/updates",
        prefetch_dir=data.."/prefetch",
        settings_path=settings_path,
        settings_backup_path=settings_backup_path,
        download_database_path=DownloadDatabase.runtime_path(data),
        isolated=options.isolated==true,
        restored_settings_source=restored_settings_source,
    },self)
    o.db=LuaSettings:open(o.settings_path)
    local startup_dirty=false
    for k,v in pairs(defaults) do
        if o.db:readSetting(k,nil)==nil then
            o.db:saveSetting(k,U.copy(v))
            startup_dirty=true
        end
    end
    local schema_before=tonumber(o.db:readSetting("schema",1)) or 1
    o:migrate()
    if schema_before<Config.SCHEMA then startup_dirty=true end
    -- Do not rewrite miuread.lua on every plugin construction. Persist only a
    -- real first-run/default/schema migration, and never turn a settings write
    -- failure into a plugin-load failure.
    if startup_dirty then
        local flushed,flush_error=o:flush()
        if flushed~=true then
            logger.warn("[MiuRead][Store] startup settings flush skipped after failure",tostring(flush_error or "unknown"))
        end
    end
    if not o.isolated then
        local valid=settings_file_valid(o.settings_path)
        if valid then refresh_settings_backup(o.settings_path,o.settings_backup_path) end
    end
    return o
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",Config.MIN_SUPPORTED_SCHEMA or 113))
        or (Config.MIN_SUPPORTED_SCHEMA or 113)
    local minimum=tonumber(Config.MIN_SUPPORTED_SCHEMA or 113) or 113
    if schema<minimum then
        -- 5.7.0-beta.3 drops the historical pre-4.6.5 migration chain. Very old
        -- settings are loaded with current defaults, while durable account/library
        -- data remains untouched. From here on only the supported migration window
        -- is executed.
        logger.warn("[MiuRead][Migration] unsupported legacy schema; applying current baseline",
            "from=",tostring(schema),"baseline=",tostring(minimum))
        schema=minimum
        self.db:saveSetting("schema",schema)
    end
    if schema<Config.SCHEMA then
        local previous=self.db:readSetting("preferences",{}) or {}
        if schema<114 then
            logger.info("[MiuRead][Migration] schema 113 -> 114 begin","from=",tostring(schema))
            -- 4.7.0-beta.8 removes periodic exact-progress uploads. Preserve the
            -- lightweight 60-second reading-time service and migrate users who
            -- explicitly selected the old continuous mode to end-of-reading sync.
            local current=self:preferences()
            current.sync=type(current.sync)=="table" and current.sync or {}
            if tostring(current.sync.progress_mode or "")=="continuous" then
                current.sync.progress_mode="close"
            end
            current.sync.progress_enabled=current.sync.progress_mode~="manual"
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 113 -> 114 done")
        end
        if schema<115 then
            logger.info("[MiuRead][Migration] schema 114 -> 115 begin","from=",tostring(schema))
            -- 4.9.0-beta.13 retires MiuRead's recursive local-library index.
            -- Supported 4.6.x installs still need one conversion into the
            -- current browser entry before obsolete root fields are discarded.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            local raw_home=type(previous.home_ui)=="table" and previous.home_ui or {}
            local function usable(path)
                path=U.trim(tostring(path or ""))
                return path~="" and lfs.attributes(path,"mode")=="directory" and path or nil
            end
            local entry=usable(raw_home.local_entry_root) or usable(home.local_entry_root)
                or usable(raw_home.local_root)
            if not entry then
                for _,root in ipairs(type(raw_home.local_roots)=="table" and raw_home.local_roots or {}) do
                    entry=usable(type(root)=="table" and root.path or root)
                    if entry then break end
                end
            end
            home.local_entry_root=entry or ""
            home.local_entry_version=1
            home.local_browse_version=3
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 114 -> 115 done",
                "entry=",tostring(home.local_entry_root~="" and home.local_entry_root or "default"))
        end
        if schema<116 then
            logger.info("[MiuRead][Migration] schema 115 -> 116 begin","from=",tostring(schema))
            -- 4.9.0-beta.16 adds low-priority next-chapter prefetch for
            -- standalone WeRead chapter EPUBs. Existing installs opt in to the
            -- same default as fresh installs; users may disable it in downloads.
            local current=self:preferences()
            if previous.chapter_prefetch_enabled==nil then current.chapter_prefetch_enabled=true end
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 115 -> 116 done")
        end
        if schema<117 then
            logger.info("[MiuRead][Migration] schema 116 -> 117 begin","from=",tostring(schema))
            -- beta.17 keeps the existing next-chapter prefetch switch and adds
            -- a separate opt-out for crossing into that chapter at end-of-book.
            local current=self:preferences()
            if previous.chapter_continuous_enabled==nil then current.chapter_continuous_enabled=true end
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 116 -> 117 done")
        end
        if schema<118 then
            logger.info("[MiuRead][Migration] schema 117 -> 118 begin","from=",tostring(schema))
            -- beta.27 moves future automatic next-chapter work into a private
            -- cache. Existing beta.16-26 prefetched chapter EPUBs remain valid
            -- formal chapter downloads and are intentionally left untouched.
            if self.db:readSetting("prefetch_cache",nil)==nil then
                self.db:saveSetting("prefetch_cache",{})
            end
            logger.info("[MiuRead][Migration] schema 117 -> 118 done")
        end
        if schema<119 then
            logger.info("[MiuRead][Migration] schema 118 -> 119 begin","from=",tostring(schema))
            -- beta.28 gives every durable credential change a monotonically
            -- increasing revision. Long-lived/read/download workers can then
            -- prove that their response still belongs to the current login
            -- credentials before they are allowed to write anything back.
            local auth=U.merge(defaults.auth,self.db:readSetting("auth",{}) or {})
            local account=type(auth.account)=="table" and auth.account or {}
            local logged=tostring(auth.login_session_id or "")~=""
                and tostring(account.vid or (auth.cookies or {}).wr_vid or "")~=""
            auth.auth_revision=logged and math.max(1,tonumber(auth.auth_revision or 0) or 0) or 0
            self.db:saveSetting("auth",auth)
            logger.info("[MiuRead][Migration] schema 118 -> 119 done",
                "logged_in=",tostring(logged),"revision=",tostring(auth.auth_revision))
        end
        if schema<120 then
            logger.info("[MiuRead][Migration] schema 119 -> 120 begin","from=",tostring(schema))
            -- beta.8 makes "阅读评论" the single presentation switch for both
            -- WeRead comments and their in-book marks. beta.6/beta.7 may have
            -- persisted a second show_marks value; discard it once so the two
            -- surfaces can never drift apart again. No EPUB/comment/favorite
            -- data is rewritten by this migration.
            local current=self:preferences()
            current.thoughts=type(current.thoughts)=="table" and current.thoughts or {}
            current.thoughts.enabled=current.thoughts.enabled~=false
            current.thoughts.show_marks=nil
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 119 -> 120 done",
                "comments_enabled=",tostring(current.thoughts.enabled))
        end
        if schema<121 then
            -- 5.7.0-beta.3 retires rollback-only local-library fields and
            -- one-cycle comment compatibility flags. Supported installs have
            -- already migrated to local_entry_root and thoughts.enabled.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.local_root=nil
            home.local_roots=nil
            home.local_library_mode=nil
            home.local_auto_update=nil
            home.auto_scan=nil
            home.local_check_on_open=nil
            home.bluetooth_shortcut_version=nil
            current.thoughts=type(current.thoughts)=="table" and current.thoughts or {}
            current.thoughts.show_marks=nil
            current.thoughts.font=nil
            current.repair=nil
            current.notices=type(current.notices)=="table" and current.notices or {}
            current.notices.library_scan=nil
            current.notices.repair_while_reading=nil
            self:save_preferences(current)
            if type(self.db.delSetting)=="function" then
                for _,key in ipairs({"book_repair_state","book_repair_history","download_queue","lockscreen_direct_version"}) do
                    self.db:delSetting(key)
                end
            end
            os.remove(self.data_dir.."/download-state.json")
            U.remove_tree(self.data_dir.."/lockscreen")
            U.remove_tree(self.data_dir.."/lockscreen-source")
            local render_dir=self.data_dir.."/cover-render-v1"
            if lfs.attributes(render_dir,"mode")=="directory" then
                for name in lfs.dir(render_dir) do
                    if name:find("%-home2%-") then os.remove(render_dir.."/"..name) end
                end
            end
            logger.info("[MiuRead][Migration] schema 120 -> 121 done")
        end
        if schema<122 then
            -- 5.7.0-beta.4 retires beta.16-26's formal-chapter prefetch marker.
            -- Those EPUBs are already valid downloads: preserve every file and only
            -- remove the obsolete behavioral flags so they behave as normal chapters.
            local library=self.db:readSetting("library",{}) or {}
            local changed=false
            for _,book in pairs(type(library)=="table" and library or {}) do
                for _,row in pairs(type(book)=="table" and (book.chapters or {}) or {}) do
                    for _,record in pairs(type(row)=="table" and row or {}) do
                        if type(record)=="table" and record.prefetch==true then
                            record.prefetch=nil
                            record.prefetch_origin=nil
                            record.prefetch_at=nil
                            record.prefetch_consumed_at=nil
                            changed=true
                        end
                    end
                end
            end
            if changed then self.db:saveSetting("library",library) end
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            current.home_ui.performance_defaults_version=nil
            current.home_ui.network_metadata_defaults_version=nil
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 121 -> 122 done",
                "legacy_prefetch_normalized=",tostring(changed))
        end
        if schema<123 then
            -- 5.7.0-beta.5 gives Home a stable reading/service action bar and
            -- moves device-only actions into the pull-down control center. The
            -- former clock card becomes the configurable status card.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.layout_version=25
            home.status_card_enabled=home.status_card_enabled~=false
            home.status_items=type(home.status_items)=="table" and home.status_items or {}
            for key,value in pairs({wifi=true,battery=true,sync=true,bluetooth=false,downloads=false}) do
                if home.status_items[key]==nil then home.status_items[key]=value end
            end
            home.status_order={"wifi","battery","sync","bluetooth","downloads"}

            home.action_items=type(home.action_items)=="table" and home.action_items or {}
            home.action_items.sleep=nil
            home.action_items.extensions=true
            local action_seen,action_order={},{}
            for _,key in ipairs(type(home.action_order)=="table" and home.action_order or {}) do
                if key~="sleep" and key~="extensions" and key~="miuread_settings" and not action_seen[key] then
                    action_seen[key]=true; action_order[#action_order+1]=key
                end
            end
            local function insert_action(key)
                if not action_seen[key] then action_seen[key]=true; action_order[#action_order+1]=key end
            end
            -- Keep the four common actions first, then the new platform-level
            -- entries, followed by any user-enabled optional shortcuts.
            local preferred={"refresh","search","downloads","sync"}
            local reordered,used={},{}
            for _,key in ipairs(preferred) do reordered[#reordered+1]=key; used[key]=true end
            reordered[#reordered+1]="extensions"; used.extensions=true
            reordered[#reordered+1]="miuread_settings"; used.miuread_settings=true
            for _,key in ipairs(action_order) do if not used[key] then reordered[#reordered+1]=key; used[key]=true end end
            for _,key in ipairs({"all_books","history","file_manager","screenshot"}) do if not used[key] then reordered[#reordered+1]=key; used[key]=true end end
            home.action_order=reordered
            home.action_layout_version=4

            home.panel_items=type(home.panel_items)=="table" and home.panel_items or {}
            home.panel_items.sync=nil
            home.panel_items.miuread_settings=nil
            home.panel_items.downloads=nil
            home.panel_items.sleep=true
            -- Exit remains available as an optional control, but the recommended
            -- eight slots now reserve a visible place for sleep.
            if home.panel_items.quit==true then home.panel_items.quit=false end
            home.panel_order={"wifi","bluetooth","rotate","screenshot","full_refresh","sleep","koreader_settings","return_koreader","quit","restart"}
            home.panel_layout_version=4
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 122 -> 123 done")
        end
        if schema<124 then
            -- 5.7.0-beta.6 turns the top of Home into one Recent Reading card.
            -- System state becomes a thin in-card information band and Home
            -- exposes one configurable statistics slot. Synchronization itself
            -- is no longer duplicated in the six-item action bar.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.layout_version=26
            local legacy_weread=home.show_weread_stats~=false
            local legacy_local=home.show_local_stats~=false
            local valid_slots={none=true,weread_today=true,weread_week=true,weread_month=true,local_today=true,local_week=true,local_month=true}
            if not valid_slots[tostring(home.stats_slot or "")] then
                if legacy_weread then home.stats_slot="weread_month"
                elseif legacy_local then home.stats_slot="local_week"
                else home.stats_slot="none" end
            end
            home.status_card_enabled=home.status_card_enabled~=false
            home.status_items=type(home.status_items)=="table" and home.status_items or {}
            for key,value in pairs({time=true,date=true,wifi=true,battery=true,sync=true,bluetooth=false,downloads=false}) do
                if home.status_items[key]==nil then home.status_items[key]=value end
            end
            do
                local wanted={"time","date","wifi","battery","sync","bluetooth","downloads"}
                local old_order=type(home.status_order)=="table" and home.status_order or {}
                local seen={time=true,date=true}
                local order={"time","date"}
                for _,key in ipairs(old_order) do
                    key=tostring(key or "")
                    if not seen[key] and home.status_items[key]~=nil then order[#order+1]=key; seen[key]=true end
                end
                for _,key in ipairs(wanted) do
                    if not seen[key] then order[#order+1]=key; seen[key]=true end
                end
                home.status_order=order
            end

            home.action_items=type(home.action_items)=="table" and home.action_items or {}
            local action=home.action_items
            local legacy_default=(tonumber(home.action_layout_version or 0) or 0)==4
                and action.refresh~=false and action.search~=false and action.downloads~=false
                and action.sync~=false and action.extensions~=false and action.miuread_settings~=false
                and action.sleep~=true and action.all_books~=true and action.history~=true
                and action.file_manager~=true and action.screenshot~=true
            if legacy_default then
                -- Only replace Sync with Sleep when the beta.5 six-item bar was
                -- still untouched. Customized bars keep the user's choices.
                action.sync=false
                action.sleep=true
                home.action_order={"refresh","search","downloads","sleep","extensions","miuread_settings","sync","all_books","history","file_manager","screenshot"}
            else
                if action.sleep==nil then action.sleep=false end
                local old_order=type(home.action_order)=="table" and home.action_order or {}
                local wanted={"refresh","search","downloads","sleep","extensions","miuread_settings","sync","all_books","history","file_manager","screenshot"}
                local order,seen={},{}
                for _,key in ipairs(old_order) do
                    key=tostring(key or "")
                    if not seen[key] then order[#order+1]=key; seen[key]=true end
                end
                for _,key in ipairs(wanted) do
                    if not seen[key] then order[#order+1]=key; seen[key]=true end
                end
                home.action_order=order
            end
            home.action_layout_version=5

            -- A restored settings backup may legitimately preserve durable
            -- preferences and book history, but in-flight worker states belong
            -- to the process that wrote that generation. Never resurrect them.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local library=self.db:readSetting("library",{}) or {}
            local cleared=0
            local restored=self.restored_settings_source~=nil
            local transient={waiting_network=true,uploading=true,retrying=true,finalizing=true,upload_unconfirmed=true,upload_failed=true,verifying_upload=true,deferred=true,verification_required=true,remote_jump_unconfirmed=true}
            for id,session in pairs(type(sessions)=="table" and sessions or {}) do
                if type(session)=="table" then
                    local pending=type(session.pending_progress)=="table" and session.pending_progress or nil
                    local pending_seq=pending and (tonumber(pending.progress_sequence or 0) or 0) or 0
                    local verified_seq=tonumber(session.progress_verified_sequence or 0) or 0
                    local uid=pending and tostring(pending.chapter_uid or pending.chapterUid or "") or ""
                    local co=pending and tonumber(pending.canonical_offset or pending.chapter_offset or pending.offset) or nil
                    local progress=pending and tonumber(pending.progress) or nil
                    local basis=pending and tostring(pending.offset_basis or pending.position_basis or "") or ""
                    local replayable=pending~=nil and uid~="" and co~=nil and progress~=nil and pending.safe==true and (basis~="" or pending.native_offset==true)
                    local stale_verified=pending~=nil and pending_seq>0 and verified_seq>=pending_seq
                    local state=tostring(session.progress_sync_state or "")
                    local has_book_record=type(library[tostring(id)])=="table"
                    local orphan=pending~=nil and not has_book_record
                    local invalid_pending=pending~=nil and not replayable
                    local clear_pending=stale_verified or orphan or (invalid_pending and (restored or transient[state]))
                    if clear_pending then
                        if session.pending_progress~=nil then session.pending_progress=false; cleared=cleared+1 end
                        pending=nil
                    end
                    -- Worker flags describe the process that wrote the settings
                    -- generation and are never safe to resurrect from backup.
                    if restored or clear_pending or (transient[state] and not replayable) then
                        session.progress_worker_active=false
                        session.progress_worker_updated_at=0
                        session.progress_upload_pending_at=false
                        session.progress_upload_error=false
                        session.progress_resubmit_allowed=false
                        session.progress_last_verify_reason=false
                    end
                    if restored and pending~=nil and replayable and has_book_record then
                        -- Keep an exact immutable snapshot, but downgrade the old
                        -- process state to verify-only work instead of replaying a
                        -- historical upload blindly.
                        session.progress_sync_state="deferred"
                        session.progress_sync_message="恢复设置后等待重新确认"
                    elseif clear_pending or (transient[state] and not replayable) then
                        session.progress_sync_state=verified_seq>0 and "local_uploaded" or ""
                        session.progress_sync_message=restored and "恢复设置后已丢弃失效的临时同步状态" or ""
                    end
                    if (restored or not has_book_record) and tonumber(session.pending_report_seconds or 0)>0 then
                        session.pending_report_seconds=0; cleared=cleared+1
                    end
                    if not has_book_record then session.sync_repair_required=false end
                end
            end
            self.db:saveSetting("sessions",sessions)
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 123 -> 124 done",
                "restored=",tostring(restored),"transient_cleared=",tostring(cleared))
        end
        if schema<125 then
            -- 5.7.0-beta.7 rolls the experimental beta.5/beta.6 Home redesign
            -- back to the established beta.4 layout. Keep the slimming and
            -- synchronization fixes, but restore the original first header row,
            -- dashboard proportions and six-item Home action bar.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.layout_version=24
            if home.show_weread_stats==nil then home.show_weread_stats=true end
            if home.show_local_stats==nil then home.show_local_stats=true end
            home.stats_slot=nil
            home.status_card_enabled=nil
            home.status_items=nil
            home.status_order=nil

            home.action_items={
                refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,
                all_books=false,history=false,file_manager=false,screenshot=false,
            }
            home.action_order={"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot"}
            home.action_layout_version=3

            home.panel_items={
                wifi=true,bluetooth=true,rotate=true,screenshot=true,full_refresh=true,
                koreader_settings=true,return_koreader=true,quit=true,sync=true,
                miuread_settings=false,downloads=false,restart=false,sleep=false,
            }
            home.panel_order={"wifi","bluetooth","rotate","screenshot","full_refresh","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep"}
            home.panel_layout_version=3

            -- Keep beta.6's ghost-sync protection while rolling back only UI.
            -- Orphan/stale transient snapshots must not reappear as actionable
            -- work after the Home layout rollback.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local library=self.db:readSetting("library",{}) or {}
            local cleared=0
            for id,session in pairs(type(sessions)=="table" and sessions or {}) do
                if type(session)=="table" then
                    local pending=type(session.pending_progress)=="table" and session.pending_progress or nil
                    local pending_seq=pending and (tonumber(pending.progress_sequence or 0) or 0) or 0
                    local verified_seq=tonumber(session.progress_verified_sequence or 0) or 0
                    local has_book_record=type(library[tostring(id)])=="table"
                    if pending and ((pending_seq>0 and verified_seq>=pending_seq) or not has_book_record) then
                        session.pending_progress=false
                        session.progress_worker_active=false
                        session.progress_worker_updated_at=0
                        session.progress_upload_pending_at=false
                        session.progress_upload_error=false
                        session.progress_resubmit_allowed=false
                        session.progress_last_verify_reason=false
                        session.progress_sync_state=verified_seq>0 and "local_uploaded" or ""
                        session.progress_sync_message="已清理失效的历史同步状态"
                        cleared=cleared+1
                    end
                    if not has_book_record then
                        if tonumber(session.pending_report_seconds or 0)>0 then
                            session.pending_report_seconds=0
                            cleared=cleared+1
                        end
                        session.sync_repair_required=false
                    end
                end
            end
            self.db:saveSetting("sessions",sessions)
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 124 -> 125 done",
                "home_layout=classic","ghost_sync_cleared=",tostring(cleared))
        end
        if schema<126 then
            -- 5.7.0-beta.10 introduces a source-agnostic Home library index.
            -- This migration only initializes view/filter state; existing
            -- databases, downloaded files and local-library caches stay put.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            local map={account="shelf",generated="device",["local"]="device",mp="shelf"}
            home.active_section=map[home.active_section] or home.active_section
            if home.active_section~="shelf" and home.active_section~="device" and home.active_section~="recent" then
                home.active_section="shelf"
            end
            home.library_layout_version=1
            home.library_membership=type(home.library_membership)=="table" and home.library_membership or {}
            home.library_filters=type(home.library_filters)=="table" and home.library_filters or {}
            home.library_filters.shelf=type(home.library_filters.shelf)=="table" and home.library_filters.shelf
                or {source="all",kind="all",locality="all",sort="recent"}
            home.library_filters.device=type(home.library_filters.device)=="table" and home.library_filters.device
                or {source="all",kind="all",locality="all",sort="recent"}
            home.source_order={"shelf","device","recent"}
            home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
            home.visible_sections.shelf=true; home.visible_sections.device=true; home.visible_sections.recent=true
            home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
            home.page_by_section.shelf=tonumber(home.page_by_section.shelf) or 1
            home.page_by_section.device=tonumber(home.page_by_section.device) or 1
            home.page_by_section.recent=tonumber(home.page_by_section.recent) or 1
            self:save_preferences(current)
            logger.info("[MiuRead][Migration] schema 125 -> 126 done",
                "home_library=unified","files_moved=false","existing_data_preserved=true")
        end
        if schema<127 then
            -- 5.8.0-beta.4 separates the complete WeRead snapshot from the
            -- user-authorized shelf, removes hidden type/locality filters and
            -- restores the complete quick-control candidate pools.
            local current=self:preferences()
            current.shelf_filter=type(current.shelf_filter)=="table" and current.shelf_filter or {enabled=false,archives={}}
            current.shelf_filter.archives=type(current.shelf_filter.archives)=="table" and current.shelf_filter.archives or {}
            current.shelf_filter.archive_keys=type(current.shelf_filter.archive_keys)=="table" and current.shelf_filter.archive_keys or {}
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.library_filters=type(home.library_filters)=="table" and home.library_filters or {}
            for _,section in ipairs({"shelf","device"}) do
                home.library_filters[section]=type(home.library_filters[section])=="table" and home.library_filters[section] or {}
                local state=home.library_filters[section]
                state.source=tostring(state.source or "all")
                state.sort=tostring(state.sort or "recent")
                state.kind="all"
                state.locality="all"
            end
            home.weread_group="all"
            home.action_items=type(home.action_items)=="table" and home.action_items or {}
            if home.action_items.extensions==nil then home.action_items.extensions=false end
            home.action_order=type(home.action_order)=="table" and home.action_order or {}
            local action_seen=false
            for _,key in ipairs(home.action_order) do if key=="extensions" then action_seen=true; break end end
            if not action_seen then home.action_order[#home.action_order+1]="extensions" end
            home.action_layout_version=4
            home.panel_items=type(home.panel_items)=="table" and home.panel_items or {}
            local panel_defaults={bluetooth=false,downloads=false,sync=false,miuread_settings=false,koreader_settings=true,
                koreader_file_manager=false,return_koreader=true,quit=false,restart=true,sleep=true,reboot=false,poweroff=false}
            for key,value in pairs(panel_defaults) do if home.panel_items[key]==nil then home.panel_items[key]=value end end
            local desired={"wifi","bluetooth","rotate","screenshot","full_refresh","downloads","sync","miuread_settings",
                "koreader_settings","koreader_file_manager","return_koreader","quit","restart","sleep","reboot","poweroff"}
            local seen,order={},{}
            for _,key in ipairs(type(home.panel_order)=="table" and home.panel_order or {}) do
                if not seen[key] then seen[key]=true; order[#order+1]=key end
            end
            for _,key in ipairs(desired) do if not seen[key] then seen[key]=true; order[#order+1]=key end end
            home.panel_order=order
            home.panel_layout_version=5
            self:save_preferences(current)
            local cache=self.db:readSetting("shelf_cache",{}) or {}
            cache.stream={enabled=false,ids={},hydrated_ids={},total=0,source="disabled_beta4",updated_at=0}
            -- A beta.3 streamed cache may contain placeholder rows. Mark it
            -- stale so Home schedules a complete snapshot refresh, while the
            -- defensive cache reader keeps selected-group users fail-closed.
            cache.updated_at=0
            self.db:saveSetting("shelf_cache",cache)
            logger.info("[MiuRead][Migration] schema 126 -> 127 done",
                "weread_scope=preserved","hidden_filters=cleared","panel_max=12","stream_navigation=false")
        end
        self.db:saveSetting("schema",Config.SCHEMA)
    end
end
function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v)
    self.db:saveSetting(k,v)
    return self:flush()
end
function Store:set_deferred(k,v) self.db:saveSetting(k,v) end
local function sanitized_auth(value)
    local auth=U.merge(defaults.auth,value or {})
    auth.auth_revision=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    auth.mp_cookie_header=nil
    auth.mp_extra_headers=nil
    auth.mp_referer=nil
    auth.mp_auth_source=nil
    auth.mp_authorized_at=nil
    return auth
end
local function same_login_cookies(a,b)
    a=type(a)=="table" and a or {}; b=type(b)=="table" and b or {}
    for key,value in pairs(a) do
        if type(key)=="string" and key:match("^wr_") and tostring((b or {})[key] or "")~=tostring(value or "") then
            return false
        end
    end
    for key,value in pairs(b) do
        if type(key)=="string" and key:match("^wr_") and tostring((a or {})[key] or "")~=tostring(value or "") then
            return false
        end
    end
    return true
end
local function same_auth_credentials(a,b)
    a=sanitized_auth(a); b=sanitized_auth(b)
    local aa=type(a.account)=="table" and a.account or {}
    local ba=type(b.account)=="table" and b.account or {}
    return tostring(a.login_session_id or "")==tostring(b.login_session_id or "")
        and tostring(aa.vid or "")==tostring(ba.vid or "")
        and tostring(a.api_key or "")==tostring(b.api_key or "")
        and tostring(a.wr_ticket or "")==tostring(b.wr_ticket or "")
        and tostring(a.wr_wrpa or "")==tostring(b.wr_wrpa or "")
        and same_login_cookies(a.cookies,b.cookies)
end
function Store:auth() return sanitized_auth(self:get("auth",{})) end
function Store:save_auth(v,opt)
    opt=type(opt)=="table" and opt or {}
    local current=sanitized_auth(self:get("auth",{}))
    local incoming=sanitized_auth(v)
    local current_revision=math.max(0,tonumber(current.auth_revision or 0) or 0)
    local incoming_revision=math.max(0,tonumber(incoming.auth_revision or 0) or 0)
    local expected=opt.expected_revision~=nil and tonumber(opt.expected_revision) or nil
    if expected~=nil and expected~=current_revision then
        return false,"登录凭据已经更新，已忽略旧任务结果"
    end
    local credentials_changed=not same_auth_credentials(current,incoming)
    if credentials_changed then
        if opt.replace_login~=true and current_revision>0 and incoming_revision~=current_revision then
            return false,"登录凭据版本已经变化，已拒绝旧凭据覆盖"
        end
        incoming.auth_revision=current_revision+1
    else
        incoming.auth_revision=current_revision
    end
    return self:set("auth",incoming)
end
function Store:auth_revision()
    return math.max(0,tonumber(self:auth().auth_revision or 0) or 0)
end
function Store:generate_login_session_id() return generate_login_session_id() end
function Store:ensure_login_session_id()
    local auth=self:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local cookies=type(auth.cookies)=="table" and auth.cookies or {}
    local has_web=tostring(cookies.wr_skey or "")~=""
    local has_agent=tostring(auth.api_key or "")~=""
    if tostring(auth.login_session_id or "")=="" and tostring(account.vid or "")~=""
        and (has_agent or has_web) then
        auth.login_session_id=generate_login_session_id()
        local saved,err=self:save_auth(auth)
        if saved~=true then return "",err end
    end
    return tostring(auth.login_session_id or "")
end
function Store:auth_health()
    local auth=self:auth()
    return U.merge(defaults.auth.health,auth.health or {})
end
function Store:update_auth_health(patch)
    local auth=self:auth()
    auth.health=U.merge(defaults.auth.health,auth.health or {})
    auth.health=U.merge(auth.health,patch or {})
    self:save_auth(auth)
    return auth.health
end
function Store:clear_auth() return self:set("auth",U.copy(defaults.auth)) end
function Store:clear_account_shelf_cache()
    local cache=self:shelf_cache()
    cache.raw_books={}; cache.raw_mp={}; cache.books={}; cache.mp={}; cache.updated_at=0
    cache.groups={updated_at=0,authoritative=false,list={},book_groups={}}
    cache.effective_scope={mode="all",fingerprint="all",updated_at=0}
    cache.stream={enabled=false,ids={},hydrated_ids={},total=0,source="",updated_at=0}
    self:save_shelf_cache(cache)
end
function Store:preferences() return U.merge(defaults.preferences,self:get("preferences",{})) end
function Store:save_preferences(v) return self:set("preferences",U.merge(defaults.preferences,v or {})) end
function Store:save_preferences_deferred(v) self:set_deferred("preferences",U.merge(defaults.preferences,v or {})) end
function Store:books_root() local p=self:preferences().download_dir; if p=="" then p=self.default_books_dir end; U.mkdir(p); return p end
function Store:epub_root() return self:books_root() end
function Store:prefetch_book_path(id) return self.prefetch_dir.."/"..U.id_name(id) end
function Store:prefetch_root(id)
    U.mkdir(self.prefetch_dir)
    if id==nil then return self.prefetch_dir end
    local path=self:prefetch_book_path(id); U.mkdir(path); return path
end
function Store:hidden_prefetch_path(id,uid,kind)
    local dir=self:prefetch_root(id)
    return dir.."/"..U.id_name(uid).."-"..U.safe_name(kind or "clean","clean")..".epub"
end
function Store:book_cache_path(id) return self.cache_books_dir.."/"..U.id_name(id) end
function Store:mp_account_dir(id)
    local path=self.mp_dir.."/"..U.id_name(id)
    U.mkdir(self.mp_dir); U.mkdir(path)
    return path
end
function Store:mp_root() U.mkdir(self.mp_dir); return self.mp_dir end
function Store:book_dir(id) local p=self:book_cache_path(id); U.mkdir(p); return p end
function Store:epub_path(filename) local p=self:epub_root().."/"..tostring(filename); U.mkdir(self:epub_root()); return p end

local function basename(path) return tostring(path or ""):match("([^/]+)$") end
function Store:library() return self:get("library",{}) end
function Store:book(id) return self:library()[tostring(id)] end
function Store:save_book(id,patch)
    local all=self:library(); local key=tostring(id)
    all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {})
    local saved,err=self:set("library",all)
    return all[key],saved,err
end
function Store:clear_book_access(id)
    local all=self:library(); local key=tostring(id)
    if type(all[key])=="table" and all[key].access~=nil then
        all[key].access=nil
        self:set("library",all)
    end
    return all[key]
end
function Store:save_variant(id,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.variants=b.variants or {}; b.variants[kind]=U.copy(record); return self:save_book(id,b)
end
function Store:save_chapter_variant(id,uid,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.chapters=b.chapters or {}; local key=tostring(uid); b.chapters[key]=b.chapters[key] or {}; b.chapters[key][kind]=U.copy(record); return self:save_book(id,b)
end
function Store:variant(id,kind) local b=self:book(id); return b and b.variants and b.variants[kind] end
function Store:chapter_variant(id,uid,kind) local b=self:book(id); return b and b.chapters and b.chapters[tostring(uid)] and b.chapters[tostring(uid)][kind] end
local function add_unique_path(out,seen,path)
    path=tostring(path or "")
    if path~="" and not seen[path] then seen[path]=true; out[#out+1]=path end
end
function Store:partial_cache_paths(id)
    local root=self:book_cache_path(id)
    local out={}
    if lfs.attributes(root,"mode")~="directory" then return out end
    local ok,iter,state=pcall(lfs.dir,root)
    if not ok or type(iter)~="function" then return out end
    for name in iter,state do
        if name~="." and name~=".." and tostring(name):match("^%.miuread%-partial%-") then out[#out+1]=root.."/"..name end
    end
    table.sort(out)
    return out
end
function Store:book_has_partial_cache(id) return #self:partial_cache_paths(id)>0 end
function Store:variant_paths(id,kind)
    local r=self:variant(id,kind)
    return r and r.file and {r.file} or {}
end
function Store:chapter_paths(id,uid)
    local b=self:book(id); local row=b and b.chapters and b.chapters[tostring(uid)]
    local out,seen={},{}
    for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end
    return out
end
function Store:book_paths(id,include_cache)
    local b=self:book(id)
    local out,seen={},{}
    if b then
        for _,r in pairs(b.variants or {}) do add_unique_path(out,seen,r and r.file) end
        for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end end
    end
    if include_cache~=false then
        add_unique_path(out,seen,self:book_cache_path(id))
        local prefetch_path=self:prefetch_book_path(id)
        if lfs.attributes(prefetch_path)~=nil then add_unique_path(out,seen,prefetch_path) end
    end
    return out
end
function Store:all_download_paths(include_covers)
    local out,seen={},{}
    for id,_ in pairs(self:library()) do for _,path in ipairs(self:book_paths(id,true)) do add_unique_path(out,seen,path) end end
    add_unique_path(out,seen,self.cache_books_dir)
    add_unique_path(out,seen,self.prefetch_dir)
    if include_covers then add_unique_path(out,seen,self.covers_dir) end
    return out
end
local function book_has_records(book)
    if type(book)~="table" then return false end
    if next(book.variants or {}) then return true end
    for _,row in pairs(book.chapters or {}) do if next(row or {}) then return true end end
    return false
end
function Store:forget_variant(id,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; if not b then return end
    if b.variants then b.variants[kind]=nil end
    if not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter(id,uid,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; local row=b and b.chapters and b.chapters[tostring(uid)]
    if row then row[kind]=nil; if next(row)==nil then b.chapters[tostring(uid)]=nil end end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter_all(id,uid)
    local all=self:library(); local key=tostring(id); local b=all[key]
    if b and b.chapters then b.chapters[tostring(uid)]=nil end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_book(id) local all=self:library(); all[tostring(id)]=nil; self:set("library",all) end
function Store:forget_book_local_state(id)
    local key=tostring(id or "")
    if key=="" then return false end
    local all=self:library(); all[key]=nil; self:set("library",all)
    local prefetch=self:get("prefetch_cache",{}); prefetch[key]=nil; self:set("prefetch_cache",prefetch)
    U.remove_tree(self:prefetch_book_path(key))
    local sessions=self:get("sessions",{}); sessions[key]=nil; self:set("sessions",sessions)
    local covers=self:get("cover_index",{}); covers[key]=nil; self:set("cover_index",covers)

    local queue_out={}
    for _,job in ipairs(self:download_queue()) do
        local job_id=tostring((job.book and (job.book.bookId or job.book.book_id)) or job.book_id or "")
        if job_id~=key then queue_out[#queue_out+1]=job end
    end
    self:save_download_queue(queue_out)

    local pending_out={}
    for _,row in ipairs(self:pending_installs()) do
        if tostring(row.book_id or "")~=key then pending_out[#pending_out+1]=row end
    end
    self:save_pending_installs(pending_out)

    local shelf=self:shelf_cache()
    local shelf_changed=false
    for _,group in ipairs({shelf.raw_books or {},shelf.raw_mp or {},shelf.books or {},shelf.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==key and row.cover_path~=nil then
                row.cover_path=nil; shelf_changed=true
            end
        end
    end
    if shelf_changed then self:save_shelf_cache(shelf) end

    local state=self:download_state()
    if tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")==key then
        self:clear_download_state()
    end
    return true
end
function Store:forget_all_books() self:set("library",{}) end
function Store:prune_missing_files()
    local all=self:library(); local changed=false
    for id,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do if not (r and r.file and U.file_exists(r.file)) then b.variants[kind]=nil; changed=true end end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do if not (r and r.file and U.file_exists(r.file)) then row[kind]=nil; changed=true end end
            if next(row or {})==nil then b.chapters[uid]=nil; changed=true end
        end
        if not book_has_records(b) and not self:book_has_partial_cache(id) then all[id]=nil; changed=true end
    end
    if changed then self:set("library",all) end
    return changed
end
function Store:delete_variant(id,kind)
    for _,path in ipairs(self:variant_paths(id,kind)) do U.remove_tree(path) end
    self:forget_variant(id,kind)
end
function Store:delete_chapter(id,uid,kind)
    local r=self:chapter_variant(id,uid,kind); if r and r.file then U.remove_tree(r.file) end
    self:forget_chapter(id,uid,kind)
end
function Store:hidden_prefetch_record(id,uid,kind)
    local all=self:get("prefetch_cache",{})
    local book=type(all[tostring(id)])=="table" and all[tostring(id)] or nil
    local row=book and type(book[tostring(uid)])=="table" and book[tostring(uid)] or nil
    return row and type(row[tostring(kind)])=="table" and U.copy(row[tostring(kind)]) or nil
end
function Store:save_hidden_prefetch(id,uid,kind,record)
    local book_id,chapter_uid,variant=tostring(id),tostring(uid),tostring(kind)
    if book_id=="" or chapter_uid=="" or variant=="" or type(record)~="table" then return nil,"invalid prefetch record" end
    local all=self:get("prefetch_cache",{})
    local old=type(all[book_id])=="table" and all[book_id] or {}
    -- One passive next-chapter artifact per book. This bounds storage and also
    -- prevents two automatic generations from racing after a chapter switch.
    for old_uid,row in pairs(old) do
        for old_kind,old_record in pairs(type(row)=="table" and row or {}) do
            if old_uid~=chapter_uid or old_kind~=variant then
                local old_file=type(old_record)=="table" and tostring(old_record.file or "") or ""
                if old_file~="" and U.file_exists(old_file) then U.remove_tree(old_file) end
            end
        end
    end
    all[book_id]={[chapter_uid]={[variant]=U.copy(record)}}
    return self:set("prefetch_cache",all)
end
function Store:forget_hidden_prefetch(id,uid,kind,remove_file)
    local book_id,chapter_uid,variant=tostring(id),tostring(uid),tostring(kind)
    local all=self:get("prefetch_cache",{})
    local book=all[book_id]
    local row=type(book)=="table" and book[chapter_uid] or nil
    local record=type(row)=="table" and row[variant] or nil
    if remove_file==true and type(record)=="table" and tostring(record.file or "")~="" then U.remove_tree(record.file) end
    if type(row)=="table" then
        row[variant]=nil
        if next(row)==nil then book[chapter_uid]=nil end
    end
    if type(book)=="table" and next(book)==nil then all[book_id]=nil end
    self:set("prefetch_cache",all)
    return record~=nil
end
function Store:hidden_prefetch_entries(id)
    local wanted=id~=nil and tostring(id) or nil
    local all=self:get("prefetch_cache",{})
    local out={}
    for book_id,book in pairs(all) do
        if wanted==nil or tostring(book_id)==wanted then
            for uid,row in pairs(type(book)=="table" and book or {}) do
                for kind,record in pairs(type(row)=="table" and row or {}) do
                    if type(record)=="table" then
                        out[#out+1]={book_id=tostring(book_id),uid=tostring(uid),kind=tostring(kind),
                            file=record.file,record=U.copy(record),hidden=true}
                    end
                end
            end
        end
    end
    return out
end
function Store:prune_hidden_prefetch(ttl)
    ttl=math.max(60,tonumber(ttl) or tonumber(Config.CHAPTER_PREFETCH_TTL) or 86400)
    local now=os.time(); local all=self:get("prefetch_cache",{}); local changed=false; local removed=0
    for book_id,book in pairs(all) do
        for uid,row in pairs(type(book)=="table" and book or {}) do
            for kind,record in pairs(type(row)=="table" and row or {}) do
                local file=type(record)=="table" and tostring(record.file or "") or ""
                local created=tonumber(type(record)=="table" and (record.prefetch_at or record.downloaded_at) or 0) or 0
                local stale=created>0 and now-created>ttl
                if file=="" or not U.file_exists(file) or stale then
                    if stale and file~="" and U.file_exists(file) then U.remove_tree(file) end
                    row[kind]=nil; removed=removed+1; changed=true
                end
            end
            if next(row)==nil then book[uid]=nil end
        end
        if next(book)==nil then all[book_id]=nil end
    end
    if changed then self:set("prefetch_cache",all) end
    return removed
end
function Store:prefetched_chapters(id)
    local out=self:hidden_prefetch_entries(id)
    table.sort(out,function(a,b)
        if a.book_id~=b.book_id then return a.book_id<b.book_id end
        if a.uid~=b.uid then return a.uid<b.uid end
        return a.kind<b.kind
    end)
    return out
end
function Store:prefetched_chapter_count(id) return #self:prefetched_chapters(id) end
function Store:delete_book(id)
    for _,path in ipairs(self:book_paths(id,true)) do U.remove_tree(path) end
    self:forget_book(id)
end
function Store:all_books()
    local o={}; for id,b in pairs(self:library()) do local x=U.copy(b); x.book_id=x.book_id or id; o[#o+1]=x end
    table.sort(o,function(a,b) return tonumber(a.updated_at or a.downloaded_at or 0)>tonumber(b.updated_at or b.downloaded_at or 0) end); return o
end
local function normalize_path(path)
    local value=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    value=value:gsub("/%./","/")
    while value:find("/[^/]+/%.%./") do value=value:gsub("/[^/]+/%.%./","/") end
    if #value>1 then value=value:gsub("/$","") end
    return value
end

local function read_pipe(command)
    local pipe=io.popen(command,"r")
    if not pipe then return nil end
    local data=pipe:read("*a")
    pipe:close()
    if data=="" then return nil end
    return data
end

local function xml_unescape(value)
    return tostring(value or "")
        :gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function filename_key(path)
    local name=tostring(basename(path) or ""):lower()
    -- Treat harmless spacing differences around the variant suffix as the same
    -- filename, but only relink when the match is unique.
    name=name:gsub("%s+", "")
    return name:gsub("　", "")
end

local function identity_from_blob(blob,identity)
    blob=tostring(blob or "")
    identity=type(identity)=="table" and identity or {}
    identity.book_id=identity.book_id
        or blob:match('"book_id"%s*:%s*"([^"]+)"')
        or blob:match("miuread://book/([^<%s\"]+)")
    identity.variant=identity.variant or blob:match('"variant"%s*:%s*"([^"]+)"')
    identity.content_type=identity.content_type or blob:match('"content_type"%s*:%s*"([^"]+)"')
    if identity.progress_source_complete==nil then
        if blob:match('"progress_source_complete"%s*:%s*true') then identity.progress_source_complete=true
        elseif blob:match('"progress_source_complete"%s*:%s*false') then identity.progress_source_complete=false end
    end
    identity.progress_source_chapter_count=identity.progress_source_chapter_count
        or tonumber(blob:match('"progress_source_chapter_count"%s*:%s*(%d+)'))
    identity.progress_source_cached_count=identity.progress_source_cached_count
        or tonumber(blob:match('"progress_source_cached_count"%s*:%s*(%d+)'))
    identity.progress_source_book_version=identity.progress_source_book_version
        or tonumber(blob:match('"progress_source_book_version"%s*:%s*(%d+)'))
    if identity.standalone==nil and blob:match('"standalone"%s*:%s*true') then identity.standalone=true end
    identity.chapter_uid=identity.chapter_uid or blob:match('"chapter_uid"%s*:%s*"?([^",}%s]+)')
    identity.title=identity.title or xml_unescape(blob:match("<dc:title[^>]*>(.-)</dc:title>"))
    identity.author=identity.author or xml_unescape(blob:match("<dc:creator[^>]*>(.-)</dc:creator>"))
    return identity
end

function Store:epub_identity_light(path)
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local file=io.open(path,"rb")
    if not file then return nil end
    local size=file:seek("end") or 0
    file:seek("set",0)
    local head=file:read(math.min(size,768*1024)) or ""
    local tail=""
    if size>#head then
        file:seek("set",math.max(0,size-1024*1024))
        tail=file:read("*a") or ""
    end
    file:close()
    local identity=identity_from_blob(head.."\n"..tail,{})
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

function Store:epub_identity(path)
    local identity=self:epub_identity_light(path) or {}
    if tostring(identity.book_id or "")~="" then return identity end
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local quoted=U.shell_quote(path)
    local raw=read_pipe("unzip -p "..quoted.." OEBPS/miuread.json 2>/dev/null")
    if raw then
        local ok,value=pcall(Json.decode,raw)
        if ok and type(value)=="table" then identity=U.merge(identity,value) end
    end
    local opf=read_pipe("unzip -p "..quoted.." OEBPS/package.opf 2>/dev/null")
    if opf then identity=identity_from_blob(opf,identity) end
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

local function metadata_key(value)
    local text=tostring(value or ""):lower()
    text=text:gsub("%.epub$","")
    text=text:gsub("%s*%[[^%]]-%]%s*$","")
    text=text:gsub("%s*【.-】%s*$","")
    text=text:gsub("[%s%c%p]+","")
    text=text:gsub("　","")
    for _,mark in ipairs({"，","。","！","？","：","；","“","”","‘","’","《","》","〈","〉","（","）","【","】","·","—","…"}) do
        text=text:gsub(mark,"",1e6)
    end
    return text
end

local function relink_saved_record(store,all,book,record,path,current_size,relink)
    if not relink or type(record)~="table" then return end
    local changed=false
    if record.file~=path then
        record.file=path
        record.directory=path:match("^(.*)/[^/]+$")
        changed=true
    end
    if current_size and tonumber(record.file_size)~=tonumber(current_size) then
        record.file_size=current_size
        changed=true
    end
    if record.directory and book.directory~=record.directory then
        book.directory=record.directory
        changed=true
    end
    if changed then store:set("library",all) end
end

-- Older MiuRead library records may still point to a valid generated EPUB but
-- lack chapter_map. The EPUB itself embeds the authoritative local chapter list
-- in OEBPS/miuread.json. Restore that list once on discovery instead of forcing
-- progress sync to guess from an empty local map. This reads only ZIP metadata
-- and the small embedded MiuRead JSON; it never scans chapter bodies or uses the
-- network.
local function restore_embedded_chapter_map(store,all,book,record,path,kind,forced_uid)
    if type(record)~="table" or type(book)~="table" then return false end
    if type(record.chapter_map)=="table" and #record.chapter_map>0 then return false end
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return false end

    local ok_installer,Installer=pcall(require,"miuread.epub_installer")
    if not ok_installer or type(Installer)~="table" or type(Installer.inspect)~="function" then return false end
    local ok_meta,meta=pcall(Installer.inspect,path)
    if not ok_meta or type(meta)~="table" then return false end

    local book_id=tostring(book.book_id or record.book_id or "")
    local meta_id=tostring(meta.book_id or meta.bookId or "")
    if book_id~="" and meta_id~="" and book_id~=meta_id then
        logger.warn("[MiuRead][Store] embedded chapter map ignored book mismatch",
            "record=",book_id,"embedded=",meta_id)
        return false
    end
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    if #chapters==0 then return false end

    record.chapter_map=U.copy(chapters)
    record.chapter_count=#chapters
    if tostring(record.core_map_hash or "")=="" and tostring(meta.core_map_hash or "")~="" then
        record.core_map_hash=tostring(meta.core_map_hash)
    end
    if record.partial_range==nil and meta.partial_range~=nil then record.partial_range=meta.partial_range==true end
    if record.range_start_index==nil then record.range_start_index=tonumber(meta.range_start_index) end
    if record.range_end_index==nil then record.range_end_index=tonumber(meta.range_end_index) end
    if record.range_start_title==nil then record.range_start_title=meta.range_start_title end
    if record.range_end_title==nil then record.range_end_title=meta.range_end_title end

    local uid=tostring(forced_uid or record.chapter_uid or meta.chapter_uid or "")
    if uid~="" then record.chapter_uid=uid end

    -- Only a complete multi-chapter EPUB may also repair an empty book catalog.
    -- A standalone/range EPUB carries only a subset and must still obtain the
    -- full WeRead catalog through the normal context-only path.
    local local_is_subset=meta.standalone==true or meta.partial_range==true
    if not local_is_subset and (type(book.catalog)~="table" or #book.catalog==0) then
        book.catalog=U.copy(chapters)
    end

    store:set("library",all)
    logger.info("[MiuRead][Store] embedded chapter map restored",
        "book=",book_id~="" and book_id or meta_id,
        "variant=",tostring(kind or record.variant or ""),
        "chapters=",tostring(#chapters),
        "standalone=",tostring(meta.standalone==true),
        "partial=",tostring(meta.partial_range==true))
    return true
end

function Store:file_record_fast(path,relink)
    if not path then return nil end
    local normalized=normalize_path(path)
    local current_size
    local function file_size()
        if current_size==nil then current_size=U.file_size(path) or false end
        return current_size~=false and current_size or nil
    end
    local all=self:library()
    local function match_record(record)
        return type(record)=="table" and record.file and normalize_path(record.file)==normalized
    end
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if match_record(record) then
                relink_saved_record(self,all,book,record,path,file_size(),relink)
                restore_embedded_chapter_map(self,all,book,record,path,kind,nil)
                return book,record,kind
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if match_record(record) then
                    record.chapter_uid=uid
                    relink_saved_record(self,all,book,record,path,file_size(),relink)
                    restore_embedded_chapter_map(self,all,book,record,path,kind,uid)
                    return book,record,kind
                end
            end
        end
    end
    local wanted_name=filename_key(path)
    if wanted_name=="" then return nil end
    local matches={}
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if type(record)=="table" and filename_key(record.file)==wanted_name then
                matches[#matches+1]={book=book,record=record,kind=kind}
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if type(record)=="table" and filename_key(record.file)==wanted_name then
                    matches[#matches+1]={book=book,record=record,kind=kind,uid=uid}
                end
            end
        end
    end
    if #matches==1 then
        local found=matches[1]
        if found.uid then found.record.chapter_uid=found.uid end
        relink_saved_record(self,all,found.book,found.record,path,file_size(),relink)
        restore_embedded_chapter_map(self,all,found.book,found.record,path,found.kind,found.uid)
        return found.book,found.record,found.kind
    end
    return nil
end

function Store:file_record_from_identity(path,meta,relink)
    if not path or type(meta)~="table" then return nil end
    local current_size=U.file_size(path)
    local all=self:library()
    local id=tostring(meta.book_id or "")
    if id=="" then
        local wanted_title=metadata_key(meta.title)
        local wanted_author=metadata_key(meta.author)
        local matches={}
        if wanted_title~="" then
            for key,book in pairs(all) do
                if metadata_key(book.title)==wanted_title then
                    local author=metadata_key(book.author)
                    if wanted_author=="" or author=="" or author==wanted_author then
                        matches[#matches+1]={id=tostring(book.book_id or key),book=book}
                    end
                end
            end
        end
        if #matches==1 then
            id=matches[1].id
            meta.book_id=id
            meta.recovered_by="embedded_title"
            logger.info("[MiuRead][Store] legacy EPUB identity recovered by title","book=",id)
        else return nil end
    end
    local kind=tostring(meta.variant or "")
    if kind=="" then
        local name=tostring(basename(path) or "")
        if name:find("纯净版",1,true) then kind="clean"
        elseif name:find("划线与想法版",1,true) or name:find("想法版",1,true) then kind="notes" end
    end
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    local standalone=meta.standalone==true
    local uid=tostring(meta.chapter_uid or ((chapters[1] and (chapters[1].uid or chapters[1].chapter_uid)) or ""))
    local book=all[id]
    if kind=="" and book then
        local available={}
        for existing_kind,existing_record in pairs(book.variants or {}) do
            if type(existing_record)=="table" then available[#available+1]=existing_kind end
        end
        kind=#available==1 and tostring(available[1]) or "recovered"
    elseif kind=="" then kind="recovered" end
    local record
    if book then
        if standalone then
            local row=uid~="" and book.chapters and book.chapters[uid] or nil
            record=row and row[kind]
            if record then record.chapter_uid=uid end
        else
            record=book.variants and book.variants[kind]
        end
        if record and (type(record.chapter_map)~="table" or #record.chapter_map==0) and #chapters>0 then
            record.chapter_map=U.copy(chapters)
            record.chapter_count=#chapters
            if tostring(record.core_map_hash or "")=="" and tostring(meta.core_map_hash or "")~="" then
                record.core_map_hash=tostring(meta.core_map_hash)
            end
        end
        if not record then
            record={
                book_id=id,title=meta.title or book.title or basename(path),author=meta.author or book.author or "",
                file=path,directory=path:match("^(.*)/[^/]+$"),variant=kind,
                content_type=meta.content_type,sync_enabled=meta.sync_enabled,read_report_enabled=meta.read_report_enabled,
                downloaded_at=tonumber(meta.generated_at) or os.time(),chapter_map=chapters,
                chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,
                partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
                range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
                range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
                annotation_error_kind=meta.annotation_error_kind,core_map_hash=meta.core_map_hash,recovered=true,
            }
            if standalone and uid~="" then
                record.chapter_uid=uid
                book.chapters=book.chapters or {}; book.chapters[uid]=book.chapters[uid] or {}; book.chapters[uid][kind]=record
            else
                book.variants=book.variants or {}; book.variants[kind]=record
            end
        end
        if (#(book.catalog or {})==0) and #chapters>0 then book.catalog=U.copy(chapters) end
    else
        book={
            book_id=id,title=meta.title or tostring(basename(path) or id):gsub("%.epub$",""),
            author=meta.author or "",variants={},chapters={},catalog=chapters,
            content_type=meta.content_type,directory=path:match("^(.*)/[^/]+$"),updated_at=os.time(),recovered=true,
        }
        record={
            book_id=id,title=book.title,author=book.author,file=path,directory=book.directory,
            variant=kind,content_type=meta.content_type,sync_enabled=meta.sync_enabled,
            read_report_enabled=meta.read_report_enabled,downloaded_at=tonumber(meta.generated_at) or os.time(),
            chapter_map=chapters,chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,recovered=true,
            partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
            range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
            range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
            annotation_error_kind=meta.annotation_error_kind,core_map_hash=meta.core_map_hash,
        }
        if standalone and uid~="" then record.chapter_uid=uid; book.chapters[uid]={[kind]=record}
        else book.variants[kind]=record end
        all[id]=book
    end
    if record then
        if meta.progress_source_complete~=nil then
            record.progress_source_complete=meta.progress_source_complete==true
        end
        if tonumber(meta.progress_source_chapter_count)~=nil then
            record.progress_source_chapter_count=tonumber(meta.progress_source_chapter_count) or 0
        end
        if tonumber(meta.progress_source_cached_count)~=nil then
            record.progress_source_cached_count=tonumber(meta.progress_source_cached_count) or 0
        end
        if tonumber(meta.progress_source_book_version)~=nil then
            record.progress_source_book_version=tonumber(meta.progress_source_book_version) or 0
        end
    end
    if record and relink then relink_saved_record(self,all,book,record,path,current_size,true) end
    return book,record,kind
end

function Store:identify_file(path,relink)
    local book,record,kind=self:file_record_fast(path,relink)
    if book then return book,record,kind end
    local meta=self:epub_identity(path)
    return self:file_record_from_identity(path,meta,relink)
end

-- Reader-session recovery must be stricter than general library relinking.
-- Only an EPUB carrying MiuRead's embedded book id is allowed to become a
-- WeRead session; a same-title ordinary EPUB must stay a local book.
function Store:recover_miuread_file(path,relink)
    local book,record,kind=self:file_record_fast(path,relink)
    if book then return book,record,kind,"record" end
    local meta=self:epub_identity(path)
    local book_id=type(meta)=="table" and tostring(meta.book_id or "") or ""
    if book_id=="" then return nil end
    book,record,kind=self:file_record_from_identity(path,meta,relink)
    if not book then return nil end
    local _,saved,save_error=self:save_book(book_id,book)
    if saved~=true then
        logger.warn("[MiuRead][Store] embedded EPUB identity recovered but persistence failed",
            "book=",book_id,"error=",tostring(save_error or "unknown"))
    else
        logger.info("[MiuRead][Store] embedded EPUB identity recovered",
            "book=",book_id,"variant=",tostring(kind or "recovered"),"file=",tostring(path))
    end
    return book,record,kind,"embedded_book_id"
end

function Store:file_record(path)
    return self:identify_file(path,true)
end

function Store:mark_last_read(id,path,progress,flush_now,at)
    id=tostring(id or "")
    if id=="" then return end
    local patch={last_read_at=tonumber(at) or os.time()}
    if path then patch.last_read_path=path end
    if progress~=nil then patch.progress_local_percent=tonumber(progress) end
    self:save_session(id,patch,flush_now)
end
function Store:recent_reads()
    local state=self:get("recent_reads",{version=1,items={}})
    if type(state)~="table" then state={version=1,items={}} end
    state.version=1
    if type(state.items)~="table" then state.items={} end
    return state
end
function Store:record_recent_read(book_id,path,at)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" and path=="" then return nil end
    local stamp=tonumber(at) or os.time()
    local key=book_id~="" and ("book:"..book_id) or ("file:"..path)
    local state=self:recent_reads()
    local items={{key=key,book_id=book_id,file=path,read_at=stamp}}
    for _,row in ipairs(state.items) do
        if type(row)=="table" and tostring(row.key or "")~=key then
            local same_book=book_id~="" and tostring(row.book_id or "")==book_id
            local same_file=path~="" and tostring(row.file or "")==path
            if not same_book and not same_file then items[#items+1]=row end
        end
        if #items>=10 then break end
    end
    state.items=items
    self:set_deferred("recent_reads",state)
    if book_id~="" then self:mark_last_read(book_id,path,nil,false,stamp) end
    return items[1]
end
function Store:clear_login_bound_sessions(reason)
    local sessions=self:get("sessions",{})
    local cleaned,changed=invalidate_report_contexts_table(sessions)
    if changed>0 then self:set("sessions",cleaned) end
    self:save_auth(invalidate_upload_health_table(self:get("auth",{})))
    logger.info("[MiuRead][Store] login-bound sessions cleared",
        "reason=",tostring(reason or "unknown"),"fields=",tostring(changed))
    return changed,reason
end
function Store:refresh_same_account_login_contexts(reason)
    local sessions=self:get("sessions",{})
    local cleaned,changed=invalidate_same_account_contexts_table(sessions)
    if changed>0 then self:set("sessions",cleaned) end
    self:save_auth(invalidate_upload_health_table(self:get("auth",{})))
    logger.info("[MiuRead][Store] same-account login contexts refreshed",
        "reason=",tostring(reason or "login_refreshed"),"fields=",tostring(changed))
    return changed,reason
end
function Store:invalidate_report_contexts(reason)
    return self:clear_login_bound_sessions(reason)
end
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch,flush_now)
    local a=self:get("sessions",{}); local k=tostring(id)
    a[k]=U.merge(a[k] or {},patch or {})
    self.db:saveSetting("sessions",a)
    if flush_now~=false then
        local saved,err=self:flush()
        return a[k],saved,err
    end
    return a[k],true
end
function Store:invalidate_book_sync_context(id,reason,core_map_hash)
    local sessions=self:get("sessions",{})
    local key=tostring(id or "")
    if key=="" then return false end
    local row=type(sessions[key])=="table" and sessions[key] or {}
    for _,field in ipairs({
        "legacy_report_context","report_context","report_login_session_id","report_core_map_hash",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "verification_login_session_id","progress_upload_state","progress_upload_verified_at","progress_upload_source",
        "pending_progress","progress_upload_error","progress_upload_pending_at",
        "pending_report_seconds"
    }) do row[field]=nil end
    row.sync_context_invalidated_at=os.time()
    row.sync_context_invalidated_reason=tostring(reason or "book_context_changed")
    row.book_core_map_hash=tostring(core_map_hash or row.book_core_map_hash or "")
    row.pending_report_seconds=0
    sessions[key]=row
    self.db:saveSetting("sessions",sessions)
    self:flush()
    return true,row
end
function Store:clear_session(id) local a=self:get("sessions",{}); a[tostring(id)]=nil; self:set("sessions",a) end
function Store:shelf_cache() return U.merge(defaults.shelf_cache,self:get("shelf_cache",{})) end
function Store:save_shelf_cache(v) return self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function Store:update_cached_progress(id,percent)
    id=tostring(id or "")
    percent=tonumber(percent)
    if id=="" or percent==nil then return false end
    local cache=self:shelf_cache()
    local changed=false
    for _,group in ipairs({cache.raw_books or {},cache.raw_mp or {},cache.books or {},cache.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==id then
                row.progress=U.clamp(percent,0,100)
                row.finished=row.progress>=100
                changed=true
            end
        end
    end
    if changed then self:save_shelf_cache(cache) end
    return changed
end
function Store:cover_guard() return U.merge(defaults.cover_guard,self:get("cover_guard",{})) end
function Store:save_cover_guard(v) self:set("cover_guard",U.merge(defaults.cover_guard,v or {})) end
function Store:cover_path(id) return self.covers_dir.."/"..U.id_name(id)..".img" end
function Store:update_state() return self:get("update_state",{}) end
function Store:save_update_state(v) return self:set("update_state",v or {}) end
function Store:download_state()
    local value=DownloadDatabase.get_download_state(self)
    return type(value)=="table" and value or {}
end
function Store:save_download_state(value)
    return DownloadDatabase.set_download_state(self,value or {})
end
function Store:clear_download_state()
    return DownloadDatabase.clear_download_state(self)
end
function Store:download_queue()
    local queue=DownloadDatabase.get_download_queue(self)
    if type(queue)~="table" then return {} end
    if #queue<=1 then return queue end
    return {queue[1]}
end
function Store:save_download_queue(queue)
    queue=type(queue)=="table" and queue or {}
    local kept={}
    if type(queue[1])=="table" then kept[1]=U.copy(queue[1]) end
    return DownloadDatabase.set_download_queue(self,kept)
end
function Store:enqueue_download(job)
    local queue=self:download_queue()
    if #queue>=1 then return nil,"full" end
    queue[1]=U.copy(job or {})
    self:save_download_queue(queue)
    return 1
end
function Store:dequeue_download()
    local queue=self:download_queue(); if #queue==0 then return nil end
    local job=table.remove(queue,1); self:save_download_queue(queue); return job
end
function Store:remove_queued_download(index)
    local queue=self:download_queue(); index=tonumber(index); if not index or not queue[index] then return false end
    table.remove(queue,index); self:save_download_queue(queue); return true
end
function Store:pending_installs() return self:get("pending_installs",{}) end
function Store:save_pending_installs(rows) self:set("pending_installs",type(rows)=="table" and rows or {}) end
function Store:add_pending_install(book_id,kind,chapter_uid,record)
    local rows=self:pending_installs()
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local item={key=key,book_id=tostring(book_id or ""),kind=tostring(kind or ""),
        chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record and record.file,
        pending_file=record and record.pending_file,created_at=os.time()}
    local replaced=false
    for index,row in ipairs(rows) do
        if tostring(row.key or "")==key then rows[index]=item; replaced=true; break end
    end
    if not replaced then rows[#rows+1]=item end
    self:save_pending_installs(rows)
    return item
end
function Store:remove_pending_install(book_id,kind,chapter_uid)
    local rows,out=self:pending_installs(),{}
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local changed=false
    for _,row in ipairs(rows) do
        if tostring(row.key or "")==key then changed=true else out[#out+1]=row end
    end
    if changed then self:save_pending_installs(out) end
    return changed
end
function Store:prune_pending_installs()
    local rows,out=self:pending_installs(),{}
    local changed=false
    for _,row in ipairs(rows) do
        if row.pending_file and U.file_exists(row.pending_file) then out[#out+1]=row else changed=true end
    end
    if changed then self:save_pending_installs(out) end
    return out
end
function Store:last_cleanup_result() return self:get("last_cleanup_result",{}) end
function Store:save_cleanup_result(result) self:set("last_cleanup_result",type(result)=="table" and result or {}) end
function Store:is_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return false end
    local rows=self:get("read_report_consumed",{})
    return rows[stamp]~=nil
end
function Store:mark_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return end
    local rows=self:get("read_report_consumed",{})
    rows[stamp]=os.time()
    local ordered={}
    for key,at in pairs(rows) do ordered[#ordered+1]={key=key,at=tonumber(at) or 0} end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index=#ordered,21,-1 do rows[ordered[index].key]=nil end
    self:set("read_report_consumed",rows)
end
local PROGRESS_SESSION_FIELDS={
    "pending_progress","progress_latest_sequence","progress_verified_sequence",
    "progress_sync_state","progress_sync_message","progress_local_percent","progress_remote_percent","progress_decided_at",
    "progress_upload_state","progress_upload_error","progress_upload_pending_at","progress_upload_verified_at",
    "progress_upload_source","progress_upload_at","progress_upload_percent","progress_upload_chapter_uid",
    "progress_upload_co","progress_upload_remote_co","progress_worker_active","progress_worker_updated_at",
}

local function progress_session_sequence(row)
    row=type(row)=="table" and row or {}
    local pending=type(row.pending_progress)=="table" and row.pending_progress or {}
    return math.max(
        tonumber(row.progress_latest_sequence or 0) or 0,
        tonumber(row.progress_verified_sequence or 0) or 0,
        tonumber(pending.progress_sequence or 0) or 0
    )
end

local function progress_session_stamp(row)
    row=type(row)=="table" and row or {}
    return math.max(
        tonumber(row.progress_decided_at or 0) or 0,
        tonumber(row.progress_upload_verified_at or 0) or 0,
        tonumber(row.progress_upload_pending_at or 0) or 0,
        tonumber(row.progress_worker_updated_at or 0) or 0
    )
end

local function progress_session_rank(row)
    row=type(row)=="table" and row or {}
    local pending=type(row.pending_progress)=="table" and row.pending_progress or nil
    local pending_seq=pending and (tonumber(pending.progress_sequence or 0) or 0) or 0
    local verified_seq=tonumber(row.progress_verified_sequence or 0) or 0
    -- For the same sequence, a verified state is terminal and must always beat
    -- an older Home copy that still says pending/uploading, even if that stale
    -- copy happened to save another preference a few seconds later.
    if verified_seq>0 and verified_seq>=pending_seq then return 3 end
    if pending_seq>verified_seq then return 2 end
    return 1
end

local function merge_newer_progress_sessions(memory_sessions,disk_sessions)
    memory_sessions=type(memory_sessions)=="table" and memory_sessions or {}
    disk_sessions=type(disk_sessions)=="table" and disk_sessions or {}
    for id,disk_row in pairs(disk_sessions) do
        if type(disk_row)=="table" then
            local memory_row=type(memory_sessions[id])=="table" and memory_sessions[id] or nil
            if memory_row then
                local disk_seq=progress_session_sequence(disk_row)
                local memory_seq=progress_session_sequence(memory_row)
                local disk_rank=progress_session_rank(disk_row)
                local memory_rank=progress_session_rank(memory_row)
                local disk_stamp=progress_session_stamp(disk_row)
                local memory_stamp=progress_session_stamp(memory_row)
                -- Reader and Home can own separate Store instances. Never let
                -- a stale Home flush resurrect an older pending progress state
                -- after the Reader (or a detached worker) already verified a
                -- newer/equally-new sequence on disk.
                if disk_seq>memory_seq
                    or (disk_seq==memory_seq and disk_rank>memory_rank)
                    or (disk_seq==memory_seq and disk_rank==memory_rank and disk_stamp>memory_stamp) then
                    for _,field in ipairs(PROGRESS_SESSION_FIELDS) do
                        memory_row[field]=U.copy(disk_row[field])
                    end
                end
            elseif progress_session_sequence(disk_row)>0 then
                memory_sessions[id]=U.copy(disk_row)
            end
        end
    end
    return memory_sessions
end

function Store:flush()
    if not self.isolated then
        local disk_data=settings_file_data(self.settings_path)
        if type(disk_data)=="table" then
            self.db.data.sessions=merge_newer_progress_sessions(self.db.data.sessions,disk_data.sessions)
        end
    end
    local previous_path=self.settings_path..".previous"
    if not self.isolated then
        local valid=settings_file_valid(self.settings_path)
        if valid then U.copy_file(self.settings_path,previous_path) end
    end

    -- Serialize exactly like KOReader LuaSettings:flush(): dump() emits only a
    -- table expression, while a settings file must be a chunk that returns it.
    -- Validate the complete chunk in memory, atomically replace the target, and
    -- keep the last valid generation if anything fails.
    local payload
    local ok,err=xpcall(function()
        payload=settings_payload(self.db.data,self.settings_path)
        local valid_payload,parse_error=settings_payload_valid(payload)
        if not valid_payload then error("serialized settings invalid: "..tostring(parse_error)) end
        local written,write_error=U.atomic_write(self.settings_path,payload,true)
        if not written then error("atomic settings write failed: "..tostring(write_error)) end
    end,debug.traceback)
    if not ok then
        logger.err("[MiuRead][Store] settings flush failed; keeping previous settings",tostring(err))
        if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
        local disk_ok=settings_file_valid(self.settings_path)
        if disk_ok then self.db=LuaSettings:open(self.settings_path) end
        return false,err
    end

    local valid,reason=settings_file_valid(self.settings_path)
    if not valid then
        logger.warn("[MiuRead][Store] atomic settings flush produced invalid file","reason=",tostring(reason))
        if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
        local disk_ok=settings_file_valid(self.settings_path)
        if disk_ok then self.db=LuaSettings:open(self.settings_path) end
        return false,reason
    end
    if not self.isolated then
        local backed_up,backup_error=U.copy_file(self.settings_path,self.settings_backup_path)
        if not backed_up then
            logger.warn("[MiuRead][Store] settings backup refresh failed",tostring(backup_error or "unknown"))
        end
        os.remove(previous_path)
    end
    return true
end
function Store:reload()
    if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
    self.db = LuaSettings:open(self.settings_path)
    if not self.isolated then
        local valid=settings_file_valid(self.settings_path)
        if valid then U.copy_file(self.settings_path,self.settings_backup_path) end
    end
    return self
end
function Store:read_persisted(key)
    local data,err=settings_file_data(self.settings_path)
    if not data then return nil,err end
    return U.copy(data[key])
end
return Store
