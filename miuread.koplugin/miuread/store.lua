local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local Config=require("miuread.config")
local Json=require("miuread.json")
local DownloadDatabase=require("miuread.download_database")
local U=require("miuread.util")
local logger=require("logger")
local Store={}; Store.__index=Store
local function generate_login_session_id()
    return tostring(os.time()).."-"..tostring(math.random(100000,999999))
end
local defaults={
 schema=Config.SCHEMA,
 auth={login_session_id="",api_key="",cookies={},wr_ticket="",wr_wrpa="",ticket_updated_at=0,
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
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,download_notice_enabled=false,download_complete_notice=true,download_reader_warning=true,download_reader_policy="ask",download_dir="",shelf_section="account",account_shelf_kind="books",home_ui={enabled=true,layout_version=23,layout_style="desk",display_size="standard",ui_font_mode="default",ui_font_face="",local_root="",local_roots={},local_browse_version=2,local_library_mode="auto",local_auto_update=true,performance_defaults_version=1,auto_scan=true,local_check_on_open=true,page_by_section={},source_order={"account","generated","local","mp"},action_items={refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false},action_order={"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot"},action_layout_version=3,panel_items={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false},panel_order={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep","full_refresh"},panel_layout_version=2,more_expanded=false,network_metadata_defaults_version=2,network_metadata_user_set=false,network_metadata=true},reader_ui={enabled=true,plugin_mode_enabled=false,show_title=false,show_status=false,show_recent=false,recent_actions={},edge_guard_enabled=true,edge_guard_percent=10,quick_layout_version=11,quick_items={toc=true,progress=true,search=true,back=true,font=true,spacing=true,page=true,comments=true,bookmark=true,highlight=true,thought=true,sync=true},quick_order={"toc","progress","search","back","font","spacing","page","comments","bookmark","highlight","thought","sync"}},notices={reader_download=true,low_battery=true,low_storage=true,full_refresh=true,lockscreen=true,library_scan=true,repair_while_reading=true,mode_switch=true,mode_environment=true},mode_intro={pending_mode="desktop",pending_reason="first_install",last_confirmed_mode="",confirmed_at=0},memory_mode={enabled=false,previous_known=false,previous_ratio=false},performance_mode={enabled=false,auto_detect=true,last_prompt_at=0,reminders_disabled=false},time_display={mode="device",zone="Asia/Shanghai",offset_minutes=480},thoughts={enabled=true,font="standard",font_face="",follow_body_font=false,width_ratio=0.90,height_ratio=0.55,display_mode="native_compact_rounded"},annotation_sync={enabled=false,review_visibility="private",highlight_style=1,highlight_color=0},repair={auto_check=true},update={manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},sync={time_enabled=false,progress_enabled=true,success_notice_enabled=true,manual_only=false,auto_upload=false,pull_on_open=true,check_resume=false,require_verified=false,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300}},
 library={},sessions={},shelf_cache={books={},mp={},updated_at=0},cover_index={},cover_guard={active=false,started_at=0,stage="",version=""},update_state={},download_queue={},
 pending_installs={},last_cleanup_result={},read_report_consumed={},recent_reads={version=1,items={}},
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
local function invalidate_upload_health_table(auth)
    auth=U.merge(defaults.auth,auth or {})
    auth.health.notice_pending=false
    auth.health.last_error_channel=""
    if tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
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
local function settings_file_valid(path)
    if not path or lfs.attributes(path,"mode")~="file" then return false,"missing" end
    local size=U.file_size(path) or 0
    if size<=0 then return false,"empty" end
    local loader,err=loadfile(path)
    return loader~=nil,err
end

local function restore_settings_file(path,backup_path)
    if not path then return false end
    local exists=lfs.attributes(path,"mode")=="file"
    local valid,reason=settings_file_valid(path)
    if valid then return false end
    local candidates={path..".previous",backup_path,path..".old"}
    for _,candidate in ipairs(candidates) do
        local backup_ok=settings_file_valid(candidate)
        if backup_ok then
            local restored,restore_error=U.copy_file(candidate,path)
            if restored then
                logger.warn("[MiuRead][Store] damaged settings restored",
                    "source=",tostring(candidate),"reason=",tostring(reason))
                return true,candidate
            end
            logger.warn("[MiuRead][Store] settings restore failed",tostring(restore_error))
        end
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
    U.mkdir(data); U.mkdir(data.."/books"); U.mkdir(data.."/mp"); U.mkdir(data.."/covers"); U.mkdir(data.."/temp"); U.mkdir(data.."/updates")
    local settings_path=options.settings_path or (DataStorage:getSettingsDir().."/miuread.lua")
    local settings_backup_path=settings_path..".miuread-backup"
    if options.isolated~=true then restore_settings_file(settings_path,settings_backup_path) end
    local o=setmetatable({
        data_dir=data,
        cache_books_dir=data.."/books",
        mp_dir=data.."/mp",
        default_books_dir=public_documents_root(data),
        covers_dir=data.."/covers",
        temp_dir=data.."/temp",
        updates_dir=data.."/updates",
        settings_path=settings_path,
        settings_backup_path=settings_backup_path,
        legacy_download_state_path=data.."/download-state.json",
        download_database_path=DownloadDatabase.runtime_path(data),
        isolated=options.isolated==true,
    },self)
    o.db=LuaSettings:open(o.settings_path)
    for k,v in pairs(defaults) do if o.db:readSetting(k,nil)==nil then o.db:saveSetting(k,U.copy(v)) end end
    o:migrate()
    -- v1.1.45 intentionally disables automatic legacy EPUB relocation. File
    -- moves must never run during every reader/file-manager transition.
    o.db:flush()
    if not o.isolated then
        local valid=settings_file_valid(o.settings_path)
        if valid then refresh_settings_backup(o.settings_path,o.settings_backup_path) end
    end
    return o
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",1)) or 1
    if schema<Config.SCHEMA then
        local previous=self.db:readSetting("preferences",{}) or {}
        local p=U.merge(defaults.preferences,previous)
        if schema<10 then
            p.annotation_mode="all"
            p.show_annotations=true
            p.sync=p.sync or {}
            p.sync.manual_only=true
            p.sync.auto_upload=false
            p.sync.pull_on_open=false
            p.sync.check_resume=false
            p.sync.require_verified=false
        end
        if schema<11 and previous.download_keep_awake==nil then
            p.download_keep_awake=true
        end
        -- Schema 12 keeps private checkpoints/comments in koreader/miuread while
        -- final EPUB files default to the normal KOReader documents directory.
        if schema<13 then
            local sessions=self.db:readSetting("sessions",{}) or {}
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.report_context=nil
                    session.psvts=nil; session.pclts=nil; session.token=nil
                    session.reader_url=nil; session.context_updated_at=nil
                    session.last_path=nil; session.last_attempts=nil; session.last_stage=nil
                    session.last_response_summary=nil; session.last_http_code=nil
                    session.last_http_length=nil; session.last_payload_public=nil
                    session.last_error=nil; session.consecutive_failures=0
                    session.read_context_version=2
                end
            end
            self.db:saveSetting("sessions",sessions)
        end
        if schema<15 then
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_enabled==nil then p.sync.progress_enabled=true end
            p.sync.pull_on_open=p.sync.progress_enabled~=false
            p.sync.require_verified=false
            p.sync.manual_only=false
        end
        if schema<16 then
            -- Public builds use one fixed OTA manifest. Legacy channel/URL
            -- preferences are ignored and replaced by the repository address.
            p.update={manifest=Config.UPDATE_MANIFEST}
        end
        if schema<18 then
            -- Replace the legacy centered comment card with the compact
            -- bottom-sheet layout. These dimensions were never user-facing,
            -- so migrate existing installations instead of preserving the
            -- oversized saved values.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.42
        end
        if schema<19 then
            -- v1.0.6 treats the saved height as a maximum, not a fixed card
            -- height. Give the comments room to show several entries while
            -- allowing short content to shrink to its actual rendered size.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.60
        end
        if schema<20 then
            -- v1.0.7 uses a near-full-width comments sheet with compact outer
            -- and inner spacing. Migrate old saved dimensions so existing
            -- installations receive the same layout without clearing data.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.985
            p.thoughts.height_ratio=0.60
        end
        if schema<21 then
            -- v1.0.8 returns to a centered dialog and reallocates interior
            -- space to the selected text and comments instead of leaving
            -- large blank areas. Existing installs are migrated directly.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<22 then
            -- v1.0.9 removes MuPDF's internal page margins and sizes short
            -- comment dialogs from the actual rendered content height.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<23 then
            -- v1.0.10 combines the lighter card proportions with the denser
            -- comment list: slightly smaller dialog, balanced inner spacing,
            -- framed source quote and compact inline like counts.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.60
        end
        if schema<24 then
            -- v1.1.0 adds the combined local/cloud shelf, two-column cover
            -- view, compact list, local shelf search and single-scope filters.
            if previous.shelf_view==nil then p.shelf_view="grid" end
            if previous.shelf_scope==nil then
                local old=previous.shelf_filters or {}
                if old.downloaded then p.shelf_scope="downloaded"
                elseif old.reading then p.shelf_scope="reading"
                elseif old.finished then p.shelf_scope="finished"
                else p.shelf_scope="all" end
                p.shelf_filters={}
            end
            if previous.shelf_sort==nil then p.shelf_sort="read" end
        end
        if schema<25 then
            -- v1.1.1 removes the unstable custom two-column Menu layout and
            -- returns every device to the proven one-column compact shelf.
            p.shelf_view="compact"
        end
        if schema<26 then
            -- v1.1.25 adds a user-facing switch for the automatic reading-time
            -- status notice. Existing users keep the current visible behavior.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.time_notice_enabled==nil then
                p.sync.time_notice_enabled=true
            end
        end
        if schema<28 then
            -- v1.1.34 records only the short-lived shelf-cover render guard.
            -- If KOReader exits while a cover page is being built, the next
            -- launch can open the shelf once without covers and avoid a loop.
            self.db:saveSetting("cover_guard",U.copy(defaults.cover_guard))
        end
        if schema<29 then
            -- Reset position confirmation for the new two-way sync rule and
            -- neutralize old diagnostic labels kept in user settings.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local function neutral(value)
                if type(value)~="string" then return value end
                value=value:gsub("legacy_[%d%.]+_","compat_read_report_")
                value=value:gsub("[%d]+%.[%d]+%.[%d]+%s*原版","兼容")
                value=value:gsub("%s+"," ")
                return value
            end
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.remote_verified=false
                    session.verified_at=nil
                    session.verified_reason=nil
                    session.last_path=neutral(session.last_path)
                    session.last_stage=neutral(session.last_stage)
                    session.last_response_summary=neutral(session.last_response_summary)
                end
            end
            self.db:saveSetting("sessions",sessions)
        end

        if schema<30 then
            -- v1.1.36 keeps the cloud shelf order by default and separates
            -- progress-success notices from reading-time notices.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_notice_mode==nil then
                p.sync.progress_notice_mode="first"
            end
            if tostring(previous.shelf_sort or "read")=="read" then
                p.shelf_sort="cloud"
            end
        end

        if schema<31 then
            -- v1.1.37 simplifies the menus and persists the single-download queue.
            -- Existing download/image preferences are retained internally for
            -- compatibility, but they are no longer exposed as routine toggles.
            self.db:saveSetting("download_queue", self.db:readSetting("download_queue", {}) or {})
        end
        if schema<32 then
            -- v1.1.38 separates the current account shelf from EPUB files
            -- generated by MiuRead. The old mixed shelf settings are kept only
            -- as migration input so local files can no longer disturb the
            -- account shelf's default ordering.
            p.shelf_section=tostring(previous.shelf_section or "account")
            if p.shelf_section~="generated" then p.shelf_section="account" end
            p.account_shelf_kind=tostring(previous.account_shelf_kind or "books")
            if p.account_shelf_kind~="mp" then p.account_shelf_kind="books" end
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or "cloud")
            local account_sort_map={cloud="default",default="default",read="read",update="update",progress="progress",title="title",author="author"}
            p.account_shelf_sort=account_sort_map[old_sort] or "default"
            local old_scope=tostring(previous.account_shelf_scope or previous.shelf_scope or "all")
            local account_scope_map={all="all",downloaded="generated",generated="generated",ungenerated="ungenerated",top="top",archive="archive"}
            p.account_shelf_scope=account_scope_map[old_scope] or "all"
            p.generated_shelf_sort=tostring(previous.generated_shelf_sort or "opened")
            if not ({opened=true,generated=true,title=true,author=true,size=true})[p.generated_shelf_sort] then p.generated_shelf_sort="opened" end
            p.generated_shelf_scope=tostring(previous.generated_shelf_scope or "all")
            if not ({all=true,in_account=true,removed=true,clean=true,notes=true})[p.generated_shelf_scope] then p.generated_shelf_scope="all" end
        end
        if schema<33 then
            -- v1.1.39 restores the shelf ordering that most closely matches
            -- the mobile client: cloud readUpdateTime descending. Old labels
            -- such as default/cloud represented interface-array order and are
            -- migrated automatically; explicit user choices are preserved.
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or p.account_shelf_sort or "read")
            local account_sort_map={
                cloud="read",default="read",cloud_order="read",interface="read",read="read",
                update="update",progress="progress",title="title",author="author",
            }
            p.account_shelf_sort=account_sort_map[old_sort] or "read"
            p.shelf_sort="read"
        end
        if schema<36 then
            -- Rebuild the small pending-install index once. This replaces the
            -- old full-library scan on every document close.
            local pending={}
            local library=self.db:readSetting("library",{}) or {}
            local function add_pending(book_id,kind,chapter_uid,record)
                if type(record)~="table" or record.pending_install~=true
                    or tostring(record.pending_file or "")=="" then return end
                local key=table.concat({tostring(book_id),tostring(chapter_uid or "full"),tostring(kind or "")},":")
                pending[#pending+1]={key=key,book_id=tostring(book_id),kind=tostring(kind or ""),
                    chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record.file,
                    pending_file=record.pending_file,created_at=tonumber(record.downloaded_at) or os.time()}
            end
            for book_id,book in pairs(library) do
                for kind,record in pairs(book.variants or {}) do add_pending(book_id,kind,nil,record) end
                for uid,row in pairs(book.chapters or {}) do
                    for kind,record in pairs(row or {}) do add_pending(book_id,kind,uid,record) end
                end
            end
            self.db:saveSetting("pending_installs",pending)
            self.db:saveSetting("last_cleanup_result",{})
        end
        if schema<37 then
            -- Add a non-destructive access state to existing generated books.
            -- Old files remain readable until their first explicit verification;
            -- no migration-time file move or lock is performed.
            local library=self.db:readSetting("library",{}) or {}
            for _,book in pairs(library) do
                if type(book)=="table" and type(book.access)~="table" then
                    book.access={
                        ownership="unknown",access_scope="unknown",status="unverified",
                        verified_at=0,valid_until=0,shelf_present=nil,
                    }
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<39 then
            -- beta.2 replaces the old five-day absolute deadlines with the
            -- current beta policy. Old EPUB metadata must not restore those
            -- deadlines after the library has migrated.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 10*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 2
            local function migrate_record(record,access)
                if type(record)~="table" then return end
                record.access_policy_version=policy
                record.ownership=record.ownership or access.ownership
                record.verified_at=tonumber(record.verified_at) or tonumber(access.verified_at) or 0
                if access.ownership=="purchased" or access.ownership=="personal_upload" then
                    record.valid_until=0
                else
                    record.valid_until=tonumber(access.valid_until) or 0
                end
            end
            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {
                        ownership="unknown",access_scope="unknown",status="unverified",
                        verified_at=0,valid_until=0,shelf_present=nil,
                    }
                    local ownership=tostring(access.ownership or "unknown")
                    local verified=tonumber(access.verified_at) or 0
                    access.policy_version=policy
                    if ownership=="purchased" or ownership=="personal_upload" then
                        access.valid_until=0
                        access.status="allowed"
                        access.lock_reason=""
                    else
                        local deadline=verified>0 and (verified+ttl) or 0
                        access.valid_until=deadline>now and deadline or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access
                    for _,record in pairs(book.variants or {}) do migrate_record(record,access) end
                    for _,row in pairs(book.chapters or {}) do
                        for _,record in pairs(row or {}) do migrate_record(record,access) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<40 then
            -- beta.3 removes developer-only controls and reapplies the current
            -- access policy without rewriting EPUB or reader sidecar files.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            p.download_notice_enabled=false
            p.sync=p.sync or {}
            p.sync.time_notice_enabled=false
            p.sync.progress_notice_mode="off"
            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 10*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 3
            local function apply_record(record,access)
                if type(record)~="table" then return end
                record.access_policy_version=policy
                record.ownership=access.ownership
                record.verified_at=tonumber(access.verified_at) or 0
                record.valid_until=tonumber(access.valid_until) or 0
            end
            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {}
                    access.policy_version=policy
                    local ownership=tostring(access.ownership or "unknown")
                    if ownership=="purchased" or ownership=="personal_upload" then
                        access.status="allowed"; access.valid_until=0; access.lock_reason=""
                    else
                        local verified=tonumber(access.verified_at) or 0
                        local deadline=verified>0 and verified+ttl or 0
                        access.valid_until=deadline>now and deadline or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access
                    for _,record in pairs(book.variants or {}) do apply_record(record,access) end
                    for _,row in pairs(book.chapters or {}) do
                        for _,record in pairs(row or {}) do apply_record(record,access) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<42 then
            -- 2.0.0-beta.1 removes obsolete shelf sort/filter settings and repairs
            -- access data written by 1.1.49-beta.1. Permanent rights are restored
            -- from surviving book or file records; temporary books keep their
            -- files and are rechecked only when needed.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            p.shelf_sort=nil
            p.shelf_scope=nil
            p.shelf_view=nil
            p.shelf_filters=nil
            p.account_shelf_sort=nil
            p.account_shelf_scope=nil
            p.generated_shelf_sort=nil
            p.generated_shelf_scope=nil

            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 3*24*60*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 5
            local lock_suffix=".miuread-locked"

            local function permanent_kind(book)
                local access=type(book.access)=="table" and book.access or {}
                local own=tostring(access.ownership or "")
                if own=="purchased" or own=="personal_upload" then return own end
                local found
                local function scan(record)
                    if found or type(record)~="table" then return end
                    local value=tostring(record.ownership or record.access_ownership or "")
                    if value=="purchased" or value=="personal_upload" then found=value end
                end
                for _,record in pairs(book.variants or {}) do scan(record) end
                for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do scan(record) end end
                return found
            end

            local function record_scope(kind,record)
                local scope=tostring(record and record.access_scope or "")
                if scope=="preview" or scope=="full" then return scope end
                return tostring(kind or ""):sub(1,8)=="preview_" and "preview" or "full"
            end

            local function unlock_record(record)
                if type(record)~="table" then return end
                local path=tostring(record.file or "")
                local target=tostring(record.original_file or path:gsub("%.miuread%-locked$", ""))
                if path:sub(-#lock_suffix)==lock_suffix and target~="" then
                    if U.file_exists(target) then
                        record.file=target
                        if path~=target and U.file_exists(path) then os.remove(path) end
                    elseif U.file_exists(path) then
                        local ok=os.rename(path,target)
                        if ok then record.file=target end
                    end
                end
                record.locked=nil
                record.lock_reason=nil
                record.locked_at=nil
                record.original_file=nil
                record.access_status="allowed"
            end

            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {}
                    local permanent=permanent_kind(book)
                    access.policy_version=policy
                    access.stale=nil
                    if permanent then
                        access.ownership=permanent
                        access.status="allowed"
                        access.access_scope="full"
                        access.valid_until=0
                        access.lock_reason=""
                    else
                        if tostring(access.ownership or "")=="purchased" or tostring(access.ownership or "")=="personal_upload" then
                            -- A permanent marker without surviving file evidence is
                            -- still preserved; this path mostly covers old clean installs.
                        elseif tostring(access.ownership_source or "")=="official_shelf_policy" then
                            access.ownership="temporary"
                            access.ownership_source="migration_from_1.1.49"
                        elseif tostring(access.ownership or "")=="" then
                            access.ownership="unknown"
                        end
                        local verified=tonumber(access.verified_at) or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            local deadline=verified>0 and verified+ttl or 0
                            access.valid_until=deadline>now and deadline or 0
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access

                    local function migrate_record(kind,record)
                        if type(record)~="table" then return end
                        record.access_policy_version=policy
                        record.access_scope=record_scope(kind,record)
                        if permanent then
                            record.ownership=permanent
                            record.valid_until=0
                            unlock_record(record)
                        else
                            record.ownership=record.ownership or access.ownership
                            local path=tostring(record.file or "")
                            if path:sub(-#lock_suffix)==lock_suffix then record.locked=true end
                            if record.locked==true then
                                record.access_status="blocked"
                            elseif access.status=="allowed" then
                                record.access_status="allowed"
                            end
                        end
                    end
                    for kind,record in pairs(book.variants or {}) do migrate_record(kind,record) end
                    for _,row in pairs(book.chapters or {}) do
                        for kind,record in pairs(row or {}) do migrate_record(kind,record) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<43 then
            -- 2.0.0-beta.2 removes local reading-rights validation completely.
            -- Restore every file renamed by earlier beta builds and discard all
            -- access/expiry/lock fields. Download, login and sync remain online
            -- features, but existing EPUB files are ordinary local documents.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            local library=self.db:readSetting("library",{}) or {}
            local suffix=".miuread-locked"

            local function clear_record(record)
                if type(record)~="table" then return end
                local path=tostring(record.file or "")
                local target=tostring(record.original_file or "")
                if target=="" and path:sub(-#suffix)==suffix then
                    target=path:sub(1,#path-#suffix)
                end
                if target~="" and path~="" and path~=target then
                    if U.file_exists(target) then
                        if U.file_exists(path) and path:sub(-#suffix)==suffix then os.remove(path) end
                        record.file=target
                    elseif U.file_exists(path) then
                        local ok=os.rename(path,target)
                        if ok then record.file=target end
                    end
                end
                record.locked=nil; record.lock_reason=nil; record.locked_at=nil; record.original_file=nil
                record.access_status=nil; record.access_policy_version=nil
                record.ownership=nil; record.ownership_source=nil
                record.access_ownership=nil; record.access_ownership_source=nil
                record.account_vid=nil; record.verified_at=nil; record.valid_until=nil
                record.last_access_check=nil
            end

            for _,book in pairs(library) do
                if type(book)=="table" then
                    book.access=nil
                    for _,record in pairs(book.variants or {}) do clear_record(record) end
                    for _,row in pairs(book.chapters or {}) do
                        for _,record in pairs(row or {}) do clear_record(record) end
                    end
                end
            end

            -- Recover orphaned locked EPUB files even when an old record was lost.
            local roots={}
            local chosen=U.trim(tostring(p.download_dir or ""))
            roots[#roots+1]=chosen~="" and chosen or self.default_books_dir
            roots[#roots+1]=self.cache_books_dir
            local seen={}
            for _,root in ipairs(roots) do
                if root and root~="" and not seen[root] then
                    seen[root]=true
                    for _,path in ipairs(U.list(root)) do
                        if tostring(path):sub(-#suffix)==suffix and U.file_exists(path) then
                            local target=tostring(path):sub(1,#path-#suffix)
                            if U.file_exists(target) then os.remove(path) else os.rename(path,target) end
                        end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<44 then
            -- 2.0.0-beta.3 restores the WeRead app shelf order. beta.2 cached
            -- the raw API array order, so discard that cache once and remove
            -- obsolete user-sort fields before the next shelf load.
            p.shelf_sort=nil; p.shelf_scope=nil; p.shelf_filters=nil
            p.account_shelf_sort=nil; p.account_shelf_scope=nil
            p.generated_shelf_sort=nil; p.generated_shelf_scope=nil
            self.db:saveSetting("shelf_cache",U.copy(defaults.shelf_cache))
        end
        if schema<45 then
            -- 2.0.0-beta.5 stores public-account lists and articles outside the
            -- global settings file. Existing books, checkpoints and EPUB files
            -- are intentionally left untouched.
            local auth=self.db:readSetting("auth",{}) or {}
            if auth.wr_ticket==nil then auth.wr_ticket="" end
            if auth.wr_wrpa==nil then auth.wr_wrpa="" end
            if auth.ticket_updated_at==nil then auth.ticket_updated_at=0 end
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))
        end
        if schema<48 then
            -- 2.0.0-beta.5.8 replaces the old browser-authorized public-account
            -- implementation with QR-login + MP_WXS article reading. Existing
            -- article HTML caches remain on disk, but obsolete collection records
            -- and queued collection downloads are detached so they cannot return.
            local auth=self.db:readSetting("auth",{}) or {}
            auth.mp_cookie_header=nil
            auth.mp_extra_headers=nil
            auth.mp_referer=nil
            auth.mp_auth_source=nil
            auth.mp_authorized_at=nil
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))

            local function is_mp_id(id)
                id=tostring(id or "")
                return id:sub(1,7)=="MP_WXS_" or id:lower()=="mpbook"
            end

            local library=self.db:readSetting("library",{}) or {}
            local sessions=self.db:readSetting("sessions",{}) or {}
            local library_changed,sessions_changed=false,false
            for id,row in pairs(library) do
                if is_mp_id(id) or (type(row)=="table" and tostring(row.content_type or "")=="mp_collection") then
                    library[id]=nil
                    library_changed=true
                    if sessions[tostring(id)]~=nil then sessions[tostring(id)]=nil; sessions_changed=true end
                end
            end
            if library_changed then self.db:saveSetting("library",library) end
            if sessions_changed then self.db:saveSetting("sessions",sessions) end

            local kept_queue={}
            for _,job in ipairs(self.db:readSetting("download_queue",{}) or {}) do
                local book=type(job.book)=="table" and job.book or {}
                local options=type(job.options)=="table" and job.options or {}
                local id=book.bookId or book.book_id
                local obsolete=is_mp_id(id) or options.mp_collection==true
                    or tostring(options.content_type or "")=="mp_collection"
                    or tostring(book.content_type or "")=="mp_collection"
                if not obsolete then kept_queue[#kept_queue+1]=job end
            end
            self.db:saveSetting("download_queue",kept_queue)

            local shelf=self.db:readSetting("shelf_cache",{}) or {}
            shelf.mp={}
            self.db:saveSetting("shelf_cache",U.merge(defaults.shelf_cache,shelf))

            local state=self:download_state()
            local state_book=type(state.book)=="table" and state.book or {}
            local state_options=type(state.options)=="table" and state.options or {}
            if is_mp_id(state.book_id or state_book.bookId or state_book.book_id)
                or state_options.mp_collection==true
                or tostring(state_options.content_type or "")=="mp_collection" then
                self:clear_download_state()
            end
        end
        if schema<50 then
            -- beta.6.1 removes beta.6.0's persistent external-EPUB negative cache.
            -- A temporary identification failure must not hide an existing book.
            self.db:saveSetting("external_epub_cache",{})
        end
        if schema<51 then
            -- beta.6.4 gives comments their own fixed font by default. Following
            -- the current book font remains optional because resolving and
            -- embedding a changing book font can delay older devices.
            p.thoughts=p.thoughts or {}
            if p.thoughts.follow_body_font==nil then p.thoughts.follow_body_font=false end
            if p.thoughts.font_face==nil then p.thoughts.font_face="" end
        end
        if schema<52 then
            -- beta.6.5 separates locally saved credentials from the server-side
            -- health of each feature. Existing logins start as unknown and are
            -- verified by the next real request instead of being shown as fully
            -- healthy merely because cookies still exist on disk.
            local auth=self.db:readSetting("auth",{}) or {}
            auth.health=U.merge(defaults.auth.health,auth.health or {})
            local has_local=tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil
            if not has_local then auth.health.state="logged_out" end
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))
        end
        if schema<53 then
            -- beta.6.6 adds a shared request-cooldown file and automatic worker
            -- restart. No user preference changes are required; old download
            -- checkpoints remain compatible and are reused in place.
        end
        if schema<54 then
            -- 2.3 adds passive automatic update checks. Checks only run while
            -- KOReader is already open and online, so they never wake Wi-Fi.
            p.update=U.merge(defaults.preferences.update,p.update or {})
            p.update.manifest=Config.UPDATE_MANIFEST
            if p.update.auto_check==nil then p.update.auto_check=true end
            if not tonumber(p.update.interval) or tonumber(p.update.interval)<21600 then
                p.update.interval=Config.AUTO_UPDATE_INTERVAL
            end
            p.update.last_attempt_at=tonumber(p.update.last_attempt_at) or 0
            p.update.last_success_at=tonumber(p.update.last_success_at) or 0
            p.update.last_prompted_version=tostring(p.update.last_prompted_version or "")
            if p.update.restart_mode~="auto" and p.update.restart_mode~="never" then
                p.update.restart_mode="ask"
            end
        end
        if schema<55 then
            -- 2.3.1 keeps account and critical status text in the main label,
            -- auto-clears obsolete completed download records, and enables
            -- reusable checkpoints for an expanding chapter-range EPUB.
        end
        if schema<56 then
            -- 2.3.2 removes renewal as a feature gate. Old `expired`/`degraded`
            -- rows may have been created by a transient renewal or HTTP 403, so
            -- logged-in accounts return to per-feature real-request validation.
            local auth=self.db:readSetting("auth",{}) or {}
            auth.health=U.merge(defaults.auth.health,auth.health or {})
            local has_local=tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil
            auth.health.notice_pending=false
            auth.health.last_error_channel=""
            if has_local then
                auth.health.state="unknown"
                for _,channel in ipairs({"shelf","progress","download","annotations","read_report"}) do
                    local previous_row=(auth.health.channels or {})[channel] or {}
                    auth.health.channels[channel]={
                        state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                        last_ok_at=tonumber(previous_row.last_ok_at or 0) or 0,
                    }
                end
            else
                auth.health.state="logged_out"
            end
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))

            local download_state=self.db:readSetting("download_state",{}) or {}
            if download_state.status=="failed" and download_state.auth_required==true then
                download_state.status="interrupted"
                download_state.auth_required=nil
                download_state.error_kind=nil
                download_state.error="登录状态将在继续下载时通过真实请求重新验证；原下载断点已保留。"
                download_state.updated_at=os.time()
                self.db:saveSetting("download_state",download_state)
            end
        end
        if schema<57 then
            -- Clear reporting contexts introduced by the 2.3 series. They may
            -- contain a stale chapter/context after QR login and cause both
            -- progress and reading-time uploads to be rejected indefinitely.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local cleaned,changed=invalidate_report_contexts_table(sessions)
            if changed>0 then self.db:saveSetting("sessions",cleaned) end
            local auth=invalidate_upload_health_table(self.db:readSetting("auth",{}) or {})
            self.db:saveSetting("auth",auth)
        end
        if schema<59 then
            -- 2.3.3 keeps all account, local-book, checkpoint, annotation and
            -- pending reading-time data, but discards protocol contexts that
            -- may combine a local snapshot with a different reader-page state.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local cleaned,changed=invalidate_report_contexts_table(sessions)
            for _,session in pairs(cleaned) do
                if type(session)=="table" then
                    if session.progress_sync_state=="mapping_pending"
                        or session.progress_sync_state=="uploading" then
                        session.progress_sync_state=nil; changed=changed+1
                    end
                    session.pending_report_seconds=math.max(0,math.floor(tonumber(session.pending_report_seconds) or 0))
                end
            end
            if changed>0 then self.db:saveSetting("sessions",cleaned) end
            self.db:saveSetting("auth",invalidate_upload_health_table(self.db:readSetting("auth",{}) or {}))
        end
        if schema<60 then
            -- 2.3.4 restores one simple success-notice switch and removes
            -- accumulated reading-time catch-up. Old pending seconds are
            -- intentionally discarded so an upgrade can never submit a long
            -- reading-time batch.
            p.sync=p.sync or {}
            p.sync.success_notice_enabled=true
            p.sync.time_notice_enabled=nil
            p.sync.progress_notice_mode=nil
            local sessions=self.db:readSetting("sessions",{}) or {}
            local changed=false
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    if tonumber(session.pending_report_seconds or 0)~=0 then changed=true end
                    session.pending_report_seconds=0
                end
            end
            if changed then self.db:saveSetting("sessions",sessions) end
        end
        if schema<61 then
            -- 3.0.0-beta.2 separates正文下载 from划线与想法 access so a
            -- successful EPUB no longer hides a persistent annotation HTTP 403.
            local auth=self.db:readSetting("auth",{}) or {}
            auth.health=U.merge(defaults.auth.health,auth.health or {})
            auth.health.channels=auth.health.channels or {}
            local previous=auth.health.channels.annotations or {}
            auth.health.channels.annotations={
                state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                last_ok_at=tonumber(previous.last_ok_at or 0) or 0,
            }
            if tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
                local partial=false
                for _,channel in ipairs({"shelf","progress","download","annotations","read_report"}) do
                    local state=tostring(((auth.health.channels or {})[channel] or {}).state or "unknown")
                    if state=="error" or state=="expired" then partial=true; break end
                end
                auth.health.state=partial and "partial" or "unknown"
            else
                auth.health.state="logged_out"
            end
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))
        end
        if schema<64 then
            -- 3.1.0-beta.3 promotes the MiuRead bookshelf from an optional
            -- preview to the default file-manager home. Keep one migration flag
            -- so a later user choice to disable it is respected.
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.enabled=true
            p.home_ui.layout_version=2
            if p.home_ui.auto_scan==nil then p.home_ui.auto_scan=true end
        end
        if schema<65 then
            -- 3.1.0-beta.4 adds the configurable home widget layout and quick center.
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=3
            if p.home_ui.widgets==nil then p.home_ui.widgets=false end
            if p.home_ui.preset==nil then p.home_ui.preset="balanced" end
            if p.home_ui.goal_minutes==nil then p.home_ui.goal_minutes=30 end
            if p.home_ui.swipe_quick==nil then p.home_ui.swipe_quick=false end
        end
        if schema<67 then
            -- 3.2.0-beta.1 replaces the multi-page widget home with a fixed
            -- reading desk. Old widget choices are intentionally discarded.
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=7
            p.home_ui.layout_style="desk"
            if p.home_ui.auto_scan==nil then p.home_ui.auto_scan=true end
            p.home_ui.widgets=nil
            p.home_ui.preset=nil
            p.home_ui.goal_minutes=nil
            p.home_ui.swipe_quick=nil
            p.home_ui.initial_page=nil
        end
        if schema<69 then
            -- 3.2.0-beta.15 moves comments to a lightweight native viewer,
            -- adds the shared book-repair channel, and removes MiuRead's
            -- fullscreen swipe interception from the home page.
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=15
            p.home_ui.layout_style=p.home_ui.layout_style=="compact" and "compact" or "desk"
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            if p.thoughts.display_mode~="native_simple" and p.thoughts.display_mode~="legacy_rich" then
                p.thoughts.display_mode="native_card"
            end
            p.thoughts.height_ratio=math.max(0.52,tonumber(p.thoughts.height_ratio) or 0.70)
            p.repair=type(p.repair)=="table" and p.repair or {}
            if p.repair.auto_check==nil then p.repair.auto_check=true end
        end
        if schema<70 then
            -- beta.20 replaces the three comment display modes with one fixed-source,
            -- paged comment card and exposes its font controls from the reader.
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="unified"
            p.thoughts.width_ratio=math.max(0.88,math.min(0.94,tonumber(p.thoughts.width_ratio) or 0.92))
            p.thoughts.height_ratio=math.max(0.58,math.min(0.80,tonumber(p.thoughts.height_ratio) or 0.72))
        end
        if schema<71 then
            -- beta.21 removed beta.20's manual page splitting; beta.22
            -- migrates this preference again to the native list renderer.
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_list"
            p.thoughts.comments_per_page=nil
            p.thoughts.width_ratio=math.max(0.88,math.min(0.94,tonumber(p.thoughts.width_ratio) or 0.92))
            p.thoughts.height_ratio=math.max(0.56,math.min(0.76,tonumber(p.thoughts.height_ratio) or 0.72))
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=17
        end
        self.db:saveSetting("preferences",p)
        if schema<72 then
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_list"
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=17
            p.home_ui.page_by_section=type(p.home_ui.page_by_section)=="table" and p.home_ui.page_by_section or {}
            self:save_preferences(p)
        end
        if schema<73 then
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_paged"
            p.thoughts.height_ratio=math.max(0.66,math.min(0.82,tonumber(p.thoughts.height_ratio) or 0.76))
            self:save_preferences(p)
        end
        if schema<74 then
            -- beta.25 restores the compact v3.0.2 visual hierarchy while
            -- keeping the safer native renderer. Saved paged-card dimensions
            -- are intentionally replaced because they produced the oversized
            -- dialog and visible footer that this migration removes.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_classic"
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.60
            p.thoughts.comments_per_page=nil
            self:save_preferences(p)
        end
        if schema<75 then
            -- beta.27 switches comments to a small-font, click-paged native list,
            -- adds a configurable quick panel, and limits waiting downloads to one.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_click_paged"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.66
            p.download_reader_warning=p.download_reader_warning~=false
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=19
            self:save_preferences(p)
            local queue=self.db:readSetting("download_queue",{}) or {}
            if #queue>1 then self.db:saveSetting("download_queue",{queue[1]}) end
        end
        if schema<76 then
            -- beta.28 replaces beta.27's unsafe comment layout with a guarded
            -- small-font pager and resets the saved popup dimensions.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_safe_paged"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.66
            self:save_preferences(p)
        end
        if schema<77 then
            -- beta.29 uses a borderless adaptive-height comment pager. Text is
            -- measured before pagination so short and long comments fill pages naturally.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_adaptive_paged"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.72
            self:save_preferences(p)
        end
        if schema<78 then
            -- beta.30 keeps one stable opaque rounded frame across comment pages.
            -- This clears the previous page inside the popup region and avoids
            -- overlapping text without triggering a full-screen refresh.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_rounded_paged"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.72
            self:save_preferences(p)
        end
        if schema<79 then
            -- beta.31 separates the fixed rounded frame from the opaque comment
            -- page surface. Page turns refresh only the inner content region,
            -- while short final pages still clear every previous text pixel.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_rounded_layered"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.72
            self:save_preferences(p)
        end
        if schema<81 then
            -- beta.33 caps comments at roughly half the screen, fills long
            -- pages by splitting oversized comments into the remaining space,
            -- and replaces the boxed shelf badges with lighter status text.
            local p=self:preferences()
            p.thoughts=type(p.thoughts)=="table" and p.thoughts or {}
            p.thoughts.display_mode="native_compact_rounded"
            p.thoughts.font="standard"
            p.thoughts.follow_body_font=false
            p.thoughts.width_ratio=0.90
            p.thoughts.height_ratio=0.55
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=20
            self:save_preferences(p)
        end
        if schema<82 then
            -- beta.37 separates desktop and plugin operation, restores the native
            -- bottom typesetting panel, adds a configurable reader control panel,
            -- centralizes notices, and hard-limits downloads to one active job plus
            -- one waiting job. Existing account, book, annotation and sync data stay.
            local p=self:preferences()
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=21
            p.home_ui.quick_items=type(p.home_ui.quick_items)=="table" and p.home_ui.quick_items or {}
            p.home_ui.quick_items.sync=true
            p.home_ui.quick_items.downloads=true
            p.home_ui.quick_items.restart=false
            p.home_ui.quick_items.quit=false
            p.reader_ui=type(p.reader_ui)=="table" and p.reader_ui or {}
            if p.reader_ui.enabled==nil then p.reader_ui.enabled=true end
            if p.reader_ui.plugin_mode_enabled==nil then p.reader_ui.plugin_mode_enabled=false end
            if p.reader_ui.show_title==nil then p.reader_ui.show_title=true end
            if p.reader_ui.show_status==nil then p.reader_ui.show_status=true end
            p.reader_ui.quick_items=type(p.reader_ui.quick_items)=="table" and p.reader_ui.quick_items or {}
            local reader_defaults={home=true,toc=true,progress=true,font=true,typeset=true,sync=true,current_book=true,downloads=false,full_refresh=false,koreader_menu=false,sleep=false,more=true}
            for key,value in pairs(reader_defaults) do
                if p.reader_ui.quick_items[key]==nil then p.reader_ui.quick_items[key]=value end
            end
            if type(p.reader_ui.quick_order)~="table" then
                p.reader_ui.quick_order={"home","toc","progress","font","typeset","sync","current_book","downloads","full_refresh","koreader_menu","sleep","more"}
            end
            p.notices=type(p.notices)=="table" and p.notices or {}
            for _,key in ipairs({"reader_download","low_battery","low_storage","full_refresh","lockscreen","library_scan","repair_while_reading","mode_switch"}) do
                if p.notices[key]==nil then p.notices[key]=true end
            end
            if p.download_reader_policy~="allow" and p.download_reader_policy~="after_reading" then
                p.download_reader_policy="ask"
            end
            self:save_preferences(p)
            local queue=self.db:readSetting("download_queue",{}) or {}
            local kept,seen={},{}
            for _,job in ipairs(queue) do
                local book=type(job)=="table" and type(job.book)=="table" and job.book or {}
                local id=tostring(book.bookId or book.book_id or "")
                if #kept<1 and (id=="" or not seen[id]) then
                    kept[#kept+1]=job
                    if id~="" then seen[id]=true end
                end
            end
            self.db:saveSetting("download_queue",kept)
        end
        if schema<84 then
            -- 3.5 separates the six always-visible homepage actions from the
            -- pull-down device/KOReader controls. Existing books, downloads,
            -- comments, reading positions and account data remain unchanged.
            local p=self:preferences()
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            p.home_ui.layout_version=22
            p.home_ui.action_items={refresh=true,search=true,downloads=true,sync=true,frontlight=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
            p.home_ui.action_order={"refresh","search","downloads","sync","frontlight","miuread_settings","all_books","history","file_manager","screenshot"}
            p.home_ui.action_layout_version=1
            p.home_ui.panel_items={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
            p.home_ui.panel_order={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
            p.home_ui.panel_layout_version=1
            p.home_ui.more_expanded=false
            p.home_ui.quick_items=nil
            p.home_ui.quick_order=nil
            self:save_preferences(p)
        end
        if schema<85 then
            -- Keep network metadata enrichment opt-in at the feature level but
            -- enabled by default for the recent-reading card. Results are
            -- cached and never block the initial home render.
            local p=self:preferences()
            p.home_ui=type(p.home_ui)=="table" and p.home_ui or {}
            if p.home_ui.network_metadata==nil then p.home_ui.network_metadata=true end
            p.home_ui.more_expanded=false
            self:save_preferences(p)
        end
        if schema<88 then
            -- beta.9 replaces the reader's default shortcut layout with the
            -- self-contained MiuRead control center. Existing user-customized
            -- layouts remain readable and are migrated again in main.lua.
            local p=self:preferences()
            p.reader_ui=type(p.reader_ui)=="table" and p.reader_ui or {}
            if p.reader_ui.show_recent==nil then p.reader_ui.show_recent=true end
            p.reader_ui.recent_actions=type(p.reader_ui.recent_actions)=="table" and p.reader_ui.recent_actions or {}
            -- Shortcut migration is completed in main.lua where the plugin can
            -- distinguish an old recommended layout from a real customization.
            self:save_preferences(p)
        end
        if schema<90 then
            -- beta.15 separates durable book identity from one QR-login session.
            -- Old EPUBs, chapter maps, local positions and annotations stay intact;
            -- only account-bound upload contexts are discarded and rebuilt lazily.
            local auth=U.merge(defaults.auth,self.db:readSetting("auth",{}) or {})
            local account=type(auth.account)=="table" and auth.account or {}
            if tostring(auth.login_session_id or "")==""
                and tostring(account.vid or "")~=""
                and tostring(auth.api_key or "")~=""
                and next(auth.cookies or {})~=nil then
                auth.login_session_id=generate_login_session_id()
            end
            self.db:saveSetting("auth",invalidate_upload_health_table(auth))
            local sessions=self.db:readSetting("sessions",{}) or {}
            local cleaned,changed=invalidate_report_contexts_table(sessions)
            if changed>0 then self.db:saveSetting("sessions",cleaned) end
        end
        if schema<93 then
            -- 4.0.0-beta.10 separates local books into automatic indexing,
            -- manual indexing and zero-index folder browsing. Preserve an
            -- existing recursive index by migrating it to manual mode; new
            -- installs stay in the safest direct browsing mode.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local previous_home=type(previous.home_ui)=="table" and previous.home_ui or {}
            if previous_home.local_library_mode==nil then
                local legacy=self.db:readSetting("home_local_index",{}) or {}
                local had_index=type(legacy)=="table" and type(legacy.books)=="table" and #legacy.books>0
                current.home_ui.local_library_mode=had_index and "manual" or "direct"
            end
            local mode=tostring(current.home_ui.local_library_mode or "direct")
            if mode~="auto" and mode~="manual" and mode~="direct" then mode="direct" end
            current.home_ui.local_library_mode=mode
            current.home_ui.auto_scan=mode=="auto"
            self:save_preferences(current)
        end
        if schema<97 then
            -- 4.2.0-beta.6 keeps memory protection separate from lightweight
            -- performance protection. Existing installs stay in standard mode;
            -- latency detection is enabled without changing device behavior.
            local current=self:preferences()
            current.performance_mode=type(current.performance_mode)=="table" and current.performance_mode or {}
            if current.performance_mode.enabled==nil then current.performance_mode.enabled=false end
            if current.performance_mode.auto_detect==nil then current.performance_mode.auto_detect=true end
            current.performance_mode.last_prompt_at=tonumber(current.performance_mode.last_prompt_at or 0) or 0
            current.performance_mode.reminders_disabled=current.performance_mode.reminders_disabled==true
            self:save_preferences(current)
        end
        if schema<98 then
            -- 4.2.0-beta.8 makes plugin mode a true non-desktop mode. Legacy
            -- reader-panel overrides are disabled and mode-environment advice
            -- starts with a clean acknowledgement set.
            local current=self:preferences()
            current.reader_ui=type(current.reader_ui)=="table" and current.reader_ui or {}
            current.reader_ui.plugin_mode_enabled=false
            current.notices=type(current.notices)=="table" and current.notices or {}
            if current.notices.mode_environment==nil then current.notices.mode_environment=true end
            current.mode_guard=type(current.mode_guard)=="table" and current.mode_guard or {}
            current.mode_guard.acknowledged={}
            self:save_preferences(current)
        end
        if schema<99 then
            -- 4.2.0-beta.9 fixes the desktop reader surface to a stable six-item
            -- layout and adds a persistent switch for comment interaction.
            local current=self:preferences()
            current.reader_ui=type(current.reader_ui)=="table" and current.reader_ui or {}
            current.reader_ui.show_recent=false
            current.reader_ui.recent_actions={}
            current.reader_ui.quick_layout_version=8
            current.reader_ui.quick_items={home=true,toc=true,progress=true,font=true,comments=true,more=true}
            current.reader_ui.quick_order={"home","toc","progress","font","comments","more"}
            current.thoughts=type(current.thoughts)=="table" and current.thoughts or {}
            if current.thoughts.enabled==nil then current.thoughts.enabled=true end
            self:save_preferences(current)
        end
        if schema<100 then
            -- 4.2.0-beta.10 replaces the bottom six-item reader surface with a
            -- transient top control center. The hidden reading state remains
            -- completely clean and the primary row is fixed to five reader tools.
            local current=self:preferences()
            current.reader_ui=type(current.reader_ui)=="table" and current.reader_ui or {}
            current.reader_ui.show_title=false
            current.reader_ui.show_status=false
            current.reader_ui.show_recent=false
            current.reader_ui.recent_actions={}
            current.reader_ui.quick_layout_version=9
            current.reader_ui.quick_items={toc=true,progress=true,font=true,comments=true,search=true}
            current.reader_ui.quick_order={"toc","progress","font","comments","search"}
            self:save_preferences(current)
        end
        if schema<101 then
            -- 4.3.0-beta.1 separates the runtime mode from the configured next
            -- mode and replaces automatic third-party UI scanning with a
            -- one-time explanation whenever the user really enters a mode.
            local current=self:preferences()
            current.mode_intro={pending_mode="",pending_reason="",last_confirmed_mode="",confirmed_at=0}
            current.notices=type(current.notices)=="table" and current.notices or {}
            current.notices.mode_environment=true
            current.mode_guard=nil
            self:save_preferences(current)
        end
        if schema<104 then
            -- 4.3.0-beta.4 no longer treats an update or schema migration as
            -- entering a new runtime mode. Existing users keep their selected
            -- mode silently; only a future explicit switch arms a prompt.
            local current=self:preferences()
            current.mode_intro=type(current.mode_intro)=="table" and current.mode_intro or {}
            current.mode_intro.pending_mode=""
            current.mode_intro.pending_reason=""
            current.mode_intro.last_confirmed_mode=tostring(current.mode_intro.last_confirmed_mode or "")
            current.mode_intro.confirmed_at=tonumber(current.mode_intro.confirmed_at or 0) or 0
            self:save_preferences(current)
        end
        if schema<106 then
            -- 4.3.0-beta.13 follows WeRead Web's default underline style.
            -- Earlier MiuRead builds persisted style 0 only because it was the
            -- plugin default; there was no UI that let a user explicitly pick 0.
            local current=self:preferences()
            current.annotation_sync=type(current.annotation_sync)=="table" and current.annotation_sync or {}
            if tonumber(current.annotation_sync.highlight_style or 0)==0 then
                current.annotation_sync.highlight_style=1
            end
            current.annotation_sync.highlight_color=tonumber(current.annotation_sync.highlight_color) or 0
            self:save_preferences(current)
        end
        if schema<109 then
            -- 4.3.0-beta.18 halves routine read-report/control writes. Existing
            -- installs that still carry the old 30-second default move to 60s;
            -- an explicitly longer interval remains untouched.
            local current=self:preferences()
            current.sync=type(current.sync)=="table" and current.sync or {}
            local interval=tonumber(current.sync.interval)
            if interval==nil or interval<=30 then current.sync.interval=Config.READ_INTERVAL end
            self:save_preferences(current)
        end
        if schema<111 then
            -- 4.3.0-beta.21 repairs the beta.20 homepage row. Frontlight is no
            -- longer selectable there; removing it lets MiuRead Settings return
            -- to the visible sixth slot without resetting other custom choices.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            home.action_items=type(home.action_items)=="table" and home.action_items or {}
            home.action_order=type(home.action_order)=="table" and home.action_order or {}
            home.action_items.frontlight=nil
            if home.action_items.sleep==nil then home.action_items.sleep=true end
            if home.action_items.miuread_settings==nil then home.action_items.miuread_settings=true end
            local seen,order={},{}
            for _,key in ipairs(home.action_order) do
                if key~="frontlight" and not seen[key] then seen[key]=true; order[#order+1]=key end
            end
            local function ensure_after(after_key,key)
                if seen[key] then return end
                local out,inserted={},false
                for _,name in ipairs(order) do
                    out[#out+1]=name
                    if name==after_key then out[#out+1]=key; inserted=true end
                end
                if not inserted then out[#out+1]=key end
                order=out; seen[key]=true
            end
            ensure_after("sync","sleep")
            ensure_after("sleep","miuread_settings")
            home.action_order=order
            home.action_layout_version=3
            self:save_preferences(current)
        end
        if schema<112 then
            -- beta.35 separates the recommended metadata default from an
            -- explicit user choice. Old builds could persist the temporary
            -- beta.8 performance default (off), so installs without the new
            -- explicit marker are repaired once to the current recommendation.
            local current=self:preferences()
            current.home_ui=type(current.home_ui)=="table" and current.home_ui or {}
            local home=current.home_ui
            local raw_home=type(previous.home_ui)=="table" and previous.home_ui or {}
            if raw_home.network_metadata_user_set~=true then
                home.network_metadata=true
                home.network_metadata_user_set=false
            end
            home.network_metadata_defaults_version=2
            home.performance_defaults_version=1
            current.reader_ui=type(current.reader_ui)=="table" and current.reader_ui or {}
            local raw_reader=type(previous.reader_ui)=="table" and previous.reader_ui or {}
            if raw_reader.show_title==nil then current.reader_ui.show_title=false end
            if raw_reader.show_status==nil then current.reader_ui.show_status=false end
            if raw_reader.show_recent==nil then current.reader_ui.show_recent=false end
            if raw_reader.edge_guard_enabled==nil then current.reader_ui.edge_guard_enabled=true end
            if raw_reader.edge_guard_percent==nil then current.reader_ui.edge_guard_percent=10 end
            self:save_preferences(current)
        end
        self.db:saveSetting("schema",Config.SCHEMA)
    end
end
function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v) self.db:saveSetting(k,v); self:flush() end
function Store:set_deferred(k,v) self.db:saveSetting(k,v) end
local function sanitized_auth(value)
    local auth=U.merge(defaults.auth,value or {})
    auth.mp_cookie_header=nil
    auth.mp_extra_headers=nil
    auth.mp_referer=nil
    auth.mp_auth_source=nil
    auth.mp_authorized_at=nil
    return auth
end
function Store:auth() return sanitized_auth(self:get("auth",{})) end
function Store:save_auth(v) self:set("auth",sanitized_auth(v)) end
function Store:generate_login_session_id() return generate_login_session_id() end
function Store:ensure_login_session_id()
    local auth=self:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    if tostring(auth.login_session_id or "")=="" and tostring(account.vid or "")~=""
        and tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
        auth.login_session_id=generate_login_session_id()
        self:save_auth(auth)
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
function Store:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function Store:clear_account_shelf_cache()
    local cache=self:shelf_cache()
    cache.books={}; cache.mp={}; cache.updated_at=0
    self:save_shelf_cache(cache)
end
function Store:preferences() return U.merge(defaults.preferences,self:get("preferences",{})) end
function Store:save_preferences(v) self:set("preferences",U.merge(defaults.preferences,v or {})) end
function Store:save_preferences_deferred(v) self:set_deferred("preferences",U.merge(defaults.preferences,v or {})) end
function Store:books_root() local p=self:preferences().download_dir; if p=="" then p=self.default_books_dir end; U.mkdir(p); return p end
function Store:epub_root() return self:books_root() end
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
    local all=self:library(); local key=tostring(id); all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {}); self:set("library",all); return all[key]
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
    if include_cache~=false then add_unique_path(out,seen,self:book_cache_path(id)) end
    return out
end
function Store:all_download_paths(include_covers)
    local out,seen={},{}
    for id,_ in pairs(self:library()) do for _,path in ipairs(self:book_paths(id,true)) do add_unique_path(out,seen,path) end end
    add_unique_path(out,seen,self.cache_books_dir)
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

    local repair=self:get("book_repair_state",{}); repair[key]=nil; self:set("book_repair_state",repair)
    local history_out={}
    for _,row in ipairs(self:get("book_repair_history",{})) do
        if tostring(row.book_id or "")~=key then history_out[#history_out+1]=row end
    end
    self:set("book_repair_history",history_out)

    local shelf=self:shelf_cache()
    local shelf_changed=false
    for _,group in ipairs({shelf.books or {},shelf.mp or {}}) do
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

local function access_from_epub_meta(_meta)
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
                return book,record,kind
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if match_record(record) then
                    record.chapter_uid=uid
                    relink_saved_record(self,all,book,record,path,file_size(),relink)
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
                annotation_requested=meta.annotation_requested==true or nil,
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
            annotation_requested=meta.annotation_requested==true or nil,
        }
        if standalone and uid~="" then record.chapter_uid=uid; book.chapters[uid]={[kind]=record}
        else book.variants[kind]=record end
        all[id]=book
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
function Store:invalidate_report_contexts(reason)
    return self:clear_login_bound_sessions(reason)
end
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch,flush_now) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self.db:saveSetting("sessions",a); if flush_now~=false then self:flush() end; return a[k] end
function Store:invalidate_book_sync_context(id,reason,core_map_hash)
    local sessions=self:get("sessions",{})
    local key=tostring(id or "")
    if key=="" then return false end
    local row=type(sessions[key])=="table" and sessions[key] or {}
    for _,field in ipairs({
        "legacy_report_context","report_context","report_login_session_id","report_core_map_hash",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "verification_login_session_id","progress_upload_state","progress_upload_verified_at","progress_upload_source",
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
function Store:save_shelf_cache(v) self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function Store:update_cached_progress(id,percent)
    id=tostring(id or "")
    percent=tonumber(percent)
    if id=="" or percent==nil then return false end
    local cache=self:shelf_cache()
    local changed=false
    for _,group in ipairs({cache.books or {},cache.mp or {}}) do
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
function Store:save_update_state(v) self:set("update_state",v or {}) end
function Store:download_state()
    local value=DownloadDatabase.get_download_state(self)
    if type(value)=="table" and next(value)~=nil then return value end
    local legacy_path=tostring(self.legacy_download_state_path or "")
    local raw=legacy_path~="" and U.read_file(legacy_path,true) or nil
    if raw and raw~="" then
        local ok,legacy=pcall(Json.decode,raw)
        if ok and type(legacy)=="table" then
            DownloadDatabase.set_download_state(self,legacy)
            os.remove(legacy_path)
            return legacy
        end
    end
    return {}
end
function Store:save_download_state(value)
    return DownloadDatabase.set_download_state(self,value or {})
end
function Store:clear_download_state()
    if self.legacy_download_state_path then os.remove(self.legacy_download_state_path) end
    return DownloadDatabase.clear_download_state(self)
end
function Store:download_queue()
    local queue=DownloadDatabase.get_download_queue(self)
    if type(queue)~="table" or next(queue)==nil then
        local legacy=self:get("download_queue",{})
        if type(legacy)=="table" and #legacy>0 then
            DownloadDatabase.set_download_queue(self,legacy)
            self:set("download_queue",{})
            queue=legacy
        end
    end
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
function Store:flush()
    local previous_path=self.settings_path..".previous"
    if not self.isolated then
        local valid=settings_file_valid(self.settings_path)
        if valid then U.copy_file(self.settings_path,previous_path) end
    end
    local ok,err=xpcall(function() self.db:flush() end,debug.traceback)
    if not ok then
        if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
        error(err)
    end
    if not self.isolated then
        local valid,reason=settings_file_valid(self.settings_path)
        if valid then
            U.copy_file(self.settings_path,self.settings_backup_path)
            os.remove(previous_path)
        else
            logger.warn("[MiuRead][Store] settings flush produced invalid file","reason=",tostring(reason))
            restore_settings_file(self.settings_path,self.settings_backup_path)
            self.db=LuaSettings:open(self.settings_path)
        end
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
return Store
