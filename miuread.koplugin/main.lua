local RawButtonDialog=require("ui/widget/buttondialog")
local RawConfirmBox=require("ui/widget/confirmbox")
local RawInfoMessage=require("ui/widget/infomessage")
local RawInputDialog=require("ui/widget/inputdialog")
local RawMenu=require("ui/widget/menu")
local RawPathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local Device=require("device")
local Blitbuffer=require("ffi/blitbuffer")
local Event=require("ui/event")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")
local function monotonic_wall_time()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuread.config")
local Text=require("miuread.text")
local U=require("miuread.util")
local Json=require("miuread.json")
local Store=require("miuread.store")
local Http=require("miuread.http")
local Api=require("miuread.api")
local Auth=require("miuread.auth")
local Reader=require("miuread.reader")
local Protocol=require("miuread.protocol")
local MP=require("miuread.mp")
local Access=require("miuread.access")
local Annotations=require("miuread.annotations")
local LocalAnnotationDatabase=require("miuread.local_annotation_database")
local AnnotationSync=require("miuread.annotation_sync")
local Downloader=require("miuread.downloader")
local StreamReader=require("miuread.stream_reader")
local DownloadProgress=require("miuread.download_progress")
local DownloadTask=require("miuread.download_task")
local DownloadResult=require("miuread.download_result")
local BookIntegrity=require("miuread.book_integrity")
local EpubInstaller=require("miuread.epub_installer")
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local MemoryMode=require("miuread.memory_mode")
local PerformanceMode=require("miuread.performance_mode")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local FullShelfView=require("miuread.full_shelf_view")
local LocalBrowserView=require("miuread.local_browser_view")
local HomeView=require("miuread.home_view")
local HomeQuickPanel=require("miuread.home_quick_panel")
local ActionSheet=require("miuread.action_sheet")
local TransientGuard=require("miuread.transient_guard")
local ScreenshotMode=require("miuread.screenshot_mode")
local GestureBridge=require("miuread.gesture_bridge")
local HomeData=require("miuread.home_data")
local TimeZone=require("miuread.timezone")
local UiScale=require("miuread.ui_scale")
local LocalLibrary=require("miuread.local_library")
local LocalMetadata=require("miuread.local_metadata")
local NetworkMetadata=require("miuread.network_metadata")
local Async=require("miuread.async")
local Sync=require("miuread.sync")
local Updater=require("miuread.updater")
local Cookies=require("miuread.cookies")
local Thoughts=require("miuread.thoughts")
local ThoughtNativePopup=require("miuread.thought_native_popup")
local ReaderToolbar=require("miuread.reader_toolbar")
local ReaderListDialog=require("miuread.reader_list_dialog")
local ReaderControlCenter=require("miuread.reader_control_center")
local ReaderProgressDialog=require("miuread.reader_progress_dialog")
local ReaderSettingsDialog=require("miuread.reader_settings_dialog")
local ReaderTocDialog=require("miuread.reader_toc_dialog")
local ReaderFrontlightDialog=require("miuread.reader_frontlight_dialog")
local DataMigration=require("miuread.data_migration")
local MigrationProgress=require("miuread.migration_progress")
local DownloadDatabase=require("miuread.download_database")
local StatusToast=require("miuread.status_toast")
local ReaderTransitionGuard=require("miuread.reader_transition_guard")
local PluginMenu=require("miuread.plugin_menu")
local PluginSettings=require("miuread.plugin_settings")
local Actions=require("miuread.actions")
local function gesture_aware_class(base, attributes)
    local class=base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base,self,event)
    end
    return class
end
local ButtonDialog=gesture_aware_class(RawButtonDialog,{_miuread_transient=true,_miuread_modal_surface=true})
local ConfirmBox=gesture_aware_class(RawConfirmBox,{_miuread_transient=true,_miuread_modal_surface=true})
local InfoMessage=gesture_aware_class(RawInfoMessage,{_miuread_transient=true,_miuread_modal_surface=true})
local InputDialog=gesture_aware_class(RawInputDialog,{_miuread_transient=true,_miuread_modal_surface=true})
local Menu=gesture_aware_class(RawMenu,{_miuread_transient=true,_miuread_modal_surface=true})
local PathChooser=gesture_aware_class(RawPathChooser,{_miuread_transient=true,_miuread_modal_surface=true})
local _=Text.tr
local unpack_args=unpack or table.unpack
local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60
local COVER_GUARD_WINDOW=6*60*60
local HOME_LOCAL_CACHE_TTL=20*60
local HOME_SHELF_REFRESH_TTL=10*60
local HOME_REMOTE_AUTO_RETRY=5*60
local HOME_SECTION_ORDER={"account","local","mp"}
local HOME_QUICK_ITEM_LEGACY_ORDER={"wifi","frontlight","refresh_shelf","full_refresh","settings","koreader_menu","downloads","sync","night","rotate","sleep","restart","quit"}
local HOME_QUICK_ITEM_LEGACY_DEFAULT={wifi=true,frontlight=true,refresh_shelf=true,full_refresh=true,settings=true,koreader_menu=true,downloads=true,sync=true,night=false,rotate=false,sleep=true,restart=false,quit=false}

-- 3.5 separates the always-visible home actions from the pull-down control
-- center. Defaults intentionally avoid duplicates, while both areas remain
-- fully configurable.
local HOME_ACTION_ITEM_V1_ORDER={"refresh","search","downloads","sync","frontlight","miuread_settings","all_books","history","file_manager","screenshot"}
local HOME_ACTION_ITEM_V1_DEFAULT={refresh=true,search=true,downloads=true,sync=true,frontlight=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
local HOME_ACTION_ITEM_V2_ORDER={"refresh","search","downloads","sync","sleep","miuread_settings","frontlight","all_books","history","file_manager","screenshot"}
local HOME_ACTION_ITEM_V2_DEFAULT={refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,frontlight=false,all_books=false,history=false,file_manager=false,screenshot=false}
-- Frontlight is no longer a homepage shortcut candidate. It lives only in the
-- pull-down direct-control section (and the reader controls).
local HOME_ACTION_ITEM_ORDER={"refresh","search","downloads","sync","sleep","miuread_settings","all_books","history","file_manager","screenshot"}
local HOME_ACTION_ITEM_DEFAULT={refresh=true,search=true,downloads=true,sync=true,sleep=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
local HOME_ACTION_LAYOUT_VERSION=3
local HOME_PANEL_ITEM_V1_ORDER={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
local HOME_PANEL_ITEM_ORDER={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
local HOME_PANEL_ITEM_V1_DEFAULT={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
local HOME_PANEL_ITEM_DEFAULT={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
local HOME_PANEL_LAYOUT_VERSION=2
local READER_QUICK_ITEM_LEGACY_ORDER={"home","toc","progress","font","typeset","sync","current_book","downloads","full_refresh","koreader_menu","sleep","more"}
local READER_QUICK_ITEM_LEGACY_DEFAULT={home=true,toc=true,progress=true,font=true,typeset=true,sync=true,current_book=true,downloads=false,full_refresh=false,koreader_menu=false,sleep=false,more=true}
local READER_QUICK_ITEM_V2_ORDER={"home","toc","progress","font","sync","more","typeset","current_book","downloads","full_refresh","koreader_menu","sleep"}
local READER_QUICK_ITEM_V2_DEFAULT={home=true,toc=true,progress=true,font=true,sync=true,more=true,typeset=false,current_book=false,downloads=false,full_refresh=false,koreader_menu=false,sleep=false}
local READER_QUICK_ITEM_V3_ORDER={"home","toc","progress","font","frontlight","sync","typeset","current_book","downloads","full_refresh","koreader_menu","sleep"}
local READER_QUICK_ITEM_V3_DEFAULT={home=true,toc=true,progress=true,font=true,frontlight=true,sync=true,typeset=false,current_book=false,downloads=false,full_refresh=false,koreader_menu=false,sleep=false}
local READER_QUICK_ITEM_ORDER={"toc","progress","font","frontlight","sync","comment_font","page_display","typeset","current_book","downloads","full_refresh","koreader_menu","sleep"}
local READER_QUICK_ITEM_DEFAULT={toc=true,progress=true,font=true,frontlight=true,sync=true,comment_font=true,page_display=false,typeset=false,current_book=false,downloads=false,full_refresh=false,koreader_menu=false,sleep=false}
local function quick_boolean_layout_matches(actual,expected,order)
    if type(actual)~="table" then return false end
    for _,key in ipairs(order or {}) do
        if (actual[key]==true)~=(expected[key]==true) then return false end
    end
    return true
end
local function quick_order_matches(actual,expected)
    if type(actual)~="table" or #actual~=#expected then return false end
    for index,key in ipairs(expected) do if actual[index]~=key then return false end end
    return true
end
-- ReaderUI and FileManager create separate plugin instances. Keep navigation
-- state in _G so opening/closing a document does not lose its MiuRead origin.
local HOME_SESSION=rawget(_G,"__MIUREAD_HOME_SESSION")
if type(HOME_SESSION)~="table" then
    HOME_SESSION={suppressed=false,native_visit=false,expected_close=false,exiting=false,return_file=nil,reader_origin=false,reader_file=nil,
        foreground="native",suspended=false,reader_session_generation=0,reader_session_file=nil,reader_session_active=false,
        return_requested=false,return_session_generation=0,return_request_file=nil}
    rawset(_G,"__MIUREAD_HOME_SESSION",HOME_SESSION)
end
local STREAM_SESSION=rawget(_G,"__MIUREAD_STREAM_SESSION")
if type(STREAM_SESSION)~="table" then
    STREAM_SESSION={reader=nil,meta=nil,pending_percent=nil}
    rawset(_G,"__MIUREAD_STREAM_SESSION",STREAM_SESSION)
end
-- ReaderUI and FileManager transition asynchronously and may use different
-- plugin instances. Keep one shared close coordinator so CloseDocument,
-- showFileManager and delayed callbacks cannot race each other.
local READER_CLOSE=rawget(_G,"__MIUREAD_READER_CLOSE")
if type(READER_CLOSE)~="table" then
    READER_CLOSE={
        state="idle",generation=0,session_generation=0,reader_file=nil,
        requested_at=0,requested_clock=0,close_event_received=false,native_requested=false,
        stable_samples=0,fallback_attempted=false,reason=nil,watch_token=0,
        poll_state=nil,poll_count=0,close_attempts=0,close_command_sent_at=0,
        foreground_stop_attempted=false,native_fallback_attempted=false,
    }
    rawset(_G,"__MIUREAD_READER_CLOSE",READER_CLOSE)
end
READER_CLOSE.close_attempts=tonumber(READER_CLOSE.close_attempts) or 0
READER_CLOSE.close_command_sent_at=tonumber(READER_CLOSE.close_command_sent_at) or 0
READER_CLOSE.foreground_stop_attempted=READER_CLOSE.foreground_stop_attempted==true
READER_CLOSE.native_fallback_attempted=READER_CLOSE.native_fallback_attempted==true

-- CloseDocument is not always a user-visible exit. KOReader may tear down and
-- recreate ReaderUI while changing orientation, resuming or rebuilding the
-- document. Keep that observation separate from the explicit ReaderClose state
-- so an internal rebuild can never start MiuRead's Home/FileManager transition.
local READER_REBUILD=rawget(_G,"__MIUREAD_READER_REBUILD")
if type(READER_REBUILD)~="table" then
    READER_REBUILD={
        state="idle",generation=0,session_generation=0,reader_file=nil,
        started_at=0,started_clock=0,max_wait=0,reason=nil,owner=nil,
        recent_book=nil,recent_started_at=0,recent_count=0,safe_until=0,
        pending_width=nil,pending_height=nil,pending_rotation=nil,
    }
    rawset(_G,"__MIUREAD_READER_REBUILD",READER_REBUILD)
end
READER_REBUILD.generation=tonumber(READER_REBUILD.generation) or 0
READER_REBUILD.session_generation=tonumber(READER_REBUILD.session_generation) or 0
READER_REBUILD.started_at=tonumber(READER_REBUILD.started_at) or 0
READER_REBUILD.started_clock=tonumber(READER_REBUILD.started_clock) or 0
READER_REBUILD.max_wait=tonumber(READER_REBUILD.max_wait) or 0
READER_REBUILD.recent_started_at=tonumber(READER_REBUILD.recent_started_at) or 0
READER_REBUILD.recent_count=tonumber(READER_REBUILD.recent_count) or 0
READER_REBUILD.safe_until=tonumber(READER_REBUILD.safe_until) or 0
local function reader_rebuild_active()
    local state=tostring(READER_REBUILD.state or "idle")
    return state=="pending" or state=="suspended_pending"
end

HOME_SESSION.home_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
HOME_SESSION.post_reader_work_interaction_generation=tonumber(HOME_SESSION.post_reader_work_interaction_generation) or 0
local function reader_close_active()
    local state=tostring(READER_CLOSE.state or "idle")
    return state~="idle" and state~="completed" and state~="failed"
end
-- One global navigation state is shared by the FileManager-side and
-- ReaderUI-side plugin instances. It replaces overlapping local booleans as
-- the authority for delayed transition callbacks while retaining the legacy
-- HOME_SESSION fields for compatibility with existing code.
local NAVIGATION=rawget(_G,"__MIUREAD_NAVIGATION")
local NAVIGATION_STATES={
    native=true,home=true,opening_reader=true,reader=true,closing_reader=true,
    native_menu=true,suspended=true,recovering=true,exiting=true,
}
local function navigation_state_from_foreground(owner)
    owner=tostring(owner or "native")
    if owner=="home" then return "home" end
    if owner=="reader" then return "reader" end
    if owner=="reader_pending" then return "opening_reader" end
    if owner=="reader_transition" or owner=="home_pending" then return "closing_reader" end
    if owner=="suspended" then return "suspended" end
    if owner=="exiting" then return "exiting" end
    return "native"
end
if type(NAVIGATION)~="table" then
    local initial=HOME_SESSION.suspended==true and "suspended"
        or navigation_state_from_foreground(HOME_SESSION.foreground)
    NAVIGATION={state=initial,generation=0,reason="startup",changed_at=os.time(),reader_session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0}
    rawset(_G,"__MIUREAD_NAVIGATION",NAVIGATION)
else
    if not NAVIGATION_STATES[tostring(NAVIGATION.state or "")] then
        NAVIGATION.state=navigation_state_from_foreground(HOME_SESSION.foreground)
    end
    NAVIGATION.generation=tonumber(NAVIGATION.generation) or 0
    NAVIGATION.changed_at=tonumber(NAVIGATION.changed_at) or os.time()
    NAVIGATION.reader_session_generation=tonumber(NAVIGATION.reader_session_generation) or 0
end
HOME_SESSION.navigation_state=NAVIGATION.state
HOME_SESSION.navigation_generation=NAVIGATION.generation
HOME_SESSION.home_restore_generation=tonumber(HOME_SESSION.home_restore_generation) or 0

local HOME_SESSION_SUPPRESSED=HOME_SESSION.suppressed==true
local HOME_NATIVE_VISIT=HOME_SESSION.native_visit==true
local HOME_EXPECTED_CLOSE=HOME_SESSION.expected_close==true
local HOME_EXITING=HOME_SESSION.exiting==true
local HOME_RETURN_FILE=HOME_SESSION.return_file
local HOME_READER_ORIGIN=HOME_SESSION.reader_origin==true
local HOME_READER_FILE=HOME_SESSION.reader_file
local function persist_home_session()
    HOME_SESSION.suppressed=HOME_SESSION_SUPPRESSED==true
    HOME_SESSION.native_visit=HOME_NATIVE_VISIT==true
    HOME_SESSION.expected_close=HOME_EXPECTED_CLOSE==true
    HOME_SESSION.exiting=HOME_EXITING==true
    HOME_SESSION.return_file=HOME_RETURN_FILE
    HOME_SESSION.reader_origin=HOME_READER_ORIGIN==true
    HOME_SESSION.reader_file=HOME_READER_FILE
end
local function sync_home_session()
    HOME_SESSION_SUPPRESSED=HOME_SESSION.suppressed==true
    HOME_NATIVE_VISIT=HOME_SESSION.native_visit==true
    HOME_EXPECTED_CLOSE=HOME_SESSION.expected_close==true
    HOME_EXITING=HOME_SESSION.exiting==true
    HOME_RETURN_FILE=HOME_SESSION.return_file
    HOME_READER_ORIGIN=HOME_SESSION.reader_origin==true
    HOME_READER_FILE=HOME_SESSION.reader_file
end
local function normalized_reader_file(path)
    path=tostring(path or "")
    if path=="" then return nil end
    return path
end
local function mark_reader_origin(path)
    HOME_READER_ORIGIN=true
    HOME_NATIVE_VISIT=false
    HOME_READER_FILE=normalized_reader_file(path) or HOME_READER_FILE
    persist_home_session()
end
-- Track a temporary KOReader menu visit globally because FileManager and
-- ReaderUI use different plugin instances. MiuRead remains visible underneath
-- native menus and is raised again after the last native page closes.
local NATIVE_MENU_GUARD=rawget(_G,"__MIUREAD_NATIVE_MENU_GUARD")
if type(NATIVE_MENU_GUARD)~="table" then
    NATIVE_MENU_GUARD={token=0,active=false,finishing=false,menu=nil,container=nil,watch=nil}
    rawset(_G,"__MIUREAD_NATIVE_MENU_GUARD",NATIVE_MENU_GUARD)
end
local DIRECT_MENU_INSERTED=false
local SCREENSAVER_PATCHED=false
local HOME_OWNER_KEY="__MIUREAD_HOME_OWNER"

local function home_owner()
    local owner=rawget(_G,HOME_OWNER_KEY)
    if type(owner)=="table" and owner._runtime_mode=="desktop" then return owner end
    return nil
end

local function install_home_screensaver_patch()
    if SCREENSAVER_PATCHED then return true end
    local ok,Screensaver=pcall(require,"ui/screensaver")
    if not ok or not Screensaver or type(Screensaver.setup)~="function" then return false end
    if Screensaver._miuread_original_setup then SCREENSAVER_PATCHED=true; return true end
    local original=Screensaver.setup
    local keys={"screensaver_type","screensaver_document_cover","screensaver_show_message","screensaver_img_background"}
    local function snapshot()
        local saved={}
        for _,key in ipairs(keys) do
            saved[key]={has=G_reader_settings:has(key),value=G_reader_settings:readSetting(key)}
        end
        return saved
    end
    local function restore(saved)
        for _,key in ipairs(keys) do
            local row=saved[key]
            if row and row.has then G_reader_settings:saveSetting(key,row.value)
            else G_reader_settings:delSetting(key) end
        end
    end
    Screensaver._miuread_original_setup=original
    Screensaver.setup=function(manager,...)
        local args={n=select("#",...),...}
        local current=HomeView.current()
        local opts=current and current.opts or nil
        local target=opts and opts.lockscreen_enabled~=false and tostring(opts.screensaver_file or "") or ""
        local use_home_target=HomeView.is_shown()
        if target=="" and HOME_READER_ORIGIN and HOME_SESSION.lockscreen_recent_enabled~=false then
            target=tostring(HOME_SESSION.screensaver_file or "")
            use_home_target=target~=""
        end

        -- Preserve KOReader's native path whenever ReaderUI/FileManager still
        -- exists.  beta.34 only intervenes in the exact beta.33 gap where the
        -- parked MiuRead home is visible after ReaderUI has closed and before a
        -- FileManager instance exists.  Kindle calls Screensaver:setup/show
        -- before the normal Suspend broadcast, so without this fallback recent
        -- KOReader versions return early and never establish screen_saver_mode.
        local ReaderUI=require("apps/reader/readerui")
        local FileManager=require("apps/filemanager/filemanager")
        local native_ui=ReaderUI.instance or FileManager.instance
        if not native_ui and args.n==0 and HomeView.is_shown() and current then
            local owner=home_owner()
            if HomeView.suspend then pcall(HomeView.suspend) end
            if owner and type(owner._home_freeze_for_suspend)=="function" then
                local frozen,freeze_err=pcall(owner._home_freeze_for_suspend,owner)
                if not frozen then
                    logger.warn("[MiuRead][Suspend] screensaver prefreeze failed",tostring(freeze_err))
                end
            end

            manager.ui=(owner and owner.ui) or current
            manager.show_message=false
            manager.prefix=""
            manager.event_message=nil
            manager.overlay_message=nil
            manager.image=nil
            manager.image_file=nil
            manager.screensaver_background="white"

            if use_home_target and target~="" and lfs.attributes(target,"mode")=="file" then
                manager.screensaver_type="cover"
                manager.image_file=target
                logger.info("[MiuRead][Suspend] screensaver home fallback",
                    "native_ui=false","target=true","prefrozen=",tostring(owner~=nil))
            else
                -- No valid MiuRead cover is available.  Keep the already-painted
                -- home surface instead of inventing a new fallback image; show()
                -- will still mark the device as being in screen-saver mode.
                manager.screensaver_type="disable"
                logger.info("[MiuRead][Suspend] screensaver home fallback",
                    "native_ui=false","target=false","prefrozen=",tostring(owner~=nil))
            end
            return
        end

        if use_home_target and target~="" and lfs.attributes(target,"mode")=="file" then
            local saved=snapshot()
            G_reader_settings:saveSetting("screensaver_type","document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover",target)
            G_reader_settings:saveSetting("screensaver_show_message",false)
            G_reader_settings:saveSetting("screensaver_img_background","white")
            local packed={xpcall(function()
                return original(manager,unpack_args(args,1,args.n))
            end,debug.traceback)}
            restore(saved)
            if not packed[1] then error(packed[2]) end
            return unpack_args(packed,2,#packed)
        end
        return original(manager,unpack_args(args,1,args.n))
    end
    SCREENSAVER_PATCHED=true
    return true
end
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local RUNTIME_MODE_KEY="__MIUREAD_RUNTIME_MODE"
local Plugin=WidgetContainer:extend{name="miuread",is_doc_only=false,version=Config.VERSION}
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end
local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuRead][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end
function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    sync_home_session()
    self.store=Store:new()
    local runtime_mode=rawget(_G,RUNTIME_MODE_KEY)
    if runtime_mode~="desktop" and runtime_mode~="plugin" then
        local configured=((self.store:preferences().home_ui or {}).enabled~=false)
        runtime_mode=configured and "desktop" or "plugin"
        rawset(_G,RUNTIME_MODE_KEY,runtime_mode)
    end
    self._runtime_mode=runtime_mode
    logger.info("[MiuRead][Mode] runtime frozen",tostring(runtime_mode))
    local timezone_ok,timezone_error=TimeZone.apply((self.store:preferences() or {}).time_display)
    if not timezone_ok then logger.warn("[MiuRead][TimeZone] startup apply failed",tostring(timezone_error or "unknown")) end
    self._reader_context=self.ui and self.ui.document~=nil
    if self._reader_context then
        local document=self.ui.document
        local path=normalized_reader_file(document and (document.file or (document.getFilePath and document:getFilePath())) or nil)
        if HOME_READER_ORIGIN or (path and HOME_READER_FILE==path) then
            mark_reader_origin(path)
            logger.info("[MiuRead][Home] reader origin restored",tostring(path or "unknown"))
        end
    end
    if self:_home_enabled() then HomeView.prune_duplicates() end
    if HOME_SESSION.suspended==true then
        self:_set_navigation_state("suspended","plugin initialized while suspended")
    elseif reader_close_active() then
        self:_set_navigation_state("closing_reader","plugin initialized during reader close")
    elseif NATIVE_MENU_GUARD.active==true or self:_navigation_state()=="native_menu" then
        self:_set_navigation_state("native_menu","native menu plugin initialized")
    elseif self._reader_context then
        self:_set_navigation_state("reader","reader plugin initialized")
    elseif HomeView.is_shown() then
        self:_set_navigation_state("home","home plugin initialized")
    else
        self:_set_navigation_state("native","file manager plugin initialized")
    end
    self._reader_active_path="/tmp/miuread-reader-active.flag"
    self._reader_busy_path="/tmp/miuread-reader-busy.until"
    self._reader_busy_until=tonumber(U.read_file(self._reader_busy_path,true) or 0) or 0
    self._reader_last_interaction_clock=0
    self._home_quick_panel_last_open=0
    self._home_quick_panel_opening=false
    -- Keep expensive home workers out of the user's immediate interaction path.
    -- Every touch extends a short quiet window; visible metadata/cover work is
    -- resumed only after that window expires.
    self._home_ui_quiet_until=0
    self._home_post_reader_protect_until=0
    self._home_modal_cooldown_until=0
    self._home_ui_resume_task=nil
    self._home_manual_metadata_retry_task=nil
    self._home_pending_network_metadata_key=nil
    -- Ordinary UI preferences are written into LuaSettings immediately but
    -- their flash flush is coalesced. Critical auth/download/session state
    -- continues to use Store:set() and remains synchronous.
    self._ui_preferences_save_pending=false
    self._ui_preferences_save_generation=0
    self._home_visible_metadata_targets={}
    self._home_visible_cover_targets={}
    self._reader_quick_panel_pending=false
    self._reader_toolbar_state_cache={session=0,page=nil,total=nil,chapter="",updated_at=0}
    self._reader_toolbar_state_task=nil
    self._reader_toolbar_prewarm_task=nil
    self._reader_toolbar_header_perf=nil
    self._reader_toolbar_options_perf=nil
    self._mode_intro_generation=0
    self._thought_popup_marker_path=self.store.temp_dir.."/thought-popup.pending.json"
    self._thought_popup_last_crash_path=self.store.data_dir.."/thought-popup-last-crash.json"
    local pending_popup=U.read_file(self._thought_popup_marker_path,true)
    if pending_popup then
        -- A pending marker can only survive an abnormal exit. Preserve it as a
        -- compact diagnostic instead of letting the next launch mistake it for
        -- a currently active window.
        U.atomic_write(self._thought_popup_last_crash_path,pending_popup,true)
        os.remove(self._thought_popup_marker_path)
        logger.warn("[MiuRead][ThoughtPopup] previous session ended while popup was active")
    end
    self._thought_popup=nil
    self._thought_popup_busy=false
    self._thought_popup_generation=0
    self._reader_checkpoint_task=nil
    self._reader_checkpoint_last=0
    self._reader_checkpoint_dirty=false
    self._reader_returning=false
    self._reader_return_generation=0
    self._reader_return_started=0
    self._reader_return_finish_task=nil
    self._reader_return_completed_generation=nil
    self._reader_return_session_generation=0
    self._reader_close_settle_task=nil
    self._reader_close_settle_generation=0
    self._reader_close_watch_task=nil
    self._reader_dimension_task=nil
    self._reader_dimension_generation=0
    self._reader_dimension_width=Device.screen:getWidth()
    self._reader_dimension_height=Device.screen:getHeight()
    self._reader_dimension_rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
    self._miuread_suspended=HOME_SESSION.suspended==true
    self._reader_native_menu_opening=false
    self._post_reader_work_task=nil
    HOME_SESSION.post_reader_work_generation=tonumber(HOME_SESSION.post_reader_work_generation) or 0
    self._post_reader_work_generation=HOME_SESSION.post_reader_work_generation
    self._reader_recovery_dialog=nil
    -- Opening state is shared with the FileManager-side plugin instance so a
    -- slow tap cannot start the same ReaderUI transition twice.
    if tonumber(HOME_SESSION.opening_at or 0)>0
        and os.time()-tonumber(HOME_SESSION.opening_at or 0)>30 then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end
    if self._reader_context then
        U.atomic_write(self._reader_active_path,"1",true)
        self._reader_busy_until=os.time()+3
        U.atomic_write(self._reader_busy_path,tostring(self._reader_busy_until),true)
    else
        os.remove(self._reader_active_path)
        os.remove(self._reader_busy_path)
    end
    self.memory_mode=MemoryMode:new(self.store)
    self.performance_mode=PerformanceMode:new(self.store)
    self._reader_interaction_resume_task=nil
    self._reader_interaction_resume_generation=0
    self._performance_prompt_pending=nil
    self._performance_prompt_dialog=nil
    self.book_repair=DataMigration:new(self.store)
    logger.info("[MiuRead] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.reader=Reader:new(self.http,self.store)
    self.api=Api:new(self.http,self.store,self.reader)
    self.mp=MP:new(self.reader,self.http,self.store,self.api)
    self.annotations=Annotations:new(self.api)
    self.annotation_sync=AnnotationSync:new(self.api,self.reader,self.store)
    do
        local annotation_prefs=self:_annotation_sync_preferences()
        logger.info("[MiuRead][AnnotationSync] initialized",
            "enabled=",tostring(annotation_prefs.enabled==true),"mode=manual")
    end
    self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http)
    self.download_task=DownloadTask:new(self.store)
    self.cache_cleanup_task=CacheCleanupTask:new(self.store)
    self.library=Library:new(self.api,self.http,self.store)
    local cover_quality_version=tonumber(self.store:get("cover_quality_version",0)) or 0
    if cover_quality_version<2 then
        local cleared,clear_error=pcall(self.library.clear_covers,self.library)
        if not cleared then logger.warn("[MiuRead][Cover] quality cache reset failed",tostring(clear_error or "unknown")) end
        self.store:set("cover_quality_version",2)
    end
    self.access=Access:new(self.library,self.api,self.reader,self.store)
    self.async=Async:new(self.store,{allow_android=true,disable_fallback=true})
    self.mp_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.search_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.shelf_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    -- User-triggered network reads that used to run through UIManager must
    -- always stay off the UI thread. This worker is intentionally separate
    -- from sync/download/search workers so those lifecycles cannot block it.
    self.interactive_network_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    self._interactive_network_generation=0
    self._interactive_network_key=nil
    self.cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.identity_async=Async:new(self.store,{poll_interval=.20,allow_android=true,
        disable_fallback=true})
    self.repair_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.annotation_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    -- Update manifest/package network I/O must never occupy the UI loop.
    -- Installation itself stays foreground because it replaces the live plugin tree.
    self.updater_async=Async:new(self.store,{poll_interval=.30,allow_android=true,disable_fallback=true})
    -- Summary scans may touch one SQLite cache per annotated book. Keep them
    -- out of every home tap and pull-down path.
    self.sync_summary_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
    self._annotation_summary_cache=nil
    self._annotation_summary_cache_at=0
    self._home_sync_summary_task=nil
    if self:_home_enabled() then
        self.home_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
        -- Desktop-only workers are not created in plugin mode.
        self.local_browser_async=Async:new(self.store,{poll_interval=.20,allow_android=true,disable_fallback=true})
        self.home_metadata_async=Async:new(self.store,{poll_interval=.35,allow_android=true,disable_fallback=true})
        self.home_cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
        -- High-quality cover conversion must never run on the UI thread.
        self.cover_render_async=Async:new(self.store,{poll_interval=.35,allow_android=true,disable_fallback=true})
    else
        self.home_async=nil
        self.local_browser_async=nil
        self.home_metadata_async=nil
        self.home_cover_async=nil
        self.cover_render_async=nil
    end
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.sync=Sync:new(self.reader,self.api,self.store,self,self.async,self.identity_async)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self._suspended_at=nil
    self._cover_generation=0
    self._cover_refresh_task=nil
    self._cover_index_pending={}
    self._cover_index_flush_task=nil
    self._cover_safe_mode=false
    self._cover_safe_notice_shown=false
    self._shelf_view=nil
    self._last_shelf_mode=false
    self._last_shelf_section="account"
    self._shelf_refresh_generation=0
    self._shelf_main_busy=false
    self._downloads_menu=nil
    self._download_book_menu=nil
    self._cache_cleanup_dialog=nil
    self._download_runtime=nil
    self._download_state_last_write=0
    self._download_state_last_stage=nil
    self._auth_notice_dialog=nil
    self._sync_success_notified=false
    self._home_view=nil
    self._home_scan_generation=0
    self._home_refreshing=false
    self._home_start_generation=0
    self._home_reader_transition=false
    self._home_metadata_generation=0
    self._home_cover_generation=0
    self._home_sections=nil
    self._home_visible_keys=nil
    self._home_active_section=nil
    self._home_hero=nil
    self._home_remote_refreshing=false
    self._home_render_refresh_task=nil
    self._home_render_refresh_generation=0
    self._home_refresh_debounce_generation=0
    self._home_state_save_generation=0
    self._home_state_save_pending=false
    self._home_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    self._home_data_revision=0
    self._home_section_revisions={account=0,generated=0,["local"]=0,mp=0}
    self._home_directory_generation=0
    self._home_directory_active_path=nil
    self._home_directory_request_owner=nil
    self._local_browser_fallback_task=nil
    self._local_browser_fallback_scanner=nil
    self._home_inline_navigation_generation=0
    self._home_cover_inflight={}
    self._home_cover_render_generation=0
    self._home_cover_render_retry_task=nil
    self._home_suspended=false
    self._home_resume_generation=0
    self._home_resume_barrier=false
    self._home_resume_first_frame=false
    self._home_resume_background_task=nil
    self._home_resume_pending_kind=nil
    self._home_resume_pending_work=nil
    self._home_resume_started_clock=nil
    self._home_resume_sleep_seconds=0
    self._home_resume_surface_task=nil
    self._reader_rebuild_task=nil
    self._reader_dimension_event_count=0
    self._reader_dimension_last_event_clock=0
    self._resume_lifecycle_generation=0
    if HOME_SESSION.page_transition_state==nil then HOME_SESSION.page_transition_state="idle" end
    if HOME_SESSION.page_transition_generation==nil then HOME_SESSION.page_transition_generation=0 end
    self._page_transition_state=tostring(HOME_SESSION.page_transition_state or "idle")
    self._page_transition_generation=tonumber(HOME_SESSION.page_transition_generation) or 0
    self._page_transition_release_task=nil
    self._download_resume_generation=0
    self._download_resume_task=nil

    if not self._reader_context then
        local guard=self.store:cover_guard()
        local guard_age=os.time()-(tonumber(guard.started_at) or 0)
        if guard.active==true and guard_age>=0 and guard_age<COVER_GUARD_WINDOW then
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] previous render did not finish; safe shelf mode enabled",
                "stage=",tostring(guard.stage or ""),"age=",tostring(guard_age))
        end
        if guard.active==true then
            self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
        end

        local startup_download_state=self.store:download_state()
        if startup_download_state.status=="completed" then self.store:clear_download_state() end
        local recovered=self:_recover_download_state()
        if not recovered then UIManager:scheduleIn(1.0,function() self:_start_next_queued_download() end) end
    end
    Actions.register()
    if self:_home_enabled() then install_home_screensaver_patch() end
    if self:_home_enabled() and not DIRECT_MENU_INSERTED then
        local ok_insert, inserter = pcall(require, "ui/plugin/insert_menu")
        if ok_insert and inserter and type(inserter.add) == "function" then
            pcall(inserter.add, "miuread_return_home_direct")
        end
        DIRECT_MENU_INSERTED = true
    end
    self.ui.menu:registerToMainMenu(self)
    if self._reader_context and self:_home_enabled() then self:_install_reader_home_bridge() end
    if not self._reader_context then
        local state=self.updater:startup()
        if state=="updated" then
            UIManager:scheduleIn(1,function() self:status_toast("更新完成","当前运行版本 "..tostring(self.version),4) end)
        elseif state=="mismatch" then
            UIManager:scheduleIn(1,function() self:info("更新文件已经替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。\n当前运行："..tostring(self.version)) end)
        end
        UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
        UIManager:scheduleIn(1.4,function() self:_show_auth_notice() end)
        UIManager:scheduleIn(5.0,function() self:maybe_auto_check_update(false) end)
        -- Mode guidance is never a startup gate. Reveal the selected runtime
        -- surface first, then show guidance only when a fresh install or an
        -- explicit user-requested mode switch armed it.
        if self:_home_enabled() and not HOME_SESSION_SUPPRESSED then
            self:_schedule_home_startup(.65)
        end
        if self:_mode_intro_needed() then
            self:_schedule_mode_intro_after_surface(.85)
        end
    end
end

function Plugin:addToMainMenu(items)
    if self.ui and self.ui.document and self:_home_enabled() then
        items.miuread_return_home_direct={
            text="退出阅读并返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:return_to_miuread_home() end),
        }
    elseif not (self.ui and self.ui.document) and self:_home_enabled() then
        -- FileManager caches its menu table. Register this recovery entry
        -- unconditionally while MiuRead home mode is enabled; checking
        -- HOME_NATIVE_VISIT here made the item disappear when the menu table
        -- had been built before the temporary native visit started.
        items.miuread_return_home_direct={
            text="返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:_return_from_native_filemanager() end),
        }
    end
    items.miuread={
        text=Config.NAME,
        sorting_hint="tools",
        sub_item_table_func=function()
            if self:_home_enabled() then
                return self.ui.document and self:reader_menu() or self:home_menu()
            end
            return self.ui.document and PluginMenu.reader(self) or PluginMenu.home(self)
        end,
    }
end
function Plugin:info(t)
    TransientGuard.close_all()
    UIManager:show(InfoMessage:new{text=tostring(t or "")})
end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:status_toast(title,text,timeout)
    local ok,err=pcall(StatusToast.show,{
        title=tostring(title or ""),
        text=tostring(text or ""),
        timeout=timeout or 3,
    })
    if not ok then
        logger.warn("[MiuRead] status toast failed",tostring(err))
        self:toast(tostring(title or "").." · "..tostring(text or ""):gsub("%s+"," "),timeout or 3)
    end
end
function Plugin:_original_weread_plugin_present()
    local plugins_root=ROOT:match("^(.*)/[^/]+$") or "."
    return lfs.attributes(plugins_root.."/weread.koplugin","mode")=="directory"
end
function Plugin:_begin_cover_guard(stage)
    self.store:save_cover_guard({
        active=true,
        started_at=os.time(),
        stage=tostring(stage or "shelf"),
        version=Config.VERSION,
    })
end
function Plugin:_clear_cover_guard()
    local guard=self.store:cover_guard()
    if guard.active==true then
        self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
    end
end
function Plugin:_shelf_covers_enabled(prefs)
    prefs=prefs or self.store:preferences()
    local enabled=prefs.shelf_covers~=false
    if enabled and self._cover_safe_mode then
        if not self._cover_safe_notice_shown then
            self._cover_safe_notice_shown=true
            self:toast("检测到上次封面加载异常，本次已使用安全书架模式。",4)
        end
        return false
    end
    return enabled
end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuRead]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end

local function interactive_child_store(auth,data_dir,temp_dir)
    local current=U.copy(type(auth)=="table" and auth or {})
    local changed=false
    local store={data_dir=tostring(data_dir or ""),temp_dir=tostring(temp_dir or "")}
    function store:auth() return U.copy(current) end
    function store:save_auth(value) current=U.copy(type(value)=="table" and value or {}); changed=true end
    function store:snapshot() return U.copy(current),changed end
    return store
end

function Plugin:_interactive_network_context()
    return {
        reader_file=normalized_reader_file(self:_current_document_path()),
        reader_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
        home_shown=HomeView.is_shown()==true,
        home_section=tostring(self._home_active_section or ""),
    }
end

function Plugin:_interactive_network_context_valid(context)
    context=type(context)=="table" and context or {}
    if self._miuread_suspended==true or HOME_SESSION.suspended==true or HOME_EXITING then return false end
    local current_file=normalized_reader_file(self:_current_document_path())
    if context.reader_file then
        return current_file==context.reader_file
            and tonumber(HOME_SESSION.reader_session_generation or 0)==tonumber(context.reader_generation or 0)
    end
    if current_file then return false end
    if context.home_shown then
        return HomeView.is_shown()==true and tostring(self._home_active_section or "")==tostring(context.home_section or "")
    end
    return true
end

function Plugin:_apply_interactive_auth(snapshot)
    if type(snapshot)~="table" or snapshot.changed~=true or type(snapshot.auth)~="table" then return false end
    local current=self.store:auth()
    local incoming=snapshot.auth
    local current_session=tostring(current.login_session_id or "")
    local incoming_session=tostring(incoming.login_session_id or "")
    if current_session=="" or incoming_session=="" or current_session~=incoming_session then
        logger.warn("[MiuRead][NetTask] ignored stale auth snapshot")
        return false
    end
    local current_vid=tostring((current.account or {}).vid or (current.cookies or {}).wr_vid or "")
    local incoming_vid=tostring((incoming.account or {}).vid or (incoming.cookies or {}).wr_vid or "")
    if current_vid~="" and incoming_vid~="" and current_vid~=incoming_vid then
        logger.warn("[MiuRead][NetTask] ignored cross-account auth snapshot")
        return false
    end
    self.store:save_auth(incoming)
    return true
end

function Plugin:_cancel_interactive_network(reason)
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    self._interactive_network_key=nil
    if self.interactive_network_async then self.interactive_network_async:cancel(reason or "cancelled") end
    return true
end

function Plugin:_run_interactive_network(key,label,worker,callback,options)
    options=type(options)=="table" and options or {}
    key=tostring(key or label or "interactive")
    label=tostring(label or key)
    if not self:is_online() then
        if options.silent~=true then self:info(_("Network unavailable")) end
        return false,"offline"
    end
    local async=self.interactive_network_async
    if not async or not async:available() then
        if options.silent~=true then self:info("当前设备暂时无法启动后台网络任务，请稍后重试。") end
        return false,"background worker unavailable"
    end
    if async:busy() then
        if tostring(self._interactive_network_key or "")==key then
            if options.silent~=true then self:toast("该网络请求正在进行中",2) end
            return false,"duplicate request"
        end
        self:_cancel_interactive_network("superseded by "..key)
    end
    self._interactive_network_generation=(tonumber(self._interactive_network_generation) or 0)+1
    local generation=self._interactive_network_generation
    self._interactive_network_key=key
    local context=options.context or self:_interactive_network_context()
    local started_at=monotonic_wall_time()
    if options.status_title and options.status_text and options.silent~=true then
        self:status_toast(options.status_title,options.status_text,tonumber(options.status_seconds) or 2)
    end
    logger.info("[MiuRead][NetTask] started","key=",key)
    local started,err=async:run(label,worker,function(result)
        if generation~=self._interactive_network_generation then return end
        self._interactive_network_key=nil
        local network_ms=math.floor((monotonic_wall_time()-started_at)*1000+.5)
        if not self:_interactive_network_context_valid(context) then
            logger.info("[MiuRead][NetTask] stale result dropped","key=",key,"network_ms=",tostring(network_ms))
            return
        end
        local callback_started=monotonic_wall_time()
        if callback then callback(result) end
        local callback_ms=math.floor((monotonic_wall_time()-callback_started)*1000+.5)
        logger.info("[MiuRead][NetTask] completed","key=",key,
            "network_ms=",tostring(network_ms),"callback_ms=",tostring(callback_ms),
            "ok=",tostring(result and result.ok==true))
    end,tonumber(options.timeout) or 35)
    if not started then
        if generation==self._interactive_network_generation then self._interactive_network_key=nil end
        if options.silent~=true then self:info("无法启动后台网络任务：\n"..tostring(err or "未知错误")) end
        return false,err
    end
    return true
end

function Plugin:_request_catalog(book,label,on_ready,options)
    options=type(options)=="table" and options or {}
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then return false,"missing book id" end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    label=tostring(label or "catalog")
    local key="catalog:"..id..":"..label
    return self:_run_interactive_network(key,label,function()
        local HttpChild=require("miuread.http")
        local ReaderChild=require("miuread.reader")
        local DownloaderChild=require("miuread.downloader")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_http=HttpChild:new(child_store)
        local child_reader=ReaderChild:new(child_http,child_store)
        local child_downloader=DownloaderChild:new(child_reader,nil,nil,child_store,child_http)
        local request_ok,catalog,rows=pcall(child_downloader.catalog,child_downloader,id)
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=request_ok,rows=request_ok and rows or nil,
            error=request_ok and nil or tostring(catalog),auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            local message=result and result.error or "章节目录加载失败"
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok~=true then
            local message=tostring(payload.error or "章节目录加载失败")
            if options.on_error then options.on_error(message)
            elseif options.silent~=true then self:info(self:_friendly_remote_error(message,"章节目录加载")) end
            return
        end
        if on_ready then on_ready(type(payload.rows)=="table" and payload.rows or {}) end
    end,{
        context=options.context,timeout=tonumber(options.timeout) or 45,silent=options.silent,
        status_title=options.status_title or "章节",
        status_text=options.status_text or "正在后台读取章节目录…",
        status_seconds=2,
    })
end

function Plugin:_wait_for_network(label,callback,options)
    options=options or {}
    self._network_wait_tokens=self._network_wait_tokens or {}
    label=tostring(label or "default")
    local token=(tonumber(self._network_wait_tokens[label]) or 0)+1
    self._network_wait_tokens[label]=token
    local started=os.time()
    local minimum=math.max(0,tonumber(options.minimum_delay) or 0)
    local maximum=math.max(minimum+1,tonumber(options.max_wait) or 45)
    local interval=math.max(.5,tonumber(options.interval) or 2)
    local function check()
        if not self._network_wait_tokens or self._network_wait_tokens[label]~=token then return end
        local elapsed=os.time()-started
        if elapsed>=minimum and self:is_online() then
            self._network_wait_tokens[label]=nil
            callback(true)
            return
        end
        if elapsed>=maximum then
            self._network_wait_tokens[label]=nil
            callback(false)
            return
        end
        UIManager:scheduleIn(interval,check)
    end
    UIManager:scheduleIn(math.max(.1,tonumber(options.initial_delay) or .1),check)
    return token
end
function Plugin:_cancel_network_waits()
    self._network_wait_tokens={}
end

function Plugin:list(title,items,empty)
    if not items or #items==0 then self:info(empty or _("No items")); return end
    -- When MiuRead home owns the foreground, keep MiuRead-origin lists inside
    -- the MiuRead visual language. Native KOReader lists are still used in
    -- ReaderUI/FileManager contexts and for genuinely native system pages.
    if HomeView.is_shown() and not self:_active_reader_ui() then
        return self:_show_standalone_menu(title,items)
    end
    for _, item in ipairs(items) do
        if type(item)=="table" and (item.sub_item_table_func or item.sub_item_table) then
            return self:_show_standalone_menu(title,items)
        end
    end
    TransientGuard.close_all()
    local menu=Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
    return menu
end
function Plugin:logged_in()
    local a=self.store:auth()
    return tostring(a.api_key or "")~="" and next(a.cookies or {})~=nil
end
function Plugin:require_login()
    if not self:logged_in() then
        self:info(_("Not logged in"))
        return false
    end
    return true
end

local AUTH_CHANNEL_LABELS={
    shelf="书架访问",progress="云端进度读取",download="正文下载",
    annotations="划线与想法访问",read_report="阅读时间上传",
}
local AUTH_CHANNEL_ORDER={"shelf","progress","download","annotations","read_report"}
local function auth_error_code(value)
    if Http.auth_error_code then
        local ok,code=pcall(Http.auth_error_code,value)
        if ok and code then return tostring(code) end
    end
    local text=tostring(value or "")
    return text:match("error_code=([%-]?%d+)") or text:match('"errcode"%s*:%s*([%-]?%d+)') or ""
end
local function auth_row(value)
    return U.merge({state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,last_ok_at=0},
        type(value)=="table" and value or {})
end
function Plugin:_auth_health()
    if self.store.auth_health then return self.store:auth_health() end
    local auth=self.store:auth()
    return U.merge({state="unknown",last_checked_at=0,last_ok_at=0,last_error_at=0,
        last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,channels={}},auth.health or {})
end
function Plugin:_save_auth_health(health)
    local auth=self.store:auth()
    auth.health=health
    self.store:save_auth(auth)
    return health
end
function Plugin:_recompute_auth_health(health)
    health.channels=health.channels or {}
    if not self:logged_in() then health.state="logged_out"; return health end
    local partial,unknown=false,false
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        local state=tostring(auth_row(health.channels[channel]).state)
        if state=="expired" or state=="error" then partial=true
        elseif state~="ok" then unknown=true end
    end
    health.state=partial and "partial" or (unknown and "unknown" or "ok")
    return health
end
function Plugin:_mark_auth_channel_ok(channel)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    health.channels[channel]={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    health.last_checked_at=now
    health.last_ok_at=now
    self:_recompute_auth_health(health)
    if health.state=="ok" then
        health.last_error_at=0
        health.last_error_code=""
        health.last_error_message=""
        health.last_error_channel=""
        health.notice_pending=false
    end
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_channel_error(channel,err,retry_at)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    health.channels[channel]={state="error",checked_at=now,error=U.first_line(err,180),code="",
        failures=(tonumber(previous.failures) or 0)+1,retry_at=tonumber(retry_at) or 0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_message=U.first_line(err,220)
    health.last_error_channel=channel
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_access_denied(channel,err,notify)
    if not self:logged_in() then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local failures=(tonumber(previous.failures) or 0)+1
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local confirmed=failures>=threshold
    local message=U.first_line(err or "HTTP 403",220)
    health.channels[channel]={state=confirmed and "expired" or "error",checked_at=now,
        error=U.first_line(message,180),code="403",failures=failures,retry_at=0,
        last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code="403"
    health.last_error_message=message
    health.last_error_channel=channel
    if notify~=false and confirmed then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature access denied",
        "channel=",tostring(channel),"failures=",tostring(failures),"confirmed=",tostring(confirmed),
        "error=",U.first_line(message,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_mark_auth_problem(channel,err,notify)
    local text=tostring(err or "登录状态暂时不可用")
    if not Http.is_auth_error(text) then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local failures=(tonumber(previous.failures) or 0)+1
    local confirmed=text:find("自动续期失败",1,true)~=nil
        or text:find("renewal=",1,true)~=nil
        or text:find("refreshed=",1,true)~=nil
    if confirmed then failures=math.max(failures,threshold) end
    local expired=failures>=threshold
    local code=auth_error_code(text)
    health.channels[channel]={state=expired and "expired" or "error",checked_at=now,
        error=U.first_line(text,180),code=code,failures=failures,retry_at=0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code=code
    health.last_error_message=U.first_line(text,220)
    health.last_error_channel=channel
    if notify~=false and expired then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature request authentication failed",
        "channel=",tostring(channel),"code=",tostring(code),"failures=",tostring(failures),
        "confirmed=",tostring(confirmed),"error=",U.first_line(text,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_clear_auth_notice_pending()
    local health=self:_auth_health()
    if health.notice_pending~=false then
        health.notice_pending=false
        self:_save_auth_health(health)
    end
end
function Plugin:_show_auth_notice()
    if self._auth_notice_dialog or not self:logged_in() then return end
    local health=self:_auth_health()
    if health.notice_pending~=true then return end
    local channel_key=tostring(health.last_error_channel or "")
    local channel=AUTH_CHANNEL_LABELS[channel_key] or "在线功能"
    local annotation_forbidden=channel_key=="annotations" and tostring(health.last_error_code or "")=="403"
    local notice_text=annotation_forbidden
        and "正文下载仍可使用，但划线与想法接口连续拒绝访问。插件已保留正文、已有批注和下载断点。请重新扫码后再次生成书籍。"
        or "只有此功能受到影响，其他功能会继续运行。插件会保留下载断点和待上传阅读时间，并在后续真实请求中自动重试。多次失败后可重新扫码。"
    local dialog
    local function close()
        if self._auth_notice_dialog==dialog then self._auth_notice_dialog=nil end
        UIManager:close(dialog)
    end
    dialog=ButtonDialog:new{
        title=channel.."暂时异常\n\n"..notice_text,
        title_align="center",
        buttons={
            {{text="查看账号状态",callback=function()
                self:_clear_auth_notice_pending(); close(); self:show_account_status()
            end}},
            {{text="重新扫码",callback=function()
                self:_clear_auth_notice_pending(); close(); self.auth_flow:start()
            end}},
            {{text="稍后处理",callback=function()
                self:_clear_auth_notice_pending(); close()
            end}},
        },
    }
    self._auth_notice_dialog=dialog
    UIManager:show(dialog)
end
function Plugin:_account_status_label()
    if not self:logged_in() then return "未登录 · 点击扫码" end
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    if health.state=="partial" then
        return name~="" and ("部分功能异常 · "..name) or "部分功能异常 · 点击查看"
    end
    if health.state~="ok" then
        return name~="" and ("已登录 · "..name) or "已登录 · 功能待验证"
    end
    return name~="" and ("已登录 · "..name) or "已登录"
end
local function account_channel_text(row)
    row=auth_row(row)
    local state=tostring(row.state or "unknown")
    if state=="ok" then return "正常" end
    if state=="expired" then return "多次验证失败，可重新扫码" end
    if state=="error" then
        local retry_at=tonumber(row.retry_at or 0) or 0
        return retry_at>os.time() and "暂时失败，等待自动重试" or "暂时失败"
    end
    return "将在实际使用时验证"
end
function Plugin:_account_details_text()
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    local lines={"账号状态","","账号："..(name~="" and name or "—")}
    if not self:logged_in() then
        lines[#lines+1]="基础登录：尚未登录"
        return table.concat(lines,"\n")
    end
    lines[#lines+1]="基础登录：正常"
    lines[#lines+1]="在线功能："..(health.state=="ok" and "全部正常" or (health.state=="partial" and "部分暂时异常" or "等待实际使用验证"))
    lines[#lines+1]=""
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        lines[#lines+1]=AUTH_CHANNEL_LABELS[channel].."："..account_channel_text((health.channels or {})[channel])
    end
    lines[#lines+1]=""
    lines[#lines+1]="最后检查："..self:_relative_time(health.last_checked_at)
    if tonumber(health.last_error_at or 0)>0 then
        local channel=AUTH_CHANNEL_LABELS[tostring(health.last_error_channel or "")] or "在线功能"
        local code=tostring(health.last_error_code or "")
        lines[#lines+1]="最近异常："..channel..(code~="" and ("（"..code.."）") or "")
    end
    local sync_status=self.sync and self.sync:status() or {}
    local pending=math.max(0,math.floor(tonumber(sync_status.pending_report_elapsed or 0) or 0))
    if pending>0 then lines[#lines+1]="待上传阅读时间："..tostring(pending).." 秒" end
    lines[#lines+1]=""
    lines[#lines+1]="续期只用于失败后的恢复，不再作为下载或上传的前置条件。"
    return table.concat(lines,"\n")
end
function Plugin:_set_all_auth_ok()
    if not self:logged_in() then return end
    local now=os.time()
    local okrow={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    local health=self:_auth_health()
    health.state="ok"
    health.last_checked_at=now
    health.last_ok_at=now
    health.last_error_at=0
    health.last_error_code=""
    health.last_error_message=""
    health.last_error_channel=""
    health.notice_pending=false
    health.channels={
        shelf=U.copy(okrow),progress=U.copy(okrow),download=U.copy(okrow),
        annotations=U.copy(okrow),read_report=U.copy(okrow),
    }
    self:_save_auth_health(health)
end
function Plugin:check_account_status()
    if not self:logged_in() then self.auth_flow:start(); return end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    local context=self:_interactive_network_context()
    self:_run_interactive_network("account-status","account-status-check",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_api=ApiChild:new(HttpChild:new(child_store),child_store)
        local ok,value=pcall(child_api.shelf,child_api,{retries=0,timeout={7,12}})
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=ok,value=ok and value or nil,error=ok and nil or tostring(value),
            auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            self:_mark_auth_channel_error("shelf",result and result.error or "账号检查失败")
            self:show_account_status()
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok==true then
            self:_mark_auth_channel_ok("shelf")
        elseif Http.is_auth_error(payload.error) then
            self:_mark_auth_problem("shelf",payload.error,false)
        else
            self:_mark_auth_channel_error("shelf",payload.error or "账号检查失败")
        end
        self:show_account_status()
    end,{context=context,timeout=24,status_title="账号状态",status_text="正在后台检查基础账号和书架访问"})
end
function Plugin:confirm_logout()
    if not self:logged_in() then self:toast("当前没有登录微信读书账号",3); return end
    local downloading=self.download_task and self.download_task:busy()
    local text="退出当前微信读书账号？\n\n已下载书籍、本地阅读记录和下载断点都会保留。"
    if downloading then text=text.."\n\n当前下载会停止；重新登录后可从断点继续。" end
    UIManager:show(ConfirmBox:new{text=text,ok_text="退出登录",ok_callback=function()
        if downloading and self.download_task then self.download_task:cancel() end
        self.auth_flow:cancel()
        self:_cancel_interactive_network("logout")
        self._auth_transitioning=true
        if self.sync and self.sync.invalidate_login_session then
            pcall(self.sync.invalidate_login_session,self.sync,"logout")
        end
        if self.store.clear_login_bound_sessions then self.store:clear_login_bound_sessions("logout") end
        if self.store.clear_account_shelf_cache then self.store:clear_account_shelf_cache() end
        self.store:clear_auth()
        self._auth_transitioning=false
        self:status_toast("账号","已退出登录",4)
    end})
end

function Plugin:on_auth_replacing(_old_auth,_new_auth)
    self:_cancel_interactive_network("auth replacing")
    self._auth_transitioning=true
    if self.sync and self.sync.invalidate_login_session then
        self.sync:invalidate_login_session("new_login")
    end
    if self.store.clear_login_bound_sessions then self.store:clear_login_bound_sessions("new_login") end
    if self.store.clear_account_shelf_cache then self.store:clear_account_shelf_cache() end
end

function Plugin:show_account_status()
    if HomeView.is_shown() and not self:_active_reader_ui() then
        local auth=self.store:auth()
        local health=self:_auth_health(); self:_recompute_auth_health(health)
        local account=type(auth.account)=="table" and auth.account or {}
        local name=U.trim(tostring(account.name or ""))
        local rows={
            {text="账号",post_text=name~="" and name or "—",enabled=false},
            {text="基础登录",post_text=self:logged_in() and "正常" or "尚未登录",enabled=false},
        }
        if self:logged_in() then
            local online_label=health.state=="ok" and "全部正常" or (health.state=="partial" and "部分暂时异常" or "等待实际使用验证")
            rows[#rows+1]={text="在线功能",post_text=online_label,enabled=false}
            for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
                rows[#rows+1]={text=AUTH_CHANNEL_LABELS[channel],post_text=account_channel_text((health.channels or {})[channel]),enabled=false}
            end
            rows[#rows+1]={text="最后检查",post_text=self:_relative_time(health.last_checked_at),enabled=false}
            rows[#rows+1]={text="账号操作",separator=true,enabled=false}
            rows[#rows+1]={text="重新检查状态",callback=function() self:check_account_status() end}
            rows[#rows+1]={text="重新扫码登录",callback=function() self.auth_flow:start() end}
            rows[#rows+1]={text="退出登录",callback=function() self:confirm_logout() end}
        else
            rows[#rows+1]={text="账号操作",separator=true,enabled=false}
            rows[#rows+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
        end
        return self:_show_miuread_menu("账号状态",rows,{page_size=7})
    end

    local dialog
    local buttons={}
    if self:logged_in() then
        buttons[#buttons+1]={{text="重新检查状态",callback=function() UIManager:close(dialog); self:check_account_status() end}}
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
        buttons[#buttons+1]={{text="退出登录",callback=function()
            UIManager:close(dialog); self:confirm_logout()
        end}}
    else
        buttons[#buttons+1]={{text="扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    end
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_account_details_text(),title_align="left",buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_auth_success(name)
    self._auth_transitioning=false
    local health=self:_auth_health()
    local web_ready=(((health.channels or {}).download or {}).state=="ok")
    if self._auth_notice_dialog then
        pcall(function() UIManager:close(self._auth_notice_dialog) end)
        self._auth_notice_dialog=nil
    end
    local resumed=false
    local state=self.store:download_state()
    if state.status=="failed" and state.auth_required==true and type(state.book)=="table" then
        state.status="interrupted"
        state.error="登录已恢复，正在继续下载。"
        state.auth_required=nil
        state.updated_at=os.time()
        self.store:save_download_state(state)
        local book,options=U.copy(state.book),U.copy(state.options or {})
        UIManager:scheduleIn(1.0,function()
            if not self._download_runtime and not (self.download_task and self.download_task:busy()) then
                self:download(book,options,false,nil,true)
            end
        end)
        resumed=true
    else
        UIManager:scheduleIn(.8,function() self:_start_next_queued_download() end)
    end
    if self.sync and self.sync.on_auth_restored then
        local ok,value=pcall(self.sync.on_auth_restored,self.sync)
        resumed=resumed or (ok and value==true)
    end
    local title="账号登录成功"
    local detail=tostring(name or "微信读书账号")
        ..(resumed and " · 正在恢复后台任务" or (web_ready and "" or " · 在线功能将在实际使用时验证"))
    self:status_toast(title,detail,5)
end
function Plugin:_download_menu_text()
    if self:_has_download_status() then
        return "下载管理 · "..tostring(self:_download_status_label()):gsub("^后台下载%s*[：·]?%s*","")
    end
    local queue=self.store:download_queue()
    return #queue>0 and ("下载管理 · "..tostring(#queue).." 项等待") or "下载管理"
end
function Plugin:_sync_menu_text()
    return "阅读同步 · "..tostring(self:progress_sync_label())
end
function Plugin:home_menu()
    sync_home_session()
    self:maybe_auto_check_update(false)
    local account={text=self:_account_status_label(),callback=function() self:show_account_status() end}
    local out={}
    if self:_home_enabled() then
        out[#out+1]={text="返回觅阅主页",callback=self:safe("home-ui",function() self:_return_to_configured_home() end)}
    end
    out[#out+1]={text="我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)}
    local trailing={
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        account,
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_native_koreader_menu() end},
    }
    for _,row in ipairs(trailing) do out[#out+1]=row end
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    if self:logged_in() and health.state=="partial" then
        for index,row in ipairs(out) do
            if row==account then table.remove(out,index); break end
        end
        table.insert(out,1,account)
    end
    return out
end

function Plugin:_confirm_current_book_rebuild(book,annotations)
    self:_open_book_stream(book)
end

function Plugin:current_book_download_menu(book)
    return {
        {text="下一章",callback=function() self:_stream_go_next_chapter() end},
    }
end

function Plugin:current_book_rebuild_menu(book)
    return {
        {text="检查与修复本书",callback=function() self:repair_current_book() end},
        {text="重新生成纯净版",callback=function() self:_confirm_current_book_rebuild(book,false) end},
        {text="重新生成划线与想法版",callback=function() self:_confirm_current_book_rebuild(book,true) end},
    }
end

function Plugin:current_book_menu()
    local r=self:_current_book_record()
    if not r or not r.book then return {{text="未识别当前觅阅书籍",enabled=false}} end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    return {
        {text="书籍详情",callback=function() self:book_details(b) end},
        {text="下一章",callback=function() self:_stream_go_next_chapter() end},
        {text="目录",callback=function() self:_show_reader_toc(function() self:show_reader_quick_panel() end) end},
    }
end

function Plugin:current_mp_article_menu(mp_context)
    local account={bookId=mp_context.bookId,title=mp_context.account_title or "公众号",author="公众号"}
    local target
    for _,article in ipairs(self.mp:cached_articles(mp_context.bookId) or {}) do
        if tostring(article.reviewId or article.originalId or "")==tostring(mp_context.reviewId or "") then
            target=article; break
        end
    end
    if not target then return {{text="当前文章信息不可用",enabled=false}} end
    local article=U.copy(target)
    return {
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(account,article,true) end},
        {text="删除本篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的本地缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(account.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
            end})
        end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_cache_menu(account,self.mp:cached_articles(account.bookId)) end},
    }
end

function Plugin:reader_menu()
    self:maybe_auto_check_update(false)
    local current_path=self:_current_document_path()
    local mp_context=self.mp and self.mp:identify_path(current_path) or nil
    if mp_context then
        local desktop=self:_home_enabled()
        local out={
            {text="返回文章列表",callback=self:safe("mp-back",function() self:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=self:safe("mp-prev",function() self:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=self:safe("mp-next",function() self:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return self:current_mp_article_menu(mp_context) end},
        }
        if desktop then out[#out+1]={text="全部阅读功能",callback=function() self:show_reader_control_center("reading") end} end
        out[#out+1]={text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end}
        if not desktop then out[#out+1]={text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end} end
        return out
    end
    local desktop=self:_home_enabled()
    local out={
        {text=desktop and "退出阅读并返回觅阅主页" or "返回书架",callback=self:safe("shelf",function()
            if desktop then self:return_to_miuread_home()
            else self:show_shelf(false,false,"account") end
        end)},
    }
    if desktop then
        out[#out+1]={text="全部阅读功能",callback=function() self:show_reader_control_center("reading") end}
    end
    out[#out+1]={text="当前书籍",sub_item_table_func=function() return self:current_book_menu() end}
    out[#out+1]={text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end}
    out[#out+1]={text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end}
    if not desktop then
        out[#out+1]={text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end}
    end
    return out
end

function Plugin:account_menu()
    local out={
        {text="账号状态",callback=function() self:show_account_status() end},
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=self:safe("login",function() self.auth_flow:start() end)},
    }
    if self:logged_in() then
        out[#out+1]={text="退出登录",callback=function() self:confirm_logout() end}
    end
    return out
end

function Plugin:_save_shelf_context(section,mp_mode)
    section=section=="generated" and "generated" or "account"
    local p=self.store:preferences()
    local changed=p.shelf_section~=section
    p.shelf_section=section
    if section=="account" and mp_mode~=nil then
        local kind=mp_mode==true and "mp" or "books"
        if p.account_shelf_kind~=kind then changed=true end
        p.account_shelf_kind=kind
    end
    if changed then self.store:save_preferences(p) end
    self._last_shelf_section=section
    if section=="account" then self._last_shelf_mode=mp_mode==true end
end


function Plugin:_friendly_remote_error(err, context)
    local text=tostring(err or "未知错误")
    local lower=text:lower()
    if text:find("[MiuReadMPNoAccount]",1,true) then
        return "微信读书书架暂时没有返回可用的公众号。"
    end
    if text:find("[MiuReadMPInvalidAccount]",1,true) then
        return "公众号信息无效，请刷新微信读书书架。"
    end
    if lower:find("参数格式错误",1,true) or lower:find("params error",1,true)
        or lower:find("parameter format",1,true) then
        return "公众号数据暂时无法读取，请刷新后重试。"
    end
    if Http.is_auth_error(text) or lower:find("api key",1,true)
        or lower:find("authorization",1,true) then
        return "登录凭证已失效或被拒绝，请在账户设置中重新扫码登录。"
    end
    if lower:find("timeout",1,true) then return "网络请求超时，请检查 Wi-Fi 后重试。" end
    if lower:find("network request failed",1,true) then return "网络连接失败，请检查 Wi-Fi 后重试。" end
    if lower:find("%.lua:%d+:") or lower:find("stack traceback",1,true) then
        return tostring(context or "请求").."失败，请稍后重试。"
    end
    return tostring(context or "请求").."失败：\n"..U.first_line(text,120)
end

function Plugin:_refresh_shelf_async(on_ready,silent)
    local function fail(err)
        if Http.is_auth_error(err) then self:_mark_auth_problem("shelf",err,true) end
        local message=self:_friendly_remote_error(err,"书架加载")
        if on_ready then
            on_ready({}, {}, message)
        elseif not silent or message:find("重新扫码登录",1,true) then
            self:toast(message,4)
        end
        return false,err
    end
    if not self:is_online() then
        return fail("network request failed: offline")
    end

    local async_available=self.shelf_async and self.shelf_async:available()
    if async_available then
        if self.shelf_async:busy() then return fail("书架正在刷新，请稍后重试。") end
    elseif self._shelf_main_busy then
        return fail("书架正在刷新，请稍后重试。")
    end

    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    local generation=self._shelf_refresh_generation
    local function succeed(data,mode)
        if generation~=self._shelf_refresh_generation then return end
        self:_mark_auth_channel_ok("shelf")
        local books,mp=self.library:normalize(data or {})
        self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
        logger.info("[MiuRead][Shelf] refresh completed","mode=",tostring(mode),
            "books=",tostring(#books),"mp=",tostring(#mp))
        if on_ready then on_ready(books,mp,nil) end
    end

    if not async_available then
        self._shelf_main_busy=true
        local loading
        if on_ready and not silent then
            loading=InfoMessage:new{text="正在加载书架……"}
            UIManager:show(loading)
        end
        logger.info("[MiuRead][Shelf] refresh started","mode=direct")
        UIManager:scheduleIn(.05,function()
            local handled,unexpected=xpcall(function()
                if generation~=self._shelf_refresh_generation then return end
                local ok,data=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
                if not ok then error(tostring(data)) end
                if loading then pcall(function() UIManager:close(loading) end); loading=nil end
                succeed(data,"direct")
            end,debug.traceback)
            self._shelf_main_busy=false
            if loading then pcall(function() UIManager:close(loading) end) end
            if not handled and generation==self._shelf_refresh_generation then fail(unexpected) end
        end)
        return true
    end

    local auth=U.copy(self.store:auth())
    logger.info("[MiuRead][Shelf] refresh started","mode=subprocess")
    local started,err=self.shelf_async:run("shelf_refresh",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        return ApiChild:new(HttpChild:new(child_store),child_store):shelf({retries=1,timeout={10,18}})
    end,function(result)
        if generation~=self._shelf_refresh_generation then return end
        if result and result.ok==true then
            succeed(result.value or {},"subprocess")
            return
        end
        fail(result and result.error or "未知错误")
    end,32)
    if not started then return fail(err or "无法启动异步任务") end
    return true
end

function Plugin:load_shelf(cb,force_remote,section)
    section=section=="generated" and "generated" or "account"
    local cached_books,cached_mp,cached_updated=self.library:cached()
    local library_snapshot=self.store:library()
    local local_books,local_mp=self.library:local_books(library_snapshot,self.store:get("sessions",{}))
    local cached_count=#cached_books+#cached_mp
    local local_count=#local_books+#local_mp
    local cache_age=math.max(0,os.time()-(tonumber(cached_updated) or 0))
    local background_available=self.shelf_async and self.shelf_async:available()

    if not force_remote then
        if cached_count>0 then
            cb(cached_books,cached_mp,nil)
            local refresh_after=background_available and SHELF_CACHE_TTL or SHELF_DIRECT_CACHE_TTL
            if self:logged_in() and cache_age>refresh_after then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
        if local_count>0 then
            if section=="account" and self:logged_in() then
                self:toast("正在加载账号书架…",2)
                self:_refresh_shelf_async(function(books,mp,err)
                    cb(books,mp,err)
                end,false)
                return
            end
            self:toast("账号书架暂未加载，可先查看“已生成书籍”。",3)
            cb({}, {}, "账号书架正在后台加载。")
            if self:logged_in() then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
    end
    if not self:logged_in() then
        cb(cached_books,cached_mp,"当前未登录，仅使用已缓存的账号书架和已生成书籍。")
        return
    end
    self:_refresh_shelf_async(function(books,mp,err)
        if err and cached_count>0 then cb(cached_books,cached_mp,err) else cb(books,mp,err) end
    end,false)
end

function Plugin:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_status_known)
    if remote_books==nil or remote_mp==nil then remote_books,remote_mp=self.library:cached() end
    local library_snapshot=self.store:library()
    local sessions=self.store:get("sessions",{})
    local local_books,local_mp=self.library:local_books(library_snapshot,sessions)
    section=section=="generated" and "generated" or "account"
    if section=="generated" then
        -- Public-account articles are standalone HTML files and no longer
        -- participate in the generated EPUB shelf.
        local rows=self.library:generated_rows(remote_books or {},{},local_books,{},remote_status_known)
        for _,row in ipairs(rows) do row.shelf_section="generated" end
        return rows
    end
    local remote_rows=mp_mode and (remote_mp or {}) or (remote_books or {})
    local local_rows=mp_mode and local_mp or local_books
    local rows=self.library:account_rows(remote_rows,local_rows)
    for _,row in ipairs(rows) do row.shelf_section="account" end
    return rows
end

function Plugin:_prepare_shelf_rows(rows)
    local cover_index=self.store:get("cover_index",{})
    for id,path in pairs(self._cover_index_pending or {}) do cover_index[id]=path end
    local cover_index_changed=false
    local download_state=self:_download_state()
    for _,b in ipairs(rows or {}) do
        b.download_active=false
        b.download_progress=nil
        local id=tostring(b.bookId or b.book_id or "")
        if id~="" then
            local session=self.store:session(id) or {}
            local snapshot=type(session.local_position_snapshot)=="table" and session.local_position_snapshot or {}
            local effective=tonumber(session.progress_local_percent)
                or (snapshot.safe==true and tonumber(snapshot.progress) or nil)
                or tonumber(session.verified_local_percent)
            if effective~=nil then b.progress=math.max(0,math.min(100,effective)) end
        end
        local removed
        b.cover_path,removed=self.library:cached_cover_path(b.bookId,cover_index)
        if removed then
            cover_index_changed=true
            if self._cover_index_pending then self._cover_index_pending[tostring(b.bookId)]=nil end
        end
        if b.annotation_pending==true or b.annotation_fallback==true then
            b.download_status=DownloadResult.shelf_status({
                annotation_pending=b.annotation_pending==true,
                annotation_fallback=b.annotation_fallback==true,
            },false)
        else
            b.download_status=nil
        end
        if tostring(download_state.book_id or "")~="" and tostring(download_state.book_id)==tostring(b.bookId or "") then
            if download_state.status=="active" then
                b.download_active=true
                b.download_progress=math.max(0,math.min(1,self:_download_percent(download_state)/100))
                b.download_status=nil
            elseif download_state.status=="pending_install" then
                b.download_status=DownloadResult.shelf_status(download_state,true)
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
            elseif download_state.status=="annotation_pending" then b.download_status="批注待修复"
            elseif download_state.status=="completed" and download_state.annotation_fallback==true then b.download_status="已生成"
            elseif download_state.status=="completed" and download_state.seen~=true then b.download_status="刚刚生成完成" end
        end
        b.status_text=self:_shelf_status_text(b)
    end
    if cover_index_changed then self.store:set("cover_index",cover_index) end
    return rows
end

function Plugin:_home_mutate_book_rows(book_id,mutator)
    book_id=tostring(book_id or "")
    if book_id=="" or type(mutator)~="function" then return false end
    local changed=false
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do
            if tostring(book.bookId or book.book_id or "")==book_id then
                mutator(book)
                changed=true
            end
        end
    end
    return changed
end

function Plugin:_home_update_download_card(runtime,state)
    local book_id=tostring(runtime and runtime.book and runtime.book.bookId or state and state.book_id or "")
    if book_id=="" then return false end
    local ratio=math.max(0,math.min(1,self:_download_percent(state)/100))
    local changed=self:_home_mutate_book_rows(book_id,function(book)
        book.download_active=true
        book.download_progress=ratio
        book.download_status=nil
        book.status_text=self:_shelf_status_text(book)
    end)
    if changed and HomeView.is_shown() and not self:_active_reader_ui() then
        local updated=HomeView.update_book(book_id)
        logger.info("[MiuRead][HomeDownload] card update",
            "book=",book_id,"percent=",tostring(math.floor(ratio*100+.5)),
            "visible=",tostring(updated==true))
        return updated==true
    end
    return false
end

function Plugin:_flush_cover_index()
    if self._cover_index_flush_task then
        UIManager:unschedule(self._cover_index_flush_task)
        self._cover_index_flush_task=nil
    end
    local pending=self._cover_index_pending or {}
    if not next(pending) then return end
    local index=self.store:get("cover_index",{})
    for id,path in pairs(pending) do index[id]=path end
    self.store:set("cover_index",index)
    self._cover_index_pending={}
end

function Plugin:_remember_cover_path(id,path)
    if not id or not path then return end
    self._cover_index_pending=self._cover_index_pending or {}
    self._cover_index_pending[tostring(id)]=path
    if self._cover_index_flush_task then return end
    local task
    task=function()
        if self._cover_index_flush_task~=task then return end
        self._cover_index_flush_task=nil
        self:_flush_cover_index()
    end
    self._cover_index_flush_task=task
    UIManager:scheduleIn(.75,task)
end

function Plugin:_shelf_status_text(b)
    if b.download_status and b.download_status~="" then return b.download_status end
    if tostring(b.content_type or "")=="mp_account" then return "公众号" end
    local state
    if b.shelf_section=="generated" then
        if b.remote_status_known~=true then state="本地书籍"
        elseif b.in_account_shelf==true then state="账号书架中"
        else state="已移出账号书架 · 本地可读" end
        if b.hasClean and b.hasNotes then state=state.." · 两个版本"
        elseif b.hasNotes then state=state.." · 划线与想法版"
        elseif b.hasClean then state=state.." · 纯净版" end
    else
        state=b.downloaded and "已生成" or "未生成"
        if b.isTop then state="置顶 · "..state end
    end
    local progress=tonumber(b.progress or 0) or 0
    if progress>=100 then return state.." · 已读完" end
    if progress>0 then return state.." · "..tostring(math.floor(progress+.5)).."%" end
    return state
end

function Plugin:_shelf_select(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    self:_open_book_stream(b)
end
function Plugin:_shelf_hold(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    self:_home_hold_book(b)
end

function Plugin:show_shelf_search_dialog(mp_mode,source_rows,section)
    section=section=="generated" and "generated" or "account"
    if not source_rows then
        local remote_books,remote_mp=self.library:cached()
        source_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,#remote_books+#remote_mp>0)
    end
    local d
    d=InputDialog:new{
        title=section=="generated" and "搜索已生成书籍" or "搜索账号书架",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q=="" then return end
                local results=self.library:search(source_rows,q)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_prepare_shelf_rows(results)
                local prefs=self.store:preferences()
                local show_covers=self:_shelf_covers_enabled(prefs)
                if show_covers then self:_begin_cover_guard("shelf_search_open") end
                local ok,view=pcall(ShelfView.show,{
                    title=(section=="generated" and "已生成书籍 · " or "账号书架 · ").."搜索 “"..q.."” · "..tostring(#results).."本",
                    books=results,
                    show_actions=false,
                    show_tabs=false,
                    show_covers=show_covers,
                    on_select=function(b) self:_shelf_select(b) end,
                    on_hold=function(b) self:_shelf_hold(b) end,
                    on_page_changed=function(page,first,last,current)
                        if show_covers then self:_on_shelf_page(results,current,page,first,last) end
                    end,
                    on_rendered=function() self:_clear_cover_guard() end,
                    on_close=function()
                        self:_cancel_cover_loading()
                        collectgarbage("step",120)
                    end,
                })
                if ok and view then return end
                self:_clear_cover_guard()
                logger.warn("[MiuRead][ShelfSearch] custom view unavailable",tostring(view))
                local items={}
                for _,book in ipairs(results) do
                    local b=book
                    items[#items+1]={
                        text=(b.downloaded and "✓ " or "")..tostring(b.title or "未命名"),
                        post_text=(tostring(b.author or "")~="" and (tostring(b.author).." · ") or "")..self:_shelf_status_text(b),
                        callback=function() self:_shelf_select(b) end,
                    }
                end
                self:list("搜索书架 · "..q,items)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end
function Plugin:_cancel_cover_loading()
    self._cover_generation=(tonumber(self._cover_generation) or 0)+1
    if self.cover_async then self.cover_async:cancel("shelf page changed") end
    if self._cover_refresh_task then
        UIManager:unschedule(self._cover_refresh_task)
        self._cover_refresh_task=nil
    end
    self:_clear_cover_guard()
end
function Plugin:_schedule_shelf_cover_refresh(view,generation,delay)
    if self._cover_refresh_task then return end
    local task
    task=function()
        if self._cover_refresh_task~=task then return end
        self._cover_refresh_task=nil
        if generation~=self._cover_generation or not view or view._miu_closed then return end
        self:_begin_cover_guard("shelf_cover_refresh")
        view._suppress_page_callback=true
        local ok,err=pcall(view.updateItems,view,nil,true)
        view._suppress_page_callback=false
        if ok then
            self:_clear_cover_guard()
            collectgarbage("step",160)
        else
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] shelf refresh failed",tostring(err))
        end
    end
    self._cover_refresh_task=task
    UIManager:scheduleIn(delay or .18,task)
end
function Plugin:_schedule_cover_continue(rows,view,page,first,last,generation,index,delay)
    UIManager:scheduleIn(delay or .06,function()
        self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    end)
end
function Plugin:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    index=index or first
    if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
    if index>last then return end
    local book=rows[index]
    if not book or not book.cover or book.cover=="" then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    local cached=book.cover_path or self.library:cached_cover_path(book.bookId)
    if cached then
        book.cover_path=cached
        local changed=false
        for _,entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id)==tostring(book.bookId) then
                if entry.cover_path~=cached then entry.cover_path=cached; changed=true end
                break
            end
        end
        if changed then self:_schedule_shelf_cover_refresh(view,generation,.12) end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    if not self.cover_async then return end
    if self.cover_async:busy() then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.25)
        return
    end
    local background_available=self.cover_async:available()
    local download_options=background_available
        and {retries=1,timeout={8,15}}
        or {retries=0,timeout={4,7}}
    local book_copy={bookId=book.bookId,cover=book.cover}
    local worker
    if background_available then
        local covers_dir=self.store.covers_dir
        worker=function()
            local HttpChild=require("miuread.http")
            local LibraryChild=require("miuread.library")
            local store={
                covers_dir=covers_dir,
                auth=function() return {cookies={}} end,
                save_auth=function() end,
                get=function(_,_,default) return default end,
                set=function() end,
            }
            local http=HttpChild:new(store)
            local options={
                retries=download_options.retries,
                timeout=download_options.timeout,
                persist_index=false,
                skip_index_lookup=true,
            }
            return LibraryChild:new(nil,http,store):cache_cover(book_copy,options)
        end
    else
        worker=function() return self.library:cache_cover(book_copy,download_options) end
    end
    local started=self.cover_async:run("shelf_cover_page",worker,function(result)
        if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
        if result and result.ok and result.value then
            if background_available then self:_remember_cover_path(book.bookId,result.value) end
            book.cover_path=result.value
            for _,entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id)==tostring(book.bookId) then entry.cover_path=result.value; break end
            end
            self:_schedule_shelf_cover_refresh(view,generation,.18)
        elseif result and result.error then
            logger.warn("[MiuRead][Cover] download failed","book_id=",tostring(book.bookId),
                "error=",U.first_line(result.error,160))
        end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,background_available and .06 or .18)
    end,background_available and 35 or 14)
    if not started then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.3)
    end
end
function Plugin:_on_shelf_page(rows,view,page,first,last)
    self:_cancel_cover_loading()
    local generation=self._cover_generation
    self:_cache_shelf_page_covers(rows,view,page,first,last,generation,first)
end
function Plugin:_cancel_shelf_refresh(reason)
    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    self._shelf_main_busy=false
    if self.shelf_async then self.shelf_async:cancel(reason or "shelf closed") end
end

function Plugin:_close_current_shelf()
    local view=self._shelf_view
    self._shelf_view=nil
    self:_cancel_cover_loading()
    self:_cancel_shelf_refresh("shelf replaced")
    if view and not view._miu_closed then pcall(function() UIManager:close(view) end) end
end
function Plugin:_reopen_shelf(mp_mode,section,force_remote)
    section=section=="generated" and "generated" or "account"
    self:_save_shelf_context(section,mp_mode)
    UIManager:scheduleIn(0,function()
        self:_close_current_shelf()
        self:show_shelf(mp_mode,force_remote,section)
    end)
end

function Plugin:_shelf_tabs(selected)
    return {
        {id="books",label="书籍",callback=function()
            if selected~="books" then self:_reopen_shelf(false,"account") end
        end},
        {id="mp",label="公众号",callback=function()
            if selected~="mp" then self:_reopen_shelf(true,"account") end
        end},
        {id="generated",label="已生成",callback=function()
            if selected~="generated" then self:_reopen_shelf(false,"generated") end
        end},
    }
end

function Plugin:_refresh_mp_accounts(on_done,silent)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if on_done then on_done(nil,"网络不可用") end
        if not silent then self:info(_("Network unavailable")) end
        return false
    end
    if self.mp_async:busy() then
        if on_done then on_done(nil,"另一项公众号任务正在进行中") end
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在获取公众号列表",2) end
    local started,err=self.mp_async:run("mp-accounts",function()
        return self.mp:accounts({force=true})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
        else
            local cached=self.mp:cached_accounts()
            local message=result and result.error or "公众号列表加载失败"
            logger.warn("[MiuRead][MP] account list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
        end
    end,60)
    if not started then
        if on_done then on_done(nil,err or "无法启动公众号列表任务") end
        if not silent then self:info(self:_friendly_remote_error(err or "无法启动公众号列表任务","公众号列表加载")) end
    end
    return started
end

function Plugin:show_mp_shelf(force_remote)
    self:_save_shelf_context("account", true)

    local function render(accounts, remote_error)
        accounts = type(accounts) == "table" and accounts or {}
        local rows = {}
        for _, account in ipairs(accounts) do
            local row = self:_mp_normalize_book(account)
            if Protocol.is_mp_account(row.bookId) then
                row.content_type = "mp_account"
                row.author = row.author ~= "" and row.author or "公众号"
                row.status_text = "点击查看文章"
                row.show_cover = false
                rows[#rows + 1] = row
            end
        end

        local function refresh()
            self:_refresh_mp_accounts(function(value, err)
                if value then self:show_mp_shelf(false)
                elseif err then self:info(self:_friendly_remote_error(err, "公众号列表加载")) end
            end, false)
        end

        local function search()
            local dialog
            dialog = InputDialog:new{
                title="搜索公众号", input="",
                buttons={{
                    {text=_("Cancel"), id="close", callback=function() UIManager:close(dialog) end},
                    {text=_("Search"), is_enter_default=true, callback=function()
                        local query=U.trim(dialog:getInputText()):lower()
                        UIManager:close(dialog)
                        if query=="" then return end
                        local found={}
                        for _, row in ipairs(rows) do
                            local hay=(tostring(row.title or "").." "..tostring(row.author or "")):lower()
                            if hay:find(query,1,true) then found[#found+1]=row end
                        end
                        if #found==0 then self:info("没有找到相关公众号")
                        elseif #found==1 then self:mp_account(found[1])
                        else
                            local items={}
                            for _, row in ipairs(found) do
                                local account=row
                                items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
                            end
                            self:list("公众号 · 搜索结果",items)
                        end
                    end},
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        if #rows == 0 then
            local items={
                {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
                {text="公众号",enabled=false},
                {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
                {text="刷新公众号",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then
                items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
            end
            if remote_error then
                items[#items+1]={text=self:_friendly_remote_error(remote_error,"公众号列表加载"),enabled=false}
            else
                items[#items+1]={text="仅显示微信读书书架返回的公众号",enabled=false}
            end
            self:list("我的书架 · 公众号",items,"暂未识别到公众号")
            return
        end

        local ok, view = pcall(ShelfView.show, {
            title="我的书架 · 公众号 · "..tostring(#rows).."个",
            books=rows, selected_tab="mp", tabs=self:_shelf_tabs("mp"),
            show_covers=false, on_search=search, on_refresh=refresh,
            on_select=function(book) self:mp_account(book) end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
            end,
        })
        if ok and view then self._shelf_view=view; return end
        logger.warn("[MiuRead][MP] shelf view unavailable",tostring(view))
        local items={
            {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
            {text="公众号",enabled=false},
            {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
            {text="搜索",callback=search},
            {text="刷新公众号",callback=refresh},
        }
        for _,row in ipairs(rows) do
            local account=row
            items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
        end
        self:list("我的书架 · 公众号",items)
    end

    local cached=self.mp:cached_accounts()
    if not force_remote and #cached>0 then
        render(cached,nil)
        if self.mp:accounts_stale() and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_accounts(function(value)
                if value and self._shelf_view and not self._shelf_view._miu_closed then
                    self:_reopen_shelf(true,"account")
                end
            end,true)
        end
        return
    end
    self:_refresh_mp_accounts(function(value,err)
        if value then render(value,err) else render(cached,err) end
    end,false)
end

function Plugin:show_shelf(mp_mode,force_remote,section)
    local prefs=self.store:preferences()
    section=section or prefs.shelf_section or "account"
    section=section=="generated" and "generated" or "account"
    if mp_mode==nil then mp_mode=tostring(prefs.account_shelf_kind or "books")=="mp" end
    self:_save_shelf_context(section,mp_mode)
    if section=="account" and mp_mode==true then
        return self:show_mp_shelf(force_remote==true)
    end
    self:load_shelf(function(remote_books,remote_mp,remote_error)
        local remote_known=remote_error==nil and (self:logged_in() or (#remote_books+#remote_mp)>0)
        local all_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_known)
        local rows=self.library:sort_filter(all_rows,{section=section})
        self:_prepare_shelf_rows(rows)
        local show_covers=self:_shelf_covers_enabled(self.store:preferences())
        local title=section=="generated" and "已生成书籍" or (mp_mode and "公众号" or "账号书架")
        if remote_error and #rows>0 then self:toast(remote_error,3) end
        local function open_account()
            if section=="account" and not mp_mode then return end
            self:_reopen_shelf(false,"account")
        end
        local function open_generated()
            if section=="generated" then return end
            self:_reopen_shelf(mp_mode,"generated")
        end
        local function refresh()
            if not self:logged_in() then self.auth_flow:start(); return end
            self:_reopen_shelf(mp_mode,section,true)
        end
        if #rows==0 then
            local items={
                {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
                {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
                {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
                {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
                {text="刷新书架",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end} end
            if remote_error then table.insert(items,3,{text=remote_error,enabled=false}) end
            self:list(title,items,"书架为空")
            return
        end
        if show_covers then self:_begin_cover_guard("shelf_open") end
        local ok,view=pcall(ShelfView.show,{
            title="我的书架 · "..(section=="generated" and "已生成" or "书籍").." · "..tostring(#rows).."本",
            books=rows,selected_tab=section=="generated" and "generated" or "books",
            tabs=self:_shelf_tabs(section=="generated" and "generated" or "books"),
            show_covers=show_covers,
            on_search=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end,
            on_refresh=refresh,on_select=function(b) self:_shelf_select(b) end,
            on_hold=function(b) self:_shelf_hold(b) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
                self:_cancel_cover_loading(); self:_cancel_shelf_refresh("shelf closed"); collectgarbage("step",160)
            end,
        })
        if ok and view then self._shelf_view=view; return end
        self:_clear_cover_guard()
        logger.warn("[MiuRead][Shelf] custom view unavailable",tostring(view))
        local items={
            {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
            {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
            {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
            {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
            {text="刷新书架",enabled=self:logged_in(),callback=refresh},
        }
        for _,b in ipairs(rows) do local book=b; items[#items+1]={text=book.title,post_text=self:_shelf_status_text(book),callback=function() self:_shelf_select(book) end} end
        self:list(title,items)
    end,force_remote,section)
end


function Plugin:_home_preferences()
    local preferences=self.store:preferences()
    preferences.home_ui=type(preferences.home_ui)=="table" and preferences.home_ui or {}
    local home=preferences.home_ui
    local changed=false
    if home.enabled==nil then home.enabled=true; changed=true end
    local old_layout_version=tonumber(home.layout_version) or 0
    if old_layout_version<20 then
        home.layout_version=20
        home.layout_style=home.layout_style=="compact" and "compact" or "desk"
        -- Keep the selected mode and page positions while upgrading the home
        -- structure. Removed experimental widget fields are no longer read.
        home.widgets=nil
        home.preset=nil
        home.goal_minutes=nil
        home.swipe_quick=nil
        home.initial_page=nil
        changed=true
    end
    if old_layout_version<23 then
        home.layout_version=23
        changed=true
    end
    if (tonumber(home.performance_defaults_version) or 0)<1 then
        -- Historical performance defaults are no longer allowed to change a
        -- feature switch during ordinary startup. The current local-library
        -- policy is normalized below from the user's saved choice.
        home.performance_defaults_version=1
        changed=true
    end
    if (tonumber(home.network_metadata_defaults_version) or 0)<2 then
        -- beta.35 repairs the historical beta.8 default once. After a user
        -- explicitly changes this switch, future upgrades must preserve it.
        if home.network_metadata_user_set~=true then home.network_metadata=true end
        home.network_metadata_defaults_version=2
        if home.network_metadata_user_set~=true then home.network_metadata_user_set=false end
        changed=true
    end
    if home.layout_style~="compact" and home.layout_style~="desk" then
        home.layout_style="desk"
        changed=true
    end
    if home.display_size~="compact" and home.display_size~="standard" and home.display_size~="large" then
        home.display_size="standard"
        changed=true
    end
    if home.ui_font_mode~="default" and home.ui_font_mode~="follow" and home.ui_font_mode~="custom" then
        home.ui_font_mode="default"
        changed=true
    end
    if type(home.ui_font_face)~="string" then home.ui_font_face=""; changed=true end
    if home.local_check_on_open==nil then home.local_check_on_open=true; changed=true end
    -- beta.16 removes the old mutually-exclusive auto/manual/folder modes.
    -- Updating the library and browsing it by folder are independent choices:
    -- the home grid is always a flat book shelf, while folder browsing remains
    -- available from the local-library entry.
    if (tonumber(home.local_browse_version) or 0)<2 then
        home.local_browse_version=2
        home.local_auto_update=true
        home.local_library_mode="auto" -- compatibility for older call sites
        home.auto_scan=true
        home.local_inline_path=nil
        home.local_inline_root=nil
        changed=true
    end
    if home.local_auto_update==nil then home.local_auto_update=true; changed=true end
    if home.local_library_mode~="auto" then home.local_library_mode="auto"; changed=true end
    if home.auto_scan~=(home.local_auto_update==true) then
        home.auto_scan=home.local_auto_update==true; changed=true
    end
    if type(home.visible_sections)~="table" then home.visible_sections={}; changed=true end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if home.visible_sections[section]==nil then home.visible_sections[section]=true; changed=true end
    end
    if type(home.source_order)~="table" then home.source_order={}; changed=true end
    local source_seen,source_order={},{}
    for _,section in ipairs(home.source_order) do
        if home.visible_sections[section]~=nil and not source_seen[section] then
            source_seen[section]=true
            source_order[#source_order+1]=section
        end
    end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if not source_seen[section] then source_seen[section]=true; source_order[#source_order+1]=section end
    end
    if table.concat(source_order,"|")~=table.concat(home.source_order,"|") then changed=true end
    home.source_order=source_order
    if home.auto_hide_empty==nil then home.auto_hide_empty=false; changed=true end
    local function normalize_quick_group(items_key,order_key,version_key,expected_version,item_order,item_defaults)
        if type(home[items_key])~="table" then home[items_key]={}; changed=true end
        if type(home[order_key])~="table" then home[order_key]={}; changed=true end
        if (tonumber(home[version_key]) or 0)<expected_version then
            -- Layout upgrades are incremental: keep explicit visibility and
            -- ordering, then append only genuinely new keys below. Special
            -- migrations that remove/replace a key run before this helper.
            home[version_key]=expected_version
            changed=true
        end
        for _,key in ipairs(item_order) do
            if home[items_key][key]==nil then home[items_key][key]=item_defaults[key]==true; changed=true end
        end
        local seen,normalized={},{}
        for _,key in ipairs(home[order_key]) do
            if item_defaults[key]~=nil and not seen[key] then seen[key]=true; normalized[#normalized+1]=key end
        end
        for _,key in ipairs(item_order) do
            if not seen[key] then seen[key]=true; normalized[#normalized+1]=key end
        end
        if table.concat(normalized,"|")~=table.concat(home[order_key],"|") then changed=true end
        home[order_key]=normalized
    end
    -- Home action layout v3 permanently removes frontlight from the homepage
    -- shortcut candidate set. It also repairs the beta.20 order where Sleep was
    -- inserted before an old Frontlight entry and pushed MiuRead Settings out
    -- of the six visible slots. User customizations are preserved otherwise.
    if (tonumber(home.action_layout_version) or 0)<HOME_ACTION_LAYOUT_VERSION then
        home.action_items=type(home.action_items)=="table" and home.action_items or {}
        home.action_order=type(home.action_order)=="table" and home.action_order or U.copy(HOME_ACTION_ITEM_V1_ORDER)
        local old_v1_recommended=quick_boolean_layout_matches(home.action_items,HOME_ACTION_ITEM_V1_DEFAULT,HOME_ACTION_ITEM_V1_ORDER)
            and quick_order_matches(home.action_order,HOME_ACTION_ITEM_V1_ORDER)
        local old_v2_recommended=quick_boolean_layout_matches(home.action_items,HOME_ACTION_ITEM_V2_DEFAULT,HOME_ACTION_ITEM_V2_ORDER)
            and quick_order_matches(home.action_order,HOME_ACTION_ITEM_V2_ORDER)
        local had_frontlight=home.action_items.frontlight==true
        if home.action_items.sleep==nil then
            home.action_items.sleep=(had_frontlight and Device:canSuspend()==true) or false
        end
        if old_v1_recommended or old_v2_recommended then
            home.action_items.sleep=Device:canSuspend()==true
            home.action_items.miuread_settings=true
        end
        home.action_items.frontlight=nil

        local seen,cleaned={},{}
        for _,name in ipairs(home.action_order) do
            if name~="frontlight" and HOME_ACTION_ITEM_DEFAULT[name]~=nil and not seen[name] then
                seen[name]=true
                cleaned[#cleaned+1]=name
            end
        end
        local function insert_after(after_key,key)
            if seen[key] then return end
            local out,inserted={},false
            for _,name in ipairs(cleaned) do
                out[#out+1]=name
                if name==after_key then out[#out+1]=key; inserted=true end
            end
            if not inserted then out[#out+1]=key end
            cleaned=out; seen[key]=true
        end
        insert_after("sync","sleep")
        insert_after("sleep","miuread_settings")
        for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do
            if not seen[key] then seen[key]=true; cleaned[#cleaned+1]=key end
        end
        home.action_order=cleaned
        home.action_layout_version=HOME_ACTION_LAYOUT_VERSION
        changed=true
    end
    normalize_quick_group("action_items","action_order","action_layout_version",HOME_ACTION_LAYOUT_VERSION,HOME_ACTION_ITEM_ORDER,HOME_ACTION_ITEM_DEFAULT)
    -- Never reintroduce the retired homepage-frontlight key from merged legacy
    -- preferences. Direct frontlight control is rendered by HomeQuickPanel.
    if home.action_items.frontlight~=nil then home.action_items.frontlight=nil; changed=true end
    -- Pull-down layout v2 keeps one horizontal row of six controls. Migrate
    -- the old recommended row before frontlight is removed from the selectable
    -- shortcut list; customized rows keep their enabled choices when possible.
    if (tonumber(home.panel_layout_version) or 0)<HOME_PANEL_LAYOUT_VERSION then
        home.panel_items=type(home.panel_items)=="table" and home.panel_items or {}
        home.panel_order=type(home.panel_order)=="table" and home.panel_order or U.copy(HOME_PANEL_ITEM_V1_ORDER)
        local old_recommended=quick_boolean_layout_matches(home.panel_items,HOME_PANEL_ITEM_V1_DEFAULT,HOME_PANEL_ITEM_V1_ORDER)
            and quick_order_matches(home.panel_order,HOME_PANEL_ITEM_V1_ORDER)
        -- Preserve the existing six shortcut choices. Only the old optional
        -- frontlight tile is removed because frontlight now has its own direct
        -- control section immediately below this row.
        if old_recommended then
            home.panel_items.quit=true
            home.panel_items.sleep=false
        end
        home.panel_items.frontlight=nil
        local kept={}
        for _,name in ipairs(home.panel_order) do if name~="frontlight" then kept[#kept+1]=name end end
        home.panel_order=kept
        home.panel_layout_version=HOME_PANEL_LAYOUT_VERSION
        changed=true
    end
    normalize_quick_group("panel_items","panel_order","panel_layout_version",HOME_PANEL_LAYOUT_VERSION,HOME_PANEL_ITEM_ORDER,HOME_PANEL_ITEM_DEFAULT)
    -- Unsupported hardware controls disappear instead of leaving dead slots.
    if not Device:canSuspend() then
        if home.panel_items.sleep==true then home.panel_items.sleep=false; changed=true end
        if home.action_items.sleep==true then home.action_items.sleep=false; changed=true end
    end
    local panel_enabled=0
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true then
            panel_enabled=panel_enabled+1
            if panel_enabled>6 then home.panel_items[key]=false; changed=true end
        end
    end
    if type(home.hidden_local_files)~="table" then home.hidden_local_files={}; changed=true end
    if home.more_expanded==nil then home.more_expanded=false; changed=true end
    if home.network_metadata==nil then home.network_metadata=true; changed=true end
    if home.background_thought_index~=nil then home.background_thought_index=nil; changed=true end
    if home.active_section~="account" and home.active_section~="generated" and home.active_section~="local" and home.active_section~="mp" then home.active_section="account"; changed=true end
    if home.lockscreen_recent==nil then home.lockscreen_recent=true; changed=true end
    home.local_root=tostring(home.local_root or "")
    local original_roots=type(home.local_roots)=="table" and home.local_roots or {}
    local normalized_roots,root_seen={},{}
    local function add_root(value)
        local item=type(value)=="table" and value or {path=value}
        local path=LocalLibrary.normalize(item.path or "")
        if path=="" or root_seen[path] or lfs.attributes(path,"mode")~="directory" then return end
        root_seen[path]=true
        normalized_roots[#normalized_roots+1]={
            path=path,
            name=U.trim(tostring(item.name or ""))~="" and U.trim(tostring(item.name)) or LocalLibrary.basename(path),
            enabled=item.enabled~=false,
            readonly=item.readonly~=false,
        }
    end
    for _,root in ipairs(original_roots) do add_root(root) end
    if #normalized_roots==0 then
        add_root(home.local_root)
        if #normalized_roots==0 then
            local legacy=self.store:get("home_local_index",{})
            if type(legacy)=="table" then add_root(legacy.root) end
        end
        if #normalized_roots==0 and lfs.attributes("/mnt/us/documents/Books","mode")=="directory" then
            add_root("/mnt/us/documents/Books")
        end
    end
    local function root_signature(rows)
        local parts={}
        for _,root in ipairs(rows or {}) do
            local item=type(root)=="table" and root or {path=root}
            parts[#parts+1]=table.concat({tostring(item.path or ""),tostring(item.name or ""),tostring(item.enabled~=false),tostring(item.readonly~=false)},"|")
        end
        return table.concat(parts,";")
    end
    if root_signature(original_roots)~=root_signature(normalized_roots) then changed=true end
    home.local_roots=normalized_roots
    home.local_root=normalized_roots[1] and normalized_roots[1].path or ""

    -- Direct browsing keeps its current folder in preferences so returning from
    -- a book or restarting KOReader restores the same level. Empty path means
    -- the multi-root picker; a single enabled root opens directly at its root.
    local old_inline_path=tostring(home.local_inline_path or "")
    local old_inline_root=tostring(home.local_inline_root or "")
    local inline_path=LocalLibrary.normalize(old_inline_path)
    local inline_root=LocalLibrary.normalize(old_inline_root)
    local enabled_roots={}
    for _,root in ipairs(normalized_roots) do if root.enabled~=false then enabled_roots[#enabled_roots+1]=root end end
    local matched_root
    if inline_path~="" and lfs.attributes(inline_path,"mode")=="directory" then
        for _,root in ipairs(enabled_roots) do
            if inline_path==root.path or inline_path:sub(1,#root.path+1)==root.path.."/" then
                matched_root=root
                break
            end
        end
    end
    if #enabled_roots==0 then
        inline_path=""; inline_root=""
    elseif matched_root then
        inline_root=matched_root.path
    elseif #enabled_roots==1 then
        inline_path=enabled_roots[1].path
        inline_root=enabled_roots[1].path
    else
        inline_path=""; inline_root=""
    end
    if old_inline_path~=inline_path or old_inline_root~=inline_root then changed=true end
    home.local_inline_path=inline_path
    home.local_inline_root=inline_root
    home.local_browse_version=2
    if type(home.page_by_section)~="table" then home.page_by_section={}; changed=true end
    if changed then self.store:save_preferences(preferences) end
    UiScale.setDisplayMode(home.display_size or "standard")
    UiScale.setFontName(self:_home_ui_font_name(home))
    return home,preferences
end

function Plugin:_save_ui_preferences(preferences,reason,delay)
    preferences=preferences or self.store:preferences()
    if not self.store.save_preferences_deferred then
        self.store:save_preferences(preferences)
        return true
    end
    self.store:save_preferences_deferred(preferences)
    self._ui_preferences_save_pending=true
    self._ui_preferences_save_generation=(tonumber(self._ui_preferences_save_generation) or 0)+1
    local generation=self._ui_preferences_save_generation
    UIManager:scheduleIn(math.max(.35,tonumber(delay) or 1.35),function()
        if generation~=(tonumber(self._ui_preferences_save_generation) or 0)
            or self._ui_preferences_save_pending~=true then return end
        self._ui_preferences_save_pending=false
        self.store:flush()
        logger.info("[MiuRead][UIState] preferences saved after idle",
            "reason=",tostring(reason or "ui"))
    end)
    return true
end

function Plugin:_mark_ui_preferences_flushed()
    if self._ui_preferences_save_pending~=true then return false end
    self._ui_preferences_save_generation=(tonumber(self._ui_preferences_save_generation) or 0)+1
    self._ui_preferences_save_pending=false
    return true
end

function Plugin:_save_home_preferences(home,preferences)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    self.store:save_preferences(preferences)
    UiScale.setDisplayMode(home.display_size or "standard")
    UiScale.setFontName(self:_home_ui_font_name(home))
end

function Plugin:_save_home_preferences_deferred(home,preferences,delay)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    if self.store.save_preferences_deferred then
        self.store:save_preferences_deferred(preferences)
    else
        return self:_save_home_preferences(home,preferences)
    end
    self._home_state_save_pending=true
    self._home_state_save_generation=(tonumber(self._home_state_save_generation) or 0)+1
    local generation=self._home_state_save_generation
    UIManager:scheduleIn(tonumber(delay) or 1.20,function()
        if generation~=self._home_state_save_generation or not self._home_state_save_pending then return end
        self._home_state_save_pending=false
        self.store:flush()
        logger.info("[MiuRead][HomeState] preferences saved after idle")
    end)
end

function Plugin:_flush_home_preferences()
    if not self._home_state_save_pending then return false end
    self._home_state_save_generation=(tonumber(self._home_state_save_generation) or 0)+1
    self._home_state_save_pending=false
    self.store:flush()
    logger.info("[MiuRead][HomeState] preferences saved before leaving home")
    return true
end

function Plugin:_home_section_cache_revision(section,page)
    self._home_section_revisions=type(self._home_section_revisions)=="table"
        and self._home_section_revisions or {}
    return table.concat({
        tostring(tonumber(self._home_data_revision) or 0),
        tostring(tonumber(self._home_section_revisions[section]) or 0),
        tostring(tonumber(page) or 1),
    },":")
end

function Plugin:_home_bump_section_revision(section)
    self._home_section_revisions=type(self._home_section_revisions)=="table"
        and self._home_section_revisions or {}
    self._home_section_revisions[section]=(tonumber(self._home_section_revisions[section]) or 0)+1
end

function Plugin:_home_enabled()
    return tostring(self._runtime_mode or rawget(_G,RUNTIME_MODE_KEY) or "desktop")=="desktop"
end

function Plugin:_configured_home_enabled()
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_runtime_mode_label()
    return self:_home_enabled() and "觅阅桌面" or "插件模式"
end

function Plugin:_configured_mode_label()
    return self:_configured_home_enabled() and "觅阅桌面" or "插件模式"
end

function Plugin:_home_mode_label()
    local current=self:_runtime_mode_label()
    local configured=self:_configured_mode_label()
    if current==configured then return current end
    return "当前"..current.." · 重启后"..configured
end

function Plugin:_mode_intro_preferences()
    local preferences=self.store:preferences()
    preferences.mode_intro=type(preferences.mode_intro)=="table" and preferences.mode_intro or {}
    return preferences.mode_intro,preferences
end

function Plugin:_mode_intro_pending_mode()
    local intro=self:_mode_intro_preferences()
    local mode=tostring(intro.pending_mode or "")
    if mode~="desktop" and mode~="plugin" then return "" end
    return mode
end

function Plugin:_mode_intro_needed()
    if self._reader_context then return false end
    if not self:_notice_enabled("mode_environment") then return false end
    local pending=self:_mode_intro_pending_mode()
    local runtime=self:_home_enabled() and "desktop" or "plugin"
    return pending~="" and pending==runtime
end

function Plugin:_set_mode_intro_pending(mode,reason)
    mode=tostring(mode or "")
    if mode~="desktop" and mode~="plugin" then return false end
    local intro,preferences=self:_mode_intro_preferences()
    intro.pending_mode=mode
    intro.pending_reason=tostring(reason or "user_switch")
    intro.pending_at=os.time()
    self.store:save_preferences(preferences)
    return true
end

function Plugin:_clear_mode_intro_pending()
    local intro,preferences=self:_mode_intro_preferences()
    if tostring(intro.pending_mode or "")=="" and tostring(intro.pending_reason or "")=="" then return false end
    intro.pending_mode=""
    intro.pending_reason=""
    intro.pending_at=0
    self.store:save_preferences(preferences)
    return true
end

function Plugin:_ack_mode_intro()
    local intro,preferences=self:_mode_intro_preferences()
    intro.last_confirmed_mode=self:_home_enabled() and "desktop" or "plugin"
    intro.confirmed_at=os.time()
    intro.pending_mode=""
    intro.pending_reason=""
    intro.pending_at=0
    self.store:save_preferences(preferences)
end

function Plugin:_desktop_compatibility_info()
    self:info("觅阅桌面会接管 KOReader 的部分主页、菜单、手势和阅读界面。\n\n如果同时启用了其他美化 UI 或美化补丁，可能造成卡顿、闪烁、菜单异常、手势失效或返回异常。\n\n建议使用觅阅桌面时，先禁用或删除其他美化 UI 和相关补丁。需要保留其他美化界面时，请使用插件模式。")
end

function Plugin:_show_mode_restart_notice(enabled)
    local text=enabled
        and "重启后将使用觅阅桌面。觅阅会提供完整主页和阅读快捷界面。"
        or "重启后将使用插件模式。KOReader 将继续管理主页和主要阅读界面，觅阅书架、下载、评论、同步、修复和账号功能仍可使用。"
    if not self:_notice_enabled("mode_switch") then
        self:toast("运行模式已保存，重启 KOReader 后生效",3)
        return true
    end
    local dialog
    dialog=ButtonDialog:new{title=text,title_align="center",buttons={
        {{text="立即重启",callback=function() UIManager:close(dialog); self:_restart_koreader("mode switch") end}},
        {{text="稍后重启",callback=function() UIManager:close(dialog); self:toast("运行模式将在重启后生效",3) end}},
        {{text="稍后重启并不再提示",callback=function()
            UIManager:close(dialog); self:_set_notice_enabled("mode_switch",false); self:toast("运行模式将在重启后生效",3)
        end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:_set_home_mode(use_miuread_home)
    local enabled=use_miuread_home==true
    local target_mode=enabled and "desktop" or "plugin"
    local home,preferences=self:_home_preferences()
    local configured=home.enabled~=false
    if configured==enabled then
        if self:_home_enabled()==enabled then
            self:_clear_mode_intro_pending()
            self:toast(enabled and "当前已是觅阅桌面模式" or "当前已是插件模式",2)
        else
            if self:_notice_enabled("mode_environment") and self:_mode_intro_pending_mode()~=target_mode then
                self:_set_mode_intro_pending(target_mode,"user_switch")
            end
            self:toast(enabled and "已设置重启后使用觅阅桌面" or "已设置重启后使用插件模式",2)
        end
        return false
    end
    home.enabled=enabled
    home.layout_version=23
    self:_save_home_preferences(home,preferences)
    if self:_home_enabled()==enabled then
        self:_clear_mode_intro_pending()
        self:toast("已取消待切换模式，当前继续使用"..self:_runtime_mode_label(),3)
        return true
    end
    if self:_notice_enabled("mode_environment") then
        self:_set_mode_intro_pending(target_mode,"user_switch")
    else
        self:_clear_mode_intro_pending()
    end
    return self:_show_mode_restart_notice(enabled)
end

function Plugin:_request_home_mode(enabled)
    return self:_set_home_mode(enabled==true)
end

function Plugin:_schedule_mode_intro_after_surface(delay)
    if not self:_mode_intro_needed() then return false end
    self._mode_intro_generation=(tonumber(self._mode_intro_generation) or 0)+1
    local generation=self._mode_intro_generation
    local attempts=0
    local function attempt()
        if generation~=self._mode_intro_generation or not self:_mode_intro_needed() then return end
        if HOME_EXITING or UIManager._exit_code~=nil then return end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.35,attempt)
            return
        end
        attempts=attempts+1
        local ready=false
        if self:_home_enabled() then
            ready=HomeView.is_shown() and not self:_active_reader_ui()
        else
            local navigation=self:_navigation_state()
            ready=not self:_active_reader_ui() and not self:_current_document_path()
                and navigation~="opening_reader" and navigation~="closing_reader"
                and navigation~="reader" and navigation~="suspended" and navigation~="exiting"
            if ready then
                local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
                if ok and FileManager then ready=FileManager.instance~=nil end
            end
        end
        if ready then
            UIManager:scheduleIn(.18,function()
                if generation==self._mode_intro_generation and self:_mode_intro_needed() then self:_show_mode_intro() end
            end)
            return
        end
        if attempts<50 then UIManager:scheduleIn(.15,attempt) end
    end
    UIManager:scheduleIn(tonumber(delay) or .8,attempt)
    return true
end

function Plugin:_show_mode_intro()
    if self._reader_context or not self:_mode_intro_needed() then return false end
    local desktop=self:_home_enabled()
    local dialog
    if desktop then
        dialog=ButtonDialog:new{
            title="当前使用：觅阅桌面\n\n觅阅桌面会提供完整主页、书架和阅读快捷界面，并接管 KOReader 的部分主页、菜单、手势和返回操作。\n\n如果同时启用了其他美化 UI 或美化补丁，可能造成卡顿、闪烁、菜单异常、手势失效或返回异常。\n\n建议先禁用或删除其他美化 UI 和相关补丁。需要保留 KOReader 原界面或其他美化 UI 时，可改用插件模式。",
            title_align="center",
            buttons={
                {{text="继续使用觅阅桌面",callback=function() UIManager:close(dialog); self:_ack_mode_intro() end}},
                {{text="切换到插件模式",callback=function()
                    UIManager:close(dialog); self:_ack_mode_intro(); self:_request_home_mode(false)
                end}},
            },
        }
    else
        dialog=ButtonDialog:new{
            title="当前使用：插件模式\n\n插件模式不会替换 KOReader 的主页和主要阅读界面，适合使用 KOReader 原界面，或搭配其他美化 UI 和美化补丁。\n\n微信书架、搜索、下载、评论、同步、修复和公众号等觅阅功能仍可使用。\n\n如果希望使用觅阅完整主页和阅读快捷界面，可以恢复觅阅桌面。恢复前建议先禁用或删除其他美化 UI 和相关补丁。",
            title_align="center",
            buttons={
                {{text="继续使用插件模式",callback=function() UIManager:close(dialog); self:_ack_mode_intro() end}},
                {{text="恢复觅阅桌面",callback=function()
                    UIManager:close(dialog); self:_ack_mode_intro(); self:_request_home_mode(true)
                end}},
            },
        }
    end
    UIManager:show(dialog)
    return true
end

function Plugin:_return_to_configured_home()
    if not self:_home_enabled() then self:toast("插件模式下不启用觅阅桌面",2); return false end
    sync_home_session()
    if HomeView.is_shown() then HomeView.raise(); return true end
    if not (self.ui and self.ui.document) and HOME_NATIVE_VISIT then return self:_return_from_native_filemanager() end
    if self:_active_reader_ui() then return self:return_to_miuread_home() end
    return self:show_miuread_home(false)
end

function Plugin:home_mode_menu()
    local rows={
        {text="使用觅阅桌面",post_text="主页 + 完整桌面阅读界面",radio=true,checked_func=function() return self:_configured_home_enabled() end,callback=function()
            self:_request_home_mode(true)
        end},
        {text="使用插件模式",post_text="保留 KOReader 或其他美化界面",radio=true,checked_func=function() return not self:_configured_home_enabled() end,callback=function()
            self:_request_home_mode(false)
        end},
        {text="当前运行",post_text=self:_home_mode_label(),enabled=false},
        {text="桌面模式兼容说明",callback=function() self:_desktop_compatibility_info() end},
    }
    return rows
end

function Plugin:_home_refresh_priority(kind)
    -- "page" is a full home-state repaint with the normal UI waveform.
    -- "full" remains the heavier structural rebuild used by settings/rotation.
    local priority={header=1,section=2,content=3,page=4,full=5}
    return priority[tostring(kind or "content")] or 3
end

function Plugin:_home_defer_refresh_kind(kind)
    kind=tostring(kind or "content")
    self._home_refresh_pending=true
    local current=self._home_refresh_pending_kind
    if not current or self:_home_refresh_priority(kind)>self:_home_refresh_priority(current) then
        self._home_refresh_pending_kind=kind
    end
    if self:_home_background_blocked() then
        local resume_current=self._home_resume_pending_kind
        if not resume_current or self:_home_refresh_priority(kind)>self:_home_refresh_priority(resume_current) then
            self._home_resume_pending_kind=kind
        end
    end
    return kind
end

function Plugin:_home_background_blocked()
    return self._home_suspended==true or self._home_resume_barrier==true
        or self:_page_transition_active()
end

function Plugin:_home_modal_surface_active()
    local stack=UIManager._window_stack or {}
    for index=#stack,1,-1 do
        local window=stack[index]
        local widget=window and window.widget or nil
        if widget and widget._miuread_modal_surface==true
            and widget._miuread_recovery_surface~=true
            and UIManager:isWidgetShown(widget) then
            self._home_modal_cooldown_until=math.max(
                tonumber(self._home_modal_cooldown_until) or 0,monotonic_wall_time()+2.6)
            return true
        end
    end
    return false
end

function Plugin:_home_ui_busy()
    local now=monotonic_wall_time()
    if self:_home_background_blocked() then return true end
    if self:_home_modal_surface_active() then return true end
    return now < (tonumber(self._home_ui_quiet_until) or 0)
        or now < (tonumber(self._home_post_reader_protect_until) or 0)
        or now < (tonumber(self._home_modal_cooldown_until) or 0)
end

function Plugin:_home_refresh_header_now(force_device,force_sync)
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    if force_device==true then HomeData.quick_device_state(true) end
    return HomeView.update_header{
        account_name=self:_home_account_name(),
        wifi_text=self:_home_wifi_text(),
        sync_text=self:_home_sync_status_label(force_sync==true),
        time_text=self:_display_time("%H:%M"),
        battery_text=self:_home_battery_text(),
    }
end

function Plugin:_home_schedule_clock()
    self._home_clock_generation=(tonumber(self._home_clock_generation) or 0)+1
    local generation=self._home_clock_generation
    if self._home_clock_task then
        UIManager:unschedule(self._home_clock_task)
        self._home_clock_task=nil
    end
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    HomeView.update_time(self:_display_time("%H:%M"))
    local task
    task=function()
        if generation~=self._home_clock_generation or self._home_clock_task~=task then return end
        if not HomeView.is_shown() then
            self._home_clock_task=nil
            return
        end
        if self._home_suspended~=true and HOME_SESSION.suspended~=true and not self:_active_reader_ui() then
            HomeView.update_time(self:_display_time("%H:%M"))
        end
        local now=os.time()
        UIManager:scheduleIn(math.max(10,60-(now%60)+.12),task)
    end
    self._home_clock_task=task
    local now=os.time()
    UIManager:scheduleIn(math.max(10,60-(now%60)+.12),task)
    return true
end

function Plugin:_home_schedule_stale_checks(delay)
    self._home_stale_check_generation=(tonumber(self._home_stale_check_generation) or 0)+1
    local generation=self._home_stale_check_generation
    if self._home_stale_check_task then
        UIManager:unschedule(self._home_stale_check_task)
        self._home_stale_check_task=nil
    end
    local task
    task=function()
        if generation~=self._home_stale_check_generation or self._home_stale_check_task~=task then return end
        if not HomeView.is_shown() or self:_active_reader_ui()
            or self._home_suspended==true or HOME_SESSION.suspended==true then
            self._home_stale_check_task=nil
            return
        end
        if self:_home_ui_busy() then
            UIManager:scheduleIn(self:_lightweight_enabled() and 1.2 or .75,task)
            return
        end
        self._home_stale_check_task=nil
        -- Cache first. Only stale sources are allowed to do work here.
        self:_home_refresh_remote(false,false)
        if self._home_active_section=="local" then self:_home_scan_local(false) end
    end
    self._home_stale_check_task=task
    local minimum=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_HOME_IDLE_DELAY) or 6) or .8
    UIManager:scheduleIn(math.max(minimum,tonumber(delay) or 4.5),task)
    return true
end

function Plugin:_home_resume_visible_work_after_idle()
    if self._home_ui_resume_task then UIManager:unschedule(self._home_ui_resume_task) end
    if self._home_suspended==true or HOME_SESSION.suspended==true then
        self._home_ui_resume_task=nil
        return false
    end
    local task
    task=function()
        if self._home_ui_resume_task~=task then return end
        if self._home_suspended==true or HOME_SESSION.suspended==true then
            self._home_ui_resume_task=nil
            return
        end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_ui_resume_task=nil
            return
        end
        local now=monotonic_wall_time()
        if self:_home_modal_surface_active() then
            UIManager:scheduleIn(.45,task)
            return
        end
        local deadline=math.max(
            tonumber(self._home_ui_quiet_until) or 0,
            tonumber(self._home_post_reader_protect_until) or 0,
            tonumber(self._home_modal_cooldown_until) or 0)
        local remain=deadline-now
        if remain>0 then
            UIManager:scheduleIn(math.max(.20,remain+.08),task)
            return
        end
        if self:_home_background_blocked() then
            UIManager:scheduleIn(.45,task)
            return
        end
        self._home_ui_resume_task=nil
        -- Recent-reading changes are applied only after the post-reader/user
        -- interaction barrier releases. This keeps Reader->Home fast and uses
        -- a static hero-layer update instead of rebuilding the shelf.
        self:_home_refresh_recent_hero_cached()
        local pending_kind=self._home_refresh_pending_kind
        if pending_kind then
            self._home_refresh_pending_kind=nil
            self._home_refresh_pending=false
            self:_refresh_home_view(nil,pending_kind)
            UIManager:scheduleIn(.35,function()
                if HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_home_resume_visible_work_after_idle()
                end
            end)
            return
        end
        local metadata=self._home_visible_metadata_targets or {}
        local covers=self._home_visible_cover_targets or {}
        self:_home_schedule_local_metadata(metadata)
        self:_home_schedule_remote_covers(covers)
        local pending_network_key=self._home_pending_network_metadata_key
        self._home_pending_network_metadata_key=nil
        if pending_network_key and self._home_hero
            and self:_home_network_metadata_key(self._home_hero)==pending_network_key then
            self:_home_schedule_network_metadata(self._home_hero,false)
        end
        UIManager:scheduleIn(.85,function()
            if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                self:_home_schedule_cover_derivatives(covers)
            end
        end)
        if self.download_task then
            self.download_task:resume("home_interaction")
            self.download_task:resume("page_transition")
        end
        self:_home_schedule_stale_checks(1.1)
        logger.info("[MiuRead][HomePerf] background released after interaction")
    end
    self._home_ui_resume_task=task
    UIManager:scheduleIn(.35,task)
end

function Plugin:_home_enter_post_reader_priority_window(seconds,reason)
    if not HomeView.is_shown() then return false end
    local duration=math.max(4.0,tonumber(seconds) or 4.0)
    self._home_post_reader_protect_until=math.max(
        tonumber(self._home_post_reader_protect_until) or 0,monotonic_wall_time()+duration)
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    if self.home_metadata_async and self.home_metadata_async:busy() then self.home_metadata_async:cancel("post-reader priority") end
    if self.home_cover_async and self.home_cover_async:busy() then self.home_cover_async:cancel("post-reader priority") end
    if self.cover_render_async and self.cover_render_async:busy() then self.cover_render_async:cancel("post-reader priority") end
    self:_home_resume_visible_work_after_idle()
    logger.info("[MiuRead][HomePerf] post-reader priority window",
        "seconds=",tostring(duration),"reason=",tostring(reason or "reader closed"))
    return true
end

function Plugin:_home_bump_interaction_generation()
    HOME_SESSION.home_interaction_generation=(tonumber(HOME_SESSION.home_interaction_generation) or 0)+1
    self._home_interaction_generation=HOME_SESSION.home_interaction_generation
    return self._home_interaction_generation
end

function Plugin:_home_note_interaction(first,kind)
    self._home_ui_quiet_until=math.max(tonumber(self._home_ui_quiet_until) or 0,monotonic_wall_time()+2.2)
    self:_home_bump_interaction_generation()
    -- Stop optional visible-book work immediately; it can be restarted from
    -- cached targets after the user has been idle for a moment.
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    if self.home_metadata_async and self.home_metadata_async:busy() then self.home_metadata_async:cancel("home interaction") end
    if self.home_cover_async and self.home_cover_async:busy() then self.home_cover_async:cancel("home interaction") end
    if self.cover_render_async and self.cover_render_async:busy() then self.cover_render_async:cancel("home interaction") end
    if self.download_task and self.download_task:busy() then self.download_task:pause("home_interaction") end
    self:_home_resume_visible_work_after_idle()
    if first then
        logger.info("[MiuRead][HomePerf] interaction priority","kind=",tostring(kind or "input"))
    end
end

function Plugin:_home_unschedule_task(field)
    local task=self[field]
    if task then
        UIManager:unschedule(task)
        self[field]=nil
        return true
    end
    return false
end

function Plugin:_home_freeze_for_suspend()
    if self._home_suspended==true then return true end
    self._home_suspended=true
    self._home_resume_barrier=true
    self._home_resume_first_frame=false
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    self._home_resume_started_clock=nil

    local cover_retry_pending=self._home_cover_render_retry_task~=nil
    self._home_resume_pending_work={
        scan=self._home_refreshing==true or (self.home_async and self.home_async:busy()) or false,
        remote=self._home_remote_refreshing==true or (self.shelf_async and self.shelf_async:busy()) or false,
        metadata=(self.home_metadata_async and self.home_metadata_async:busy()) or false,
        covers=(self.home_cover_async and self.home_cover_async:busy())
            or (self.cover_render_async and self.cover_render_async:busy())
            or cover_retry_pending or false,
    }
    if self._home_refresh_pending_kind then self:_home_defer_refresh_kind(self._home_refresh_pending_kind) end

    self:_home_unschedule_task("_home_refresh_task")
    self:_home_unschedule_task("_home_render_refresh_task")
    self:_home_unschedule_task("_home_resume_background_task")
    self:_home_unschedule_task("_home_ui_resume_task")
    self:_home_unschedule_task("_home_clock_task")
    self:_home_unschedule_task("_home_stale_check_task")
    self:_home_unschedule_task("_home_cover_render_retry_task")
    self:_home_unschedule_task("_home_manual_metadata_retry_task")
    self._home_pending_network_metadata_key=nil
    self._home_refresh_debounce_generation=(tonumber(self._home_refresh_debounce_generation) or 0)+1
    self._home_render_refresh_generation=(tonumber(self._home_render_refresh_generation) or 0)+1
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    self._home_refreshing=false
    self._home_remote_refreshing=false
    self._home_cover_inflight={}

    if self.home_async then self.home_async:cancel("device suspended") end
    if self.local_browser_async then self.local_browser_async:cancel("device suspended") end
    if self.home_metadata_async then self.home_metadata_async:cancel("device suspended") end
    if self.home_cover_async then self.home_cover_async:cancel("device suspended") end
    if self.cover_render_async then self.cover_render_async:cancel("device suspended") end
    if self.annotation_async then self.annotation_async:cancel("device suspended") end
    if self.updater_async then
        self.updater_async:cancel("device suspended")
        self._auto_update_check_running=false
    end
    if self.sync_summary_async then self.sync_summary_async:cancel("device suspended") end
    self:_home_unschedule_task("_home_sync_summary_task")
    if self.shelf_async and self._home_resume_pending_work.remote then self.shelf_async:cancel("device suspended") end

    logger.info("[MiuRead][Resume] home tasks frozen",
        "generation=",tostring(self._home_resume_generation),
        "scan=",tostring(self._home_resume_pending_work.scan),
        "remote=",tostring(self._home_resume_pending_work.remote),
        "metadata=",tostring(self._home_resume_pending_work.metadata),
        "covers=",tostring(self._home_resume_pending_work.covers))
    return true
end

function Plugin:_home_resume_visible_targets()
    local current=HomeView.current()
    local opts=current and current.opts or {}
    local metadata_targets,cover_targets={},{}
    if opts.hero then
        metadata_targets[#metadata_targets+1]=opts.hero
        cover_targets[#cover_targets+1]=opts.hero
    end
    for _,book in ipairs(opts.shelf_books or {}) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    return metadata_targets,cover_targets
end

function Plugin:_home_finish_resume_background(generation)
    if generation~=self._home_resume_generation or self._home_suspended==true then return false end
    self._home_resume_background_task=nil
    self._home_resume_barrier=false
    local pending_kind=self._home_resume_pending_kind or self._home_refresh_pending_kind
    self._home_resume_pending_kind=nil
    local pending=self._home_resume_pending_work or {}
    self._home_resume_pending_work=nil

    logger.info("[MiuRead][Resume] background released",
        "generation=",tostring(generation),"refresh=",tostring(pending_kind or "none"))

    if pending_kind then
        self._home_refresh_pending_kind=nil
        self._home_refresh_pending=false
        self:_notify_home_data_changed(pending_kind)
    end

    if pending.scan then
        UIManager:scheduleIn(.25,function()
            if generation==self._home_resume_generation and not self:_home_background_blocked() and HomeView.is_shown() then
                self:_home_scan_local(false)
            end
        end)
    end
    if pending.remote then
        UIManager:scheduleIn(.70,function()
            if generation==self._home_resume_generation and not self:_home_background_blocked() and HomeView.is_shown() then
                self:_home_refresh_remote(false,false)
            end
        end)
    end
    if pending.metadata or pending.covers then
        UIManager:scheduleIn(1.05,function()
            if generation~=self._home_resume_generation or self:_home_background_blocked() or not HomeView.is_shown() then return end
            local metadata_targets,cover_targets=self:_home_resume_visible_targets()
            if pending.metadata then self:_home_schedule_local_metadata(metadata_targets) end
            if pending.covers then
                self:_home_schedule_remote_covers(cover_targets)
                self:_home_schedule_cover_derivatives(cover_targets)
            end
        end)
    end
    if self.download_task then self.download_task:on_resume() end
    return true
end

function Plugin:_home_schedule_resume_background(delay,generation)
    generation=tonumber(generation) or tonumber(self._home_resume_generation) or 0
    self:_home_unschedule_task("_home_resume_background_task")
    local interaction_generation=tonumber(self._home_interaction_generation) or 0
    local task
    task=function()
        if self._home_resume_background_task~=task then return end
        self._home_resume_background_task=nil
        if generation~=self._home_resume_generation or self._home_suspended==true then return end
        if interaction_generation~=(tonumber(self._home_interaction_generation) or 0) then
            self:_home_schedule_resume_background(2.4,generation)
            return
        end
        self:_home_finish_resume_background(generation)
    end
    self._home_resume_background_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 3.5),task)
    return true
end

function Plugin:_home_resume_interaction(generation,first,kind)
    if generation~=self._home_resume_generation or self._home_suspended==true then return end
    self:_home_bump_interaction_generation()
    local elapsed=self._home_resume_started_clock and math.floor((os.clock()-self._home_resume_started_clock)*1000+.5) or -1
    if first then
        logger.info("[MiuRead][Resume] first interaction",
            "kind=",tostring(kind or "input"),"ms=",tostring(elapsed))
    end
    if self._home_resume_barrier==true then self:_home_schedule_resume_background(2.4,generation) end
end

function Plugin:_home_begin_resume(slept)
    self._home_suspended=false
    self._home_resume_barrier=true
    self._home_resume_first_frame=false
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    local generation=self._home_resume_generation
    self._home_resume_started_clock=os.clock()
    self._home_resume_sleep_seconds=math.max(0,tonumber(slept) or 0)
    HOME_SESSION.last_resume_clock=monotonic_wall_time()

    if self._home_resume_surface_task then
        UIManager:unschedule(self._home_resume_surface_task)
        self._home_resume_surface_task=nil
    end

    local long_safe=self._home_resume_sleep_seconds>=7200
    logger.info("[MiuRead][Resume] event received",
        "generation=",tostring(generation),"slept=",tostring(self._home_resume_sleep_seconds),
        "mode=",long_safe and "long_safe_restore" or "normal")

    -- Do not touch UIManager's window ordering in the Resume callback. Kindle
    -- may still be restoring the framebuffer and orientation at that point.
    -- Wait for two identical geometry samples, then repaint/rebuild only the
    -- already-shown Home surface via public widget operations.
    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._home_resume_surface_task~=task
            or generation~=self._home_resume_generation
            or self._home_suspended==true or HOME_SESSION.suspended==true then return end
        attempts=attempts+1
        local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
        local rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
        if sw==last_w and sh==last_h and rotation==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=sw,sh,rotation,0
        end
        if stable<1 and attempts<7 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._home_resume_surface_task=nil
        local raised=HomeView.resume{
            rebuild_visual=long_safe,
            on_interaction=function(first,kind)
                self:_home_resume_interaction(generation,first,kind)
            end,
        }
        if not raised then
            self._home_resume_barrier=false
            self.sync:on_resume(slept)
            self:_schedule_home_startup(.12)
            logger.warn("[MiuRead][Resume] existing home unavailable; startup scheduled")
            return
        end
        self._home_resume_first_frame=true
        self:_home_schedule_clock()
        local elapsed=math.floor((os.clock()-self._home_resume_started_clock)*1000+.5)
        logger.info("[MiuRead][Resume] first surface released",
            "ms=",tostring(elapsed),"samples=",tostring(attempts),
            "mode=",long_safe and "long_safe_restore" or "normal")
        UIManager:scheduleIn(.10,function()
            if generation==self._home_resume_generation and self._home_suspended~=true then
                self.sync:on_resume(slept)
            end
        end)
        self:_home_schedule_resume_background(long_safe and 4.2 or 3.5,generation)
    end
    self._home_resume_surface_task=task
    UIManager:scheduleIn(.12,task)
    return true
end

function Plugin:_refresh_home_view(message,refresh_kind)
    if message and message~="" then self:toast(message,2) end
    if self:_home_background_blocked() then
        self:_home_defer_refresh_kind(refresh_kind or "content")
        logger.info("[MiuRead][Resume] home rebuild deferred",tostring(refresh_kind or "content"))
        return false
    end
    if HomeView.is_shown() then
        local kind=refresh_kind or "content"
        UIManager:scheduleIn(.05,function()
            if not HomeView.is_shown() or self:_active_reader_ui() then return end
            if kind=="header" then
                -- Header-only state changes must not reconstruct shelves or covers.
                self:_home_refresh_header_now(false,false)
            else
                self:_show_miuread_home_now(false,true,true,kind)
            end
        end)
        return true
    end
    return false
end

function Plugin:_notify_home_data_changed(refresh_kind)
    local requested=self:_home_defer_refresh_kind(refresh_kind or "content")
    if self:_home_background_blocked() then
        logger.info("[MiuRead][Resume] data refresh deferred",tostring(requested))
        return true
    end
    self._home_refresh_debounce_generation=(tonumber(self._home_refresh_debounce_generation) or 0)+1
    local generation=self._home_refresh_debounce_generation
    local task
    task=function()
        if generation~=self._home_refresh_debounce_generation then return end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_refresh_task=nil
            return
        end
        if self:_home_ui_busy() then
            self._home_refresh_task=nil
            self:_home_resume_visible_work_after_idle()
            return
        end
        self._home_refresh_task=nil
        local kind=self._home_refresh_pending_kind or "content"
        self._home_refresh_pending_kind=nil
        self._home_refresh_pending=false
        self:_refresh_home_view(nil,kind)
    end
    if self._home_refresh_task then UIManager:unschedule(self._home_refresh_task) end
    self._home_refresh_task=task
    -- Several cover/download/status events inside this window become one
    -- ordinary e-ink UI update instead of a visible series of repaints.
    UIManager:scheduleIn(.25,task)
    return true
end

function Plugin:_home_schedule_render_refresh(kind)
    if self:_home_background_blocked() then
        self:_home_defer_refresh_kind(kind or "content")
        return false
    end
    self._home_render_refresh_generation=(tonumber(self._home_render_refresh_generation) or 0)+1
    local generation=self._home_render_refresh_generation
    local task
    task=function()
        if generation~=self._home_render_refresh_generation then return end
        self._home_render_refresh_task=nil
        if HomeView.is_shown() and not self:_active_reader_ui() then
            HomeView.refresh(kind or "content")
        end
    end
    self._home_render_refresh_task=task
    UIManager:scheduleIn(.35,task)
end

function Plugin:_home_apply_cover_path(book_id,path)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" or path=="" then return false end
    local changed=false
    local function apply(book)
        if type(book)=="table" and tostring(book.bookId or book.book_id or "")==book_id
            and tostring(book.cover_path or "")~=path then
            book.cover_path=path
            -- A new raw source invalidates the small display derivative. The
            -- background renderer will replace it without blocking this view.
            book.home_cover_path=nil
            changed=true
        end
    end
    local hero_id=self:_home_cover_render_id(self._home_hero)
    hero_id=tostring(hero_id or "")
    apply(self._home_hero)
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book) end
    end
    if hero_id==book_id then
        local current=HomeView.current()
        if current and current.opts and not current.opts.screensaver_file then current.opts.screensaver_file=path end
    end
    return changed
end

function Plugin:_home_refresh_remote(force,user_requested)
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.remote=true
        return false
    end
    if self._home_remote_refreshing or self:_active_reader_ui() then return false end
    local _,_,updated_at=self.library:cached()
    local now=os.time()
    local age=math.max(0,now-(tonumber(updated_at) or 0))
    local shelf_ttl=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_HOME_REMOTE_TTL) or 30*60)
        or HOME_SHELF_REFRESH_TTL
    if force~=true then
        if age<shelf_ttl then return false end
        if now-(tonumber(self._home_remote_auto_attempt_at) or 0)<HOME_REMOTE_AUTO_RETRY then return false end
    end
    if not self:logged_in() then
        if user_requested then self:toast("登录后才能刷新微信书架",3) end
        return false
    end
    if not self:is_online() then
        if user_requested then self:toast("当前没有网络连接",3) end
        return false
    end
    self._home_remote_refreshing=true
    if force~=true then self._home_remote_auto_attempt_at=now end
    if user_requested then self:toast("正在刷新书架…",2) end
    local started=self:_refresh_shelf_async(function(_,_,err)
        self._home_remote_refreshing=false
        if err then
            if user_requested then self:toast(self:_friendly_remote_error(err,"书架刷新"),4) end
            return
        end
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_notify_home_data_changed("section")
        end
        if user_requested then self:toast("书架已刷新",2) end
    end,true)
    if not started then self._home_remote_refreshing=false end
    return started==true
end

function Plugin:_home_manual_refresh()
    local active=self._home_active_section or "account"
    if active=="account" or active=="mp" then
        local started=self:_home_refresh_remote(true,true)
        if not started and HomeView.is_shown() then self:_notify_home_data_changed("section") end
        return true
    end
    if active=="local" then
        local started=self:_home_scan_local(true)
        if started then self:toast("正在更新本地书库…",2)
        else self:toast("本地书库暂时无法开始更新",2) end
        return true
    end
    -- Generated books are already known to MiuRead. Reconcile its saved
    -- records/files only; do not scan arbitrary folders or query the network.
    self.store:reload()
    self.store:prune_missing_files()
    self:toast("正在更新已下载书籍…",2)
    self:_notify_home_data_changed("section")
    return true
end

function Plugin:_home_refresh_whole_page()
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    -- "Refresh entire home" means show every state MiuRead already knows now.
    -- It does not force network, local scans, metadata lookups or a full-waveform
    -- e-ink refresh; those remain separate explicit actions.
    HomeData.quick_device_state(true)
    self._home_recent_read_dirty=true
    HOME_SESSION.recent_read_dirty=true
    local shown=self:_show_miuread_home_now(false,true,true,"page",{skip_background=true})
    if shown then
        self:_home_schedule_clock()
        self:toast("主页状态已刷新",2)
    end
    return shown==true
end

function Plugin:_home_complete_refresh(confirmed)
    if confirmed~=true and self:_notice_enabled("library_scan") then
        self:_confirm_library_scan(function() self:_home_complete_refresh(true) end)
        return true
    end
    self:_home_reset_local_metadata()
    self.store:reload()
    self.store:prune_missing_files()
    self:toast("正在完整更新书架与书籍信息…",3)
    self:_home_refresh_remote(true,false)
    self:_home_scan_local(true)
    UIManager:scheduleIn(.35,function()
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_show_miuread_home_now(true,true,true,"content")
        end
    end)
    UIManager:scheduleIn(1.8,function()
        if HomeView.is_shown() and not self:_active_reader_ui() then UIManager:setDirty("all","full") end
    end)
    return true
end

function Plugin:_set_home_layout(style)
    style=style=="compact" and "compact" or "desk"
    local home,preferences=self:_home_preferences()
    home.layout_style=style
    home.layout_version=23
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(style=="compact" and "已切换到紧凑布局" or "已切换到标准布局","full")
end

function Plugin:_home_open_section(section)
    if section=="account" then return self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end) end
    if section=="generated" then return self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end) end
    if section=="local" then return self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end) end
    return self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
end

function Plugin:_home_visible_section_keys(sections,home)
    sections=sections or self._home_sections or {}
    home=home or self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local keys={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local entry=sections[section]
        local enabled=home.visible_sections[section]~=false
        local empty=not entry or #(entry.rows or {})==0
        if enabled and (home.auto_hide_empty~=true or not empty) then keys[#keys+1]=section end
    end
    -- Never leave the home without a selectable source. When every visible
    -- source is empty, keep the first user-enabled one as an empty-state tab.
    if #keys==0 then
        for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
            if home.visible_sections[section]~=false then keys[1]=section; break end
        end
    end
    if #keys==0 then
        home.visible_sections.account=true
        keys[1]="account"
    end
    return keys
end

function Plugin:_home_build_tabs(active)
    local tabs={}
    for _,section in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do
        local tab_section=section
        local entry=self._home_sections and self._home_sections[tab_section] or nil
        tabs[#tabs+1]={
            title=entry and entry.title or tab_section,
            count=entry and #(entry.rows or {}) or 0,
            selected=active==tab_section,
            on_tap=function() self:_set_home_section(tab_section) end,
        }
    end
    return tabs
end

function Plugin:_home_page_limit()
    -- 3.5 uses a stable 4 × 2 grid in both orientations.
    return 8
end

function Plugin:_home_preview_page(rows,hero,page,limit)
    limit=math.max(1,tonumber(limit) or self:_home_page_limit())
    local filtered,seen={},{}
    -- “继续阅读”是快捷入口，不应从对应书架中隐藏同一本书。
    -- 保留书架项目，确保标题数量、分页数量和实际可见内容一致。
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            filtered[#filtered+1]=book
        end
    end
    local has_folders=false
    for _,book in ipairs(filtered) do if book.local_folder==true or book.kind=="folder" then has_folders=true; break end end
    if has_folders then
        local packed,current,used={}, {}, 0
        local columns=4
        for _,book in ipairs(filtered) do
            local weight=(book.local_folder==true or book.kind=="folder") and 2 or 1
            -- A two-column folder card may not start in the last column. Count
            -- the unused slot before pagination so rendering never crosses the
            -- right edge when folders and books are mixed.
            local padding=(weight==2 and used%columns==columns-1) and 1 or 0
            if used>0 and used+padding+weight>limit then
                packed[#packed+1]=current; current={}; used=0; padding=0
            end
            used=used+padding
            current[#current+1]=book; used=used+weight
        end
        if #current>0 or #packed==0 then packed[#packed+1]=current end
        local total_pages=math.max(1,#packed)
        page=math.max(1,math.min(total_pages,tonumber(page) or 1))
        return packed[page] or {},page,total_pages,#filtered
    end
    local total_pages=math.max(1,math.ceil(#filtered/limit))
    page=math.max(1,math.min(total_pages,tonumber(page) or 1))
    local first=(page-1)*limit+1
    local preview={}
    for index=first,math.min(#filtered,first+limit-1) do preview[#preview+1]=filtered[index] end
    return preview,page,total_pages,#filtered
end

function Plugin:_home_page_for(section)
    local home=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    return math.max(1,tonumber(home.page_by_section[section]) or 1)
end

function Plugin:_home_change_page(delta)
    local section=self._home_active_section or "account"
    local selected=self._home_sections and self._home_sections[section]
    if not selected then return false end
    local home,preferences=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    local _,current,total=self:_home_preview_page(selected.rows,self._home_hero,home.page_by_section[section],self:_home_page_limit())
    local target=math.max(1,math.min(total,current+(tonumber(delta) or 0)))
    if target==current then return true end
    home.page_by_section[section]=target
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
    return self:_home_apply_section(section)
end

function Plugin:_home_apply_section(section)
    local selected=self._home_sections and self._home_sections[section]
    if not selected or not HomeView.is_shown() then return false end
    self._home_active_section=section
    local home=self:_home_preferences()
    local preview,page,total_pages=self:_home_preview_page(
        selected.rows,self._home_hero,
        home.page_by_section and home.page_by_section[section],
        self:_home_page_limit()
    )
    if not home.page_by_section or tonumber(home.page_by_section[section])~=page then
        local current,preferences=self:_home_preferences()
        current.page_by_section=type(current.page_by_section)=="table" and current.page_by_section or {}
        current.page_by_section[section]=page
        self:_save_home_preferences_deferred(current,preferences)
    end
    local started=os.clock()
    local updated=HomeView.update_section{
        tabs=self:_home_build_tabs(section),
        shelf_title=section=="local" and self:_home_local_inline_title() or "",
        shelf_books=preview,
        shelf_page=page,
        shelf_pages=total_pages,
        empty_text=selected.empty,
        on_open_book=function(book,anchor) self:_home_open_book(book,anchor) end,
        on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end,
        home_actions=self:_home_action_entries(),
        on_shelf_all=function()
            if section=="local" then self:show_home_local_library()
            else self:show_home_all_books() end
        end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
        section_cache_key=section,
        section_revision=self:_home_section_cache_revision(section,page),
    }
    -- Section switching must remain a pure in-memory operation. Metadata,
    -- cover extraction, local scans and network work are intentionally not
    -- started here; they are handled on initial home load or explicit refresh.
    logger.info("[MiuRead][HomeSwitch] applied",
        "section=",tostring(section),"page=",tostring(page),
        "ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    return updated
end

function Plugin:_set_home_section(section)
    local allowed={}
    for _,key in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do allowed[key]=true end
    section=allowed[section] and section or (self._home_visible_keys and self._home_visible_keys[1]) or "account"
    local home,preferences=self:_home_preferences()
    if home.active_section==section and self._home_active_section==section then return end
    home.active_section=section
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
    if self:_home_apply_section(section) then
        logger.info("[MiuRead][Home] section updated partial",tostring(section))
    else
        self:_refresh_home_view(nil,"section")
    end
    if section=="local" then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and self._home_active_section=="local" then self:_home_ensure_local_inline_loaded() end
        end)
        self:_home_schedule_stale_checks(1.0)
    end
end

function Plugin:_home_cover_render_id(book)
    if type(book)~="table" then return nil end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return id end
    local seed=tostring(book.cover_path or book.file or book.title or "book")
    local hash=5381
    for i=1,#seed do hash=(hash*33+seed:byte(i))%4294967296 end
    return string.format("local-%08x",hash)
end

function Plugin:_home_prepare_lockscreen_cover(book)
    if type(book)~="table" then return nil end
    local width,height=Device.screen:getWidth(),Device.screen:getHeight()
    if width<=0 or height<=0 then return nil end
    local id=self:_home_cover_render_id(book)
    if not id then return tostring(book.cover_path or "")~="" and book.cover_path or nil end
    local dir=self.store.data_dir.."/lockscreen"
    U.mkdir(dir)
    local prefix=dir.."/"..U.id_name(id)
    local current=prefix.."-fill3-"..tostring(width).."x"..tostring(height)..".png"
    if lfs.attributes(current,"mode")=="file" and (tonumber(U.file_size(current) or 0) or 0)>0 then return current end
    -- Keep the beta.2 full-screen artifact as a temporary fallback while the
    -- sharper beta.3 image is rebuilt in a low-priority worker.
    local previous=prefix.."-fill2-"..tostring(width).."x"..tostring(height)..".png"
    if lfs.attributes(previous,"mode")=="file" and (tonumber(U.file_size(previous) or 0) or 0)>0 then return previous end
    local fallback=tostring(book.cover_path or "")
    return fallback~="" and fallback or nil
end

function Plugin:_home_apply_rendered_cover_path(book_id,path)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" or path=="" then return false,false,{} end
    local changed=false
    local hero_changed=false
    local sections={}
    local function apply(book,section)
        if type(book)=="table" and tostring(self:_home_cover_render_id(book) or "")==book_id
            and tostring(book.home_cover_path or "")~=path then
            book.home_cover_path=path
            changed=true
            if section then sections[section]=true end
        end
    end
    if self._home_hero and tostring(self:_home_cover_render_id(self._home_hero) or "")==book_id then
        apply(self._home_hero)
        hero_changed=true
    end
    for key,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book,key) end
    end
    return changed,hero_changed,sections
end

function Plugin:_home_cover_target_fresh(target,inputs)
    target=tostring(target or "")
    if target=="" or lfs.attributes(target,"mode")~="file" then return false end
    if (tonumber(U.file_size(target) or 0) or 0)<=0 then return false end
    local target_mtime=tonumber(lfs.attributes(target,"modification") or 0) or 0
    if target_mtime<=0 then return false end
    local found=false
    for _,raw in ipairs(inputs or {}) do
        local path=tostring(raw or "")
        if path~="" and path~=target and lfs.attributes(path,"mode")=="file" then
            found=true
            local source_mtime=tonumber(lfs.attributes(path,"modification") or 0) or 0
            if source_mtime<=0 or source_mtime>target_mtime then return false end
        end
    end
    return found
end

function Plugin:_home_cover_input_stamp(inputs)
    local parts={}
    for _,raw in ipairs(inputs or {}) do
        local path=tostring(raw or "")
        if path~="" and lfs.attributes(path,"mode")=="file" then
            parts[#parts+1]=table.concat({
                path,
                tostring(tonumber(lfs.attributes(path,"modification") or 0) or 0),
                tostring(tonumber(U.file_size(path) or 0) or 0),
            },"|")
        end
    end
    table.sort(parts)
    return table.concat(parts,"+")
end

function Plugin:_home_schedule_cover_derivatives(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.covers=true
        return false
    end
    if not self.cover_render_async or not self.cover_render_async:available() then return false end
    local lightweight=self:_lightweight_enabled()
    local derivative_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_COVER_QUEUE) or 1) or math.huge
    local derivative_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_GAP) or 1.0) or .8

    local check_started=monotonic_wall_time()
    local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
    if sw<=0 or sh<=0 then return false end
    local thumb_w=math.max(240,math.min(420,math.floor(sw*.34+.5)))
    local thumb_h=math.max(340,math.floor(thumb_w/.69+.5))
    local render_dir=self.store.data_dir.."/cover-render-v1"
    local lock_dir=self.store.data_dir.."/lockscreen"
    local source_dir=self.store.data_dir.."/lockscreen-source"
    U.mkdir(render_dir); U.mkdir(lock_dir); U.mkdir(source_dir)

    local hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
    local items,seen={},{}
    for _,book in ipairs(books or {}) do
        if type(book)=="table" then
            local id=self:_home_cover_render_id(book)
            if id and not seen[id] then
                local sources,source_seen={},{}
                local function add(path)
                    path=tostring(path or "")
                    if path~="" and not source_seen[path] and lfs.attributes(path,"mode")=="file" then
                        source_seen[path]=true
                        sources[#sources+1]=path
                    end
                end
                add(book.cover_path)
                local stored=(book.bookId or book.book_id) and self.store:book(tostring(book.bookId or book.book_id)) or nil
                local record=(book.bookId or book.book_id) and self:_preferred_record(tostring(book.bookId or book.book_id)) or nil
                if type(stored)=="table" then add(stored.cover_path) end
                if type(record)=="table" then add(record.cover_path) end
                local file=tostring(book.file or (record and record.file) or "")
                if #sources>0 or (file~="" and U.file_exists(file)) then
                    seen[id]=true
                    local inputs={}
                    for _,path in ipairs(sources) do inputs[#inputs+1]=path end
                    if file~="" and U.file_exists(file) and not source_seen[file] then inputs[#inputs+1]=file end
                    local home_target=render_dir.."/"..U.id_name(id).."-home1-"..tostring(thumb_w).."x"..tostring(thumb_h)..".png"
                    local lock_target=(hero_id~="" and id==hero_id)
                        and (lock_dir.."/"..U.id_name(id).."-fill3-"..tostring(sw).."x"..tostring(sh)..".png") or nil
                    items[#items+1]={
                        id=id,
                        sources=sources,
                        inputs=inputs,
                        input_stamp=self:_home_cover_input_stamp(inputs),
                        file=file,
                        source_dir=source_dir,
                        home_target=home_target,
                        home_w=thumb_w,home_h=thumb_h,
                        lock_target=lock_target,
                        lock_w=sw,lock_h=sh,
                        home_fresh=self:_home_cover_target_fresh(home_target,inputs),
                        lock_fresh=not lock_target or self:_home_cover_target_fresh(lock_target,inputs),
                    }
                    if #items>=10 then break end
                end
            end
        end
    end
    if #items==0 then return false end

    local worker_items={}
    local fresh_count=0
    local fast_changed=false
    local fast_hero_changed=false
    local fast_sections={}
    local fast_ids={}
    for _,item in ipairs(items) do
        if item.home_fresh then
            fresh_count=fresh_count+1
            local changed,is_hero,sections=self:_home_apply_rendered_cover_path(item.id,item.home_target)
            fast_changed=fast_changed or changed
            fast_hero_changed=fast_hero_changed or is_hero
            if changed then fast_ids[item.id]=true end
            for section in pairs(sections or {}) do fast_sections[section]=true end
        end
        if item.lock_target and item.lock_fresh then
            local current_hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
            if current_hero_id~="" and item.id==current_hero_id then
                HOME_SESSION.screensaver_file=item.lock_target
                local current=HomeView.current()
                if current and current.opts then current.opts.screensaver_file=item.lock_target end
            end
        end
        if not (item.home_fresh and item.lock_fresh) and #worker_items<derivative_limit then
            worker_items[#worker_items+1]=item
        end
    end

    if fast_changed and HomeView.is_shown() and not self:_active_reader_ui() then
        for section in pairs(fast_sections) do self:_home_bump_section_revision(section) end
        local active=self._home_active_section or "account"
        if fast_hero_changed and self._home_hero then HomeView.update_hero(self._home_hero) end
        if fast_sections[active] then
            for id in pairs(fast_ids) do HomeView.update_book(id) end
        end
    end

    if #worker_items==0 then
        logger.info("[MiuRead][CoverRender] visible cache reused",
            "fresh=",tostring(fresh_count),
            "check_ms=",tostring(math.floor((monotonic_wall_time()-check_started)*1000+.5)))
        return false
    end

    local signature_parts={tostring(sw),tostring(sh),tostring(thumb_w),tostring(thumb_h),hero_id}
    for _,item in ipairs(worker_items) do
        signature_parts[#signature_parts+1]=table.concat({
            tostring(item.id),tostring(item.home_target),tostring(item.lock_target or ""),tostring(item.input_stamp or "")
        },"|")
    end
    local request_signature=table.concat(signature_parts,";")
    local now_clock=os.time()
    if self._home_cover_render_inflight_signature==request_signature then return false end
    if self._home_cover_render_last_signature==request_signature
        and now_clock-(tonumber(self._home_cover_render_last_clock) or 0)<5 then return false end
    if self._home_cover_render_failed_signature==request_signature
        and now_clock-(tonumber(self._home_cover_render_failed_clock) or 0)<600 then
        logger.info("[MiuRead][CoverRender] retry cooled down","seconds=600")
        return false
    end
    local competing=lightweight and (
        (self.home_metadata_async and self.home_metadata_async:busy())
        or (self.home_cover_async and self.home_cover_async:busy())
    )
    if self.cover_render_async:busy() or competing then
        if not self._home_cover_render_retry_task then
            local retry
            retry=function()
                if self._home_cover_render_retry_task~=retry then return end
                self._home_cover_render_retry_task=nil
                if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                    self:_home_schedule_cover_derivatives(books)
                end
            end
            self._home_cover_render_retry_task=retry
            UIManager:scheduleIn(derivative_gap,retry)
        end
        return false
    end

    self._home_cover_render_inflight_signature=request_signature
    self._home_cover_render_generation=(tonumber(self._home_cover_render_generation) or 0)+1
    local generation=self._home_cover_render_generation
    local worker=function()
        local CoverRender=require("miuread.cover_render")
        local LocalMetadataChild=require("miuread.local_metadata")
        local UChild=require("miuread.util")
        CoverRender.lower_priority()
        local out={}
        for _,item in ipairs(worker_items) do
            local sources={}
            for _,path in ipairs(item.sources or {}) do sources[#sources+1]=path end
            if item.file~="" and UChild.file_exists(item.file) then
                local ok,metadata=pcall(LocalMetadataChild.read,item.file,item.source_dir,{open_document=false,use_bim=true})
                if ok and type(metadata)=="table" and tostring(metadata.cover_path or "")~="" then
                    sources[#sources+1]=metadata.cover_path
                end
            end
            local source=CoverRender.best_source(sources)
            if source then
                local home_path=item.home_target
                if not CoverRender.is_fresh(home_path,source) then
                    home_path=CoverRender.render_home(source,item.home_target,item.home_w,item.home_h)
                end
                local lock_path
                if item.lock_target then
                    lock_path=item.lock_target
                    if not CoverRender.is_fresh(lock_path,source) then
                        lock_path=CoverRender.render_fill(source,item.lock_target,item.lock_w,item.lock_h,{ink_boost=.075})
                    end
                end
                out[#out+1]={id=item.id,home_path=home_path,lock_path=lock_path,source=source}
            end
        end
        return out
    end

    logger.info("[MiuRead][CoverRender] worker scheduled",
        "pending=",tostring(#worker_items),"fresh=",tostring(fresh_count),
        "check_ms=",tostring(math.floor((monotonic_wall_time()-check_started)*1000+.5)))
    local render_started=monotonic_wall_time()
    local started=self.cover_render_async:run("home-cover-render",worker,function(result)
        if self._home_cover_render_inflight_signature==request_signature then
            self._home_cover_render_inflight_signature=nil
        end
        if generation~=self._home_cover_render_generation then return end
        if not result or result.ok~=true or type(result.value)~="table" then
            self._home_cover_render_failed_signature=request_signature
            self._home_cover_render_failed_clock=os.time()
            if result and result.error then logger.warn("[MiuRead][CoverRender] worker failed",U.first_line(result.error,120)) end
            return
        end
        self._home_cover_render_failed_signature=nil
        self._home_cover_render_failed_clock=0
        self._home_cover_render_last_signature=request_signature
        self._home_cover_render_last_clock=os.time()
        if self._download_runtime~=nil then
            -- Rendering may have started just before a download. Keep the files,
            -- but do not touch the visible shelf until the download finishes.
            logger.info("[MiuRead][CoverRender] visible apply deferred during download")
            return
        end
        local any_changed=false
        local hero_changed=false
        local changed_sections={}
        local changed_ids={}
        for _,entry in ipairs(result.value) do
            if entry.home_path and lfs.attributes(entry.home_path,"mode")=="file" then
                local changed,is_hero,sections=self:_home_apply_rendered_cover_path(entry.id,entry.home_path)
                any_changed=any_changed or changed
                hero_changed=hero_changed or is_hero
                if changed then changed_ids[entry.id]=true end
                for section in pairs(sections or {}) do changed_sections[section]=true end
            end
            if entry.lock_path and lfs.attributes(entry.lock_path,"mode")=="file" then
                local current_hero_id=tostring(self:_home_cover_render_id(self._home_hero) or "")
                if current_hero_id~="" and entry.id==current_hero_id then
                    HOME_SESSION.screensaver_file=entry.lock_path
                    local current=HomeView.current()
                    if current and current.opts then current.opts.screensaver_file=entry.lock_path end
                end
            end
        end
        if any_changed and HomeView.is_shown() and not self:_active_reader_ui() then
            for section in pairs(changed_sections) do self:_home_bump_section_revision(section) end
            local active=self._home_active_section or "account"
            if hero_changed and self._home_hero then HomeView.update_hero(self._home_hero) end
            if changed_sections[active] then
                for id in pairs(changed_ids) do HomeView.update_book(id) end
            end
        end
        logger.info("[MiuRead][CoverRender] visible cache ready",
            "rendered=",tostring(#result.value),"fresh=",tostring(fresh_count),
            "elapsed_ms=",tostring(math.floor((monotonic_wall_time()-render_started)*1000+.5)),
            "lightweight=",tostring(lightweight))
        if lightweight and HomeView.is_shown() and not self:_active_reader_ui() then
            UIManager:scheduleIn(derivative_gap,function()
                if HomeView.is_shown() and not self:_active_reader_ui() and not self:_home_ui_busy() then
                    self:_home_schedule_cover_derivatives(books)
                end
            end)
        end
    end,55)
    if started~=true and self._home_cover_render_inflight_signature==request_signature then
        self._home_cover_render_inflight_signature=nil
    end
    return started==true
end

function Plugin:_time_preferences()
    local preferences=self.store:preferences()
    preferences.time_display=TimeZone.normalize(preferences.time_display)
    return preferences.time_display,preferences
end

function Plugin:_display_time(format,timestamp)
    local value=self:_time_preferences()
    return TimeZone.date(value,format,timestamp)
end

function Plugin:_save_time_preferences(value,preferences,message)
    preferences=preferences or self.store:preferences()
    preferences.time_display=TimeZone.normalize(value)
    self.store:save_preferences(preferences)
    -- MiuRead now formats its own regional time; it no longer depends on
    -- changing Kindle's process timezone.
    TimeZone.apply(preferences.time_display)
    if HomeView.is_shown() then self:_refresh_home_view(message or "时间显示已更新","full")
    elseif message then self:toast(message,2) end
    return true
end

function Plugin:_set_time_mode(mode)
    local value,preferences=self:_time_preferences()
    value.mode=mode
    self:_save_time_preferences(value,preferences,"时间来源已更新")
end

function Plugin:time_mode_menu()
    return {
        {text="跟随设备",post_text="使用 Kindle / KOReader 当前时区",checked_func=function()
            return (self:_time_preferences()).mode=="device"
        end,callback=function() self:_set_time_mode("device") end},
        {text="地区时区",post_text="支持常用地区及夏令时",checked_func=function()
            return (self:_time_preferences()).mode=="zone"
        end,callback=function() self:_set_time_mode("zone") end},
        {text="固定 UTC 偏移",post_text="适合没有地区时区数据的旧设备",checked_func=function()
            return (self:_time_preferences()).mode=="fixed"
        end,callback=function() self:_set_time_mode("fixed") end},
    }
end

function Plugin:time_zone_menu()
    local rows={}
    for _,zone in ipairs(TimeZone.zones()) do
        local id,label=zone.id,zone.label
        rows[#rows+1]={text=label,post_text=TimeZone.zone_offset_text(id),checked_func=function()
            local value=self:_time_preferences()
            return value.mode=="zone" and value.zone==id
        end,callback=function()
            local value,preferences=self:_time_preferences()
            value.mode="zone"; value.zone=id
            self:_save_time_preferences(value,preferences,"时区已切换为"..label)
        end}
    end
    return rows
end

function Plugin:time_fixed_offset_dialog()
    local value,preferences=self:_time_preferences()
    local dialog
    dialog=InputDialog:new{
        title="固定 UTC 偏移",
        description="输入例如 +09:00、+08:00 或 -05:00",
        input=TimeZone.offset_text(value.offset_minutes),
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text="保存",is_enter_default=true,callback=function()
                local parsed=TimeZone.parse_offset(dialog:getInputText())
                if parsed==nil then self:toast("请输入 -14:00 到 +14:00 之间的有效偏移",3); return end
                UIManager:close(dialog)
                value.mode="fixed"; value.offset_minutes=parsed
                self:_save_time_preferences(value,preferences,"固定时区已更新")
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:time_display_settings_menu()
    local value=self:_time_preferences()
    return {
        {text="时间来源",post_text=TimeZone.label(value),sub_item_table_func=function() return self:time_mode_menu() end},
        {text="地区时区",post_text=TimeZone.zone(value.zone) and TimeZone.zone(value.zone).label or "中国 · 北京",sub_item_table_func=function() return self:time_zone_menu() end},
        {text="固定 UTC 偏移",post_text=TimeZone.offset_text(value.offset_minutes),callback=function() self:time_fixed_offset_dialog() end},
        {text="当前时间",post_text=self:_display_time("%Y-%m-%d %H:%M"),enabled=false},
        {text="说明",post_text="只调整觅阅显示 不修改 Kindle 系统时钟",enabled=false},
    }
end

function Plugin:_toggle_home_lockscreen(confirmed)
    local home,preferences=self:_home_preferences()
    local enabling=home.lockscreen_recent==false
    if enabling and confirmed~=true and self:_notice_enabled("lockscreen") then
        local dialog
        dialog=ButtonDialog:new{title="锁屏封面需要生成和写入图片，关闭书籍或刷新主页时可能会稍慢。",title_align="center",buttons={
            {{text="开启",callback=function() UIManager:close(dialog); self:_toggle_home_lockscreen(true) end}},
            {{text="开启并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("lockscreen",false); self:_toggle_home_lockscreen(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    home.lockscreen_recent=enabling
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(home.lockscreen_recent and "主页锁屏将显示最近阅读封面" or "已恢复 KOReader 原锁屏设置","header")
end

function Plugin:home_layout_settings_menu()
    local home=self:_home_preferences()
    return {
        {text="标准布局",post_text="继续阅读与分类书架",checked_func=function() return home.layout_style~="compact" end,callback=function()
            self:_set_home_layout("desk")
        end},
        {text="紧凑布局",post_text="缩小内容，适合旧设备",checked_func=function() return home.layout_style=="compact" end,callback=function()
            self:_set_home_layout("compact")
        end},
    }
end

function Plugin:_set_home_display_size(mode)
    if mode~="compact" and mode~="standard" and mode~="large" then mode="standard" end
    local home,preferences=self:_home_preferences()
    home.display_size=mode
    self:_save_home_preferences(home,preferences)
    local labels={compact="紧凑",standard="标准",large="大号"}
    self:_refresh_home_view("觅阅显示大小已切换为"..(labels[mode] or "标准"),"full")
end

function Plugin:home_display_size_menu()
    local labels={compact="紧凑",standard="标准",large="大号"}
    local details={compact="显示更多内容",standard="默认，适合多数设备",large="更大的文字与图标"}
    local rows={}
    for _,mode in ipairs({"compact","standard","large"}) do
        local key=mode
        rows[#rows+1]={
            text=labels[key],post_text=details[key],
            checked_func=function() return self:_home_preferences().display_size==key end,
            callback=function() self:_set_home_display_size(key) end,
        }
    end
    return rows
end

function Plugin:_home_ui_body_font_name()
    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        value=ok and U.trim(tostring(value or "")) or ""
        if value~="" then return value end
    end
    local font=self.ui and self.ui.font
    local value=font and U.trim(tostring(font.font_face or "")) or ""
    if value~="" then return value end
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,saved=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        saved=ok and U.trim(tostring(saved or "")) or ""
        if saved~="" then return saved end
    end
    return nil
end

function Plugin:_home_ui_font_name(home)
    home=type(home)=="table" and home or (self.store:preferences().home_ui or {})
    local mode=tostring(home.ui_font_mode or "default")
    if mode=="follow" then return self:_home_ui_body_font_name() end
    if mode=="custom" then
        local value=U.trim(tostring(home.ui_font_face or ""))
        return value~="" and value or nil
    end
    return nil
end

function Plugin:_home_ui_font_label(home)
    home=type(home)=="table" and home or self:_home_preferences()
    local mode=tostring(home.ui_font_mode or "default")
    if mode=="follow" then
        local name=self:_home_ui_body_font_name()
        return name and ("跟随正文 · "..name) or "跟随正文"
    end
    if mode=="custom" then
        local name=U.trim(tostring(home.ui_font_face or ""))
        return name~="" and name or "自定义字体"
    end
    return "界面默认"
end

function Plugin:_set_home_ui_font(mode,face)
    mode=tostring(mode or "default")
    if mode~="follow" and mode~="custom" then mode="default" end
    local home,preferences=self:_home_preferences()
    home.ui_font_mode=mode
    if face~=nil then home.ui_font_face=U.trim(tostring(face or "")) end
    if mode=="custom" and U.trim(tostring(home.ui_font_face or ""))=="" then
        home.ui_font_mode="default"
    end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view("觅阅界面字体已更新","full")
    else self:toast("觅阅界面字体已更新",2) end
    return true
end

function Plugin:home_ui_font_face_menu()
    local rows={}
    local choices=self:_reader_font_face_choices()
    if #choices==0 then return {{text="未读取到可用正文字体",enabled=false}} end
    for _,choice in ipairs(choices) do
        local selected=tostring(choice.name or "")
        local label=tostring(choice.label or selected)
        rows[#rows+1]={
            text=label,
            checked_func=function()
                local home=self:_home_preferences()
                return home.ui_font_mode=="custom" and tostring(home.ui_font_face or "")==selected
            end,
            keep_menu_open=true,
            callback=function() self:_set_home_ui_font("custom",selected) end,
        }
    end
    return rows
end

function Plugin:home_ui_font_menu()
    local home=self:_home_preferences()
    return {
        {text="界面默认字体",checked_func=function() return self:_home_preferences().ui_font_mode=="default" end,keep_menu_open=true,callback=function() self:_set_home_ui_font("default") end},
        {text="跟随阅读正文字体",post_text=self:_home_ui_body_font_name() or "最近使用",checked_func=function() return self:_home_preferences().ui_font_mode=="follow" end,keep_menu_open=true,callback=function() self:_set_home_ui_font("follow") end},
        {text="自定义字体",post_text=home.ui_font_mode=="custom" and self:_home_ui_font_label(home) or "选择正文字体库",sub_item_table_func=function() return self:home_ui_font_face_menu() end},
    }
end

function Plugin:_home_toggle_source(section)
    local allowed={account=true,generated=true,["local"]=true,mp=true}
    if not allowed[section] then return false end
    local home,preferences=self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local currently=home.visible_sections[section]~=false
    if currently then
        local enabled=0
        for _,key in ipairs(HOME_SECTION_ORDER) do
            if home.visible_sections[key]~=false then enabled=enabled+1 end
        end
        if enabled<=1 then self:toast("至少保留一个书架来源",2); return false end
    end
    home.visible_sections[section]=not currently
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:_toggle_home_auto_hide_empty()
    local home,preferences=self:_home_preferences()
    home.auto_hide_empty=home.auto_hide_empty~=true
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
end

local HOME_SOURCE_LABELS={account="微信书架",generated="已下载",["local"]="本地书籍",mp="公众号"}

function Plugin:_home_move_source(key,delta)
    local home,preferences=self:_home_preferences()
    local order=home.source_order or HOME_SECTION_ORDER
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    home.source_order=order
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:home_source_order_menu()
    local home=self:_home_preferences()
    local rows={}
    for index,key in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[item_key] or item_key,
            post_text=tostring(item_index),
            sub_item_table_func=function()
                local current=self:_home_preferences().source_order or HOME_SECTION_ORDER
                local current_index
                for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
                current_index=current_index or item_index
                return {
                    {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_home_move_source(item_key,-1) end},
                    {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_home_move_source(item_key,1) end},
                }
            end,
        }
    end
    return rows
end

function Plugin:home_source_settings_menu()
    local home=self:_home_preferences()
    local rows={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local key=section
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[key],
            checked_func=function() return self:_home_preferences().visible_sections[key]~=false end,
            keep_menu_open=true,
            callback=function() self:_home_toggle_source(key) end,
        }
    end
    rows[#rows+1]={
        text="自动隐藏空来源",
        checked_func=function() return self:_home_preferences().auto_hide_empty==true end,
        keep_menu_open=true,
        callback=function() self:_toggle_home_auto_hide_empty() end,
    }
    rows[#rows+1]={text="调整来源顺序",sub_item_table_func=function() return self:home_source_order_menu() end}
    rows[#rows+1]={text="恢复默认顺序",callback=function()
        local current,preferences=self:_home_preferences()
        current.source_order=U.copy(HOME_SECTION_ORDER)
        self:_save_home_preferences(current,preferences)
        self:_refresh_home_view("书架来源顺序已恢复默认","content")
    end}
    return rows
end

local HOME_ACTION_LABELS={
    refresh="更新",search="搜索",downloads="下载",sync="同步",sleep="休眠",
    miuread_settings="觅阅设置",all_books="全部书籍",history="阅读历史",file_manager="文件管理",screenshot="截图",
}
local HOME_PANEL_LABELS={
    wifi="Wi-Fi",rotate="旋转屏幕",screenshot="截图",koreader_settings="KOReader 设置",
    return_koreader="返回 KOReader",quit="退出 KOReader",frontlight="前光",sync="同步",
    miuread_settings="觅阅设置",downloads="下载",restart="重启 KOReader",sleep="休眠",full_refresh="全屏刷新",
}

function Plugin:_home_toggle_group_item(group,key)
    local home,preferences=self:_home_preferences()
    local is_action=group=="action"
    local items_key=is_action and "action_items" or "panel_items"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local max_count=6
    local items=home[items_key] or {}
    local currently=items[key]==true
    local count=0
    for _,name in ipairs(order) do if items[name]==true then count=count+1 end end
    if not currently and count>=max_count then
        self:toast((is_action and "主页快捷栏最多显示六项" or "下滑工具栏最多显示六项"),2)
        return false
    end
    items[key]=not currently
    home[items_key]=items
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_home_move_group_item(group,key,delta)
    local home,preferences=self:_home_preferences()
    local order_key=group=="action" and "action_order" or "panel_order"
    local order=home[order_key] or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    home[order_key]=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_home_group_order_menu(group)
    local home=self:_home_preferences()
    local order=group=="action" and (home.action_order or HOME_ACTION_ITEM_ORDER) or (home.panel_order or HOME_PANEL_ITEM_ORDER)
    local labels=group=="action" and HOME_ACTION_LABELS or HOME_PANEL_LABELS
    local rows={}
    for index,key in ipairs(order) do
        local item_key,item_index=key,index
        rows[#rows+1]={
            text=labels[item_key] or item_key,post_text=tostring(item_index),
            sub_item_table_func=function()
                local current=self:_home_preferences()[group=="action" and "action_order" or "panel_order"] or order
                local current_index
                for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
                current_index=current_index or item_index
                return {
                    {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_home_move_group_item(group,item_key,-1) end},
                    {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_home_move_group_item(group,item_key,1) end},
                }
            end,
        }
    end
    return rows
end

function Plugin:_home_group_settings_menu(group)
    local is_action=group=="action"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local defaults=is_action and HOME_ACTION_ITEM_DEFAULT or HOME_PANEL_ITEM_DEFAULT
    local labels=is_action and HOME_ACTION_LABELS or HOME_PANEL_LABELS
    local items_key=is_action and "action_items" or "panel_items"
    local order_key=is_action and "action_order" or "panel_order"
    local version_key=is_action and "action_layout_version" or "panel_layout_version"
    local rows={}
    for _,key in ipairs(order) do
        local item_key=key
        rows[#rows+1]={
            text=labels[item_key] or item_key,
            checked_func=function() return self:_home_preferences()[items_key][item_key]==true end,
            keep_menu_open=true,
            callback=function() self:_home_toggle_group_item(group,item_key) end,
        }
    end
    rows[#rows+1]={text="调整顺序",sub_item_table_func=function() return self:_home_group_order_menu(group) end}
    rows[#rows+1]={text="恢复推荐布局",callback=function()
        local home,preferences=self:_home_preferences()
        home[items_key]={}
        for _,key in ipairs(order) do home[items_key][key]=defaults[key]==true end
        home[order_key]=U.copy(order)
        home[version_key]=is_action and HOME_ACTION_LAYOUT_VERSION or HOME_PANEL_LAYOUT_VERSION
        self:_save_home_preferences(home,preferences)
        if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
        self:toast("已恢复推荐布局")
    end}
    return rows
end

function Plugin:home_action_settings_menu() return self:_home_group_settings_menu("action") end
function Plugin:home_panel_settings_menu() return self:_home_group_settings_menu("panel") end

function Plugin:_home_group_enabled_count(group)
    local home=self:_home_preferences()
    local is_action=group=="action"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local items=home[is_action and "action_items" or "panel_items"] or {}
    local count=0
    for _,key in ipairs(order) do if items[key]==true then count=count+1 end end
    return count
end

function Plugin:_home_restore_all_quick_defaults()
    local home,preferences=self:_home_preferences()
    home.action_items={}
    for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do home.action_items[key]=HOME_ACTION_ITEM_DEFAULT[key]==true end
    home.action_order=U.copy(HOME_ACTION_ITEM_ORDER)
    home.action_layout_version=HOME_ACTION_LAYOUT_VERSION
    home.panel_items={}
    for _,key in ipairs(HOME_PANEL_ITEM_ORDER) do home.panel_items[key]=HOME_PANEL_ITEM_DEFAULT[key]==true end
    home.panel_order=U.copy(HOME_PANEL_ITEM_ORDER)
    home.panel_layout_version=HOME_PANEL_LAYOUT_VERSION
    if not Device:canSuspend() then home.panel_items.sleep=false end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    self:toast("主页快捷布局已恢复推荐设置",2)
end

function Plugin:home_customization_menu()
    return {
        {text="主页快捷栏",post_text=tostring(self:_home_group_enabled_count("action")).." / 6",sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="下滑工具栏",post_text=tostring(self:_home_group_enabled_count("panel")).." / 6",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="恢复全部推荐布局",post_text="主页 + 下滑工具栏",callback=function() self:_home_restore_all_quick_defaults() end},
    }
end

function Plugin:show_home_customization(anchor)
    return self:_show_standalone_menu("主页自定义",self:home_customization_menu(),{anchor=anchor})
end

local READER_QUICK_LABELS={
    toc="目录",progress="阅读进度",font="字体排版",frontlight="前光",sync="阅读同步",
    comment_font="评论显示",page_display="页面显示",home="觅阅书架",typeset="高级排版",
    current_book="当前书籍",downloads="下载管理",full_refresh="全屏刷新",
    koreader_menu="KOReader 高级菜单",sleep="休眠",
}

function Plugin:_reader_preferences()
    local preferences=self.store:preferences()
    local reader=type(preferences.reader_ui)=="table" and preferences.reader_ui or {}
    local changed=false
    if reader.enabled==nil then reader.enabled=true; changed=true end
    if reader.plugin_mode_enabled~=false then reader.plugin_mode_enabled=false; changed=true end
    -- beta.11 keeps the reading surface completely clean while the panel is hidden.
    -- All reader controls live in the transient quick panel or the complete MiuRead menu.
    if reader.show_title~=false then reader.show_title=false; changed=true end
    if reader.show_status~=false then reader.show_status=false; changed=true end
    if reader.show_recent~=false then reader.show_recent=false; changed=true end
    if type(reader.recent_actions)~="table" or #reader.recent_actions>0 then reader.recent_actions={}; changed=true end
    if reader.edge_guard_enabled==nil then reader.edge_guard_enabled=true; changed=true end
    local edge_percent=tonumber(reader.edge_guard_percent)
    if edge_percent~=5 and edge_percent~=10 and edge_percent~=15 and edge_percent~=20 then
        reader.edge_guard_percent=10
        changed=true
    end

    local fixed_order={"toc","progress","search","back","font","spacing","page","comments","bookmark","highlight","thought","sync"}
    local fixed_items={toc=true,progress=true,search=true,back=true,font=true,spacing=true,page=true,comments=true,bookmark=true,highlight=true,thought=true,sync=true}
    local order_ok=type(reader.quick_order)=="table" and #reader.quick_order==#fixed_order
    if order_ok then
        for index,key in ipairs(fixed_order) do
            if reader.quick_order[index]~=key then order_ok=false; break end
        end
    end
    local items_ok=type(reader.quick_items)=="table"
    if items_ok then
        local count=0
        for key,value in pairs(reader.quick_items) do
            if value==true then
                count=count+1
                if fixed_items[key]~=true then items_ok=false; break end
            end
        end
        if count~=#fixed_order then items_ok=false end
    end
    if tonumber(reader.quick_layout_version)~=11 or not order_ok or not items_ok then
        reader.quick_layout_version=11
        reader.quick_order=U.copy(fixed_order)
        reader.quick_items=U.copy(fixed_items)
        changed=true
    end

    preferences.reader_ui=reader
    if changed then self.store:save_preferences(preferences) end
    return reader,preferences
end

function Plugin:_reader_panel_active()
    local reader=self:_reader_preferences()
    return self:_home_enabled() and reader.enabled~=false
end

function Plugin:_save_reader_preferences(reader,preferences)
    preferences=preferences or self.store:preferences()
    preferences.reader_ui=reader
    self.store:save_preferences(preferences)
end

function Plugin:_reader_edge_guard_state()
    local reader=self:_reader_preferences()
    local percent=tonumber(reader.edge_guard_percent) or 10
    if percent~=5 and percent~=10 and percent~=15 and percent~=20 then percent=10 end
    return reader.edge_guard_enabled~=false,percent
end

function Plugin:_reader_toggle_edge_guard()
    local reader,preferences=self:_reader_preferences()
    reader.edge_guard_enabled=reader.edge_guard_enabled==false
    self:_save_reader_preferences(reader,preferences)
    return reader.edge_guard_enabled~=false
end

function Plugin:_reader_set_edge_guard_percent(percent)
    percent=tonumber(percent)
    if percent~=5 and percent~=10 and percent~=15 and percent~=20 then return false end
    local reader,preferences=self:_reader_preferences()
    reader.edge_guard_percent=percent
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:reader_quick_panel_settings_menu()
    return {
        {text="启用觅阅阅读控制中心",checked_func=function() return self:_reader_preferences().enabled~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.enabled=reader.enabled==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="阅读评论",post_text=self:_thoughts_enabled_label(),checked_func=function() return self:_thoughts_enabled() end,keep_menu_open=true,callback=function() self:_toggle_thoughts_enabled() end},
        {text="评论显示设置",post_text=self:_thought_font_size_label(),sub_item_table_func=function() return self:thought_font_settings_menu() end},
    }
end

function Plugin:_notice_enabled(key)
    local notices=self.store:preferences().notices or {}
    return notices[key]~=false
end

function Plugin:_set_notice_enabled(key,enabled)
    local p=self.store:preferences(); p.notices=type(p.notices)=="table" and p.notices or {}
    p.notices[key]=enabled==true
    self.store:save_preferences(p)
end

local NOTICE_LABELS={
    reader_download="阅读时下载提醒",low_battery="低电量下载提醒",low_storage="存储空间提醒",
    full_refresh="全屏刷新说明",lockscreen="锁屏封面影响说明",library_scan="扫描书库提醒",
    repair_while_reading="阅读中修复提醒",mode_switch="运行模式切换说明",mode_environment="进入模式说明",
}

function Plugin:notice_settings_menu()
    local order={"reader_download","low_battery","low_storage","full_refresh","lockscreen","library_scan","repair_while_reading","mode_switch","mode_environment"}
    local rows={}
    for _,key in ipairs(order) do
        local notice_key=key
        rows[#rows+1]={text=NOTICE_LABELS[notice_key] or notice_key,checked_func=function() return self:_notice_enabled(notice_key) end,keep_menu_open=true,callback=function()
            self:_set_notice_enabled(notice_key,not self:_notice_enabled(notice_key))
        end}
    end
    rows[#rows+1]={text="恢复全部使用提醒",callback=function()
        for _,key in ipairs(order) do self:_set_notice_enabled(key,true) end
        self:toast("使用提醒已恢复")
    end}
    rows[#rows+1]={text="数据删除与覆盖确认",post_text="始终保留",enabled=false}
    return rows
end

function Plugin:download_reader_policy_menu()
    local choices={{"ask","每次询问（推荐）"},{"allow","允许阅读时后台下载"},{"after_reading","退出阅读后再下载"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return tostring(self.store:preferences().download_reader_policy or "ask")==key end,callback=function()
            local p=self.store:preferences(); p.download_reader_policy=key; self.store:save_preferences(p); self:toast("阅读时下载策略已更新")
        end}
    end
    return rows
end

function Plugin:_download_network_mode()
    return tostring((self.store:preferences() or {}).download_network_mode or "auto")=="ipv4" and "ipv4" or "auto"
end

function Plugin:_download_network_mode_label()
    return self:_download_network_mode()=="ipv4" and "IPv4" or "自动"
end

function Plugin:_set_download_network_mode(mode,quiet)
    mode=tostring(mode or "auto")=="ipv4" and "ipv4" or "auto"
    local preferences=self.store:preferences()
    preferences.download_network_mode=mode
    self.store:save_preferences(preferences)
    local active=self.download_task and self.download_task:busy()
    if active then
        local ok,err=self.download_task:set_network_mode(mode)
        if not ok then
            logger.warn("[MiuRead][Download] active network mode switch unavailable",tostring(err))
            if quiet~=true then self:toast("设置已保存，将从下一次下载生效",3) end
            return false
        end
    end
    if quiet~=true then
        self:toast(mode=="ipv4" and "下载网络已切换为 IPv4" or "下载网络已恢复自动选择",3)
    end
    return true
end

function Plugin:download_network_mode_menu()
    return {
        {text="自动（推荐）",radio=true,checked_func=function() return self:_download_network_mode()=="auto" end,callback=function() self:_set_download_network_mode("auto") end},
        {text="仅 IPv4",radio=true,checked_func=function() return self:_download_network_mode()=="ipv4" end,callback=function() self:_set_download_network_mode("ipv4") end},
    }
end

function Plugin:_show_download_ipv4_suggestion(runtime,state)
    if not runtime or runtime.network_prompted==true then return end
    runtime.network_prompted=true
    -- Mark the current task as already prompted before showing the dialog.
    -- The worker keeps downloading, and a UI transition/restart cannot turn
    -- the same detection into repeated prompts. Choosing IPv4 below overwrites
    -- this task-local silent marker immediately.
    if self.download_task and self.download_task:busy() then
        self.download_task:dismiss_network_suggestion()
    end
    local auto=tonumber(state and state.network_auto_seconds)
    local ipv4=tonumber(state and state.network_ipv4_seconds)
    local comparison=""
    if auto and ipv4 then
        comparison="\n\n自动线路约 "..string.format("%.1f",auto).." 秒，IPv4 约 "..string.format("%.1f",ipv4).." 秒。"
    end
    local dialog
    dialog=ButtonDialog:new{
        title="检测到 IPv4 下载更快\n\n当前下载多次响应较慢。觅阅已对同一服务器进行了两组网络对照，两组测试中 IPv4 都明显更快。"..comparison.."\n\n是否切换到 IPv4？",
        title_align="center",
        buttons={
            {{text="切换 IPv4",callback=function()
                UIManager:close(dialog)
                local switched=self:_set_download_network_mode("ipv4",true)
                if switched then
                    self:status_toast("下载网络","已切换为 IPv4，当前下载从下一次请求开始使用",4)
                else
                    self:status_toast("下载网络","IPv4 设置已保存，将从下一次下载生效",4)
                end
            end}},
            {{text="继续当前网络",callback=function()
                UIManager:close(dialog)
            end}},
        },
    }
    UIManager:show(dialog)
end

function Plugin:show_home_layout_dialog()
    local home=self:_home_preferences()
    local function choose(style)
        self:_set_home_layout(style)
    end
    return self:_show_standalone_menu("页面布局",{
        {text="标准布局",radio=true,checked_func=function() return home.layout_style~="compact" end,callback=function() choose("desk") end},
        {text="紧凑布局",radio=true,checked_func=function() return home.layout_style=="compact" end,callback=function() choose("compact") end},
    })
end

function Plugin:_home_close_to_native(show_notice)
    -- This is the only temporary path that intentionally reveals FileManager.
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=true
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    HOME_EXPECTED_CLOSE=true
    self:_home_stop_background("temporary native visit")
    -- Ensure there is always a native page below the fullscreen MiuRead home.
    self:_ensure_filemanager_base(HOME_RETURN_FILE)
    HomeQuickPanel.close()
    ActionSheet.close()
    HomeView.close(true)
    self._home_view=nil
    self:_set_foreground("native")
    HOME_EXPECTED_CLOSE=false
    persist_home_session()
    if show_notice~=false then
        self:toast("已进入 KOReader；可从“返回觅阅主页”回到觅阅",3)
    end
    return true
end

function Plugin:_home_leave_and_run(reason,callback)
    sync_home_session()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    persist_home_session()
    self._home_child_reason=reason or "home action"
    local runner=function()
        local ok,err=xpcall(callback,debug.traceback)
        if not ok then
            logger.warn("[MiuRead][Home] action failed",tostring(reason),tostring(err))
            self:info("这个入口暂时无法打开。\n\n"..tostring(err))
        end
    end
    if type(UIManager.tickAfterNext)=="function" then UIManager:tickAfterNext(runner)
    else UIManager:scheduleIn(.05,runner) end
end

function Plugin:_show_miuread_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
    if #items==0 then self:info("没有可用选项"); return nil end

    local function build_rows()
        local rows={}
        for _,entry in ipairs(items) do
            local source=entry
            local enabled=source.enabled~=false
            if type(source.enabled_func)=="function" then
                local ok,value=pcall(source.enabled_func)
                enabled=ok and value~=false
            end
            local label=""
            if type(source.text_func)=="function" then
                local ok,value=pcall(source.text_func)
                label=ok and tostring(value or "") or ""
            else
                label=tostring(source.text or "")
            end
            local checked=false
            if type(source.checked_func)=="function" then
                local ok,value=pcall(source.checked_func)
                checked=ok and value==true
            end
            if checked then label=(source.radio==true and "● " or "✓ ")..label end

            local value=source.post_text
            if type(value)=="function" then
                local ok,result=pcall(value)
                value=ok and result or ""
            end
            value=tostring(value or "")

            local row={
                label=label,
                value=value,
                detail=tostring(source.detail or ""),
                enabled=enabled,
                checked=checked,
                bold=source.separator==true or source.heading==true,
                arrow=false,
            }
            local icon_key=source.icon_key or source.icon
            if icon_key and tostring(icon_key)~="" then row.icon=tostring(icon_key) end

            if source.sub_item_table_func or source.sub_item_table then
                row.arrow=true
                row.callback=function()
                    local child=source.sub_item_table
                    if type(source.sub_item_table_func)=="function" then
                        local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                        if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                        child=value
                    end
                    local child_options=U.copy(options)
                    child_options.on_back=function()
                        self:_show_miuread_menu(title,items,options)
                    end
                    child_options.on_close=nil
                    self:_show_miuread_menu(tostring(source.text or title),child,child_options)
                end
            elseif type(source.callback)=="function" then
                -- Only a real child page gets a chevron. Toggles and direct
                -- actions stay visually flat even when their menu closes.
                row.arrow=source.arrow==true
                row.keep_open=source.keep_menu_open==true
                row.callback=function(...)
                    logger.info("[MiuRead][Menu] MiuRead item tapped",tostring(source.text or ""))
                    local args={...}
                    local ok,err=xpcall(function() return source.callback(unpack_args(args)) end,debug.traceback)
                    if not ok then
                        logger.warn("[MiuRead][Menu] MiuRead action failed",tostring(source.text or ""),tostring(err))
                        self:info("这个入口暂时无法打开。\n\n"..tostring(err))
                    end
                end
            end
            rows[#rows+1]=row
        end
        return rows
    end

    local on_back=options.on_back or options.on_close
    local on_home=options.on_home
    if on_home==nil and HomeView.is_shown() then
        on_home=function()
            if HomeView.is_shown() then HomeView.raise(true) end
        end
    end
    local dialog,err=ReaderListDialog.show{
        title=tostring(title or "觅阅"),
        subtitle=tostring(options.subtitle or ""),
        items=build_rows,
        page_size=tonumber(options.page_size) or 7,
        on_back=on_back,
        on_home=on_home,
    }
    if not dialog then
        logger.warn("[MiuRead][Menu] custom list unavailable",tostring(err or "unknown"))
    end
    return dialog
end

function Plugin:_show_home_bubble_menu(title,items,options)
    options=type(options)=="table" and options or {}
    items=type(items)=="table" and items or {}
    local resolved={}
    for _,source in ipairs(items) do
        if type(source)=="table" and source.hidden~=true then
            local enabled=source.enabled~=false
            if type(source.enabled_func)=="function" then
                local ok,value=pcall(source.enabled_func)
                enabled=ok and value~=false
            end
            local label=source.text
            if label==nil and type(source.text_func)=="function" then
                local ok,value=pcall(source.text_func); if ok then label=value end
            end
            label=tostring(label or "")
            if type(source.checked_func)=="function" then
                local ok,checked=pcall(source.checked_func)
                if ok and checked==true then label="✓ "..label end
            end
            resolved[#resolved+1]={source=source,label=label,enabled=enabled,detail=tostring(source.post_text or "")}
        end
    end
    if #resolved==0 then return ActionSheet.show{anchor=options.anchor,title=tostring(title or "觅阅"),subtitle="没有可用选项",auto_close=1.6} end
    local page_size=math.max(4,math.min(8,tonumber(options.page_size) or 8))
    local pages=math.max(1,math.ceil(#resolved/page_size))
    local page=math.max(1,math.min(pages,tonumber(options.page) or 1))
    local first=(page-1)*page_size+1
    local last=math.min(#resolved,first+page_size-1)
    local actions={}
    local parent=options._bubble_parent
    for index=first,last do
        local row=resolved[index]
        local source=row.source
        local has_child=source.sub_item_table_func~=nil or source.sub_item_table~=nil
        actions[#actions+1]={
            icon=has_child and "›" or (row.label:sub(1,3)=="✓ " and "✓" or "•"),
            label=row.label,detail=row.detail,enabled=row.enabled,submenu=has_child,
            callback=function()
                if has_child then
                    local child=source.sub_item_table
                    if type(source.sub_item_table_func)=="function" then
                        local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                        if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                        child=value
                    end
                    local child_opts=U.copy(options)
                    child_opts.page=1
                    child_opts._bubble_parent={title=title,items=items,options=U.copy(options)}
                    child_opts._bubble_parent.options._bubble_parent=parent
                    return self:_show_home_bubble_menu(tostring(source.text or title),child,child_opts)
                end
                if type(source.callback)=="function" then
                    local ok,err=xpcall(source.callback,debug.traceback)
                    if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(err)); return end
                    if source.keep_menu_open==true then
                        local reopen=U.copy(options); reopen.page=page
                        UIManager:scheduleIn(.04,function() self:_show_home_bubble_menu(title,items,reopen) end)
                    end
                end
            end,
        }
    end
    local footer={}
    if parent then
        footer[#footer+1]={label="‹ 返回",callback=function()
            local back=U.copy(parent.options or {})
            return self:_show_home_bubble_menu(parent.title,parent.items,back)
        end}
    end
    if page>1 then footer[#footer+1]={label="‹ 上一页",callback=function()
        local previous=U.copy(options); previous.page=page-1
        return self:_show_home_bubble_menu(title,items,previous)
    end} end
    if page<pages then footer[#footer+1]={label="下一页 ›",callback=function()
        local following=U.copy(options); following.page=page+1
        return self:_show_home_bubble_menu(title,items,following)
    end} end
    return ActionSheet.show{
        anchor=options.anchor,preferred_direction=options.preferred_direction or "below",
        width_ratio=tonumber(options.width_ratio) or .78,columns=1,
        title=tostring(title or "觅阅"),subtitle=pages>1 and ("第 "..page.." / "..pages.." 页") or tostring(options.subtitle or ""),
        actions=actions,footer_actions=footer,
    }
end

function Plugin:_show_standalone_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
    if options.force_native~=true and options.native_input~=true
        and HomeView.is_shown() and not self:_active_reader_ui() then
        return self:_show_miuread_menu(title,items,options)
    end
    if options.reader_context==true and type(options.on_home)=="function"
        and not (items[1] and items[1]._miuread_reader_home==true) then
        local navigable={{
            _miuread_reader_home=true,
            text="返回觅阅主页",
            post_text="⌂",
            separator=true,
            close_before_action=true,
            callback=options.on_home,
        }}
        for _,entry in ipairs(items) do navigable[#navigable+1]=entry end
        items=navigable
    end
    if #items==0 then self:info("没有可用选项"); return nil end
    local menu
    local close_standalone
    local rows={}
    for _,entry in ipairs(items) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then
            local ok,value=pcall(source.enabled_func)
            enabled=ok and value~=false
        end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then
            local ok,checked=pcall(source.checked_func)
            if ok and checked==true then label="✓ "..label end
        end
        local row={
            text=label,
            post_text=source.post_text,
            enabled=enabled,
            separator=source.separator,
        }
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then
                    local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                    if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                    child=value
                end
                local child_options=U.copy(options)
                child_options.on_close=function()
                    self:_show_standalone_menu(title,items,options)
                end
                if close_standalone then close_standalone(true) end
                UIManager:scheduleIn(.04,function()
                    self:_show_standalone_menu(tostring(source.text or title),child,child_options)
                end)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...)
                logger.info("[MiuRead][Menu] standalone item tapped",tostring(source.text or ""))
                local args={...}
                local function run_action()
                    local ok,err=xpcall(function() return source.callback(unpack_args(args)) end,debug.traceback)
                    if not ok then
                        logger.warn("[MiuRead][Menu] standalone action failed",tostring(source.text or ""),tostring(err))
                        self:info("这个入口暂时无法打开。\n\n"..tostring(err))
                        return
                    end
                    if source.keep_menu_open==true and menu and UIManager:isWidgetShown(menu) then
                        UIManager:scheduleIn(.05,function()
                            if menu and UIManager:isWidgetShown(menu) then
                                local refreshed=self:_standalone_rows(title,items,menu)
                                if refreshed then menu.item_table=refreshed; pcall(menu.updateItems,menu) end
                            end
                        end)
                    end
                end
                if source.close_before_action==true and close_standalone then
                    if close_standalone()~=false then UIManager:scheduleIn(.04,run_action)
                    else run_action() end
                else
                    run_action()
                end
            end
        end
        rows[#rows+1]=row
    end
    -- Reader-side menus must receive their own title-bar tap before any
    -- ReaderUI gesture zone. RawMenu keeps KOReader's native event order; the
    -- bridged Menu remains unchanged for MiuRead home pages.
    TransientGuard.close_all()
    local MenuClass=options.native_input==true and RawMenu or Menu
    menu=MenuClass:new{title=tostring(title or "觅阅"),item_table=rows,is_borderless=true,title_bar_fm_style=true}
    menu._miuread_transient=true
    menu._miuread_modal_surface=true
    -- TitleBar captures a dynamic self:onClose() call when it is created.
    -- Replacing Menu:onClose on this concrete instance is sufficient and avoids
    -- mutating already-built child button fields that differ across KOReader
    -- versions.
    close_standalone=function(suppress_restore)
        if not menu or menu._miuread_closing then return true end
        suppress_restore=suppress_restore==true or menu._miuread_suppress_restore==true
        menu._miuread_closing=true
        local ok,err=pcall(UIManager.close,UIManager,menu)
        if not ok then
            menu._miuread_closing=false
            logger.warn("[MiuRead][Menu] standalone close failed",tostring(err))
            return false
        end
        if suppress_restore~=true and type(options.on_close)=="function" and not menu._miuread_restore_scheduled then
            menu._miuread_restore_scheduled=true
            UIManager:scheduleIn(.06,function()
                local restore_ok,restore_err=pcall(options.on_close)
                if not restore_ok then logger.warn("[MiuRead][Menu] standalone restore failed",tostring(restore_err)) end
            end)
        end
        return true
    end
    menu.onClose=close_standalone
    menu.onCloseAllMenus=close_standalone
    menu._close=function(_,_,cancel_pending)
        menu._miuread_suppress_restore=cancel_pending==true
        return close_standalone(cancel_pending==true)
    end
    UIManager:show(menu)
    return menu
end

-- Small helper used only when a standalone toggle menu stays open.
function Plugin:_standalone_rows(title,items,menu)
    local rows={}
    for _,entry in ipairs(items or {}) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then local ok,v=pcall(source.enabled_func); enabled=ok and v~=false end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then local ok,v=pcall(source.checked_func); if ok and v==true then label="✓ "..label end end
        local row={text=label,post_text=source.post_text,enabled=enabled,separator=source.separator}
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then local ok,v=xpcall(source.sub_item_table_func,debug.traceback); if not ok then self:info(tostring(v)); return end; child=v end
                self:_show_standalone_menu(tostring(source.text or title),child)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...) return source.callback(...) end
        end
        rows[#rows+1]=row
    end
    return rows
end

function Plugin:_reader_open_native_page(label,opener,return_callback)
    if not (self.ui and self.ui.document) then return false end
    self._reader_native_return_token=(tonumber(self._reader_native_return_token) or 0)+1
    local token=self._reader_native_return_token
    local reader_ui=self.ui
    local document=reader_ui.document
    local reader_session=tonumber(HOME_SESSION.reader_session_generation) or 0
    self:_close_miuread_transients()
    self:_set_navigation_state("native_menu","reader native page "..tostring(label or ""))
    local baseline={}
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget then baseline[widget]=true end
    end

    local function restore_reader(reason,restore_callback)
        if token~=self._reader_native_return_token then return false end
        if self.ui~=reader_ui or not self.ui or self.ui.document~=document then return false end
        if tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return false end
        if reader_close_active() or self._reader_returning or self._home_reader_transition then return false end
        self:_set_navigation_state("reader",reason or "native reader page closed")
        if restore_callback==true and type(return_callback)=="function" then
            local restore_ok,restore_err=pcall(return_callback)
            if not restore_ok then logger.warn("[MiuRead][Reader] native page restore failed",tostring(restore_err)) end
        end
        return true
    end

    UIManager:scheduleIn(.05,function()
        if token~=self._reader_native_return_token or reader_close_active()
            or HOME_SESSION.suspended==true or self._miuread_suspended==true
            or self.ui~=reader_ui or not self.ui or self.ui.document~=document
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return end
        local ok,result=xpcall(opener,debug.traceback)
        if not ok or result==false then
            logger.warn("[MiuRead][Reader] native page open failed",tostring(label or ""),tostring(result))
            restore_reader("native reader page open failed",false)
            if type(return_callback)=="function" then UIManager:scheduleIn(.06,return_callback) end
            return
        end
        local seen_overlay=false
        local stable=0
        local attempts=0
        local function has_new_overlay()
            for _,window in ipairs(UIManager._window_stack or {}) do
                local widget=window and window.widget or nil
                if widget and not baseline[widget] and widget.toast~=true and widget._miuread_transient~=true
                    and UIManager:isWidgetShown(widget) then
                    return true
                end
            end
            return false
        end
        local function watch()
            if token~=self._reader_native_return_token then return end
            if HOME_SESSION.suspended==true or self._miuread_suspended==true then
                UIManager:scheduleIn(.6,watch)
                return
            end
            if self.ui~=reader_ui or not self.ui or self.ui.document~=document then return end
            if tonumber(HOME_SESSION.reader_session_generation or 0)~=reader_session then return end
            if reader_close_active() or self._reader_returning or self._home_reader_transition then return end
            attempts=attempts+1
            if has_new_overlay() then
                seen_overlay=true
                stable=0
            else
                stable=stable+1
            end
            if (seen_overlay and stable>=3) or (not seen_overlay and attempts>=18) then
                restore_reader("native reader page closed",true)
                return
            end
            local delay=attempts<60 and .12 or (attempts<300 and .30 or .70)
            UIManager:scheduleIn(delay,watch)
        end
        UIManager:scheduleIn(.12,watch)
    end)
    return true
end

function Plugin:_reader_wifi_state()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr or type(NetworkMgr.isWifiOn)~="function" then return nil end
    local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok then return value==true end
    return nil
end

function Plugin:_reader_wifi_toggle()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local on=self:_reader_wifi_state()==true
    local ok=false
    if on then
        if type(NetworkMgr.toggleWifiOff)=="function" then ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr)
        elseif type(NetworkMgr.turnOffWifi)=="function" then ok=pcall(NetworkMgr.turnOffWifi,NetworkMgr) end
        if ok then self:toast("Wi-Fi 已关闭",1.5) end
    else
        if type(NetworkMgr.toggleWifiOn)=="function" then ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr)
        elseif type(NetworkMgr.turnOnWifi)=="function" then ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr) end
        if ok then self:toast("正在开启 Wi-Fi",1.5) end
    end
    if ok then HomeData.invalidate_device_state() end
    return ok==true
end

function Plugin:_reader_wifi_settings(back_callback)
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local restored=false
    local function restore_reader_menu()
        if restored then return end
        restored=true
        if type(back_callback)=="function" then UIManager:scheduleIn(.12,back_callback) end
    end
    local function show_network_list()
        if type(NetworkMgr.getNetworkList)=="function" then
            local ok_list,networks=pcall(NetworkMgr.getNetworkList,NetworkMgr)
            if ok_list and type(networks)=="table" then
                local ok_widget,NetworkSetting=pcall(require,"ui/widget/networksetting")
                if ok_widget and NetworkSetting and type(NetworkSetting.new)=="function" then
                    local dialog=NetworkSetting:new{network_list=networks}
                    local original_on_close=dialog.onCloseWidget
                    dialog.onCloseWidget=function(widget)
                        if type(original_on_close)=="function" then
                            local ok_close,err=xpcall(function() original_on_close(widget) end,debug.traceback)
                            if not ok_close then logger.warn("[MiuRead][Reader] network picker close failed",tostring(err)) end
                        end
                        restore_reader_menu()
                    end
                    UIManager:show(dialog)
                    return true
                end
            end
        end
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,restore_reader_menu,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,restore_reader_menu,true)
            if ok then return true end
        end
        return false
    end
    if self:_reader_wifi_state()==true then
        if show_network_list() then return true end
    elseif type(NetworkMgr.toggleWifiOn)=="function" then
        -- KOReader's long-press flag enables Wi-Fi and keeps the network list
        -- visible. Restore the MiuRead reader panel only after that picker closes.
        local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,restore_reader_menu,true,true)
        if ok then return true end
    elseif type(NetworkMgr.turnOnWifi)=="function" then
        local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,function()
            UIManager:scheduleIn(.1,function()
                if not show_network_list() then restore_reader_menu() end
            end)
        end,true)
        if ok then return true end
    end
    self:info("Wi-Fi 网络列表暂时无法打开")
    restore_reader_menu()
    return false
end

function Plugin:_home_wifi_text()
    local state=HomeData.cached_device_state() or HomeData.quick_device_state() or {}
    if state.wifi_on==false then return "已关闭" end
    if state.wifi_on==true then
        local ssid=U.trim(tostring(state.wifi_name or ""))
        if ssid~="" then return U.utf8_truncate(ssid,13,"…") end
        return state.online==true and "已连接" or "未连接"
    end
    return "Wi-Fi"
end

function Plugin:_home_status_line()
    -- Backward-compatible text for older callers; the home header renders
    -- Wi-Fi, sync and time as independent groups from beta.18 onward.
    return self:_home_wifi_text()
end

function Plugin:_home_battery_text()
    local device=HomeData.cached_device_state() or HomeData.quick_device_state() or {}
    if tonumber(device.battery) then
        return tostring(math.floor(tonumber(device.battery)+.5)).."%"
    end
    return "--%"
end

function Plugin:_schedule_home_startup(delay)
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    local generation=self._home_start_generation
    local function attempt(number)
        if generation~=self._home_start_generation then return end
        sync_home_session()
        if HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil
            or HOME_SESSION.suspended==true or not self:_home_enabled() then return end
        if HomeView.is_shown() or self:_active_reader_ui() then return end
        local navigation=self:_navigation_state()
        if navigation=="opening_reader" or navigation=="reader" or navigation=="closing_reader"
            or navigation=="native_menu" or navigation=="suspended" or navigation=="exiting" then
            if number<40 and navigation~="exiting" then UIManager:scheduleIn(.25,function() attempt(number+1) end) end
            return
        end
        local owner=tostring(HOME_SESSION.foreground or "")
        local owner_age=os.time()-(tonumber(HOME_SESSION.foreground_changed_at) or os.time())
        if (owner=="reader" or owner=="reader_pending" or owner=="reader_transition") and owner_age<6 then
            if number<40 then UIManager:scheduleIn(.25,function() attempt(number+1) end) end
            return
        end
        local ready=false
        local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
        if ok and FileManager and FileManager.instance then ready=true end
        if not ready and number>=4 then
            ready=self:_ensure_filemanager_base(HOME_RETURN_FILE)
        end
        if ready then
            local shown=self:_show_miuread_home_now(false,false,true)
            if shown or HomeView.is_shown() then
                logger.info("[MiuRead][Home] startup bookshelf shown","attempt=",tostring(number))
                return
            end
        end
        if number<40 then
            UIManager:scheduleIn(.25,function() attempt(number+1) end)
        else
            logger.warn("[MiuRead][Home] startup bookshelf was not shown")
        end
    end
    UIManager:scheduleIn(tonumber(delay) or .5,function() attempt(1) end)
end

function Plugin:_home_status_text(book,is_local)
    book=book or {}
    local id=tostring(book.bookId or book.book_id or "")
    local state=self:_download_state()
    local state_id=tostring(state.book_id or (state.book and state.book.bookId) or "")
    if id~="" and state_id==id then
        if state.status=="active" then
            -- Active progress is rendered as a thin bar on the matching shelf
            -- card. Keep it out of Recent Reading and out of status text.
            return ""
        end
        if state.status=="failed" then return "失败" end
        if state.status=="annotation_pending" then return "批注待修复" end
        if state.status=="interrupted" or state.status=="pending_install" then return "待修复" end
    end
    if id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==id then return "排队中" end
        end
    end
    if is_local or book.source=="local" or book.local_file==true then return "本地" end
    local file=tostring(book.file or "")
    if book.source=="miuread" or book.shelf_section=="generated" or (file~="" and U.file_exists(file)) then return "已生成" end
    if Protocol.is_mp_account(id) or book.source=="mp" then return "公众号" end
    return "未生成"
end

function Plugin:_home_root()
    local prefs=self.store:preferences().home_ui or {}
    local explicit=U.trim(tostring(prefs.local_root or ""))
    if explicit~="" and lfs.attributes(explicit,"mode")=="directory" then return explicit end

    local native_home=""
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"home_dir")
        if ok then native_home=U.trim(tostring(value or "")) end
    end
    local download_root=tostring(self.store.default_books_dir or ""):gsub("/+$","")
    local normalized_home=native_home:gsub("/+$","")
    if download_root~="" and (normalized_home==download_root or normalized_home:sub(1,#download_root+1)==download_root.."/") then
        -- KOReader often remembers the MiuRead download folder as its current
        -- home. That is not the user's full local library.
        native_home=""
    end

    for _,candidate in ipairs({
        "/mnt/us/documents",
        "/mnt/onboard",
        native_home,
        "/mnt/us/books",
        self.store.default_books_dir,
    }) do
        if candidate and candidate~="" and candidate~="/" and lfs.attributes(candidate,"mode")=="directory" then
            return candidate
        end
    end
    return self.store.default_books_dir
end

function Plugin:_home_local_cache()
    local value=self.store:get("home_local_index",{})
    if type(value)~="table" then value={} end
    value.books=type(value.books)=="table" and value.books or {}
    return value
end

function Plugin:_home_local_tree_cache()
    local cache=self.store:get("home_local_tree_index",{version=1,dirs={}})
    cache=type(cache)=="table" and cache or {version=1,dirs={}}
    cache.version=1
    cache.dirs=type(cache.dirs)=="table" and cache.dirs or {}
    return cache
end

function Plugin:_home_local_roots(enabled_only)
    local home=self:_home_preferences()
    local rows={}
    for _,root in ipairs(type(home.local_roots)=="table" and home.local_roots or {}) do
        local path=LocalLibrary.normalize(root.path or "")
        if path~="" and lfs.attributes(path,"mode")=="directory"
            and (not enabled_only or root.enabled~=false) then
            rows[#rows+1]={path=path,name=U.trim(tostring(root.name or ""))~="" and U.trim(tostring(root.name)) or LocalLibrary.basename(path),enabled=root.enabled~=false,readonly=root.readonly~=false}
        end
    end
    return rows
end

function Plugin:_home_local_root_for_path(path,roots)
    path=LocalLibrary.normalize(path)
    for _,root in ipairs(roots or self:_home_local_roots(true)) do
        local root_path=LocalLibrary.normalize(root.path)
        if path==root_path or path:sub(1,#root_path+1)==root_path.."/" then return root end
    end
    return nil
end

function Plugin:_home_local_inline_context()
    local home=self:_home_preferences()
    local roots=self:_home_local_roots(true)
    if #roots==0 then return {roots=roots,picker=true,path="",root=nil} end
    local path=LocalLibrary.normalize(home.local_inline_path or "")
    if #roots>1 and path=="" then return {roots=roots,picker=true,path="",root=nil} end
    local root=self:_home_local_root_for_path(path,roots)
    if not root then
        if #roots==1 then path=roots[1].path; root=roots[1]
        else return {roots=roots,picker=true,path="",root=nil} end
    end
    return {roots=roots,picker=false,path=path,root=root}
end

function Plugin:_home_local_inline_parent_entry(context)
    if not context or context.picker or not context.root then return nil end
    local path=LocalLibrary.normalize(context.path)
    local root_path=LocalLibrary.normalize(context.root.path)
    local target
    local detail
    if path~=root_path then
        target=path:match("^(.*)/[^/]+$") or root_path
        if target=="" or not (target==root_path or target:sub(1,#root_path+1)==root_path.."/") then target=root_path end
        detail=target==root_path and tostring(context.root.name or LocalLibrary.basename(root_path)) or LocalLibrary.basename(target)
    elseif #(context.roots or {})>1 then
        target=""
        detail="书库目录"
    else
        return nil
    end
    return {
        kind="folder",local_folder=true,local_parent=true,source="local",
        title="返回上一级",status_text=tostring(detail or "上一级"),
        folder_path=target,path=target,root_path=root_path,
    }
end

function Plugin:_home_local_inline_rows()
    local context=self:_home_local_inline_context()
    local rows={}
    if context.picker then
        for _,root in ipairs(context.roots or {}) do
            local entry=self:_home_local_folder_entry(root.path,root.name,root.path)
            entry.local_root_entry=true
            rows[#rows+1]=entry
        end
        return rows,context,nil
    end
    local parent=self:_home_local_inline_parent_entry(context)
    if parent then rows[#rows+1]=parent end
    local snapshot=self:_home_local_tree_cache().dirs[context.path]
    if type(snapshot)=="table" then
        local folders,books=self:_local_browser_decorate(snapshot,context.root.path)
        for _,folder in ipairs(folders) do rows[#rows+1]=folder end
        for _,book in ipairs(books) do rows[#rows+1]=book end
    end
    return rows,context,snapshot
end

function Plugin:_home_local_inline_title()
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return "" end
    local context=self:_home_local_inline_context()
    if context.picker then return "选择本地书库目录" end
    local root_name=tostring(context.root and context.root.name or "本地书籍")
    if context.path==LocalLibrary.normalize(context.root and context.root.path or "") then
        return U.utf8_truncate(root_name,26,"…")
    end
    return U.utf8_truncate(root_name.." / "..LocalLibrary.basename(context.path),26,"…")
end

function Plugin:_home_local_empty_text()
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    if mode=="manual" then return "本地书库尚未扫描\n请在设置中点击扫描本地书库" end
    if mode~="direct" then return "这里还没有本地书籍\n请先设置本地书库目录" end
    local context=self:_home_local_inline_context()
    if #(context.roots or {})==0 then return "这里还没有本地书籍\n请先设置本地书库目录" end
    if context.picker then return "请选择一个本地书库目录" end
    local snapshot=self:_home_local_tree_cache().dirs[context.path]
    if type(snapshot)~="table" then return "正在读取这个文件夹…" end
    if snapshot.error then return "无法读取文件夹\n"..tostring(snapshot.error) end
    return "这个文件夹里没有可显示的书籍"
end

function Plugin:_home_local_folder_entry(path,title,root_path)
    path=LocalLibrary.normalize(path)
    local snapshot=self:_home_local_tree_cache().dirs[path]
    local count=type(snapshot)=="table" and (#(snapshot.folders or {})+#(snapshot.books or {})) or nil
    return {
        kind="folder",local_folder=true,source="local",title=tostring(title or LocalLibrary.basename(path)),
        folder_path=path,path=path,root_path=LocalLibrary.normalize(root_path or path),
        status_text=count and (tostring(count).." 项") or "文件夹",
    }
end

function Plugin:_home_local_known_paths()
    local known={}
    local function remember(path)
        path=LocalLibrary.normalize(path)
        if path~="" then known[path]=true end
    end
    for _,book in pairs(self.store:library() or {}) do
        for _,record in pairs(book.variants or {}) do
            if type(record)=="table" then remember(record.file); remember(record.original_file) end
        end
        for _,chapter in pairs(book.chapters or {}) do
            for _,record in pairs(chapter or {}) do
                if type(record)=="table" then remember(record.file); remember(record.original_file) end
            end
        end
    end
    return known
end

function Plugin:_home_local_rows()
    local index_cache=self:_home_local_cache()
    local tree=self:_home_local_tree_cache()
    local roots=self:_home_local_roots(true)
    local rows={}
    local known_paths=self:_home_local_known_paths()
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    local hidden=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    local indexed_by_file={}
    for _,book in ipairs(index_cache.books or {}) do indexed_by_file[LocalLibrary.normalize(book.file)]=book end

    local function add_book(row)
        local path=LocalLibrary.normalize(row and row.file or "")
        if path=="" or not U.file_exists(path) or known_paths[path] or hidden[path]==true
            or LocalLibrary.is_likely_dictionary(path,row.title) then return end
        local copy=U.copy(row)
        local old=indexed_by_file[path]
        if old and tonumber(old.modified_at or 0)==tonumber(copy.modified_at or 0) then LocalMetadata.merge(copy,old) end
        copy.file=path; copy.local_file=true; copy.source="local"
        copy.status_text=self:_home_status_text(copy,true)
        rows[#rows+1]=copy
    end

    if mode=="direct" then
        -- The home grid itself is the folder browser. Only the selected level
        -- is exposed; recursive indexes remain completely separate.
        local inline_rows=self:_home_local_inline_rows()
        for _,row in ipairs(inline_rows or {}) do rows[#rows+1]=row end
    else
        local enabled={}
        for _,root in ipairs(roots) do enabled[LocalLibrary.normalize(root.path)]=true end
        for _,book in ipairs(index_cache.books or {}) do
            local root=LocalLibrary.normalize(book.library_root or index_cache.root or "")
            if root=="" or enabled[root] then add_book(book) end
        end
        table.sort(rows,function(a,b)
            local am,bm=tonumber(a.last_read_at or a.modified_at) or 0,tonumber(b.last_read_at or b.modified_at) or 0
            if am~=bm then return am>bm end
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        end)
    end
    return rows,index_cache
end

function Plugin:_home_apply_local_inline_section(refresh_metadata)
    if not self._home_sections then return false end
    local rows=select(1,self:_home_local_rows())
    self._home_sections["local"]={title="本地书籍",rows=rows,empty=self:_home_local_empty_text()}
    self:_home_bump_section_revision("local")
    if self._home_active_section~="local" or not HomeView.is_shown() then return true end
    local updated=self:_home_apply_section("local")
    if refresh_metadata and updated then
        local home=self:_home_preferences()
        local preview=self:_home_preview_page(rows,self._home_hero,
            home.page_by_section and home.page_by_section["local"],self:_home_page_limit())
        self:_home_schedule_local_metadata(preview)
        self:_home_schedule_remote_covers(preview)
    end
    return updated
end

function Plugin:_home_set_local_inline_location(path,root_path)
    local home,preferences=self:_home_preferences()
    home.local_inline_path=LocalLibrary.normalize(path or "")
    home.local_inline_root=LocalLibrary.normalize(root_path or "")
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    home.page_by_section["local"]=1
    self:_home_bump_interaction_generation()
    self:_save_home_preferences_deferred(home,preferences)
end

function Plugin:_home_local_inline_navigate(path,root_path)
    path=LocalLibrary.normalize(path or "")
    root_path=LocalLibrary.normalize(root_path or "")
    if path~="" and lfs.attributes(path,"mode")~="directory" then
        self:info("本地书库目录不存在")
        return false
    end
    self._home_inline_navigation_generation=(tonumber(self._home_inline_navigation_generation) or 0)+1
    local generation=self._home_inline_navigation_generation
    self:_home_set_local_inline_location(path,root_path)
    local cached=path~="" and self:_home_local_tree_cache().dirs[path] or nil
    self:_home_apply_local_inline_section(type(cached)=="table")
    if path=="" then return true end
    if type(cached)~="table" or cached.error then self:toast("正在打开文件夹…",2) end
    local home=self:_home_preferences()
    if type(cached)=="table" and not cached.error and home.local_check_on_open==false then return true end
    return self:_home_refresh_local_directory(path,function(snapshot)
        if generation~=self._home_inline_navigation_generation then return end
        local context=self:_home_local_inline_context()
        if context.picker or LocalLibrary.normalize(context.path)~=path then return end
        self:_home_apply_local_inline_section(true)
    end,true)
end

function Plugin:_home_ensure_local_inline_loaded()
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return false end
    local context=self:_home_local_inline_context()
    if context.picker or context.path=="" then return false end
    local existing=self:_home_local_tree_cache().dirs[context.path]
    if type(existing)=="table" and not existing.error then return true end
    local generation=(tonumber(self._home_inline_navigation_generation) or 0)+1
    self._home_inline_navigation_generation=generation
    self:toast("正在读取本地文件夹…",2)
    return self:_home_refresh_local_directory(context.path,function()
        if generation~=self._home_inline_navigation_generation then return end
        local current=self:_home_local_inline_context()
        if current.picker or LocalLibrary.normalize(current.path)~=LocalLibrary.normalize(context.path) then return end
        self:_home_apply_local_inline_section(true)
    end,true)
end

function Plugin:_home_handle_back()
    if self._home_active_section~="local" then return false end
    local home=self:_home_preferences()
    if tostring(home.local_library_mode or "direct")~="direct" then return false end
    local context=self:_home_local_inline_context()
    if context.picker or not context.root then return false end
    local parent=self:_home_local_inline_parent_entry(context)
    if not parent then return false end
    self:_home_local_inline_navigate(parent.folder_path,parent.root_path)
    return true
end

function Plugin:_home_attach_local_record(row)
    if type(row)~="table" then return row end
    local id=tostring(row.bookId or row.book_id or "")
    if id=="" then return row end
    local stored=type(row.local_record)=="table" and row.local_record or self.store:book(id)
    if type(stored)=="table" then
        for _,key in ipairs({"description","intro","summary","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and stored[key]~=nil and stored[key]~="" then row[key]=stored[key] end
        end
        if not row.cover_path and stored.cover_path then row.cover_path=stored.cover_path end
    end
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        row.file=record.file
        for _,key in ipairs({"description","author","title","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and record[key]~=nil and record[key]~="" then row[key]=record[key] end
        end
        if not row.cover_path and record.cover_path then row.cover_path=record.cover_path end
    end
    return row
end

function Plugin:_home_miuread_rows()
    local remote_books,remote_mp=self.library:cached()
    remote_books=type(remote_books)=="table" and remote_books or {}
    local remote_by_id={}
    for _,book in ipairs(remote_books) do
        local id=tostring(book.bookId or book.book_id or "")
        if id~="" then remote_by_id[id]=book end
    end
    local rows=self:_shelf_rows("generated",false,remote_books,{},#remote_books>0)
    rows=self.library:sort_filter(rows,{section="generated"})
    table.sort(rows,function(a,b)
        local ar,br=tonumber(a.lastReadTime) or 0,tonumber(b.lastReadTime) or 0
        if ar~=br then return ar>br end
        local ad,bd=tonumber(a.downloadedAt) or 0,tonumber(b.downloadedAt) or 0
        if ad~=bd then return ad>bd end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    self:_prepare_shelf_rows(rows)
    local fields={"title","author","description","intro","summary","category","publisher","translator","wordCount","cover"}
    for _,row in ipairs(rows) do
        self:_home_attach_local_record(row)
        local id=tostring(row.bookId or row.book_id or "")
        local remote=remote_by_id[id]
        if remote then
            for _,key in ipairs(fields) do
                if (row[key]==nil or row[key]=="") and remote[key]~=nil and remote[key]~="" then row[key]=remote[key] end
            end
        end
        row.description=row.description or row.intro or row.summary
        row.source="miuread"
        row.status_text=self:_home_status_text(row,false)
    end
    return rows
end

local function normalized_home_time(value)
    local stamp=tonumber(value) or 0
    if stamp>100000000000 then stamp=math.floor(stamp/1000) end
    return stamp>0 and stamp or 0
end

local function home_recent_item_identity(item)
    if type(item)~="table" then return "","" end
    local id=tostring(item.book_id or item.bookId or "")
    local file=LocalLibrary.normalize(item.file or "")
    return id,file
end

local function home_recent_item_key(item)
    local id,file=home_recent_item_identity(item)
    if id~="" then return "book:"..id end
    return file~="" and ("file:"..file) or ""
end

function Plugin:_home_share_recent_read(book_id,path,stamp)
    book_id=tostring(book_id or "")
    path=LocalLibrary.normalize(path or "")
    stamp=normalized_home_time(stamp)
    if stamp<=0 or (book_id=="" and path=="") then return false end
    local item={book_id=book_id,file=path,read_at=stamp}
    item.key=home_recent_item_key(item)
    local bridge=type(HOME_SESSION.recent_reads_bridge)=="table"
        and HOME_SESSION.recent_reads_bridge or {version=1,items={}}
    bridge.version=1
    bridge.items=type(bridge.items)=="table" and bridge.items or {}
    local items={item}
    local seen_ids,seen_files={},{}
    if book_id~="" then seen_ids[book_id]=true end
    if path~="" then seen_files[path]=true end
    for _,old in ipairs(bridge.items) do
        local old_id,old_file=home_recent_item_identity(old)
        local duplicate=(old_id~="" and seen_ids[old_id]) or (old_file~="" and seen_files[old_file])
        if not duplicate and (old_id~="" or old_file~="") then
            if old_id~="" then seen_ids[old_id]=true end
            if old_file~="" then seen_files[old_file]=true end
            items[#items+1]=old
            if #items>=10 then break end
        end
    end
    bridge.items=items
    HOME_SESSION.recent_reads_bridge=bridge
    HOME_SESSION.recent_read_dirty=true
    return true
end

function Plugin:_home_recent_read_state()
    local stored
    if self.store.recent_reads then stored=self.store:recent_reads()
    else stored=self.store:get("recent_reads",{version=1,items={}}) end
    stored=type(stored)=="table" and stored or {version=1,items={}}
    stored.items=type(stored.items)=="table" and stored.items or {}
    local bridge=type(HOME_SESSION.recent_reads_bridge)=="table"
        and HOME_SESSION.recent_reads_bridge or {items={}}
    local merged={version=1,items={}}
    local seen_ids,seen_files={},{}
    local function append(item)
        if type(item)~="table" then return end
        local id,file=home_recent_item_identity(item)
        if id=="" and file=="" then return end
        if (id~="" and seen_ids[id]) or (file~="" and seen_files[file]) then return end
        if id~="" then seen_ids[id]=true end
        if file~="" then seen_files[file]=true end
        merged.items[#merged.items+1]=item
    end
    for _,item in ipairs(type(bridge.items)=="table" and bridge.items or {}) do
        append(item)
        if #merged.items>=10 then break end
    end
    if #merged.items<10 then
        for _,item in ipairs(stored.items) do
            append(item)
            if #merged.items>=10 then break end
        end
    end
    return merged
end

function Plugin:_home_apply_recent_read_times(...)
    local state=self:_home_recent_read_state()
    local by_book,by_file={},{}
    for _,item in ipairs(state.items or {}) do
        if type(item)=="table" then
            local stamp=normalized_home_time(item.read_at)
            local id=tostring(item.book_id or "")
            local file=LocalLibrary.normalize(item.file or "")
            if stamp>0 and id~="" and stamp>(tonumber(by_book[id]) or 0) then by_book[id]=stamp end
            if stamp>0 and file~="" and stamp>(tonumber(by_file[file]) or 0) then by_file[file]=stamp end
        end
    end
    for index=1,select("#",...) do
        local list=select(index,...)
        for _,book in ipairs(type(list)=="table" and list or {}) do
            local id=tostring(book.bookId or book.book_id or "")
            local file=LocalLibrary.normalize(book.file or "")
            local stamp=math.max(tonumber(by_book[id]) or 0,tonumber(by_file[file]) or 0)
            if stamp>0 then book.local_recent_read_at=stamp end
        end
    end
    return state
end

function Plugin:_home_book_time(book)
    if type(book)~="table" then return 0 end
    local primary=math.max(
        normalized_home_time(book.local_recent_read_at),
        normalized_home_time(book.lastReadTime),
        normalized_home_time(book.readUpdateTime),
        normalized_home_time(book.last_read_at),
        normalized_home_time(book.opened_at))
    if primary>0 then return primary end
    return math.max(
        normalized_home_time(book.cloudUpdatedAt),
        normalized_home_time(book.updateTime),
        normalized_home_time(book.downloadedAt),
        normalized_home_time(book.modified_at))
end

function Plugin:_home_recent_book(miuread_rows,local_rows,account_rows)
    local lists={miuread_rows or {},local_rows or {},account_rows or {}}
    local state=self:_home_apply_recent_read_times(unpack_args(lists))
    local by_book,by_file={},{}
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder") then
                local id=tostring(book.bookId or book.book_id or "")
                local file=LocalLibrary.normalize(book.file or "")
                if id~="" and not by_book[id] then by_book[id]=book end
                if file~="" and not by_file[file] then by_file[file]=book end
            end
        end
    end
    -- A successful local Reader session is authoritative. Progress 0% and
    -- 100% are both valid recent reads; cloud timestamps are only fallback.
    for _,item in ipairs(state.items or {}) do
        if type(item)=="table" then
            local id=tostring(item.book_id or "")
            local file=LocalLibrary.normalize(item.file or "")
            local match=(id~="" and by_book[id]) or (file~="" and by_file[file]) or nil
            if match then return match end
        end
    end
    local best
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder")
                and (not best or self:_home_book_time(book)>self:_home_book_time(best)) then best=book end
        end
    end
    if best then return best end
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder") then return book end
        end
    end
    return nil
end

function Plugin:_home_last_read_text(book)
    local stamp=self:_home_book_time(book)
    if stamp<=0 then return "" end
    local now=os.time()
    local day=self:_display_time("%Y-%m-%d",stamp)
    if day==self:_display_time("%Y-%m-%d",now) then return "今天 "..self:_display_time("%H:%M",stamp) end
    if day==self:_display_time("%Y-%m-%d",now-24*60*60) then return "昨天 "..self:_display_time("%H:%M",stamp) end
    if self:_display_time("%Y",stamp)==self:_display_time("%Y",now) then return self:_display_time("%m月%d日",stamp) end
    return self:_display_time("%Y年%m月%d日",stamp)
end

function Plugin:_home_source_text(book)
    if not book then return "" end
    if book.source=="local" or book.local_file==true then
        local format=tostring(book.format or ""):upper()
        return format~="" and ("本地 · "..format) or "本地书籍"
    end
    if book.source=="miuread" or book.shelf_section=="generated" then return "微信书架" end
    if Protocol.is_mp_account(tostring(book.bookId or book.book_id or "")) then return "公众号" end
    local category=U.trim(tostring(book.category or ""))
    return category~="" and ("微信书架 · "..category) or "微信书架"
end

function Plugin:_show_home_book_open_popup(book,anchor)
    return self:_open_book_stream(book,anchor)
end

function Plugin:_stream_enabled()
    return Config.STREAM_READING==true
end

function Plugin:_stream_active()
    local session=STREAM_SESSION
    if not session or not session.reader or session.reader.active~=true then return false end
    local path=normalized_reader_file(self:_current_document_path())
    local epub=normalized_reader_file(session.reader.epub_path)
    return path~="" and epub~="" and path==epub
end

function Plugin:_stream_book_id_from_path(path,book)
    local book_id=book and tostring(book.book_id or book.bookId or "") or ""
    if book_id~="" then return book_id end
    local meta=path and self.store:epub_identity(path) or nil
    return meta and tostring(meta.book_id or "") or ""
end

function Plugin:_stream_account_book(book,path)
    if book and (book.source=="local" or book.local_file==true) then return false end
    local book_id=self:_stream_book_id_from_path(path,book)
    return book_id~=""
end

function Plugin:_should_open_book_stream(book,path,options)
    options=type(options)=="table" and options or {}
    if not self:_stream_enabled() or options.stream_result==true then return false end
    if self._stream_open_inflight==true then return false end
    if self:_stream_active() then return false end
    local session=STREAM_SESSION
    local active_epub=session and session.reader and normalized_reader_file(session.reader.epub_path) or ""
    if active_epub~="" and normalized_reader_file(path)==active_epub then return false end
    return self:_stream_account_book(book,path)
end

function Plugin:_redirect_open_to_stream(book,path,reason)
    local book_id=self:_stream_book_id_from_path(path,book)
    if book_id=="" then return false end
    logger.warn("[MiuRead][Stream] redirect to stream",
        "reason=",tostring(reason or ""),"book=",book_id,"path=",tostring(path or ""))
    self._stream_open_inflight=true
    local owner=self
    UIManager:nextTick(function()
        owner._stream_open_inflight=nil
        owner:_open_book_stream({
            bookId=book_id,
            title=book and book.title,
            author=book and book.author,
        })
    end)
    return true
end

function Plugin:_close_stream_session()
    self._stream_hydrating_key=nil
    if STREAM_SESSION.reader then
        pcall(STREAM_SESSION.reader.close,STREAM_SESSION.reader)
        STREAM_SESSION.reader=nil
        STREAM_SESSION.meta=nil
        STREAM_SESSION.pending_percent=nil
    end
end

function Plugin:_handle_stream_error(err,channel)
    local text=tostring(err or "未知错误")
    if Http.is_auth_error(text) then
        self:_mark_auth_problem(channel or "download",text,true)
        local dialog
        dialog=ButtonDialog:new{title="微信读书登录已失效\n\n无法在线加载章节，请重新扫码登录。\n\n已下载书籍和本地阅读记录不会删除。",title_align="center",
            buttons={
                {{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}},
                {{text="稍后",callback=function() UIManager:close(dialog) end}},
            }}
        UIManager:show(dialog)
        return true
    end
    self:info("无法加载：\n"..U.first_line(text,120))
    return false
end

function Plugin:_run_stream_task(label,fn,done,timeout)
    local loading=InfoMessage:new{text=tostring(label or "正在加载章节……")}
    UIManager:show(loading)
    UIManager:forceRePaint()
    local function finish(result)
        pcall(function() UIManager:close(loading) end)
        if done then done(result) end
    end
    -- Stream fetch/build must stay in the main plugin context. KOReader subprocess
    -- workers cannot reuse live HTTP sessions, FFI codec handles, or StreamReader
    -- instances, and JSON cannot round-trip the stream controller back to the UI.
    UIManager:scheduleIn(.05,function()
        local ok,value=pcall(fn)
        finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
    end)
    return true
end

function Plugin:_reader_plugin_instance()
    local reader_ui=self:_active_reader_ui()
    return reader_ui and reader_ui.miuread or nil
end

function Plugin:_reader_miuread_plugin()
    if self.ui and self.ui.document then return self end
    return self:_reader_plugin_instance()
end

function Plugin:_install_thought_link_guard()
    local ui=self.ui
    if not ui or not ui.link or type(ui.link.onGotoLink)~="function" then
        logger.warn("[MiuRead][ThoughtPopup] link guard skipped: reader link module unavailable")
        return false
    end
    local link=ui.link
    if link._miuread_thought_link_patched then return true end
    local owner=self
    link._miuread_original_onGotoLink=link.onGotoLink
    link.onGotoLink=function(link_self,lnk,neglect_current_location,allow_footnote_popup)
        local info=owner:_thought_info_from_link(lnk)
        if info and owner:_show_thought_info(info) then return true end
        return link._miuread_original_onGotoLink(link_self,lnk,neglect_current_location,allow_footnote_popup)
    end
    if type(link.getLinkFromGes)=="function" and not link._miuread_original_getLinkFromGes then
        link._miuread_original_getLinkFromGes=link.getLinkFromGes
        link.getLinkFromGes=function(link_self,ges)
            local lnk=link._miuread_original_getLinkFromGes(link_self,ges)
            if not lnk then return nil end
            local info=owner:_thought_info_from_link(lnk)
            if info then lnk.miuread_thought_href="#"..tostring(info.anchor or "") end
            return lnk
        end
    end
    if type(link.onTap)=="function" then
        link._miuread_original_onTap=link.onTap
        link.onTap=function(link_self,_,ges)
            local info=owner:_resolve_thought_from_ges(ges)
            if info then
                if owner:_thought_edge_page_turn(ges) then return true end
                return owner:_show_thought_info(info)
            end
            return link._miuread_original_onTap(link_self,_,ges)
        end
    end
    link._miuread_thought_link_patched=true
    logger.info("[MiuRead][ThoughtPopup] link guard installed")
    return true
end

function Plugin:_setup_stream_thought_tap()
    local plugin=self:_reader_miuread_plugin()
    if not plugin then
        logger.warn("[MiuRead][ThoughtPopup] stream hooks skipped: reader plugin missing")
        return false
    end
    local tap_ok=plugin:_setup_thought_tap()
    local guard_ok=plugin:_install_thought_link_guard()
    logger.info("[MiuRead][ThoughtPopup] stream hooks",
        "tap=",tostring(tap_ok==true),"guard=",tostring(guard_ok==true))
    return tap_ok or guard_ok
end

function Plugin:_ensure_stream_reader_hooks(attempt)
    attempt=tonumber(attempt) or 1
    local stream=STREAM_SESSION.reader
    if not stream or stream.active~=true then return false end
    self:_setup_stream_thought_tap()
    local plugin=self:_reader_plugin_instance()
    if plugin and type(plugin._patch_stream_end_of_book)=="function" then
        plugin:_patch_stream_end_of_book()
    end
    if self:_stream_active() then
        if plugin and type(plugin._apply_stream_pending_position)=="function" then
            plugin:_apply_stream_pending_position()
        end
        return true
    end
    if attempt<6 then
        local owner=self
        UIManager:scheduleIn(.25+attempt*.15,function() owner:_ensure_stream_reader_hooks(attempt+1) end)
    end
    return false
end

function Plugin:_apply_stream_chapter_result(stream,result,options)
    options=options or {}
    if not result or result.ok~=true or type(result.value)~="table" then
        self:_handle_stream_error(result and result.error or "未知错误","download")
        if options.close_on_fail then self:_close_stream_session() end
        return false
    end
    local payload=result.value
    local epub_path=tostring(payload.path or "")
    if epub_path=="" or not U.file_exists(epub_path) then
        self:info("章节文件未生成")
        if options.close_on_fail then self:_close_stream_session() end
        return false
    end
    STREAM_SESSION.reader=stream
    STREAM_SESSION.meta=payload.meta
    STREAM_SESSION.pending_percent=payload.meta and payload.meta.pending_percent or nil
    local open_opts={stream_result=true,force_reopen=options.force_reopen==true}
    local opened
    if options.switch and self.ui and self.ui.document and type(self.ui.switchDocument)=="function" then
        opened=self:_open_file_direct(epub_path,open_opts)
    else
        opened=self:_open_file_direct(epub_path,open_opts)
    end
    if opened==false then
        self:_close_stream_session()
        return false
    end
    local owner=self
    UIManager:scheduleIn(.1,function() owner:_ensure_stream_reader_hooks(1) end)
    UIManager:scheduleIn(.6,function() owner:_ensure_stream_reader_hooks(2) end)
    if options.defer_annotations==true then
        self:_stream_schedule_annotation_hydration(stream,payload.meta)
    end
    return true
end

function Plugin:_stream_schedule_annotation_hydration(stream,meta)
    stream = stream or (STREAM_SESSION and STREAM_SESSION.reader)
    if not stream or stream.active ~= true then return false end
    meta = type(meta) == "table" and meta or {}
    if meta.annotation_requested == true then return false end
    local chapter_uid = tostring(meta.uid or meta.chapter_uid or stream.current_uid or "")
    local index = tonumber(meta.index or stream.current_index) or 1
    if chapter_uid == "" then return false end
    local hydrate_key = tostring(stream.book and stream.book.bookId or "") .. ":" .. chapter_uid
    if self._stream_hydrating_key == hydrate_key then return false end
    self._stream_hydrating_key = hydrate_key
    local owner = self
    UIManager:scheduleIn(.25, function()
        if owner._stream_hydrating_key ~= hydrate_key then return end
        if not stream or stream.active ~= true then owner._stream_hydrating_key=nil; return end
        if stream.current_uid ~= chapter_uid then owner._stream_hydrating_key=nil; return end
        owner:_run_stream_task("正在同步划线与想法…", function()
            local path, hydrated_meta = stream:load_chapter_with_annotations(index)
            if not path then error(tostring(hydrated_meta or "批注同步失败")) end
            return {path = path, meta = hydrated_meta}
        end, function(result)
            owner._stream_hydrating_key = nil
            if not result or result.ok ~= true then
                logger.warn("[MiuRead][Stream] annotation hydration failed", tostring(result and result.error or "unknown"))
                return
            end
            owner:_apply_stream_chapter_result(stream,result,{switch=true,force_reopen=true})
        end, 180)
    end)
    return true
end

function Plugin:_open_book_stream(book,anchor)
    if not self:require_login() then return false end
    local target=U.copy(book or {})
    logger.warn("[MiuRead][Stream] open requested",
        "book=",tostring(target.bookId or target.book_id or ""),
        "title=",tostring(target.title or ""))
    self:_close_stream_session()
    self:_home_stop_background("stream open")
    local stream=StreamReader:new(self.store,self.reader,self.api,self.annotations,self.downloader)
    local owner=self
    self:_run_stream_task("正在加载《"..tostring(target.title or "书籍").."》……",function()
        local path,meta=stream:open(target,{fetch_annotations=false})
        if not path then error(tostring(meta or "打开失败")) end
        return {path=path,meta=meta,stream=stream}
    end,function(result)
        if not result or result.ok~=true then
            owner:_handle_stream_error(result and result.error or "未知错误","download")
            pcall(stream.close,stream)
            return
        end
        local payload=result.value
        owner:_apply_stream_chapter_result(payload.stream,{ok=true,value={path=payload.path,meta=payload.meta}},{close_on_fail=true,defer_annotations=true})
    end,180)
    return true
end

function Plugin:_stream_go_chapter(index)
    local session=STREAM_SESSION
    if not session or not session.reader or session.reader.active~=true then return false end
    local stream=session.reader
    local owner=self
    local chapter=stream.chapters and stream.chapters[index]
    local title=tostring(chapter and chapter.title or "章节")
    self:_run_stream_task("正在加载："..title,function()
        local path,meta=stream:load_chapter(index,{fetch_annotations=false})
        if not path then error(tostring(meta or "加载失败")) end
        return {path=path,meta=meta}
    end,function(result)
        if not owner:_apply_stream_chapter_result(stream,result,{switch=true,defer_annotations=true}) then return end
        UIManager:nextTick(function()
            if owner.ui and owner.ui.document then
                owner.ui:handleEvent(Event:new("GotoPage",1))
            end
        end)
    end,180)
    return true
end

function Plugin:_stream_go_next_chapter()
    local session=STREAM_SESSION
    if not session or not session.reader then return false end
    local next_index=session.reader:next_index()
    if not next_index then
        self:info("已经是最后一章")
        return false
    end
    return self:_stream_go_chapter(next_index)
end

function Plugin:_patch_stream_end_of_book()
    local ui=self.ui
    if not ui or not ui.status or ui.status._miuread_stream_eob_patched then return end
    local status=ui.status
    status._miuread_stream_original_onEndOfBook=status.onEndOfBook
    local owner=self
    status.onEndOfBook=function(status_self,...)
        if not owner:_stream_active() then
            if status._miuread_stream_original_onEndOfBook then
                return status._miuread_stream_original_onEndOfBook(status_self,...)
            end
            return false
        end
        owner:_show_stream_end_dialog()
        return true
    end
    status._miuread_stream_eob_patched=true
end

function Plugin:_show_stream_end_dialog()
    local session=STREAM_SESSION
    local has_next=session and session.reader and session.reader:has_next()
    local buttons={}
    if has_next then
        buttons[#buttons+1]={{text="下一章",callback=function()
            if self._stream_end_dialog then UIManager:close(self._stream_end_dialog); self._stream_end_dialog=nil end
            self:_stream_go_next_chapter()
        end}}
    else
        buttons[#buttons+1]={{text="已是最后一章",enabled=false,callback=function() end}}
    end
    buttons[#buttons+1]={{text="返回书架",callback=function()
        if self._stream_end_dialog then UIManager:close(self._stream_end_dialog); self._stream_end_dialog=nil end
        self:return_to_miuread_home("stream end")
    end}}
    if self._stream_end_dialog then pcall(UIManager.close,UIManager,self._stream_end_dialog) end
    self._stream_end_dialog=ButtonDialog:new{
        title="本章已读完",
        title_align="center",
        buttons=buttons,
    }
    UIManager:show(self._stream_end_dialog)
end

function Plugin:_stream_toc_items()
    local session=STREAM_SESSION
    if not session or not session.reader or not session.reader.chapters then return nil end
    local stream=session.reader
    local current=tonumber(stream.current_index) or 1
    local items={}
    for index,chapter in ipairs(stream.chapters) do
        local title=U.trim(tostring(chapter.title or ""))
        if title=="" then title="第 "..tostring(index).." 节" end
        local depth=tonumber(chapter.level or chapter.chapterLevel or chapter.chapter_level) or 1
        items[#items+1]={
            title=title,
            depth=depth,
            current=index==current,
            callback=function()
                if index==current then return true end
                self:_stream_go_chapter(index)
                return true
            end,
        }
    end
    return items,current
end

function Plugin:_apply_stream_pending_position()
    local percent=tonumber(STREAM_SESSION.pending_percent)
    if not percent or percent<=0 then return end
    STREAM_SESSION.pending_percent=nil
    if not (self.ui and self.ui.document) then return end
    UIManager:scheduleIn(.15,function()
        if self.ui and self.ui.document then
            self.ui:handleEvent(Event:new("GotoPercent",percent))
        end
    end)
end

function Plugin:_home_open_book(book,anchor)
    if book and (book.local_folder==true or book.kind=="folder") then
        local folder_path=LocalLibrary.normalize(book.folder_path or book.path)
        local root_path=LocalLibrary.normalize(book.root_path or folder_path)
        local home=self:_home_preferences()
        if tostring(home.local_library_mode or "direct")=="direct"
            and HomeView.is_shown() and self._home_active_section=="local" then
            return self:_home_local_inline_navigate(folder_path,root_path)
        end
        local root=self:_home_local_root_for_path(folder_path,self:_home_local_roots(true))
        return self:show_local_browser(folder_path,root or {path=root_path,name=book.title},{},false)
    end
    if book and (book.source=="local" or book.local_file==true) then return self:_home_open_local(book) end
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if Protocol.is_mp_account(id) then
        return self:_home_leave_and_run("mp account",function() self:mp_account(book) end)
    end
    self:_home_attach_local_record(book)
    if id~="" then
        self:_home_stop_background("stream open")
        return self:_open_book_stream(book,anchor)
    end
    self:info("无法打开书籍")
    return false
end

function Plugin:_home_book_key(book)
    if not book then return "" end
    if book.local_folder==true or book.kind=="folder" then
        local folder=LocalLibrary.normalize(book.folder_path or book.path or "")
        if folder~="" then return "folder:"..folder end
    end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return "book:"..id end
    local path=tostring(book.file or "")
    if path~="" then return "file:"..path end
    return tostring(book.title or "").."|"..tostring(book.author or "")
end

function Plugin:_home_recent_books(miuread_rows,local_rows,account_rows,hero,limit)
    local rows={}
    local hero_key=self:_home_book_key(hero)
    local seen={}
    if hero_key~="" then seen[hero_key]=true end
    for _,list in ipairs({miuread_rows or {},local_rows or {},account_rows or {}}) do
        for _,book in ipairs(list) do
            local progress=tonumber(book.progress) or 0
            local key=self:_home_book_key(book)
            if not (book.local_folder==true or book.kind=="folder")
                and (progress>0 or self:_home_book_time(book)>0) and key~="" and not seen[key] then
                seen[key]=true
                rows[#rows+1]=book
            end
        end
    end
    table.sort(rows,function(a,b)
        local at,bt=self:_home_book_time(a),self:_home_book_time(b)
        if at~=bt then return at>bt end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    local result={}
    for i=1,math.min(math.max(1,tonumber(limit) or 3),#rows) do result[#result+1]=rows[i] end
    return result
end


function Plugin:_home_all_rows()
    local rows,seen={},{}
    -- Prefer the downloaded copy when the same WeRead book exists in both
    -- "微信书架" and "已下载".
    for _,section in ipairs({"account","local","mp"}) do
        local entry=self._home_sections and self._home_sections[section]
        for _,book in ipairs(entry and entry.rows or {}) do
            local key=self:_home_book_key(book)
            if not (book.local_folder==true or book.kind=="folder") and key~="" and not seen[key] then
                seen[key]=true
                rows[#rows+1]=book
            end
        end
    end
    return rows
end

function Plugin:_home_show_full_shelf(title,rows,options)
    options=type(options)=="table" and options or {}
    rows=type(rows)=="table" and rows or {}
    if #rows==0 then self:info("这里还没有书籍") return false end
    self:_prepare_shelf_rows(rows)
    local prefs=self.store:preferences()
    local show_covers=self:_shelf_covers_enabled(prefs)
    if show_covers then self:_begin_cover_guard("home_all_books") end
    local view
    local ok,result=pcall(function()
        view=FullShelfView.show{
            title=tostring(title or "全部书籍").." · "..tostring(#rows).."本",
            books=rows,
            show_actions=options.show_actions==true,
            show_tabs=false,
            show_covers=show_covers,
            left_action_label=options.left_action_label,
            right_action_label=options.right_action_label,
            on_left_action=options.on_left_action,
            on_right_action=options.on_right_action,
            on_select=function(book,anchor) self:_home_open_book(book,anchor) end,
            on_hold=function(book,anchor) self:_home_hold_book(book,anchor) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function()
                if self._home_full_shelf_view==view then self._home_full_shelf_view=nil end
                self:_cancel_cover_loading()
                collectgarbage("step",120)
            end,
        }
        return view
    end)
    view=result or view
    if ok and view then
        self._home_full_shelf_view=view
        self:_home_schedule_local_shelf_metadata(rows,view)
        return true
    end
    self:_clear_cover_guard()
    logger.warn("[MiuRead][Home] full shelf unavailable",tostring(view))
    local items={}
    for _,book in ipairs(rows) do
        local row=book
        items[#items+1]={
            text=tostring(row.title or "未命名"),
            post_text=tostring(row.author or ""),
            callback=function(anchor) self:_home_open_book(row,anchor) end,
            hold_callback=function() self:_home_hold_book(row) end,
        }
    end
    self:list(tostring(title or "全部书籍"),items)
    return true
end

function Plugin:_home_all_books_state()
    self._home_all_books_options=type(self._home_all_books_options)=="table" and self._home_all_books_options or {
        source="all",status="all",sort="recent",
    }
    return self._home_all_books_options
end

function Plugin:_home_all_books_apply(rows)
    local state=self:_home_all_books_state()
    local filtered={}
    for _,book in ipairs(rows or {}) do
        local source=tostring(book.source or book.shelf_section or "")
        local id=tostring(book.bookId or book.book_id or "")
        local source_ok=state.source=="all"
            or (state.source=="account" and source=="account" and not Protocol.is_mp_account(id))
            or (state.source=="generated" and (source=="miuread" or source=="generated" or book.shelf_section=="generated"))
            or (state.source=="local" and (source=="local" or book.local_file==true))
            or (state.source=="mp" and Protocol.is_mp_account(id))
        local progress=tonumber(book.progress or 0) or 0
        local status=tostring(book.status_text or "")
        local status_ok=state.status=="all"
            or (state.status=="reading" and progress>0 and progress<100)
            or (state.status=="unread" and progress<=0)
            or (state.status=="finished" and progress>=100)
            or (state.status=="downloaded" and book.file and U.file_exists(book.file))
            or (state.status=="failed" and (status:find("失败",1,true) or status:find("修复",1,true)))
        if source_ok and status_ok then filtered[#filtered+1]=book end
    end
    table.sort(filtered,function(a,b)
        if state.sort=="title" then
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        elseif state.sort=="author" then
            local aa,ba=tostring(a.author or ""):lower(),tostring(b.author or ""):lower()
            if aa~=ba then return aa<ba end
            return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
        elseif state.sort=="added" then
            local at=tonumber(a.created_at or a.added_at or a.updated_at or 0) or 0
            local bt=tonumber(b.created_at or b.added_at or b.updated_at or 0) or 0
            if at~=bt then return at>bt end
        else
            local at,bt=self:_home_book_time(a),self:_home_book_time(b)
            if at~=bt then return at>bt end
        end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return filtered
end

function Plugin:_home_close_full_shelf()
    local view=self._home_full_shelf_view
    if view and UIManager:isWidgetShown(view) then
        pcall(function() UIManager:close(view) end)
    end
    self._home_full_shelf_view=nil
end

function Plugin:_home_all_books_option_dialog()
    local state=self:_home_all_books_state()
    local source_labels={all="全部来源",account="微信书架",generated="已下载",["local"]="本地书籍",mp="公众号"}
    local status_labels={all="全部状态",reading="阅读中",unread="尚未开始",finished="已读完",downloaded="已下载",failed="异常"}
    local sort_labels={recent="最近阅读",added="最近加入",title="按书名",author="按作者"}

    local function apply_choice(key,value)
        state[key]=value
        self:_home_close_full_shelf()
        UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
    end
    local function choice_rows(key,choices,labels)
        local rows={}
        for _,value in ipairs(choices) do
            local choice_value=value
            rows[#rows+1]={
                text=labels[choice_value],radio=true,checked_func=function() return state[key]==choice_value end,
                callback=function() apply_choice(key,choice_value) end,
            }
        end
        return rows
    end

    return self:_show_standalone_menu("筛选与排序",{
        {text="来源",post_text=source_labels[state.source],sub_item_table_func=function()
            return choice_rows("source",{"all","account","generated","local","mp"},source_labels)
        end},
        {text="状态",post_text=status_labels[state.status],sub_item_table_func=function()
            return choice_rows("status",{"all","reading","unread","finished","downloaded","failed"},status_labels)
        end},
        {text="排序",post_text=sort_labels[state.sort],sub_item_table_func=function()
            return choice_rows("sort",{"recent","added","title","author"},sort_labels)
        end},
        {text="恢复默认",post_text="全部来源 · 全部状态 · 最近阅读",callback=function()
            self._home_all_books_options={source="all",status="all",sort="recent"}
            self:_home_close_full_shelf()
            UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
        end},
    })
end

function Plugin:show_home_all_books()
    local rows=self:_home_all_books_apply(self:_home_all_rows())
    if #rows==0 then self:info("当前筛选条件下没有书籍") return false end
    local view
    local ok=self:_home_show_full_shelf("全部书籍",rows,{
        show_actions=true,
        left_action_label="搜索全部书籍",
        right_action_label="筛选与排序",
        on_left_action=function() self:show_home_search_dialog() end,
        on_right_action=function() self:_home_all_books_option_dialog() end,
    })
    return ok
end

function Plugin:show_home_reading_history()
    local rows={}
    for _,book in ipairs(self:_home_all_rows()) do
        if self:_home_book_time(book)>0 or tonumber(book.progress or 0)>0 then rows[#rows+1]=book end
    end
    table.sort(rows,function(a,b)
        local at,bt=self:_home_book_time(a),self:_home_book_time(b)
        if at~=bt then return at>bt end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return self:_home_show_full_shelf("阅读历史",rows)
end

function Plugin:show_home_search_dialog()
    local d
    d=InputDialog:new{
        title="搜索全部书籍",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local query=U.trim(d:getInputText())
                UIManager:close(d)
                if query=="" then return end
                local results=self.library:search(self:_home_all_rows(),query)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_home_show_full_shelf("搜索 “"..query.."”",results)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_home_local_book_details(book)
    local lines={tostring(book.title or "未命名")}
    if U.trim(tostring(book.author or ""))~="" then lines[#lines+1]="作者："..tostring(book.author) end
    if U.trim(tostring(book.format or ""))~="" then lines[#lines+1]="格式："..tostring(book.format) end
    if tonumber(book.progress or 0)>0 then lines[#lines+1]="进度："..tostring(math.floor((tonumber(book.progress) or 0)+.5)).."%" end
    if U.trim(tostring(book.description or ""))~="" then lines[#lines+1]="\n"..tostring(book.description) end
    lines[#lines+1]="\n文件："..tostring(book.file or "")
    self:info(table.concat(lines,"\n"))
end

function Plugin:_home_refresh_one_book_metadata(book,network_too)
    if type(book)~="table" then return false end
    local path=tostring(book.file or "")
    local local_changed=false
    if path~="" and U.file_exists(path) then
        self:toast("正在更新这本书的信息…",2)
        local metadata,err=LocalMetadata.read(path,self:_home_local_metadata_dir(),{open_document=true,use_bim=true})
        if metadata then
            if book.source=="local" or book.local_file==true then
                local_changed=self:_home_update_local_cache(path,metadata)
            else
                local_changed=self:_home_update_miuread_metadata(path,metadata)
            end
            if LocalMetadata.merge(book,metadata) then local_changed=true end
            book.status_text=self:_home_status_text(book,book.source=="local" or book.local_file==true)
        else
            logger.warn("[MiuRead][Home] local metadata refresh failed",tostring(err or "unknown"))
        end
    end
    local network_started=false
    if network_too~=false then
        network_started=self:_home_schedule_network_metadata(book,true,false,nil,true)==true
    end
    if local_changed then self:_refresh_home_view(network_started and "本地信息已更新，正在网络补全" or "书籍信息已更新","content")
    elseif network_started then self:toast("正在从网络补全书籍信息…",2)
    elseif path=="" or not U.file_exists(path) then
        self:info("当前没有可读取的本地文件，网络信息也暂时无法获取")
        return false
    else
        self:toast("没有发现需要更新的信息",2)
    end
    return local_changed or network_started
end

function Plugin:_home_remove_lockscreen_cover_cache(book)
    if type(book)~="table" then return false end
    local id=tostring(book.bookId or book.book_id or "")
    if id=="" then return false end
    local dir=self.store.data_dir.."/lockscreen"
    if lfs.attributes(dir,"mode")~="directory" then return false end
    local prefix=U.id_name(id).."-"
    local removed=false
    local ok,iter,state,var=pcall(lfs.dir,dir)
    if not ok or not iter then return false end
    for name in iter,state,var do
        if name~="." and name~=".." and name:sub(1,#prefix)==prefix and name:match("%.png$") then
            if os.remove(dir.."/"..name) then removed=true end
        end
    end
    return removed
end

function Plugin:_home_force_refresh_current_cover(book,on_done)
    if type(book)~="table" then return false end
    local id=tostring(book.bookId or book.book_id or "")
    local cover=tostring(book.cover or book.coverUrl or "")
    if cover=="" and id~="" then
        local remote_books=self.library:cached()
        for _,row in ipairs(type(remote_books)=="table" and remote_books or {}) do
            if tostring(row.bookId or row.book_id or "")==id then
                cover=tostring(row.cover or row.coverUrl or "")
                if cover~="" then break end
            end
        end
    end
    if id=="" or cover=="" or not self.home_cover_async or self.home_cover_async:busy() then return false end
    if not self:is_online() then return false end

    local old_cached=self.library:cached_cover_path(id)
    local refresh_token="manual-"..tostring(os.time()).."-"..tostring(math.floor((os.clock()%1)*1000))
    local item={bookId=id,cover=cover}
    local background=self.home_cover_async:available()
    local covers_dir=self.store.covers_dir
    local worker
    if background then
        worker=function()
            local HttpChild=require("miuread.http")
            local LibraryChild=require("miuread.library")
            local store={
                covers_dir=covers_dir,
                auth=function() return {cookies={}} end,
                save_auth=function() end,
                get=function(_,_,default) return default end,
                set=function() end,
            }
            return LibraryChild:new(nil,HttpChild:new(store),store):cache_cover(item,{
                retries=1,timeout={8,15},persist_index=false,skip_index_lookup=true,
                cache_suffix=refresh_token,
            })
        end
    else
        worker=function()
            return self.library:cache_cover(item,{
                retries=0,timeout={4,7},persist_index=false,skip_index_lookup=true,
                cache_suffix=refresh_token,
            })
        end
    end

    local started=self.home_cover_async:run("home-cover-manual-refresh",worker,function(result)
        if not result or result.ok~=true or not result.value then
            logger.warn("[MiuRead][Cover] manual refresh failed",tostring(id),
                tostring(result and result.error or "unknown"))
            if on_done then on_done(false) end
            return
        end
        local path=tostring(result.value)
        local index=self.store:get("cover_index",{})
        index[tostring(id)]=path
        self.store:set("cover_index",index)
        if self._cover_index_pending then self._cover_index_pending[tostring(id)]=nil end

        book.cover_path=path
        self:_home_apply_cover_path(id,path)
        for key,section in pairs(self._home_sections or {}) do
            for _,row in ipairs(section.rows or {}) do
                if tostring(row.bookId or row.book_id or "")==id then
                    row.cover_path=path
                    self:_home_bump_section_revision(key)
                    break
                end
            end
        end

        self:_home_remove_lockscreen_cover_cache(book)
        local home=self:_home_preferences()
        if home.lockscreen_recent~=false then
            local hero=self._home_hero
            if hero and tostring(hero.bookId or hero.book_id or "")==id then
                hero.cover_path=path
                local screensaver=self:_home_prepare_lockscreen_cover(hero)
                HOME_SESSION.screensaver_file=screensaver
                local current=HomeView.current()
                if current and current.opts then current.opts.screensaver_file=screensaver end
                UIManager:scheduleIn(.25,function()
                    if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_schedule_cover_derivatives({hero}) end
                end)
            end
        end

        if old_cached and old_cached~=path then os.remove(old_cached) end
        if HomeView.is_shown() then
            if self._home_hero and tostring(self._home_hero.bookId or self._home_hero.book_id or "")==id then
                HomeView.update_hero(self._home_hero)
            end
            HomeView.update_book(id)
        end
        logger.info("[MiuRead][Cover] manual refresh complete",tostring(id),tostring(path))
        if on_done then on_done(true) end
    end,background and 35 or 14)
    return started==true
end

function Plugin:_home_refresh_current_network_metadata(book)
    if type(book)~="table" then return false end
    if not self:is_online() then
        self:toast("当前未联网，无法更新书籍信息和封面",2)
        return false
    end

    self:toast("正在更新这本书的信息和封面…",2)
    local state={metadata_done=false,metadata_ok=false,metadata_partial=false,cover_done=false,cover_ok=false,finished=false}
    local function finish()
        if state.finished or not state.metadata_done or not state.cover_done then return end
        state.finished=true
        if state.metadata_ok and state.cover_ok then
            self:toast(state.metadata_partial
                and "封面和书籍信息已刷新，部分资料暂未找到"
                or "书籍信息和封面已更新",2)
        elseif state.cover_ok then
            self:toast("封面已更新，网络书籍信息更新失败",2)
        elseif state.metadata_ok then
            self:toast(state.metadata_partial
                and "书籍信息已刷新，部分资料暂未找到；封面更新失败"
                or "书籍信息已更新，封面更新失败",2)
        else
            self:toast("当前书籍更新失败，请稍后重试",2)
        end
    end

    local metadata_started=self:_home_schedule_network_metadata(book,true,true,function(ok,_,detail)
        state.metadata_done=true
        state.metadata_ok=ok==true
        state.metadata_partial=type(detail)=="table" and detail.partial==true
        finish()
    end,true)==true
    if not metadata_started then state.metadata_done=true end

    local cover_started=self:_home_force_refresh_current_cover(book,function(ok)
        state.cover_done=true
        state.cover_ok=ok==true
        finish()
    end)==true
    if not cover_started then state.cover_done=true end

    if metadata_started or cover_started then
        finish()
        return true
    end
    if self.home_metadata_async and self.home_metadata_async:busy() then
        self:toast("已有图书信息任务正在进行，请稍后再试",2)
    elseif self.home_cover_async and self.home_cover_async:busy() then
        self:toast("已有封面任务正在进行，请稍后再试",2)
    elseif tostring(book.cover or book.coverUrl or "")=="" then
        self:toast("当前书籍没有可更新的网络封面",2)
    else
        self:toast("当前暂时无法开始更新",2)
    end
    return false
end

function Plugin:_home_hide_local_book(book)
    local path=tostring(book and book.file or ""):gsub("\\","/"):gsub("/+","/")
    if path=="" then return false end
    local home,preferences=self:_home_preferences()
    home.hidden_local_files=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    home.hidden_local_files[path]=true
    self:_save_home_preferences(home,preferences)
    self:_show_miuread_home_now(false,true,true,"content")
    self:toast("已从觅阅书架隐藏")
    return true
end

function Plugin:_home_delete_local_book(book,anchor,confirmed)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在") return false end
    local function delete_now()
        local ok,err=os.remove(path)
        if not ok then self:info("删除失败：\n"..tostring(err or "无法删除文件")); return end
        local cache=self:_home_local_cache()
        local kept={}
        for _,row in ipairs(cache.books or {}) do if tostring(row.file or "")~=path then kept[#kept+1]=row end end
        cache.books=kept
        self.store:set("home_local_index",cache)
        self:_show_miuread_home_now(false,true,true,"content")
        self:toast("本地文件已删除")
    end
    if confirmed==true then delete_now(); return true end
    if HomeView.is_shown() then
        return ActionSheet.show{
            anchor=anchor,preferred_direction="above",width_ratio=.60,
            title="删除本地文件？",subtitle="《"..tostring(book.title or "书籍").."》删除后无法通过觅阅恢复。",
            actions={
                {icon="×",label="取消",detail="保留本地文件",callback=function() end},
                {icon="!",label="删除文件",detail="阅读进度侧边文件不会主动删除",danger=true,callback=delete_now},
            },
        }
    end
    UIManager:show(ConfirmBox:new{text="删除本地文件《"..tostring(book.title or "书籍").."》？\n\n文件删除后无法通过觅阅恢复。阅读进度侧边文件不会主动删除。",ok_text="删除文件",cancel_text="取消",ok_callback=delete_now})
    return true
end

function Plugin:_home_repair_book(book)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then self:info("这本书没有可用的修复记录") return false end
    return self:_repair_downloaded_book(id)
end

function Plugin:_show_home_refresh_popup(anchor)
    ActionSheet.show{
        cache_key="home_refresh",
        anchor=anchor,
        preferred_direction="below",
        title="更新",
        subtitle="内容更新与墨水屏全刷分开执行",
        actions={
            {icon="↻",label="更新当前栏目",detail="只检查当前看到的内容",callback=function() self:_home_manual_refresh() end},
            {icon="▣",label="刷新整个主页",detail="核对已有状态并整页更新一次",callback=function() self:_home_refresh_whole_page() end},
            {icon="☁",label="更新微信书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
            {icon="⌕",label="更新本地书库",detail="检查新增、删除和移动的书籍",callback=function()
                local started=self:_home_scan_local(true)
                if started then self:toast("正在更新本地书库…",2) end
            end},
            {icon="i",label="更新最近阅读信息",detail="更新顶部这本书的资料和封面",callback=function()
                local hero=self._home_hero
                if hero then self:_home_refresh_current_network_metadata(hero)
                else self:toast("当前没有最近阅读书籍",2) end
            end},
            {icon="▤",label="全屏刷新",detail="整屏刷新并清除墨水屏残影",callback=function() self:_home_full_refresh(true) end},
        },
    }
end

function Plugin:_show_home_download_popup(anchor)
    return
end

function Plugin:_show_home_sync_popup(anchor)
    local summary=self:_home_sync_summary()
    local subtitle=self:_home_sync_status_label()
    if summary.total>0 then
        subtitle=subtitle.."  ·  进度 "..tostring(summary.progress)
            .."  时间 "..tostring(summary.time)
            .."  划线 "..tostring(summary.highlight)
            .."  想法 "..tostring(summary.thought)
    end
    ActionSheet.show{
        cache_key="home_sync",
        anchor=anchor,
        preferred_direction="below",
        title="同步",
        subtitle=subtitle,
        actions={
            {icon="⇅",label="同步待处理内容",detail="进度 时间 划线与想法",callback=function() self:_sync_home_pending() end},
            {icon="i",label="查看同步详情",detail="分别查看四类数据状态",callback=function() self:show_sync_status(false) end},
            {icon="⚙",label="同步设置",detail="开关 可见范围 提醒与诊断",callback=function()
                self:_show_standalone_menu("同步设置",self:sync_settings_menu())
            end},
        },
        wide_last=true,
    }
end

function Plugin:_show_home_search_popup(anchor)
    ActionSheet.show{
        cache_key="home_search",
        anchor=anchor,
        preferred_direction="below",
        width_ratio=.58,
        title="搜索",
        subtitle="从主页直接查找或浏览书籍",
        actions={
            {icon="⌕",label="搜索书籍",detail="按书名或作者查找",callback=function() self:show_home_search_dialog() end},
            {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
        },
    }
end

function Plugin:_show_home_frontlight_popup(anchor)
    local enabled=self:_reader_frontlight_enabled()
    local value=math.floor((tonumber(self:_reader_frontlight_value()) or 0)+.5)
    ActionSheet.show{
        cache_key="home_frontlight",
        anchor=anchor,
        preferred_direction="below",
        width_ratio=.60,
        title="前光",
        subtitle="当前亮度 "..tostring(value),
        actions={
            {icon="☼",label="亮度与色温",detail="打开完整前光调节",callback=function() self:_home_frontlight() end},
            {icon=enabled and "○" or "●",label=enabled and "关闭前光" or "开启前光",detail="快速切换前光",callback=function() self:_reader_toggle_frontlight() end},
            {icon="◐",label="切换夜间模式",detail="反转阅读显示",callback=function() self:_home_toggle_night() end},
        },
        wide_last=true,
    }
end

function Plugin:_show_home_settings_center()
    return self:_show_standalone_menu("觅阅设置",{
        {text="首页与书架",post_text="布局 书架与快捷入口",sub_item_table_func=function() return self:display_settings_menu() end},
        {text="阅读界面",post_text="显示与快捷控制",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end},
        {text="评论、划线与想法",post_text="评论显示与本地批注",sub_item_table_func=function() return PluginSettings.comments(self) end},
        {text="时间与时区",post_text="时间来源与地区显示",sub_item_table_func=function() return self:time_display_settings_menu() end},
        {text="更新与关于",post_text="版本 更新通道与说明",sub_item_table_func=function() return PluginSettings.update_about(self) end},
        {text="工具与维护",post_text="修复 清理与诊断",sub_item_table_func=function() return self:maintenance_menu() end},
    },{page_size=6})
end

function Plugin:_show_home_settings_popup(anchor)
    local actions={
        {icon="▦",label="首页与书架",detail="布局 书架与快捷入口",callback=function()
            self:_show_standalone_menu("首页与书架",self:display_settings_menu(),{anchor=anchor})
        end},
        {icon="Aa",label="阅读界面",detail="显示与快捷控制",callback=function()
            self:_show_standalone_menu("阅读界面",self:reader_quick_panel_settings_menu(),{anchor=anchor})
        end},
        {icon="✎",label="评论与批注",detail="评论 划线与想法",callback=function()
            self:_show_standalone_menu("评论、划线与想法",PluginSettings.comments(self),{anchor=anchor})
        end},
        {icon="◷",label="时间与时区",detail="时间来源与地区显示",callback=function()
            self:_show_standalone_menu("时间与时区",self:time_display_settings_menu(),{anchor=anchor})
        end},
        {icon="↺",label="更新与关于",detail="版本 更新通道与说明",callback=function()
            self:_show_standalone_menu("更新与关于",PluginSettings.update_about(self),{anchor=anchor})
        end},
        {icon="⚙",label="工具与维护",detail="修复 清理与诊断",callback=function()
            self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor})
        end},
    }
    return ActionSheet.show{
        cache_key="home_settings",
        anchor=anchor,preferred_direction="below",width_ratio=.78,columns=2,
        title="觅阅设置",subtitle="常用设置与维护",actions=actions,
    }
end

function Plugin:_show_home_all_books_popup(anchor)
    ActionSheet.show{
        cache_key="home_all_books",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="全部书籍",subtitle="浏览完整书架",
        actions={
            {icon="▦",label="打开全部书籍",detail="查看当前所有书籍",callback=function() self:show_home_all_books() end},
            {icon="◷",label="阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
        },
    }
end

function Plugin:_show_home_history_popup(anchor)
    ActionSheet.show{
        cache_key="home_history",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="阅读历史",subtitle="最近阅读与完整书架",
        actions={
            {icon="◷",label="打开阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
            {icon="▦",label="全部书籍",detail="返回完整书架浏览",callback=function() self:show_home_all_books() end},
        },
    }
end

function Plugin:_show_home_file_manager_popup(anchor)
    ActionSheet.show{
        cache_key="home_file_manager",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="文件管理",subtitle="本地文件入口",
        actions={
            {icon="▤",label="打开 KOReader 文件管理",detail="进入原生文件浏览器",callback=function() self:_home_close_to_native(true) end},
            {icon="▦",label="本地书库",detail="查看觅阅本地书籍",callback=function() self:show_home_local_library() end},
        },
    }
end

function Plugin:_show_home_screenshot_popup(anchor)
    ActionSheet.show{
        cache_key="home_screenshot",
        anchor=anchor,preferred_direction="below",width_ratio=.58,
        title="截图",subtitle="屏幕操作",
        actions={
            {icon="▣",label="开始截图",detail="进入截图模式",callback=function() ScreenshotMode.start(self,anchor) end},
            {icon="▤",label="全屏刷新",detail="清除墨水屏残影",callback=function() self:_home_full_refresh() end},
        },
    }
end

function Plugin:_home_visible_action_neighbor(key,direction)
    local home=self:_home_preferences()
    local order=home.action_order or HOME_ACTION_ITEM_ORDER
    local items=home.action_items or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return nil end
    local step=direction<0 and -1 or 1
    local i=index+step
    while i>=1 and i<=#order do
        if items[order[i]]==true then return order[i] end
        i=i+step
    end
    return nil
end

function Plugin:_home_move_visible_action(key,direction)
    local home,preferences=self:_home_preferences()
    local order=home.action_order or U.copy(HOME_ACTION_ITEM_ORDER)
    local items=home.action_items or {}
    local index,target
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local step=direction<0 and -1 or 1
    local i=index+step
    while i>=1 and i<=#order do
        if items[order[i]]==true then target=i; break end
        i=i+step
    end
    if not target then return false end
    order[index],order[target]=order[target],order[index]
    home.action_order=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_show_home_quick_notice(anchor,title,subtitle,delay)
    return ActionSheet.show{
        anchor=anchor,preferred_direction="below",width_ratio=.48,
        title=tostring(title or "完成"),subtitle=tostring(subtitle or ""),auto_close=tonumber(delay) or 1.4,
    }
end

function Plugin:_home_replace_action_item(from_key,to_key)
    if from_key==to_key then return true end
    local home,preferences=self:_home_preferences()
    local items=home.action_items or {}
    if items[to_key]==true then return false end
    local order=home.action_order or U.copy(HOME_ACTION_ITEM_ORDER)
    local from_i,to_i
    for i,name in ipairs(order) do
        if name==from_key then from_i=i end
        if name==to_key then to_i=i end
    end
    if not from_i or not to_i then return false end
    order[from_i],order[to_i]=order[to_i],order[from_i]
    items[from_key]=false; items[to_key]=true
    home.action_items=items; home.action_order=order
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
    return true
end

function Plugin:_show_home_action_replace_popup(key,anchor)
    local home=self:_home_preferences()
    local actions={}
    for _,candidate in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if candidate~=key and home.action_items[candidate]~=true then
            if candidate~="sleep" or Device:canSuspend() then
                local target=candidate
                actions[#actions+1]={icon="↔",label=HOME_ACTION_LABELS[target] or target,detail="替换当前快捷项",callback=function()
                    self:_home_replace_action_item(key,target)
                end}
            end
        end
    end
    return ActionSheet.show{
        anchor=anchor,preferred_direction="below",width_ratio=.70,title="更换快捷项",subtitle="替换后保持当前位置",
        actions=actions,
    }
end

function Plugin:_home_action_function_actions(key,anchor)
    if key=="refresh" then return {
        {icon="↻",label="更新当前栏目",detail="只检查当前看到的内容",callback=function() self:_home_manual_refresh() end},
        {icon="▣",label="刷新整个主页",detail="核对已有状态并整页更新一次",callback=function() self:_home_refresh_whole_page() end},
        {icon="☁",label="更新微信书架",detail="重新获取微信书架变化",callback=function() self:_home_refresh_remote(true,true) end},
        {icon="⌕",label="更新本地书库",detail="检查新增、删除和移动的书籍",callback=function()
            local started=self:_home_scan_local(true)
            if started then self:toast("正在更新本地书库…",2) end
        end},
        {icon="i",label="更新最近阅读信息",detail="更新顶部这本书的资料和封面",callback=function()
            local hero=self._home_hero
            if hero then self:_home_refresh_current_network_metadata(hero)
            else self:toast("当前没有最近阅读书籍",2) end
        end},
        {icon="▤",label="全屏刷新",detail="整屏刷新并清除墨水屏残影",callback=function() self:_home_full_refresh(true) end},
    } end
    if key=="search" then return {
        {icon="⌕",label="搜索书籍",detail="按书名或作者查找",callback=function() self:show_home_search_dialog() end},
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
        {icon="◷",label="阅读历史",detail="查看最近阅读记录",callback=function() self:show_home_reading_history() end},
        {icon="▤",label="本地书库",detail="浏览本地书籍",callback=function() self:show_home_local_library() end},
        {icon="◎",label="公众号",detail="切换到公众号书架",callback=function() self:_set_home_section("mp") end},
    } end
    if key=="downloads" then return {
        {icon="⇩",label="下载任务",detail="进度 排队与失败重试",callback=function() self:show_downloads() end},
        {icon="⚙",label="下载设置",detail="策略 目录与提醒",callback=function() self:_show_standalone_menu("下载设置",self:download_settings_menu(),{anchor=anchor}) end},
        {icon="✚",label="检查书籍完整性",detail="发现需要修复的已下载书",callback=function() self:scan_downloaded_books_for_integrity_repair() end},
        {icon="⌫",label="存储清理",detail="清理临时文件与失效缓存",callback=function() self:show_download_cleanup_dialog() end},
    } end
    if key=="sync" then return {
        {icon="⇅",label="立即同步",detail="处理当前待同步内容",callback=function() self:_sync_home_pending() end},
        {icon="i",label="同步详情",detail="查看各类数据状态",callback=function() self:show_sync_status(false) end},
        {icon="✚",label="修复同步",detail="检查并修复异常状态",callback=function() self:show_sync_status(true) end},
        {icon="⚙",label="同步设置",detail="开关 范围与提醒",callback=function() self:_show_standalone_menu("同步设置",self:sync_settings_menu(),{anchor=anchor}) end},
        {icon="!",label="同步诊断",detail="查看诊断信息",callback=function() self:_show_standalone_menu("同步诊断",self:sync_diagnostics_menu(),{anchor=anchor}) end},
    } end
    if key=="sleep" then
        local rows={
            {icon="◐",label="休眠",detail="立即进入休眠",callback=function() self:_home_sleep() end},
            {icon="←",label="返回 KOReader",detail="离开觅阅桌面",callback=function() self:_home_close_to_native(true) end},
            {icon="↺",label="重启 KOReader",detail="保存状态后重新启动",callback=function() self:_show_home_power_confirm(anchor,"重启 KOReader？","阅读状态会先保存。","重启",function() self:_restart_koreader("home power bubble") end) end},
            {icon="⏻",label="退出 KOReader",detail="返回 Kindle 原生环境",callback=function() self:_show_home_power_confirm(anchor,"退出 KOReader？","当前阅读和设置会先保存。","退出",function() self:_quit_koreader(true) end) end},
        }
        if type(Device.canReboot)=="function" and Device:canReboot() then rows[#rows+1]={icon="↻",label="重启设备",detail="重新启动 Kindle",callback=function() self:_home_reboot_device(anchor) end} end
        if type(Device.canPowerOff)=="function" and Device:canPowerOff() then rows[#rows+1]={icon="■",label="关闭设备",detail="完全关闭 Kindle",danger=true,callback=function() self:_home_poweroff_device(anchor) end} end
        return rows
    end
    if key=="miuread_settings" then return {
        {icon="▦",label="首页与书架",detail="布局 书架与快捷入口",callback=function() self:_show_standalone_menu("首页与书架",self:display_settings_menu(),{anchor=anchor}) end},
        {icon="Aa",label="阅读界面",detail="显示与快捷控制",callback=function() self:_show_standalone_menu("阅读界面",self:reader_quick_panel_settings_menu(),{anchor=anchor}) end},
        {icon="✎",label="评论与批注",detail="评论 划线与想法",callback=function() self:_show_standalone_menu("评论、划线与想法",PluginSettings.comments(self),{anchor=anchor}) end},
        {icon="⇅",label="同步",detail="进度 时间与批注同步",callback=function() self:_show_standalone_menu("同步",self:sync_settings_menu(),{anchor=anchor}) end},
        {icon="↺",label="更新与关于",detail="版本 更新通道与说明",callback=function() self:_show_standalone_menu("更新与关于",PluginSettings.update_about(self),{anchor=anchor}) end},
        {icon="⚙",label="工具与维护",detail="修复 清理与诊断",callback=function() self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor}) end},
    } end
    if key=="all_books" then return {
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
        {icon="◷",label="阅读历史",detail="最近阅读记录",callback=function() self:show_home_reading_history() end},
    } end
    if key=="history" then return {
        {icon="◷",label="阅读历史",detail="最近阅读记录",callback=function() self:show_home_reading_history() end},
        {icon="▦",label="全部书籍",detail="打开完整书架",callback=function() self:show_home_all_books() end},
    } end
    if key=="file_manager" then return {
        {icon="▤",label="KOReader 文件管理",detail="打开原生文件浏览器",callback=function() self:_home_close_to_native(true) end},
        {icon="▦",label="本地书库",detail="查看觅阅本地书籍",callback=function() self:show_home_local_library() end},
    } end
    if key=="screenshot" then return {
        {icon="▣",label="开始截图",detail="进入截图模式",callback=function() ScreenshotMode.start(self,anchor) end},
        {icon="▤",label="全屏刷新",detail="清除残影",callback=function() self:_home_full_refresh() end},
    } end
    return {}
end

function Plugin:_show_home_action_manage_popup(key,label,anchor)
    local can_left=self:_home_visible_action_neighbor(key,-1)~=nil
    local can_right=self:_home_visible_action_neighbor(key,1)~=nil
    local actions=self:_home_action_function_actions(key,anchor)
    local manage={
        {label="← 左移",enabled=can_left,callback=function() self:_home_move_visible_action(key,-1) end},
        {label="更换",callback=function() self:_show_home_action_replace_popup(key,anchor) end},
        {label="隐藏",callback=function() self:_home_toggle_group_item("action",key) end},
        {label="右移 →",enabled=can_right,callback=function() self:_home_move_visible_action(key,1) end},
    }
    return ActionSheet.show{
        cache_key="home_action_manage_"..tostring(key),
        anchor=anchor,preferred_direction="below",width_ratio=.80,
        title=tostring(label or HOME_ACTION_LABELS[key] or "快捷项"),subtitle="点击使用主功能 · 长按扩展与管理",
        actions=actions,wide_last=(#actions%2==1),footer_actions=manage,
    }
end

function Plugin:_home_book_delete_state(book)
    local book_id=tostring(book and (book.bookId or book.book_id) or "")
    if book_id=="" then return nil end
    self.store:reload()
    self.store:prune_missing_files()
    local stored=self.store:book(book_id)
    if not stored then return {book_id=book_id,variants={},chapter_count=0,has_partial=false} end
    local kinds={"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}
    local variants={}
    local preferred=self:_preferred_record(book_id)
    local preferred_file=preferred and tostring(preferred.file or "") or ""
    local current_kind=nil
    for _,kind in ipairs(kinds) do
        local record=stored.variants and stored.variants[kind]
        if record and record.file and U.file_exists(record.file) then
            local row={kind=kind,label=self:_variant_label(kind),record=record}
            variants[#variants+1]=row
            if preferred_file~="" and tostring(record.file)==preferred_file then current_kind=kind end
        end
    end
    if not current_kind and variants[1] then current_kind=variants[1].kind end
    local _,chapter_count=self:_download_book_labels(U.merge(stored,{book_id=book_id}))
    return {
        book_id=book_id,
        stored=stored,
        variants=variants,
        current_kind=current_kind,
        chapter_count=tonumber(chapter_count) or 0,
        has_partial=self.store:book_has_partial_cache(book_id)==true,
    }
end

function Plugin:_show_home_delete_book_popup(book,anchor)
    local state=self:_home_book_delete_state(book)
    if not state then self:info("这本书没有可删除的本地记录") return false end
    local current_label="未识别"
    for _,row in ipairs(state.variants or {}) do
        if row.kind==state.current_kind then current_label=row.label; break end
    end
    local installed={}
    for _,row in ipairs(state.variants or {}) do installed[#installed+1]=row.label end
    if state.chapter_count>0 then installed[#installed+1]="单章文件" end
    if state.has_partial then installed[#installed+1]="未完成缓存" end
    if #installed==0 then self:info("这本书没有可删除的本地版本") return false end
    local subtitle="ⓘ 当前版本："..current_label
    if #installed>1 then subtitle=subtitle.." · 本地共 "..tostring(#installed).." 类文件" end
    local actions={}
    if state.current_kind then
        actions[#actions+1]={
            icon="⌫",label="删除当前版本",detail=current_label.." · 仅删除这个 EPUB",danger=true,
            callback=function() self:_confirm_delete_variant(state.book_id,state.current_kind,book.title) end,
        }
    end
    if #installed>1 or not state.current_kind then
        actions[#actions+1]={
            icon="!",label="删除全部本地版本",detail="同时清理本机评论、记录与缓存",danger=true,
            callback=function() self:_confirm_delete_book_downloads(state.book_id,book.title) end,
        }
    end
    actions[#actions+1]={
        icon="i",label="查看已下载版本",detail=table.concat(installed,"、"),
        callback=function() self:downloaded_book_menu(state.book_id) end,
    }
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="above",
        width_ratio=.66,
        title="删除书籍 · "..tostring(book.title or "书籍"),
        subtitle=subtitle,
        actions=actions,wide_last=(#actions%2==1),
        footer_action={label="取消",callback=function() end},
    }
    return true
end

function Plugin:_show_home_local_book_more(book,anchor)
    ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.62,
        title=tostring(book.title or "本地书籍"),subtitle="更多书籍操作",
        actions={
            {icon="▤",label="在文件管理中查看",detail="打开 KOReader 文件浏览器",callback=function() self:_home_close_to_native(true) end},
            {icon="−",label="从觅阅书架隐藏",detail="保留本地文件",callback=function() self:_home_hide_local_book(book) end},
        },
        footer_action={label="返回书籍操作",callback=function() self:_home_hold_book(book,anchor) end},
    }
end

function Plugin:_show_home_remote_book_more(book,anchor)
    local target=U.copy(book)
    self:_home_attach_local_record(target)
    local id=tostring(target.bookId or target.book_id or "")
    local actions={
        {icon="▶",label="开始阅读",detail="按云端进度在线阅读",callback=function() self:_open_book_stream(target,anchor) end},
        {icon="i",label="书籍详情",detail="简介、作者与出版信息",callback=function() self:book_details(target) end},
    }
    return ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.66,
        title=tostring(target.title or "书籍"),subtitle="更多书籍操作",
        actions=actions,wide_last=(#actions%2==1),
        footer_action={label="返回书籍操作",callback=function() self:_home_hold_book(target,anchor) end},
    }
end

function Plugin:_home_hold_book(book,anchor)
    if not book then return end
    if book.local_folder==true or book.kind=="folder" then
        local actions={
            {icon="▤",label="在文件管理中查看",detail="打开 KOReader 文件浏览器",callback=function() self:_home_close_to_native(true) end},
        }
        if not book.local_parent then
            actions[#actions+1]={icon="refresh",label="刷新这一层",detail="只更新当前文件夹",callback=function()
                local path=LocalLibrary.normalize(book.folder_path or book.path)
                self:_home_refresh_local_directory(path,function()
                    local context=self:_home_local_inline_context()
                    if HomeView.is_shown() and not context.picker and LocalLibrary.normalize(context.path)==path then
                        self:_home_apply_local_inline_section(true)
                    end
                end,true)
            end}
        end
        ActionSheet.show{
            anchor=anchor,preferred_direction="above",width_ratio=.62,
            title=tostring(book.title or "文件夹"),subtitle=book.local_parent and "本地书库导航" or "本地书库文件夹",
            actions=actions,wide_last=(#actions%2==1),
        }
        return
    end
    local id=tostring(book.bookId or book.book_id or "")
    if Protocol.is_mp_account(id) then
        local target=U.copy(book)
        ActionSheet.show{
            anchor=anchor,
            preferred_direction="above",
            width_ratio=.62,
            title=tostring(target.title or "公众号"),
            subtitle=U.trim(tostring(target.author or ""))~="" and tostring(target.author) or "公众号内容",
            actions={
                {icon="i",label="查看信息",detail="作者与简介",callback=function()
                    local lines={tostring(target.title or "公众号")}
                    if U.trim(tostring(target.author or ""))~="" then lines[#lines+1]="作者："..tostring(target.author) end
                    if U.trim(tostring(target.description or target.intro or ""))~="" then lines[#lines+1]="\n"..tostring(target.description or target.intro) end
                    self:info(table.concat(lines,"\n"))
                end},
                {icon="↻",label="刷新并打开",detail="更新文章列表后打开",callback=function()
                    self:_refresh_shelf_async(function() self:mp_account(target) end,false)
                end},
                {icon="⇩",label="下载管理",detail="查看文章下载任务",callback=function() self:show_downloads() end},
            },
            wide_last=true,
        }
        return
    end
    if book.source=="local" or book.local_file==true then
        ActionSheet.show{
            anchor=anchor,
            preferred_direction="above",
            width_ratio=.66,
            title=tostring(book.title or "本地书籍"),
            subtitle=U.trim(tostring(book.author or ""))~="" and tostring(book.author) or "本地书籍",
            actions={
                {icon="i",label="查看详情",detail="文件、进度和图书信息",callback=function() self:_home_local_book_details(book) end},
                {icon="↻",label="更新书籍信息",detail="重新提取并尝试网络补全",callback=function() self:_home_refresh_one_book_metadata(book,true) end},
                {icon="!",label="删除本地文件",detail="删除后无法通过觅阅恢复",danger=true,callback=function() self:_home_delete_local_book(book,anchor) end},
            },
            wide_last=true,
            footer_action={label="更多书籍操作",callback=function() self:_show_home_local_book_more(book,anchor) end},
        }
        return
    end

    local target=U.copy(book)
    self:_home_attach_local_record(target)
    local primary_actions={
        {icon="▶",label="开始阅读",detail="按云端进度在线阅读",callback=function() self:_open_book_stream(target,anchor) end},
        {icon="i",label="查看详情",detail="书籍简介和出版信息",callback=function() self:book_details(target) end},
        {icon="↻",label="更新书籍信息",detail="微信读书详情与网络补全",callback=function() self:_home_refresh_one_book_metadata(target,true) end},
    }
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="above",
        width_ratio=.66,
        title=tostring(target.title or "书籍"),
        subtitle=U.trim(tostring(target.author or ""))~="" and tostring(target.author) or "在线阅读",
        actions=primary_actions,wide_last=(#primary_actions%2==1),
        footer_action={label="更多书籍操作",callback=function() self:_show_home_remote_book_more(target,anchor) end},
    }
end

function Plugin:_home_action_entries()
    local home=self:_home_preferences()
    local download_state=self:_download_state()
    local queue=self.store:download_queue()
    local download_badge=nil
    if download_state.status=="failed" then download_badge="!"
    elseif download_state.status=="active" then download_badge=tostring(self:_download_percent(download_state)).."%"
    elseif #queue>0 then download_badge=tostring(#queue) end

    local sync_summary=self:_home_sync_summary()
    local sync_badge=nil
    if sync_summary.failed>0 then sync_badge="!"
    elseif sync_summary.total>0 then sync_badge=sync_summary.total>99 and "99+" or tostring(sync_summary.total) end

    local definitions={
        refresh={icon="↻",icon_key="refresh",label="更新",callback=function()
            -- Single tap means "update what I am looking at". E-ink full refresh
            -- remains available from the long-press menu and quick panel.
            self:_home_manual_refresh()
        end},
        search={icon="⌕",icon_key="search",label="搜索",callback=function(anchor) self:_show_home_search_popup(anchor) end},
        sync={icon="⇅",icon_key="sync",label="同步",badge=sync_badge,callback=function(anchor)
            self:_sync_home_pending(); self:_show_home_quick_notice(anchor,"正在同步","待处理内容已提交")
        end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",callback=function(anchor) self:_show_home_settings_popup(anchor) end},
        all_books={icon="▦",label="全部书籍",callback=function() self:show_home_all_books() end},
        history={icon="◷",label="阅读历史",callback=function() self:show_home_reading_history() end},
        file_manager={icon="▤",label="文件管理",callback=function(anchor) self:_show_home_file_manager_popup(anchor) end},
        screenshot={icon="▣",label="截图",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
    }
    if Device:canSuspend() then definitions.sleep={icon="◐",icon_key="sleep",label="休眠",callback=function() self:_home_sleep() end} end
    for key,entry in pairs(definitions) do
        local item_key=key; local item_label=entry.label
        entry.hold_callback=function(anchor) self:_show_home_action_manage_popup(item_key,item_label,anchor) end
    end
    local entries,used={},{}
    for _,key in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if home.action_items[key]==true and definitions[key] and not used[key] then
            used[key]=true; entries[#entries+1]=definitions[key]
            if #entries>=6 then break end
        end
    end
    return entries
end

function Plugin:_home_download_notice()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    local notice
    if state.status=="active" then
        local percent=self:_download_percent(state)
        notice={
            title="正在下载《"..tostring(state.title or "书籍").."》",
            detail="已完成 "..tostring(percent).."%",
            progress=percent/100,
        }
    elseif state.status=="failed" then
        notice={
            title="有一项下载未完成",
            detail=state.auth_required==true and "账号需要重新登录" or "点击查看并继续下载",
            important=true,
        }
    elseif state.status=="annotation_pending" then
        notice={
            title="正文已下载完成",
            detail="划线与想法待补全，点击查看",
            important=true,
        }
    elseif state.status=="interrupted" or state.status=="pending_install" then
        notice={
            title="下载等待继续",
            detail=self:_download_status_label():gsub("^后台下载%s*[·：]?%s*",""),
            important=true,
        }
    elseif #queue>0 then
        notice={title=tostring(#queue).." 项等待下载",detail="点击查看下载队列"}
    end
    if notice then
        notice.on_tap=function() self:_home_leave_and_run("downloads",function() self:show_downloads() end) end
    end
    return notice
end

function Plugin:_home_library_sections(account_count,generated_count,local_count,mp_count)
    return {
        {title="微信书架",detail="账号中的全部书籍",count=account_count,on_tap=function()
            self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end)
        end},
        {title="已下载",detail="已保存到设备",count=generated_count,on_tap=function()
            self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end)
        end},
        {title="本地书籍",detail="KOReader 普通文件",count=local_count,on_tap=function()
            self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end)
        end},
        {title="公众号",detail="公众号与文章",count=mp_count,on_tap=function()
            self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
        end},
    }
end

function Plugin:_home_alerts()
    local alerts={}
    local health=self:_auth_health(); self:_recompute_auth_health(health)
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local previously_logged_in=U.trim(tostring(account.name or ""))~="" or (tonumber(account.logged_at) or 0)>0
    if not self:logged_in() and previously_logged_in then
        alerts[#alerts+1]={title="微信读书账号需要重新登录",detail="点击重新扫码；已下载书籍和本地阅读记录不会删除",important=true,on_tap=function() self:_home_leave_and_run("login",function() self.auth_flow:start() end) end}
    elseif health.state=="partial" then
        alerts[#alerts+1]={title="账号部分功能需要处理",detail="点击查看状态；必要时重新扫码即可恢复",important=true,on_tap=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end}
    end
    return alerts
end

function Plugin:_home_stop_background(reason)
    self:_flush_home_preferences()
    self._home_resume_generation=(tonumber(self._home_resume_generation) or 0)+1
    self:_home_unschedule_task("_home_resume_background_task")
    self:_home_unschedule_task("_home_manual_metadata_retry_task")
    self._home_pending_network_metadata_key=nil
    self._home_resume_barrier=false
    self._home_suspended=false
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_refreshing=false
    self._home_cover_inflight={}
    if self.home_async then self.home_async:cancel(reason or "home hidden") end
    self:_cancel_home_directory_request(reason or "home hidden")
    if self.home_metadata_async then self.home_metadata_async:cancel(reason or "home hidden") end
    if self.home_cover_async then self.home_cover_async:cancel(reason or "home hidden") end
    if self.cover_render_async then self.cover_render_async:cancel(reason or "home hidden") end
end

function Plugin:_home_merge_directory_snapshot(snapshot,old_snapshot)
    snapshot=type(snapshot)=="table" and snapshot or {folders={},books={}}
    old_snapshot=type(old_snapshot)=="table" and old_snapshot or {}
    local old_by_file={}
    for _,row in ipairs(old_snapshot.books or {}) do old_by_file[LocalLibrary.normalize(row.file)]=row end
    local legacy=self:_home_local_cache()
    for _,row in ipairs(legacy.books or {}) do
        local path=LocalLibrary.normalize(row.file)
        if old_by_file[path]==nil then old_by_file[path]=row end
    end
    for _,row in ipairs(snapshot.books or {}) do
        local old=old_by_file[LocalLibrary.normalize(row.file)]
        if old and tonumber(old.modified_at or 0)==tonumber(row.modified_at or 0) then LocalMetadata.merge(row,old) end
        row.local_file=true; row.source="local"; row.status_text=self:_home_status_text(row,true)
    end
    return snapshot
end

function Plugin:_home_store_directory_snapshot(path,snapshot)
    path=LocalLibrary.normalize(path)
    local cache=self:_home_local_tree_cache()
    snapshot=self:_home_merge_directory_snapshot(snapshot,cache.dirs[path])
    cache.dirs[path]=snapshot
    cache.updated_at=os.time()
    self.store:set("home_local_tree_index",cache)
    return snapshot
end

function Plugin:_home_scan_local(force)
    local home=self:_home_preferences()
    local mode="auto" -- compatibility label for existing logging
    if force~=true and home.local_auto_update~=true then return false end
    if force~=true then
        local cached=self:_home_local_cache()
        local scanned_at=tonumber(cached and cached.scanned_at or 0) or 0
        local local_ttl=self:_lightweight_enabled()
            and (tonumber(Config.LIGHTWEIGHT_HOME_LOCAL_TTL) or 60*60)
            or HOME_LOCAL_CACHE_TTL
        if scanned_at>0 and os.time()-scanned_at<local_ttl then return false end
    end
    if self:_home_background_blocked() or self:_active_reader_ui() then return false end
    local roots=self:_home_local_roots(true)
    if #roots==0 or not self.home_async or self.home_async:busy() or not self.home_async:available() then return false end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    local generation=self._home_scan_generation
    self._home_refreshing=true
    local root_payload=U.copy(roots)
    local recursive=true
    if not recursive then
        local context=self:_home_local_inline_context()
        local seen={}
        for _,item in ipairs(root_payload) do seen[LocalLibrary.normalize(item.path)]=true end
        if not context.picker and context.path~="" and not seen[LocalLibrary.normalize(context.path)] then
            root_payload[#root_payload+1]={path=context.path,name=LocalLibrary.basename(context.path),enabled=true,readonly=true}
        end
    end
    local started,err=self.home_async:run(recursive and "home-local-library" or "home-local-roots",function()
        local ok_ffi,ffi=pcall(require,"ffi")
        if ok_ffi and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,recursive and 14 or 12) end)
        end
        local Library=require("miuread.local_library")
        if recursive then
            local merged={books={},roots={},scanned_at=os.time(),truncated=false}
            for _,root in ipairs(root_payload) do
                local result=Library.scan(root.path,{limit=1000,max_depth=5,include_dictionaries=false})
                merged.roots[#merged.roots+1]={path=root.path,name=root.name,truncated=result.truncated==true}
                for _,book in ipairs(result.books or {}) do
                    book.library_root=root.path
                    merged.books[#merged.books+1]=book
                    if #merged.books>=1000 then merged.truncated=true; break end
                end
                if #merged.books>=1000 then break end
            end
            table.sort(merged.books,function(a,b)
                local am,bm=tonumber(a.modified_at) or 0,tonumber(b.modified_at) or 0
                if am~=bm then return am>bm end
                return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
            end)
            return merged
        end
        local result={}
        for _,root in ipairs(root_payload) do
            result[root.path]=Library.list_directory(root.path,{limit=1600,include_cover=false,include_dictionaries=false})
        end
        return result
    end,function(result)
        if generation~=self._home_scan_generation then return end
        self._home_refreshing=false
        if not result or result.ok~=true or type(result.value)~="table" then
            logger.warn("[MiuRead][Home] local scan failed",tostring(result and result.error or "unknown"))
            return
        end
        if recursive then
            local previous=self:_home_local_cache()
            local previous_by_file={}
            for _,book in ipairs(previous.books or {}) do previous_by_file[LocalLibrary.normalize(book.file)]=book end
            for _,book in ipairs(result.value.books or {}) do
                local old=previous_by_file[LocalLibrary.normalize(book.file)]
                if old and tonumber(old.modified_at or 0)==tonumber(book.modified_at or 0) then LocalMetadata.merge(book,old) end
                book.local_file=true; book.source="local"; book.status_text=self:_home_status_text(book,true)
            end
            self.store:set("home_local_index",result.value)
            logger.info("[MiuRead][Home] local library indexed",
                "mode=",mode,"books=",tostring(#(result.value.books or {})),
                "truncated=",tostring(result.value.truncated==true))
        else
            for path,snapshot in pairs(result.value) do self:_home_store_directory_snapshot(path,snapshot) end
            logger.info("[MiuRead][Home] local folders refreshed","count=",tostring(#root_payload),"recursive=false")
        end
        if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    end,recursive and 240 or 120)
    if not started then
        self._home_refreshing=false
        logger.warn("[MiuRead][Home] local scan not started",tostring(err))
        return false
    end
    return true
end

function Plugin:_cancel_local_browser_fallback()
    local task=self._local_browser_fallback_task
    if task then UIManager:unschedule(task) end
    self._local_browser_fallback_task=nil
    local scanner=self._local_browser_fallback_scanner
    self._local_browser_fallback_scanner=nil
    if scanner and scanner.cancel then pcall(scanner.cancel,scanner) end
end

function Plugin:_cancel_home_directory_request(reason)
    self._home_directory_generation=(tonumber(self._home_directory_generation) or 0)+1
    if self.local_browser_async then self.local_browser_async:cancel(reason or "local folder request cancelled") end
    self:_cancel_local_browser_fallback()
    self._home_directory_active_path=nil
    self._home_directory_request_owner=nil
end

function Plugin:_home_refresh_local_directory(path,callback,force,owner)
    path=LocalLibrary.normalize(path)
    local cache=self:_home_local_tree_cache()
    local cached=cache.dirs[path]
    if force~=true and type(cached)=="table" then
        if callback then callback(cached,false) end
        return true
    end
    if path=="" or lfs.attributes(path,"mode")~="directory" then
        if callback then callback({path=path,folders={},books={},error="文件夹不存在"},false) end
        return false
    end
    local function failure_snapshot(message)
        if type(cached)=="table" and not cached.error then return cached end
        return self:_home_store_directory_snapshot(path,{
            path=path,folders={},books={},scanned_at=os.time(),error=tostring(message or "无法读取文件夹"),
        })
    end

    -- A new navigation request owns the directory slot. Cancelling the old
    -- worker and generation prevents a late result from replacing the folder
    -- the user is currently viewing.
    self:_cancel_home_directory_request("new local folder request")
    local generation=self._home_directory_generation
    self._home_directory_active_path=path
    self._home_directory_request_owner=owner

    local function complete(snapshot,scanned)
        if generation~=self._home_directory_generation then return false end
        self:_cancel_local_browser_fallback()
        self._home_directory_active_path=nil
        self._home_directory_request_owner=nil
        if callback then callback(snapshot,scanned) end
        return true
    end

    local function start_incremental(reason)
        logger.info("[MiuRead][LocalBrowser] using incremental reader",path,tostring(reason or "worker unavailable"))
        local scanner=LocalLibrary.new_directory_scan(path,{
            limit=1600,include_cover=false,include_dictionaries=false,
        })
        self._local_browser_fallback_scanner=scanner
        local task
        task=function()
            if self._local_browser_fallback_task~=task or generation~=self._home_directory_generation then
                if scanner and scanner.cancel then pcall(scanner.cancel,scanner) end
                return
            end
            local ok,done=pcall(scanner.step,scanner,32)
            if not ok then
                self._local_browser_fallback_task=nil
                self._local_browser_fallback_scanner=nil
                complete(failure_snapshot(tostring(done or "无法读取文件夹")),true)
                return
            end
            if done then
                self._local_browser_fallback_task=nil
                self._local_browser_fallback_scanner=nil
                local good,snapshot=pcall(scanner.snapshot,scanner)
                if not good or type(snapshot)~="table" then
                    complete(failure_snapshot(tostring(snapshot or "无法读取文件夹")),true)
                elseif snapshot.error then
                    complete(failure_snapshot(snapshot.error),true)
                else
                    complete(self:_home_store_directory_snapshot(path,snapshot),true)
                end
                return
            end
            UIManager:scheduleIn(.02,task)
        end
        self._local_browser_fallback_task=task
        UIManager:scheduleIn(0,task)
        return true
    end

    local worker=self.local_browser_async
    if not worker or not worker:available() then
        return start_incremental("background worker unavailable")
    end
    local started,err=worker:run("local-folder",function()
        local ok_ffi,ffi=pcall(require,"ffi")
        if ok_ffi and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,10) end)
        end
        local Library=require("miuread.local_library")
        return Library.list_directory(path,{limit=1600,include_cover=false,include_dictionaries=false})
    end,function(result)
        if generation~=self._home_directory_generation then return end
        if result and result.ok==true and type(result.value)=="table" then
            complete(self:_home_store_directory_snapshot(path,result.value),true)
        else
            complete(failure_snapshot(tostring(result and result.error or "无法读取文件夹")),true)
        end
    end,90)
    if started then return true end
    logger.warn("[MiuRead][LocalBrowser] background read not started",tostring(err))
    return start_incremental(tostring(err or "worker did not start"))
end

function Plugin:_home_local_metadata_dir()
    local path=self.store.covers_dir.."/local"
    U.mkdir(path)
    return path
end

function Plugin:_home_reset_local_metadata()
    local dir=self:_home_local_metadata_dir()
    U.remove_tree(dir)
    U.mkdir(dir)
    local prefix=tostring(dir):gsub("\\","/"):gsub("/+","/").."/"
    local function clear_book(book)
        local changed=false
        local cover=tostring(book.cover_path or ""):gsub("\\","/"):gsub("/+","/")
        if cover:sub(1,#prefix)==prefix then book.cover_path=nil; changed=true end
        for _,key in ipairs({"metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if book[key]~=nil then book[key]=nil; changed=true end
        end
        return changed
    end
    local cache=self:_home_local_cache()
    local changed=false
    for _,book in ipairs(cache.books or {}) do if clear_book(book) then changed=true end end
    if changed then self.store:set("home_local_index",cache) end

    local tree=self:_home_local_tree_cache()
    local tree_changed=false
    for _,snapshot in pairs(tree.dirs or {}) do
        for _,book in ipairs(type(snapshot)=="table" and snapshot.books or {}) do
            if clear_book(book) then tree_changed=true end
        end
    end
    if tree_changed then tree.updated_at=os.time(); self.store:set("home_local_tree_index",tree) end
end

function Plugin:_home_update_local_cache(filepath,metadata)
    filepath=LocalLibrary.normalize(filepath)
    local cache=self:_home_local_cache()
    local changed=false
    for _,row in ipairs(cache.books or {}) do
        if LocalLibrary.normalize(row.file)==filepath then
            if LocalMetadata.merge(row,metadata) then changed=true end
            row.status_text=self:_home_status_text(row,true)
            break
        end
    end
    if changed then
        cache.scanned_at=tonumber(cache.scanned_at) or os.time()
        self.store:set("home_local_index",cache)
    end
    local tree=self:_home_local_tree_cache()
    local tree_changed=false
    for _,snapshot in pairs(tree.dirs or {}) do
        for _,row in ipairs(type(snapshot)=="table" and snapshot.books or {}) do
            if LocalLibrary.normalize(row.file)==filepath then
                if LocalMetadata.merge(row,metadata) then tree_changed=true end
                row.status_text=self:_home_status_text(row,true)
            end
        end
    end
    if tree_changed then tree.updated_at=os.time(); self.store:set("home_local_tree_index",tree) end
    return changed or tree_changed
end

function Plugin:_home_update_miuread_metadata(filepath,metadata)
    local book,record=self.store:identify_file(filepath,true)
    if type(book)~="table" then return false end
    local changed=LocalMetadata.merge(book,metadata)
    if type(record)=="table" and LocalMetadata.merge(record,metadata) then changed=true end
    local id=tostring(book.book_id or (record and record.book_id) or "")
    if changed and id~="" then self.store:save_book(id,book) end
    return changed
end



function Plugin:_home_network_metadata_key(book)
    if type(book)~="table" then return "" end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return "book:"..id end
    local file=tostring(book.file or ""):gsub("\\","/"):gsub("/+","/")
    if file~="" then return "file:"..file end
    local title=U.trim(tostring(book.title or ""))
    local author=U.trim(tostring(book.author or ""))
    if title~="" then return "title:"..title.."|"..author end
    return ""
end

function Plugin:_home_network_metadata_cache()
    local cache=self.store:get("home_network_metadata",{version=1,rows={}})
    cache=type(cache)=="table" and cache or {version=1,rows={}}
    cache.rows=type(cache.rows)=="table" and cache.rows or {}
    return cache
end

local function home_network_patch_has_data(patch)
    if type(patch)~="table" then return false end
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        if U.trim(tostring(patch[key] or ""))~="" then return true end
    end
    return false
end

local HOME_NETWORK_DETAIL_FIELDS={"description","category","publisher","published_date","isbn"}

local function home_network_patch_field_count(patch)
    if type(patch)~="table" then return 0 end
    local count=0
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        if U.trim(tostring(patch[key] or ""))~="" then count=count+1 end
    end
    return count
end

local function home_network_missing_fields(book,patch)
    book=type(book)=="table" and book or {}
    patch=type(patch)=="table" and patch or {}
    local missing={}
    for _,key in ipairs(HOME_NETWORK_DETAIL_FIELDS) do
        local value=patch[key]
        if value==nil or value=="" then value=book[key] end
        if key=="description" and U.trim(tostring(value or ""))=="" then
            value=book.intro or book.summary
        end
        if U.trim(tostring(value or ""))=="" then missing[#missing+1]=key end
    end
    return missing
end

function Plugin:_home_merge_network_patch(book,patch)
    if type(book)~="table" or type(patch)~="table" then return false end
    local changed=false
    local function fill(key,value)
        if value==nil or value=="" then return end
        local current=book[key]
        if current==nil or current=="" then book[key]=value; changed=true end
    end
    for _,key in ipairs({"title","author","description","category","publisher","published_date","language","isbn","pages"}) do
        fill(key,patch[key])
    end
    if patch.metadata_source and (book.network_metadata_source==nil or book.network_metadata_source=="") then
        book.network_metadata_source=patch.metadata_source
        changed=true
    end
    return changed
end

function Plugin:_home_apply_cached_network_metadata(book)
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local row=self:_home_network_metadata_cache().rows[key]
    if type(row)~="table" or type(row.patch)~="table" then return false end
    return self:_home_merge_network_patch(book,row.patch)
end

function Plugin:_home_save_network_metadata(book,patch,completed)
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    cache.rows[key]={
        checked_at=os.time(),
        completed=completed==true,
        patch=type(patch)=="table" and patch or {},
    }
    local count=0
    local ordered={}
    for cache_key,row in pairs(cache.rows) do
        ordered[#ordered+1]={key=cache_key,at=tonumber(type(row)=="table" and row.checked_at or 0) or 0}
    end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index,row in ipairs(ordered) do
        count=index
        if index>120 then cache.rows[row.key]=nil end
    end
    self.store:set("home_network_metadata",cache)
    return count>0
end

function Plugin:_home_queue_manual_network_metadata(book,force,silent,on_done)
    if self._home_manual_metadata_retry_task then
        logger.info("[MiuRead][HomeMetadata] manual request already queued",
            "book=",tostring(book and (book.bookId or book.book_id) or ""))
        return false
    end
    local deadline=monotonic_wall_time()+12
    local task
    task=function()
        if self._home_manual_metadata_retry_task~=task then return end
        if not HomeView.is_shown() or self:_active_reader_ui() then
            self._home_manual_metadata_retry_task=nil
            logger.info("[MiuRead][HomeMetadata] manual queue cancelled", "reason=home_hidden")
            if on_done then on_done(false,nil,{error="home_hidden"}) end
            return
        end
        if not self:is_online() then
            self._home_manual_metadata_retry_task=nil
            logger.info("[MiuRead][HomeMetadata] manual queue cancelled", "reason=offline")
            if on_done then on_done(false,nil,{error="offline"}) end
            return
        end
        local blocked=self:_home_background_blocked()
        local busy=self.home_metadata_async and self.home_metadata_async:busy()
        if blocked or busy then
            if monotonic_wall_time()<deadline then
                UIManager:scheduleIn(.25,task)
                return
            end
            self._home_manual_metadata_retry_task=nil
            logger.warn("[MiuRead][HomeMetadata] manual queue timed out",
                "book=",tostring(book and (book.bookId or book.book_id) or ""),
                "blocked=",tostring(blocked),"busy=",tostring(busy))
            if on_done then on_done(false,nil,{error="worker_busy_timeout"}) end
            return
        end
        self._home_manual_metadata_retry_task=nil
        local started=self:_home_schedule_network_metadata(book,force,silent,on_done,true)
        if not started and on_done then on_done(false,nil,{error="retry_start_failed"}) end
    end
    self._home_manual_metadata_retry_task=task
    UIManager:scheduleIn(.18,task)
    logger.info("[MiuRead][HomeMetadata] manual request queued",
        "book=",tostring(book and (book.bookId or book.book_id) or ""))
    return true
end

function Plugin:_home_schedule_network_metadata(book,force,silent,on_done,explicit)
    explicit=explicit==true
    if type(book)~="table" or not HomeView.is_shown() or self:_active_reader_ui() then return false end
    if explicit then
        -- A user-requested metadata refresh must not be rejected by the quiet
        -- window created by that very tap. It still yields to real lifecycle
        -- transitions/suspend and stays on the background worker.
        if self:_home_background_blocked() then
            return self:_home_queue_manual_network_metadata(book,force,silent,on_done)
        end
    elseif self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        local pending_key=self:_home_network_metadata_key(book)
        if pending_key~="" then self._home_pending_network_metadata_key=pending_key end
        return false
    end
    local home=self:_home_preferences()
    if home.network_metadata==false and force~=true then return false end
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    local cached=cache.rows[key]
    local cached_completed=type(cached)=="table" and (cached.completed==true
        or home_network_patch_has_data(cached.patch))
    if force~=true and cached_completed then
        if type(cached.patch)=="table" and self:_home_merge_network_patch(book,cached.patch) then
            if self._home_hero and self:_home_network_metadata_key(self._home_hero)==key then
                HomeView.update_hero(self._home_hero)
            end
        end
        return false
    end
    if not self:is_online() or not self.home_metadata_async or not self.home_metadata_async:available() then return false end
    if self.home_metadata_async:busy() then
        if explicit then return self:_home_queue_manual_network_metadata(book,force,silent,on_done) end
        return false
    end
    local candidate=U.copy(book)
    local id=tostring(candidate.bookId or candidate.book_id or "")
    if self._home_pending_network_metadata_key==key then self._home_pending_network_metadata_key=nil end
    if explicit then
        logger.info("[MiuRead][HomeMetadata] manual requested",
            "book=",id~="" and id or key)
    end
    local started,err=self.home_metadata_async:run("home-network-metadata",function()
        local patch={}
        if id~="" and not Protocol.is_mp_account(id) then
            local ok,detail=pcall(self.api.book,self.api,id)
            if ok and type(detail)=="table" then
                local info=type(detail.bookInfo)=="table" and detail.bookInfo
                    or (type(detail.book)=="table" and detail.book or detail)
                patch.title=info.title or detail.title
                patch.author=info.author or detail.author
                patch.description=info.intro or info.description or info.summary
                    or detail.intro or detail.description or detail.summary
                patch.category=info.category or detail.category
                patch.publisher=info.publisher or detail.publisher
                patch.isbn=info.isbn or info.isbn13 or info.isbn10 or detail.isbn
                patch.published_date=info.publishTime or info.publishedDate or detail.publishTime
                patch.metadata_source="weread_book_info"
            end
        end
        local merged=U.copy(candidate)
        for k,v in pairs(patch) do if v~=nil and v~="" then merged[k]=v end end
        local needs_external = U.trim(tostring(patch.description or merged.description or merged.intro or merged.summary or ""))==""
            or U.trim(tostring(patch.category or merged.category or ""))==""
            or U.trim(tostring(patch.publisher or merged.publisher or ""))==""
            or U.trim(tostring(patch.published_date or merged.published_date or ""))==""
            or U.trim(tostring(patch.isbn or merged.isbn or ""))==""
        if needs_external then
            local external=NetworkMetadata.fetch(self.http,merged)
            if type(external)=="table" then
                for k,v in pairs(external) do if (patch[k]==nil or patch[k]=="") and v~=nil and v~="" then patch[k]=v end end
            end
        end
        return patch
    end,function(result)
        if not result or result.ok~=true then
            logger.warn("[MiuRead][HomeMetadata] network metadata unavailable",
                "book=",id~="" and id or key,
                "error=",tostring(result and result.error or "unknown"))
            if not cached_completed then self:_home_save_network_metadata(candidate,{},false) end
            if force==true and silent~=true then self:toast("网络图书信息更新失败，请稍后重试",2) end
            if on_done then on_done(false,nil,{error=tostring(result and result.error or "unknown")}) end
            return
        end
        local patch=type(result.value)=="table" and result.value or {}
        local saved_patch={}
        if type(cached)=="table" and type(cached.patch)=="table" then
            for k,v in pairs(cached.patch) do if v~=nil and v~="" then saved_patch[k]=v end end
        end
        for k,v in pairs(patch) do if v~=nil and v~="" then saved_patch[k]=v end end
        local found=home_network_patch_has_data(saved_patch)
        self:_home_save_network_metadata(candidate,saved_patch,found)
        if self._home_hero and self:_home_network_metadata_key(self._home_hero)==key then
            local changed=self:_home_merge_network_patch(self._home_hero,patch)
            if changed and HomeView.is_shown() then HomeView.update_hero(self._home_hero) end
        end
        local missing=home_network_missing_fields(candidate,saved_patch)
        local detail={
            partial=found and #missing>0,
            complete=found and #missing==0,
            missing=missing,
            fields=home_network_patch_field_count(saved_patch),
            source=tostring(saved_patch.metadata_source or patch.metadata_source or "unknown"),
        }
        logger.info("[MiuRead][HomeMetadata] completed",
            "book=",id~="" and id or key,
            "found=",tostring(found),
            "fields=",tostring(detail.fields),
            "source=",detail.source,
            "missing=",#missing>0 and table.concat(missing,",") or "none")
        if force==true and silent~=true then
            if not found then
                self:toast("暂未找到可补全的网络信息",2)
            elseif #missing>0 then
                self:toast("网络书籍信息已刷新，部分资料暂未找到",2)
            else
                self:toast("当前书籍的网络信息已更新",2)
            end
        end
        if on_done then on_done(found,patch,detail) end
    end,35)
    if not started then
        logger.warn("[MiuRead][HomeMetadata] network metadata worker not started",
            "book=",id~="" and id or key,"error=",tostring(err))
        if explicit and self.home_metadata_async and self.home_metadata_async:busy() then
            return self:_home_queue_manual_network_metadata(book,force,silent,on_done)
        end
    end
    return started==true
end

function Plugin:_home_schedule_local_metadata(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        return false
    end
    if not HomeView.is_shown() then return false end
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_LOCAL_METADATA_QUEUE) or 3) or 6
    local metadata_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_METADATA_GAP) or .75) or .22
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local filepath=tostring(book and book.file or "")
        local is_local=book and (book.source=="local" or book.local_file==true)
        if filepath~="" and is_local and not seen[filepath] and LocalMetadata.needs_refresh(book,true) then
            seen[filepath]=true
            queue[#queue+1]={file=filepath,book=book}
            -- Prioritise only what the user can see now. Remaining covers are
            -- picked up on later pages instead of blocking the home screen.
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 then return false end

    local index=1
    local hero_changed=false
    local changed_book_keys={}
    local cache_dir=self:_home_local_metadata_dir()
    local function finish()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() then return end
        if hero_changed and self._home_hero then
            HomeView.update_hero(self._home_hero)
        end
        for key in pairs(changed_book_keys) do HomeView.update_book(key) end
    end
    local function apply_metadata(item,metadata,err)
        if generation~=self._home_metadata_generation then return end
        if metadata then
            local visible_changed=item.book and LocalMetadata.merge(item.book,metadata) or false
            self:_home_update_local_cache(item.file,metadata)
            if visible_changed then
                local item_id=tostring(item.book and (item.book.bookId or item.book.book_id) or "")
                local item_key=item_id~="" and item_id or ("file:"..tostring(item.file or ""))
                local hero=self._home_hero
                local hero_id=tostring(hero and (hero.bookId or hero.book_id) or "")
                local hero_file=tostring(hero and hero.file or "")
                local is_hero=(item_id~="" and hero_id==item_id)
                    or (item_id=="" and hero_id=="" and hero_file~="" and hero_file==tostring(item.file or ""))
                if is_hero then hero_changed=true
                elseif item_key~="file:" then changed_book_keys[item_key]=true end
            end
        elseif err then
            logger.warn("[MiuRead][Home] local metadata unavailable",tostring(item.file),tostring(err))
        end
        index=index+1
    end
    local function next_book()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if self:_home_ui_busy() then UIManager:scheduleIn(math.max(.45,metadata_gap),next_book); return end
        local item=queue[index]
        if not item then finish(); return end
        if self.home_metadata_async and self.home_metadata_async:available() then
            if self.home_metadata_async:busy() then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book); return end
            local filepath=item.file
            local started=self.home_metadata_async:run("home-local-metadata",function()
                local Metadata=require("miuread.local_metadata")
                return Metadata.read(filepath,cache_dir,{open_document=true,use_bim=true})
            end,function(result)
                if generation~=self._home_metadata_generation then return end
                if result and result.ok and type(result.value)=="table" then
                    apply_metadata(item,result.value)
                else
                    apply_metadata(item,nil,result and result.error or "后台提取失败")
                end
                if queue[index] then UIManager:scheduleIn(metadata_gap,next_book) else finish() end
            end,45)
            if not started then UIManager:scheduleIn(.4,next_book) end
            return
        end
        -- Compatibility fallback for devices without subprocess support. Run
        -- only one visible book per tick and stop immediately when reading starts.
        local metadata,err=LocalMetadata.read(item.file,cache_dir,{open_document=true,use_bim=true})
        apply_metadata(item,metadata,err)
        if queue[index] then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book) else finish() end
    end
    UIManager:scheduleIn(lightweight and math.max(1.2,metadata_gap*2) or .8,next_book)
    return true
end

function Plugin:_home_schedule_remote_covers(books)
    if self._download_runtime~=nil then return false end
    if self:_home_ui_busy() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.covers=true
        return false
    end
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_REMOTE_COVER_QUEUE) or 4) or 10
    local cover_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_COVER_GAP) or .65) or .08
    local derivative_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_DERIVATIVE_GAP) or 1.0) or .75
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    local generation=self._home_cover_generation
    self._home_cover_inflight=type(self._home_cover_inflight)=="table" and self._home_cover_inflight or {}
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local id=tostring(book and (book.bookId or book.book_id) or "")
        if id~="" and not seen[id] and not self._home_cover_inflight[id]
            and book.cover and book.cover~="" and not book.cover_path then
            seen[id]=true
            queue[#queue+1]={bookId=id,cover=book.cover,book=book}
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 or not self.home_cover_async then return end
    local index,changed_count=1,0
    local changed_sections={}
    local changed_ids={}
    local rendered_books={}
    local hero_changed=false
    local function mark_changed(book_id)
        changed_ids[tostring(book_id or "")]=true
        local hero_id=tostring(self._home_hero and (self._home_hero.bookId or self._home_hero.book_id) or "")
        if hero_id==book_id then hero_changed=true end
        for key,section in pairs(self._home_sections or {}) do
            for _,book in ipairs(section.rows or {}) do
                if tostring(book.bookId or book.book_id or "")==book_id then
                    changed_sections[key]=true
                    break
                end
            end
        end
    end
    local function apply_batch()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if changed_count<=0 then return end
        for section in pairs(changed_sections) do self:_home_bump_section_revision(section) end
        local active=self._home_active_section or "account"
        if hero_changed and self._home_hero then
            -- Update only the recent-reading static layer; unrelated shelf cards
            -- keep their rendered objects and do not blink.
            HomeView.update_hero(self._home_hero)
        end
        if changed_sections[active] then
            for id in pairs(changed_ids) do HomeView.update_book(id) end
        end
        logger.info("[MiuRead][HomeCoverBatch] applied",
            "changed=",tostring(changed_count),"hero=",tostring(hero_changed),
            "active=",tostring(active))
    end
    local function finish()
        if changed_count>0 and generation==self._home_cover_generation and HomeView.is_shown() then
            -- Let the final worker callback leave the input path before one
            -- bounded e-ink update. A later tab switch wins automatically.
            UIManager:scheduleIn(.35,apply_batch)
        end
        if #rendered_books>0 and generation==self._home_cover_generation then
            UIManager:scheduleIn(derivative_gap,function()
                if generation==self._home_cover_generation and HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_home_schedule_cover_derivatives(rendered_books)
                end
            end)
        end
    end
    local function next_cover()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self._download_runtime~=nil then return end
        if self:_home_ui_busy() then UIManager:scheduleIn(math.max(.45,cover_gap),next_cover); return end
        if lightweight and self.home_metadata_async and self.home_metadata_async:busy() then
            UIManager:scheduleIn(math.max(.5,cover_gap),next_cover)
            return
        end
        if self.home_cover_async:busy() then UIManager:scheduleIn(math.max(.3,cover_gap),next_cover); return end
        local item=queue[index]
        if not item then finish(); return end
        if self._home_cover_inflight[item.bookId] then
            index=index+1
            if queue[index] then UIManager:scheduleIn(.02,next_cover) else finish() end
            return
        end
        self._home_cover_inflight[item.bookId]=generation
        local background=self.home_cover_async:available()
        local covers_dir=self.store.covers_dir
        local worker
        if background then
            worker=function()
                local HttpChild=require("miuread.http")
                local LibraryChild=require("miuread.library")
                local store={
                    covers_dir=covers_dir,
                    auth=function() return {cookies={}} end,
                    save_auth=function() end,
                    get=function(_,_,default) return default end,
                    set=function() end,
                }
                return LibraryChild:new(nil,HttpChild:new(store),store):cache_cover(item,{
                    retries=1,timeout={8,15},persist_index=false,skip_index_lookup=true,
                })
            end
        else
            worker=function()
                return self.library:cache_cover(item,{
                    retries=0,timeout={4,7},persist_index=false,skip_index_lookup=true,
                })
            end
        end
        local started=self.home_cover_async:run("home-cover",worker,function(result)
            if self._home_cover_inflight[item.bookId]==generation then
                self._home_cover_inflight[item.bookId]=nil
            end
            if generation~=self._home_cover_generation then return end
            if result and result.ok and result.value then
                self:_remember_cover_path(item.bookId,result.value)
                local changed=self:_home_apply_cover_path(item.bookId,result.value)
                if item.book then
                    item.book.cover_path=result.value
                    item.book.home_cover_path=nil
                    rendered_books[#rendered_books+1]=item.book
                end
                if changed then
                    changed_count=changed_count+1
                    mark_changed(item.bookId)
                end
            elseif result and result.error then
                logger.warn("[MiuRead][Home] cover download failed",tostring(item.bookId),U.first_line(result.error,120))
            end
            index=index+1
            if queue[index] then UIManager:scheduleIn(cover_gap,next_cover) else finish() end
        end,background and 35 or 14)
        if not started then
            if self._home_cover_inflight[item.bookId]==generation then self._home_cover_inflight[item.bookId]=nil end
            UIManager:scheduleIn(math.max(.35,cover_gap),next_cover)
        end
    end
    logger.info("[MiuRead][HomeCoverBatch] queued","count=",tostring(#queue),
        "lightweight=",tostring(lightweight))
    UIManager:scheduleIn(lightweight and math.max(.8,cover_gap) or .12,next_cover)
end

function Plugin:_home_open_miuread(book)
    self:_home_stop_background("opening book")
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id~="" and self:_stream_enabled() then
        return self:_open_book_stream(book)
    end
    local record=id~="" and self:_preferred_record(id) or nil
    if record and record.file and U.file_exists(record.file) then
        return self:_open_file_direct(record.file)
    end
    if id~="" then self:book_menu(book) else self:info("本地书籍记录不存在") end
end

function Plugin:_home_open_local(book)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在"); return end
    self:_home_stop_background("opening local book")
    return self:_open_file_direct(path)
end

function Plugin:_home_schedule_local_shelf_metadata(rows,view)
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local lightweight=self:_lightweight_enabled()
    local queue_limit=lightweight and (tonumber(Config.LIGHTWEIGHT_LOCAL_METADATA_QUEUE) or 3) or 8
    local metadata_gap=lightweight and (tonumber(Config.LIGHTWEIGHT_METADATA_GAP) or .75) or .25
    local queue={}
    for _,book in ipairs(rows or {}) do
        if not (book.local_folder==true or book.kind=="folder")
            and book.file and LocalMetadata.needs_refresh(book,true) then
            queue[#queue+1]=book
            if #queue>=queue_limit then break end
        end
    end
    if #queue==0 then return false end
    local index,changed_any=1,false
    local cache_dir=self:_home_local_metadata_dir()
    local function finish()
        if changed_any and generation==self._home_metadata_generation
            and view and not view._miu_closed and type(view.updateItems)=="function" then
            pcall(view.updateItems,view,nil,true)
        end
    end
    local function apply_metadata(book,metadata,err)
        if metadata then
            local visible_changed=LocalMetadata.merge(book,metadata)
            book.status_text=self:_home_status_text(book,true)
            local cache_changed=self:_home_update_local_cache(book.file,metadata)
            changed_any=changed_any or visible_changed or cache_changed
        elseif err then
            logger.warn("[MiuRead][Home] local shelf metadata unavailable",tostring(book.file),tostring(err))
        end
        index=index+1
    end
    local function next_book()
        if generation~=self._home_metadata_generation or self:_active_reader_ui() then return end
        local book=queue[index]
        if not book then finish(); return end
        if self.home_metadata_async and self.home_metadata_async:available() then
            if self.home_metadata_async:busy() then UIManager:scheduleIn(math.max(.35,metadata_gap),next_book); return end
            local filepath=book.file
            local started=self.home_metadata_async:run("shelf-local-metadata",function()
                local Metadata=require("miuread.local_metadata")
                return Metadata.read(filepath,cache_dir,{open_document=true,use_bim=true})
            end,function(result)
                if generation~=self._home_metadata_generation then return end
                if result and result.ok and type(result.value)=="table" then
                    apply_metadata(book,result.value)
                else
                    apply_metadata(book,nil,result and result.error or "后台提取失败")
                end
                if queue[index] then UIManager:scheduleIn(metadata_gap,next_book) else finish() end
            end,45)
            if not started then UIManager:scheduleIn(.4,next_book) end
            return
        end
        local metadata,err=LocalMetadata.read(book.file,cache_dir,{open_document=true,use_bim=true})
        apply_metadata(book,metadata,err)
        if queue[index] then UIManager:scheduleIn(math.max(.4,metadata_gap),next_book) else finish() end
    end
    UIManager:scheduleIn(lightweight and math.max(.8,metadata_gap) or .25,next_book)
    return true
end

function Plugin:_local_browser_decorate(snapshot,root_path)
    snapshot=type(snapshot)=="table" and snapshot or {folders={},books={}}
    local cache=self:_home_local_tree_cache()
    local folders={}
    for _,folder in ipairs(snapshot.folders or {}) do
        local path=LocalLibrary.normalize(folder.folder_path or folder.path)
        local child=cache.dirs[path]
        local count=type(child)=="table" and (#(child.folders or {})+#(child.books or {})) or nil
        folders[#folders+1]={
            kind="folder",local_folder=true,source="local",title=tostring(folder.title or LocalLibrary.basename(path)),
            folder_path=path,path=path,root_path=LocalLibrary.normalize(root_path or path),
            status_text=count and (tostring(count).." 项") or "文件夹",
        }
    end
    local books={}
    local known=self:_home_local_known_paths()
    local home=self:_home_preferences()
    local hidden=type(home.hidden_local_files)=="table" and home.hidden_local_files or {}
    for _,book in ipairs(snapshot.books or {}) do
        local path=LocalLibrary.normalize(book.file)
        if path~="" and U.file_exists(path) and not known[path] and hidden[path]~=true
            and not LocalLibrary.is_likely_dictionary(path,book.title) then
            book.file=path; book.local_file=true; book.source="local"; book.status_text=self:_home_status_text(book,true)
            books[#books+1]=book
        end
    end
    return folders,books
end

function Plugin:_show_local_browser_snapshot(path,root,stack,snapshot)
    path=LocalLibrary.normalize(path)
    root=root or {path=path,name=LocalLibrary.basename(path)}
    stack=type(stack)=="table" and stack or {}
    local folders,books=self:_local_browser_decorate(snapshot,root.path)
    local title=(path==LocalLibrary.normalize(root.path))
        and tostring(root.name or LocalLibrary.basename(path))
        or tostring(LocalLibrary.basename(path))
    local view
    local function open_folder(folder)
        -- Keep the current level alive underneath. This preserves its page
        -- position and avoids a home-screen flash while the child directory is
        -- read in the background.
        local next_stack=U.copy(stack)
        next_stack[#next_stack+1]={path=path,title=title}
        self:show_local_browser(folder.folder_path or folder.path,root,next_stack,false,view)
    end
    local function go_back()
        if view and not view._miu_closed then UIManager:close(view) end
        -- The previous directory (or the MiuRead home at the configured root)
        -- is already present underneath.
    end
    view=LocalBrowserView.show{
        title=title,folders=folders,books=books,
        empty_text=snapshot.error and ("无法读取文件夹\n"..tostring(snapshot.error)) or "这个文件夹里没有可显示的书籍",
        on_open_folder=open_folder,
        on_open_book=function(book) self:_home_open_local(book) end,
        on_hold_book=function(book) self:_home_hold_book(book) end,
        on_back=go_back,
        on_close=function(closed_view)
            if self._home_directory_request_owner==closed_view then
                self:_cancel_home_directory_request("local browser closed")
            end
        end,
        on_refresh=function()
            self:_home_refresh_local_directory(path,function(fresh)
                local next_folders,next_books=self:_local_browser_decorate(fresh,root.path)
                if view and not view._miu_closed then view:updateData{folders=next_folders,books=next_books,error=fresh.error} end
                if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            end,true,view)
        end,
    }
    self:_home_schedule_local_shelf_metadata(books,view)
    return view
end

function Plugin:show_local_browser(path,root,stack,force,request_owner)
    path=LocalLibrary.normalize(path)
    if path=="" or lfs.attributes(path,"mode")~="directory" then self:info("本地书库目录不存在"); return false end
    local cache=self:_home_local_tree_cache()
    local cached=cache.dirs[path]
    if type(cached)=="table" and force~=true then
        local view=self:_show_local_browser_snapshot(path,root,stack,cached)
        local home=self:_home_preferences()
        if home.local_check_on_open~=false then
            self:_home_refresh_local_directory(path,function(fresh,scanned)
                if not scanned or not view or view._miu_closed then return end
                local folders,books=self:_local_browser_decorate(fresh,root and root.path or path)
                view:updateData{folders=folders,books=books,error=fresh.error}
                self:_home_schedule_local_shelf_metadata(books,view)
            end,true,view)
        end
        return view
    end
    self:toast("正在打开文件夹…",2)
    self:_home_refresh_local_directory(path,function(snapshot)
        self:_show_local_browser_snapshot(path,root,stack,snapshot)
        if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    end,true,request_owner)
    return true
end

function Plugin:_open_local_library_folders()
    local roots=self:_home_local_roots(true)
    if #roots==0 then
        self:info("还没有设置本地书库目录。\n\n可在 首页与书架 → 本地书籍 中添加。")
        return false
    end
    if #roots==1 then return self:show_local_browser(roots[1].path,roots[1],{},false) end
    local folders={}
    for _,root in ipairs(roots) do folders[#folders+1]=self:_home_local_folder_entry(root.path,root.name,root.path) end
    local picker
    picker=LocalBrowserView.show{
        title="本地文件夹",folders=folders,books={},
        on_open_folder=function(folder)
            local selected
            for _,root in ipairs(roots) do if root.path==folder.folder_path then selected=root; break end end
            self:show_local_browser(folder.folder_path,selected or {path=folder.folder_path,name=folder.title},{},false,picker)
        end,
        on_back=function(view) if view and not view._miu_closed then UIManager:close(view) end end,
        on_close=function(closed_view)
            if self._home_directory_request_owner==closed_view then self:_cancel_home_directory_request("local root picker closed") end
        end,
        on_refresh=function() self:_home_scan_local(true) end,
    }
    return picker
end

function Plugin:show_home_local_library(rows)
    local roots=self:_home_local_roots(true)
    if #roots==0 then
        self:info("还没有设置本地书库目录。\n\n可在 首页与书架 → 本地书籍 中添加。")
        return false
    end
    rows=type(rows)=="table" and rows or select(1,self:_home_local_rows())
    if #rows==0 then
        if self:_home_preferences().local_auto_update==true then self:_home_scan_local(false) end
        self:info("本地书库暂时没有可显示的书籍。")
        return false
    end
    return self:_home_show_full_shelf("本地书籍",rows,{
        show_actions=true,
        left_action_label="搜索",
        right_action_label="文件夹",
        on_left_action=function() self:show_home_search_dialog("local") end,
        on_right_action=function() self:_open_local_library_folders() end,
    })
end

function Plugin:_home_account_name()
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local name=U.trim(tostring(account.name or ""))
    if name~="" then return name end
    return self:logged_in() and "已登录" or "未登录"
end

function Plugin:_cancel_native_menu_guard()
    -- Clean up a beta.4 callback override if this code is loaded in the same
    -- process during development; beta.5 never installs a new override.
    local legacy_menu=NATIVE_MENU_GUARD.menu
    local legacy_close=NATIVE_MENU_GUARD.original_close
    if legacy_menu and legacy_close and legacy_menu.onCloseFileManagerMenu~=legacy_close then
        legacy_menu.onCloseFileManagerMenu=legacy_close
    end
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    NATIVE_MENU_GUARD.active=false
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=nil
    NATIVE_MENU_GUARD.container=nil
    NATIVE_MENU_GUARD.watch=nil
    NATIVE_MENU_GUARD.original_close=nil
end

function Plugin:_return_from_native_filemanager()
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local menu=NATIVE_MENU_GUARD.menu or (fm and fm.menu) or nil
    if menu and menu.menu_container and type(menu.onCloseFileManagerMenu)=="function" then
        pcall(menu.onCloseFileManagerMenu,menu)
    end
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    persist_home_session()
    local shown=self:show_miuread_home(false)
    if shown then
        self:_set_foreground("home")
        HomeView.raise(true)
        UIManager:scheduleIn(.04,function() UIManager:setDirty("all","full") end)
    end
    return shown
end

function Plugin:_native_menu_overlay_present()
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local reader=self:_active_reader_ui()
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget and widget~=fm and widget~=reader and widget~=HomeView.current()
            and widget.toast~=true then
            return true
        end
    end
    return false
end

function Plugin:_finish_native_menu_visit(token,reason)
    if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active or NATIVE_MENU_GUARD.finishing then return false end
    NATIVE_MENU_GUARD.finishing=true
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
        self:_cancel_native_menu_guard()
        return false
    end

    -- A book opened from this temporary menu still belongs to the MiuRead
    -- navigation session. The exact file is filled in as soon as ReaderUI is
    -- available.
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    local function settle(attempt)
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        sync_home_session()
        if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.6,function() settle(attempt+1) end)
            return
        end
        local reader=self:_active_reader_ui()
        if reader then
            local file=reader.document and reader.document.file or nil
            mark_reader_origin(file)
            self:_close_home_for_reader("native menu opened reader")
            self:_cancel_native_menu_guard()
            logger.info("[MiuRead][Home] native menu closed into reader",tostring(reason or "closed"))
            return
        end
        -- Native settings and plugin dialogs may replace the original menu.
        -- Wait until the last native layer closes before raising MiuRead again.
        if self:_native_menu_overlay_present() then
            local delay=attempt<20 and .12 or (attempt<80 and .3 or .7)
            UIManager:scheduleIn(delay,function() settle(attempt+1) end)
            return
        end

        self:_cancel_native_menu_guard()
        HOME_SESSION_SUPPRESSED=false
        HOME_NATIVE_VISIT=false
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_EXPECTED_CLOSE=false
        persist_home_session()
        logger.info("[MiuRead][Home] native menu closed; MiuRead home revealed",tostring(reason or "closed"))
        if HomeView.is_shown() then
            self:_set_foreground("home")
            HomeView.raise(true)
            UIManager:scheduleIn(.04,function() UIManager:setDirty("all","full") end)
        else
            self:_ensure_filemanager_base(HOME_RETURN_FILE)
            self:_restore_home_after_reader_close(1)
            UIManager:scheduleIn(.18,function() UIManager:setDirty("all","full") end)
        end
    end
    UIManager:scheduleIn(.04,function() settle(1) end)
    return true
end

function Plugin:_guard_native_koreader_menu(menu)
    if not menu then return nil end
    self:_set_navigation_state("native_menu","KOReader menu opened over home")
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    local token=NATIVE_MENU_GUARD.token
    NATIVE_MENU_GUARD.active=true
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=menu
    NATIVE_MENU_GUARD.container=menu.menu_container

    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    -- Do not replace KOReader's close callback. Native settings pages replace
    -- their menu/container as navigation goes deeper; observing the window
    -- stack is safer than changing callbacks owned by KOReader.
    local function watch()
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        sync_home_session()
        if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            UIManager:scheduleIn(.6,watch)
            return
        end
        local container=menu.menu_container or NATIVE_MENU_GUARD.container
        if not container or not UIManager:isWidgetShown(container) then
            self:_finish_native_menu_visit(token,"watchdog")
            return
        end
        UIManager:scheduleIn(.16,watch)
    end
    NATIVE_MENU_GUARD.watch=watch
    UIManager:scheduleIn(.16,watch)
    return token
end

function Plugin:_show_native_koreader_menu()
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil then return false end
    -- Ignore repeated taps while a native menu/settings visit is active. This
    -- prevents duplicate menu stacks and duplicate close watchers.
    if NATIVE_MENU_GUARD.active then return true end
    self:_cancel_native_menu_guard()
    self:_set_navigation_state("native_menu","opening KOReader menu over home")
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self:_ensure_filemanager_base(HOME_RETURN_FILE)
    if HomeView.is_shown() then HomeView.raise(true) end

    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    local candidates={}
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    if fm and fm.menu then candidates[#candidates+1]=fm.menu end
    if self.ui and self.ui.menu and self.ui.menu~=(fm and fm.menu) then
        candidates[#candidates+1]=self.ui.menu
    end
    for _,menu in ipairs(candidates) do
        if menu and type(menu.onShowMenu)=="function" then
            local ok,err=xpcall(function() menu:onShowMenu() end,debug.traceback)
            if ok then
                self:_guard_native_koreader_menu(menu)
                logger.info("[MiuRead][Home] native KOReader menu opened over MiuRead home")
                return true
            end
            logger.warn("[MiuRead][Home] native menu failed",tostring(err))
        end
    end

    self:_cancel_native_menu_guard()
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    persist_home_session()
    if HomeView.is_shown() then
        self:_set_foreground("home")
        HomeView.raise()
    else
        self:_set_navigation_state("recovering","native menu unavailable")
    end
    logger.warn("[MiuRead][Home] no native KOReader menu available")
    self:info("KOReader 菜单暂时无法打开")
    return false
end

function Plugin:_home_wifi_toggle()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    local ok
    if on then
        if type(NetworkMgr.toggleWifiOff)=="function" then ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr)
        elseif type(NetworkMgr.turnOffWifi)=="function" then ok=pcall(NetworkMgr.turnOffWifi,NetworkMgr) end
        if ok then self:toast("Wi-Fi 已关闭",1.5) end
    else
        if type(NetworkMgr.toggleWifiOn)=="function" then ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr)
        elseif type(NetworkMgr.turnOnWifi)=="function" then ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr) end
        if ok then self:toast("正在开启 Wi-Fi",1.5) end
    end
    if ok then HomeData.invalidate_device_state() end
    UIManager:scheduleIn(1,function() self:_refresh_home_view(nil,"header") end)
    return ok==true
end

function Plugin:_home_wifi_settings()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end

    -- Only refresh the MiuRead home after KOReader's network picker has
    -- actually closed. Refreshing while it is visible rebuilds the home view
    -- over the picker and makes the network list disappear immediately.
    local function refresh_after_picker_close()
        UIManager:scheduleIn(.15,function()
            self:_refresh_home_view(nil,"header")
        end)
    end

    local function show_network_list()
        -- Wi-Fi is already on: build KOReader's native network picker directly.
        if type(NetworkMgr.getNetworkList)=="function" then
            local ok_list,networks=pcall(NetworkMgr.getNetworkList,NetworkMgr)
            if ok_list and type(networks)=="table" then
                local ok_widget,NetworkSetting=pcall(require,"ui/widget/networksetting")
                if ok_widget and NetworkSetting and type(NetworkSetting.new)=="function" then
                    local dialog=NetworkSetting:new{
                        network_list=networks,
                        -- Deliberately omit connect_callback here. KOReader
                        -- auto-dismisses an already-connected network picker
                        -- when that callback is present. The close hook below
                        -- performs the single MiuRead header refresh instead.
                    }
                    local original_on_close=dialog.onCloseWidget
                    dialog.onCloseWidget=function(widget)
                        if type(original_on_close)=="function" then
                            local ok_close,err=xpcall(function()
                                original_on_close(widget)
                            end,debug.traceback)
                            if not ok_close then
                                logger.warn("[MiuRead][Home] network picker close failed",tostring(err))
                            end
                        end
                        refresh_after_picker_close()
                    end
                    UIManager:show(dialog)
                    return true
                end
            end
        end

        -- Backends with their own picker use KOReader's long-press flag.
        -- Their completion callback runs after the picker has been dismissed.
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,refresh_after_picker_close,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,refresh_after_picker_close,true)
            if ok then return true end
        end
        return false
    end

    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    if on then
        if show_network_list() then return true end
    elseif type(NetworkMgr.toggleWifiOn)=="function" then
        -- Ask KOReader to enable Wi-Fi and show the available network list.
        local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,refresh_after_picker_close,true,true)
        if ok then return true end
    elseif type(NetworkMgr.turnOnWifi)=="function" then
        local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr,function()
            UIManager:scheduleIn(.1,show_network_list)
        end,true)
        if ok then return true end
    end

    self:info("Wi-Fi 网络列表暂时无法打开")
    return false
end

function Plugin:_home_frontlight()
    local ok_fl,has_fl=pcall(Device.hasFrontlight,Device)
    if not ok_fl or not has_fl then self:info("当前设备不支持前光"); return false end
    return self:_show_frontlight_panel{placement="center"}
end

function Plugin:_home_toggle_night()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    UIManager:scheduleIn(.2,function() UIManager:setDirty("all","full") end)
    return true
end

function Plugin:_home_rotate()
    local Screen=Device.screen
    local current=Screen:getRotationMode()
    local next_mode
    if current==Screen.DEVICE_ROTATED_CLOCKWISE then
        next_mode=Screen.DEVICE_ROTATED_UPSIDE_DOWN
    elseif current==Screen.DEVICE_ROTATED_UPSIDE_DOWN then
        next_mode=Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
    elseif current==Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        next_mode=Screen.DEVICE_ROTATED_UPRIGHT
    else
        next_mode=Screen.DEVICE_ROTATED_CLOCKWISE
    end
    UIManager:broadcastEvent(Event:new("SetRotationMode",next_mode))
    return true
end

function Plugin:_home_full_refresh(confirmed)
    if confirmed~=true and self:_notice_enabled("full_refresh") then
        local dialog
        dialog=ButtonDialog:new{title="全屏刷新可以清除墨水屏残影，屏幕会短暂闪烁。",title_align="center",buttons={
            {{text="立即刷新",callback=function() UIManager:close(dialog); self:_home_full_refresh(true) end}},
            {{text="刷新并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("full_refresh",false); self:_home_full_refresh(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return true
    end
    UIManager:setDirty("all","full")
    return true
end

function Plugin:_home_sleep()
    if Device:canSuspend() then
        UIManager:flushSettings()
        UIManager:suspend()
        return true
    end
    self:info("当前设备不支持休眠")
    return false
end

function Plugin:_home_device_power_busy(action_label)
    action_label=tostring(action_label or "执行此操作")
    if (self.download_task and self.download_task:busy()) or self._download_runtime~=nil then
        self:info("当前下载任务尚未完成，暂不"..action_label.."。\n\n请等待任务结束，或先在下载管理中取消任务。")
        return true
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then
        self:info("缓存任务尚未完成，暂不"..action_label.."。")
        return true
    end
    return false
end

function Plugin:_show_home_power_confirm(anchor,title,detail,confirm_label,callback)
    return ActionSheet.show{
        anchor=anchor,preferred_direction="above",width_ratio=.58,
        title=tostring(title or "确认操作"),subtitle=tostring(detail or ""),
        actions={
            {icon="×",label="取消",detail="不执行任何操作",callback=function() end},
            {icon="!",label=tostring(confirm_label or "确定"),detail="保存当前状态后执行",danger=true,callback=callback},
        },
    }
end

function Plugin:_flush_before_power_action()
    pcall(function() self:_flush_home_preferences() end)
    pcall(function() self:onFlushSettings() end)
    if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
end

function Plugin:_home_reboot_device(anchor,confirmed)
    if type(Device.canReboot)~="function" or not Device:canReboot() then
        self:info("当前设备不支持由 KOReader 重启设备")
        return false
    end
    if self:_home_device_power_busy("重启设备") then return false end
    if confirmed~=true and HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"重启整个设备？","这会重新启动 Kindle，而不是只重启 KOReader。","重启设备",function()
            self:_home_reboot_device(anchor,true)
        end)
    end
    self:_flush_before_power_action()
    UIManager:broadcastEvent(Event:new("RequestReboot"))
    return true
end

function Plugin:_home_poweroff_device(anchor,confirmed)
    if type(Device.canPowerOff)~="function" or not Device:canPowerOff() then
        self:info("当前设备不支持由 KOReader 关机")
        return false
    end
    if self:_home_device_power_busy("关机") then return false end
    if confirmed~=true and HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"关闭整个设备？","日常使用建议优先使用休眠。","关机",function()
            self:_home_poweroff_device(anchor,true)
        end)
    end
    self:_flush_before_power_action()
    UIManager:broadcastEvent(Event:new("RequestPowerOff"))
    return true
end

function Plugin:_home_preview_books(rows,hero,limit)
    local out,seen={},{}
    local hero_key=self:_home_book_key(hero)
    if hero_key~="" then seen[hero_key]=true end
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            out[#out+1]=book
            if #out>=math.max(1,tonumber(limit) or 4) then break end
        end
    end
    return out
end

function Plugin:maintenance_menu()
    return {
        {text="书库维护",post_text="扫描 资料 封面与书架",sub_item_table_func=function()
            return {
                {text="重新扫描全部本地书库",callback=function()
                    local started=self:_home_scan_local(true)
                    if started then self:toast("正在重新扫描本地书库…",2) end
                end},
                {text="更新缺失书籍资料",callback=function()
                    self:_home_reset_local_metadata(); self:_home_complete_refresh(true)
                end},
                {text="重建封面",callback=function() self:_clear_cover_cache() end},
                {text="重建书架索引",callback=function()
                    self.store:reload(); self.store:prune_missing_files(); self:_show_miuread_home_now(false,true,true,"full")
                end},
            }
        end},
        {text="书籍修复",post_text="完整性与旧评论数据",sub_item_table_func=function()
            return {
                {text="检查下载完整性",callback=function() self:scan_downloaded_books_for_integrity_repair() end},
                {text="评论数据迁移",sub_item_table_func=function() return self:book_repair_settings_menu() end},
            }
        end},
        {text="存储清理",post_text="临时文件 缓存与旧记录",callback=function() self:show_download_cleanup_dialog() end},
        {text="诊断",post_text="同步与时间",sub_item_table_func=function()
            return {
                {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
                {text="时间诊断",callback=function()
                    local value=self:_time_preferences()
                    local zone=TimeZone.zone(value.zone)
                    self:info("觅阅时间："..self:_display_time("%Y-%m-%d %H:%M:%S")
                        .."\n设备时间："..os.date("%Y-%m-%d %H:%M:%S")
                        .."\n显示来源："..TimeZone.label(value)
                        .."\n地区："..tostring(zone and zone.label or "—")
                        .."\n偏移："..TimeZone.offset_text(TimeZone.offset_minutes(value)))
                end},
            }
        end},
        {text="性能与兼容性",post_text=self:_performance_mode_label(),sub_item_table_func=function() return PluginSettings.performance(self) end},
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
        {text="系统操作",post_text="退出 重启与关机",sub_item_table_func=function()
            local system_items={
                {text="退出 KOReader",callback=function() self:_quit_koreader() end},
                {text="重启 KOReader",callback=function() self:_restart_koreader() end},
            }
            if type(Device.canReboot)=="function" and Device:canReboot() then
                system_items[#system_items+1]={text="重启设备",callback=function() self:_home_reboot_device() end}
            end
            if type(Device.canPowerOff)=="function" and Device:canPowerOff() then
                system_items[#system_items+1]={text="关机",callback=function() self:_home_poweroff_device() end}
            end
            return system_items
        end},
    }
end

function Plugin:show_home_quick_panel(more_expanded)
    local started=monotonic_wall_time()
    local now=started
    if self._home_quick_panel_opening==true
        or now-(tonumber(self._home_quick_panel_last_open) or 0)<.35 then return true end
    self._home_quick_panel_opening=true
    self._home_quick_panel_last_open=now

    -- Opening the control center must never query Wi-Fi, disk or download
    -- storage. The home surface already has a recent device snapshot.
    local state=HomeData.cached_device_state() or {}
    local wifi_on=state.wifi_on
    local wifi_name=U.trim(tostring(state.wifi_name or ""))
    local wifi_detail
    if wifi_on==nil then wifi_detail="状态未知"
    elseif wifi_on~=true then wifi_detail="已关闭"
    elseif wifi_name~="" then wifi_detail=U.utf8_truncate(wifi_name,11,"…")
    elseif state.online==true then wifi_detail="已连接"
    else wifi_detail="未连接" end
    local download_detail=tostring(self._home_panel_download_detail or "")
    local sync_label=self:_home_sync_status_label()
    local definitions={
        wifi={
            icon="Wi-Fi",
            icon_path=ROOT.."/resources/"..(wifi_on==false and "wifi-off.svg" or (state.online==true and "wifi-connected.svg" or "wifi-disconnected.svg")),
            label="Wi-Fi",detail=wifi_detail,
            callback=function() self:_home_wifi_toggle() end,
            hold_callback=function() self:_home_wifi_settings() end
        },
        rotate={icon="↻",icon_key="rotate",label="旋转",detail="",callback=function() self:_home_rotate() end},
        screenshot={icon="▣",icon_key="screenshot",label="截图",detail="",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
        koreader_settings={icon="⚙",icon_key="ko-reader",label="KO设置",detail="",callback=function() self:_show_native_koreader_menu() end},
        return_koreader={icon="←",icon_key="return",label="返回KO",detail="",callback=function() self:_home_close_to_native(true) end},
        quit={icon="⏻",icon_key="power",label="退出 KOReader",detail="",callback=function() self:_quit_koreader() end},
        sync={icon="⇅",icon_key="sync",label="同步",detail=sync_label,callback=function() self:_sync_home_pending() end,hold_callback=function(anchor) self:_show_home_sync_popup(anchor) end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",detail="",callback=function() self:_show_home_settings_center() end},
        downloads={icon="⇩",icon_key="download",label="下载",detail=download_detail,
            callback=function(anchor) self:_show_home_download_popup(anchor) end,
            hold_callback=function() self:show_downloads() end},
        restart={icon="↺",icon_key="restart",label="重启",detail="",callback=function() self:_restart_koreader() end},
        full_refresh={icon="▤",icon_key="full-refresh",label="全屏刷新",detail="",callback=function() self:_home_full_refresh() end},
    }
    if Device:canSuspend() then
        definitions.sleep={icon="◐",icon_key="sleep",label="休眠",detail="",callback=function() self:_home_sleep() end}
    end

    local home,preferences=self:_home_preferences()
    local buttons={}
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true and definitions[key] then buttons[#buttons+1]=definitions[key] end
        if #buttons>=6 then break end
    end

    local battery=tonumber(state.battery) and (tostring(math.floor(state.battery+.5)).."%") or "未知"
    local status_text=tostring(self._home_panel_status_text or "")
    if status_text=="" and sync_label:match("^失败") then status_text="同步需要处理" end
    local frontlight_control=nil
    if Device:hasFrontlight() then
        local minimum,maximum=self:_reader_frontlight_bounds()
        local warmth_state=self:_reader_warmth_state()
        frontlight_control={
            get_enabled=function() return self:_reader_frontlight_enabled() end,
            get_night=function() return self:_reader_night_enabled() end,
            on_toggle=function() return self:_reader_toggle_frontlight() end,
            on_night=function() return self:_home_toggle_night() end,
            brightness={min=minimum,max=maximum,value=self:_reader_frontlight_value() or minimum,get_value=function() return self:_reader_frontlight_value() or minimum end,on_set=function(value)
                if not self:_reader_set_frontlight(value) then return false end
                return self:_reader_frontlight_value() or value
            end},
            warmth=warmth_state and {min=warmth_state.min,max=warmth_state.max,value=warmth_state.value,get_value=function() local latest=self:_reader_warmth_state(); return latest and latest.value or warmth_state.value end,on_set=function(value)
                if not self:_reader_set_warmth(value) then return false end
                local latest=self:_reader_warmth_state(); return latest and latest.value or value
            end} or nil,
        }
    end
    local prepared=monotonic_wall_time()
    local panel,err=HomeQuickPanel.show{
        time_text=self:_display_time("%H:%M"),
        battery_text=battery,
        status_text=status_text,
        buttons=buttons,
        frontlight=frontlight_control,
        on_customize=function(anchor) self:show_home_customization(anchor) end,
        on_tools=function(anchor)
            self:_show_standalone_menu("工具与维护",self:maintenance_menu(),{anchor=anchor})
        end,
    }
    self._home_quick_panel_opening=false
    local completed=monotonic_wall_time()
    local total_ms=math.floor((completed-started)*1000+.5)
    logger.info("[MiuRead][QuickPanel] timing",
        "prep_ms=",tostring(math.floor((prepared-started)*1000+.5)),
        "show_ms=",tostring(math.floor((completed-prepared)*1000+.5)),
        "total_ms=",tostring(total_ms))
    if not panel then
        logger.warn("[MiuRead][QuickPanel] unavailable",tostring(err or "unknown"))
        self:info("快捷控制暂时无法打开")
        return false
    end
    self:_record_performance("home_panel",total_ms)
    return true
end

function Plugin:_begin_koreader_exit(reason)
    self:_cancel_interactive_network(reason or "KOReader exit")
    self:_cancel_native_menu_guard()
    HOME_EXITING=true
    HOME_SESSION_SUPPRESSED=true
    HOME_NATIVE_VISIT=false
    HOME_RETURN_FILE=nil
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    HOME_EXPECTED_CLOSE=true
    self:_set_foreground("exiting")
    persist_home_session()
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    self:_home_stop_background(reason or "KOReader exit")
    self:_close_reader_recovery_surface()
    self:_release_reader_transition_guard("KOReader exit")
    HomeQuickPanel.close()
    HomeView.close()
    self._home_view=nil
end

function Plugin:_quit_koreader(confirmed,anchor)
    local active=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local queued=#self.store:download_queue()>0
    local detail=""
    if active and queued then detail="当前任务会中断，重启后可继续；排队任务会保留。"
    elseif active then detail="当前任务会中断，重新启动后可继续。"
    elseif queued then detail="当前有一个排队任务，重新启动后仍会保留。" end
    local function do_exit()
        self:_begin_koreader_exit("quit")
        pcall(function() self:onFlushSettings() end)
        if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
        UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
    end
    if confirmed==true then do_exit(); return true end
    if HomeView.is_shown() then
        return self:_show_home_power_confirm(anchor,"退出 KOReader？",detail~="" and detail or "当前阅读和设置会先保存。","退出",do_exit)
    end
    UIManager:show(ConfirmBox:new{text="退出 KOReader？"..(detail~="" and ("\n\n"..detail) or ""),ok_text="退出",cancel_text="取消",ok_callback=do_exit})
    return true
end

function Plugin:show_home_menu()
    if not self:_home_enabled() then return self:_show_standalone_menu("插件设置",PluginSettings.menu(self)) end
    return self:_show_standalone_menu("觅阅菜单",self:settings_menu())
end

function Plugin:home_preview_menu()
    return {
        {text="打开觅阅菜单",callback=function() self:show_home_menu() end},
        {text="切换到插件模式",callback=function() self:_set_home_mode(false) end},
        {text="KOReader 文件管理器",callback=function() self:_home_close_to_native() end},
    }
end

function Plugin:_schedule_reader_interaction_resume(target)
    self._reader_interaction_resume_generation=(tonumber(self._reader_interaction_resume_generation) or 0)+1
    local generation=self._reader_interaction_resume_generation
    if self._reader_interaction_resume_task then
        UIManager:unschedule(self._reader_interaction_resume_task)
        self._reader_interaction_resume_task=nil
    end
    local task
    task=function()
        if self._reader_interaction_resume_task~=task
            or generation~=self._reader_interaction_resume_generation then return end
        if self._miuread_suspended==true or HOME_SESSION.suspended==true then
            self._reader_interaction_resume_task=nil
            return
        end
        local now=os.time()
        local deadline=math.max(tonumber(target) or 0,tonumber(self._reader_busy_until or 0) or 0)
        if deadline>now then
            UIManager:scheduleIn(math.max(.25,deadline-now+.15),task)
            return
        end
        self._reader_interaction_resume_task=nil
        if self.download_task then self.download_task:resume("reader_interaction") end
    end
    self._reader_interaction_resume_task=task
    UIManager:scheduleIn(math.max(.25,(tonumber(target) or os.time())-os.time()+.15),task)
end

function Plugin:_mark_reader_busy(seconds,share_report)
    local path=tostring(self._reader_busy_path or "")
    if path=="" then return false end
    self._reader_last_interaction_clock=os.clock()
    local now=os.time()
    local target=math.max(now+math.max(1,tonumber(seconds) or 4),tonumber(self._reader_busy_until or 0) or 0)
    self._reader_busy_until=target
    local active_download=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local wrote=true
    -- Keep page turns memory-only in the normal case. The shared /tmp marker is
    -- written only when a visible panel gesture specifically asks the report
    -- subprocess to yield, or while a download is already competing for I/O.
    if active_download or share_report==true then wrote=U.atomic_write(path,tostring(target),true)==true end
    -- Reading interaction always wins over background generation. This used to
    -- happen only in optional lightweight mode, which is why active downloads
    -- could still make the first page turn or pull-down panel feel sticky.
    if active_download and self.download_task then
        self.download_task:pause("reader_interaction")
        self:_schedule_reader_interaction_resume(target)
    end
    return wrote
end

function Plugin:_reader_background_idle()
    if os.time()<(tonumber(self._reader_busy_until) or 0) then return false end
    local quiet=self:_lightweight_enabled()
        and (tonumber(Config.LIGHTWEIGHT_READER_IDLE_SECONDS) or 1.5) or .80
    return os.clock()-(tonumber(self._reader_last_interaction_clock) or 0)>=quiet
end

function Plugin:_reader_toolbar_cache()
    local session=tonumber(HOME_SESSION.reader_session_generation or 0) or 0
    local cache=self._reader_toolbar_state_cache
    if type(cache)~="table" or tonumber(cache.session or -1)~=session then
        cache={session=session,page=nil,total=nil,chapter="",updated_at=0}
        self._reader_toolbar_state_cache=cache
    end
    return cache
end

function Plugin:_reset_reader_toolbar_state_cache()
    if self._reader_toolbar_state_task then
        UIManager:unschedule(self._reader_toolbar_state_task)
        self._reader_toolbar_state_task=nil
    end
    self._reader_toolbar_state_cache={
        session=tonumber(HOME_SESSION.reader_session_generation or 0) or 0,
        page=nil,total=nil,chapter="",updated_at=0,
    }
end

function Plugin:_refresh_reader_toolbar_state_cache(page)
    if not (self.ui and self.ui.document) then return false end
    local started=os.clock()
    local cache=self:_reader_toolbar_cache()
    local current=tonumber(page)
    if not current then current=self:_reader_current_page() end
    if current then cache.page=current end

    if not tonumber(cache.total) or tonumber(cache.total)<=0 then
        local document=self.ui.document
        local total
        if type(document.getPageCount)=="function" then
            local ok,value=pcall(document.getPageCount,document)
            if ok then total=tonumber(value) end
        end
        total=total or (document.info and tonumber(document.info.number_of_pages)) or nil
        if total and total>0 then cache.total=total end
    end

    local chapter_started=os.clock()
    if current then
        local toc=self.ui and self.ui.toc or nil
        local chapter=""
        if toc and type(toc.getTocTitleByPage)=="function" then
            local ok,value=pcall(toc.getTocTitleByPage,toc,current)
            if ok and value then chapter=U.trim(tostring(value)) end
        end
        if chapter~="" then cache.chapter=chapter elseif tostring(cache.chapter or "")=="" then cache.chapter="当前章节" end
    end
    cache.updated_at=os.time()
    local chapter_ms=math.floor((os.clock()-chapter_started)*1000+.5)
    local total_ms=math.floor((os.clock()-started)*1000+.5)
    if total_ms>=20 or chapter_ms>=15 then
        logger.info("[MiuRead][ReaderToolbarState] refreshed",
            "page=",tostring(cache.page or ""),"chapter_ms=",tostring(chapter_ms),"total_ms=",tostring(total_ms))
    end
    return true
end

function Plugin:_schedule_reader_toolbar_state_refresh(page,delay)
    if self._reader_toolbar_state_task then UIManager:unschedule(self._reader_toolbar_state_task) end
    local session=tonumber(HOME_SESSION.reader_session_generation or 0) or 0
    local requested=tonumber(page)
    local task
    task=function()
        if self._reader_toolbar_state_task~=task then return end
        if self._miuread_suspended==true or HOME_SESSION.suspended==true then
            self._reader_toolbar_state_task=nil
            return
        end
        if not self:_reader_background_idle() then
            UIManager:scheduleIn(.35,task)
            return
        end
        self._reader_toolbar_state_task=nil
        if self.ui and self.ui.document and not reader_close_active()
            and tonumber(HOME_SESSION.reader_session_generation or 0)==session then
            self:_refresh_reader_toolbar_state_cache(requested)
        end
    end
    self._reader_toolbar_state_task=task
    UIManager:scheduleIn(tonumber(delay) or .05,task)
    return true
end

function Plugin:_reader_toolbar_cached_percent()
    local cache=self:_reader_toolbar_cache()
    local page,total=tonumber(cache.page),tonumber(cache.total)
    if page and total and total>0 then return math.max(0,math.min(100,page/total*100)) end
    return nil
end

function Plugin:_reader_progress_percent()
    local ui=self.ui
    local document=ui and ui.document
    if not ui or not document then return nil end
    local current,total
    if type(ui.getCurrentPage)=="function" and type(document.getPageCount)=="function" then
        local ok_current,value_current=pcall(ui.getCurrentPage,ui)
        local ok_total,value_total=pcall(document.getPageCount,document)
        if ok_current and ok_total then current,total=tonumber(value_current),tonumber(value_total) end
    end
    if current and total and total>0 then
        return math.max(0,math.min(100,current/total*100))
    end
    local rolling=ui.rolling
    local pos=rolling and tonumber(rolling.current_page or rolling.current_pos)
    local pages=rolling and tonumber(rolling.page_count or rolling.full_height)
    if pos and pages and pages>0 then return math.max(0,math.min(100,pos/pages*100)) end
    return nil
end

function Plugin:_reader_jump_percent(delta)
    local current=self:_reader_progress_percent()
    if not current then self:info("当前文档暂时无法按百分比调整进度"); return false end
    local target=math.max(0,math.min(100,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(4)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_reader_adjust_font_size(delta)
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local current=font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
    if not current then
        self:info("当前文档暂时无法直接调整字号")
        return false
    end
    local target=math.max(12,math.min(72,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(5)
    if font and type(font.onSetFontSize)=="function" then
        local ok=pcall(font.onSetFontSize,font,target)
        if ok then return true end
    end
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("SetFontSize",target))
        return true
    end
    return false
end

function Plugin:_reader_goto_percent(target)
    target=math.max(0,math.min(100,tonumber(target) or 0))
    if not (self.ui and type(self.ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_reader_previous_chapter()
    local ui=self.ui
    if not (ui and ui.document and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    ui:handleEvent(Event:new("GotoPrevChapter"))
    return true
end

function Plugin:_reader_next_chapter()
    local ui=self.ui
    if not (ui and ui.document and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    ui:handleEvent(Event:new("GotoNextChapter"))
    return true
end

function Plugin:_show_reader_progress_control(back_callback)
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    ReaderProgressDialog.show{
        percent=self:_reader_progress_percent() or 0,
        on_goto_percent=function(target) self:_reader_goto_percent(target) end,
        on_adjust=function(delta) self:_reader_jump_percent(delta) end,
        on_jump=function() self:_show_reader_position_jump() end,
        on_prev_chapter=function() self:_reader_previous_chapter() end,
        on_next_chapter=function() self:_reader_next_chapter() end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_show_reader_position_jump(back_callback)
    local ui=self.ui
    local gotopage=ui and ui.gotopage
    if gotopage and type(gotopage.onShowGotoDialog)=="function" then
        self:_mark_reader_busy(5)
        return self:_reader_open_native_page("页面跳转",function()
            gotopage:onShowGotoDialog()
            return true
        end,back_callback or function() self:show_reader_quick_panel() end)
    end
    self:info("当前文档暂时无法跳转位置")
    return false
end
function Plugin:_reader_current_page()
    local ui=self.ui
    if ui and type(ui.getCurrentPage)=="function" then
        local ok,value=pcall(ui.getCurrentPage,ui)
        if ok and tonumber(value) then return tonumber(value) end
    end
    local rolling=ui and ui.rolling or nil
    return tonumber(rolling and (rolling.current_page or rolling.current_pos))
end

function Plugin:_reader_toc_items()
    if self:_stream_active() then
        local stream_items,stream_current=self:_stream_toc_items()
        if stream_items and #stream_items>0 then return stream_items,stream_current end
    end
    local ui=self.ui
    local toc=ui and ui.toc or nil
    if not toc then return {},nil end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    local source=type(toc.toc)=="table" and toc.toc or {}
    local current_index
    local current_page=self:_reader_current_page()
    if current_page and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,current_page)
        if ok then current_index=tonumber(value) end
    end
    -- Some document backends do not expose getTocIndexByPage reliably.
    -- Fall back to the nearest preceding ToC entry so opening the directory
    -- still follows the actual reading position.
    if current_page and not current_index then
        local nearest_page=-math.huge
        for index,entry in ipairs(source) do
            local page=tonumber(entry.page or entry.pageno)
            if page and page<=current_page and page>=nearest_page then
                current_index=index
                nearest_page=page
            end
        end
    end
    local items={}
    for index,entry in ipairs(source) do
        local item=entry
        local title=U.trim(tostring(item.title or item.text or item.name or ""))
        if title=="" then title="未命名章节" end
        local page=tonumber(item.page or item.pageno)
        local xpointer=item.xpointer or item.xp
        local destination_page=page
        local destination_xpointer=xpointer
        items[#items+1]={
            title=title,
            depth=tonumber(item.depth or item.level) or 1,
            page=page,
            page_label=item.page_label or (page and tostring(page) or ""),
            current=current_index==index,
            callback=function()
                local current_ui=self.ui
                if not (current_ui and current_ui.document) then return false end
                local link=current_ui.link
                if link and type(link.addCurrentLocationToStack)=="function" then
                    pcall(link.addCurrentLocationToStack,link)
                end
                self:_mark_reader_busy(5)
                if destination_xpointer then
                    current_ui:handleEvent(Event:new("GotoXPointer",destination_xpointer,destination_xpointer))
                    return true
                end
                if destination_page then
                    current_ui:handleEvent(Event:new("GotoPage",destination_page))
                    return true
                end
                return false
            end,
        }
    end
    return items,current_index
end

function Plugin:_show_reader_toc(back_callback)
    local items=self:_reader_toc_items()
    if #items>0 then
        self:_mark_reader_busy(6)
        local dialog,err=ReaderTocDialog.show{
            title="目录",
            items=items,
            auto_follow=true,
            on_back=back_callback or function() self:show_reader_quick_panel() end,
            on_home=function() return self:return_to_miuread_home("reader surface") end,
        }
        if dialog then return true end
        logger.warn("[MiuRead][ReaderToc] custom dialog unavailable",tostring(err or "unknown"))
    end
    -- A native full-screen ToC is an acceptable compatibility fallback; it is
    -- intentionally different from the native bottom configuration strip.
    local toc=self.ui and self.ui.toc
    if toc and type(toc.onShowToc)=="function" then
        self:_mark_reader_busy(5)
        return self:_reader_open_native_page("目录",function()
            toc:onShowToc()
            return true
        end,back_callback or function() self:show_reader_quick_panel() end)
    end
    self:info("当前书籍没有可用目录")
    return false
end

function Plugin:_reader_line_spacing_value()
    local ui=self.ui
    local font=ui and ui.font or nil
    local configurable=ui and ui.document and ui.document.configurable or nil
    return tonumber((font and font.configurable and font.configurable.line_spacing)
        or (configurable and configurable.line_spacing)
        or (font and font.line_space_percent)) or 100
end

function Plugin:_reader_set_line_spacing(value)
    local font=self.ui and self.ui.font or nil
    local target=math.max(50,math.min(200,math.floor((tonumber(value) or 100)+.5)))
    if font and type(font.onSetLineSpace)=="function" then
        self:_mark_reader_busy(5)
        local ok=pcall(font.onSetLineSpace,font,target)
        if ok then return true end
    end
    self:info("当前文档暂时无法直接调整行距")
    return false
end

function Plugin:_reader_adjust_line_spacing(delta)
    return self:_reader_set_line_spacing(self:_reader_line_spacing_value()+(tonumber(delta) or 0))
end

function Plugin:_reader_font_weight_value()
    local ui=self.ui
    local font=ui and ui.font or nil
    local configurable=ui and ui.document and ui.document.configurable or nil
    return tonumber((font and font.configurable and font.configurable.font_base_weight)
        or (configurable and configurable.font_base_weight)) or 0
end

function Plugin:_reader_font_weight_label()
    local value=self:_reader_font_weight_value()
    if value<=-.5 then return "较细" end
    if value>=1.5 then return "很粗" end
    if value>=.5 then return "较粗" end
    return "默认"
end

function Plugin:_reader_set_font_weight(value)
    local font=self.ui and self.ui.font or nil
    local target=math.max(-1,math.min(3,tonumber(value) or 0))
    target=math.floor(target*4+.5)/4
    if font and type(font.onSetFontBaseWeight)=="function" then
        self:_mark_reader_busy(5)
        local ok=pcall(font.onSetFontBaseWeight,font,target)
        if ok then return true end
    end
    self:info("当前文档暂时无法直接调整字体粗细")
    return false
end

function Plugin:_reader_adjust_font_weight(delta)
    return self:_reader_set_font_weight(self:_reader_font_weight_value()+(tonumber(delta) or 0))
end

function Plugin:_show_reader_font_face_menu(back_callback)
    local font=self.ui and self.ui.font or nil
    if not font then self:info("当前文档暂时无法选择字体"); return false end
    if type(font.setupFaceMenuTable)=="function" then pcall(font.setupFaceMenuTable,font) end
    local items=font.face_table
    if type(items)=="table" and #items>0 then
        return self:_show_reader_menu_table("正文字体",items,back_callback)
    end
    self:info("当前 KOReader 版本没有提供可供觅阅读取的字体列表")
    return false
end
function Plugin:_show_reader_spacing_panel(back_callback)
    ReaderSettingsDialog.show{
        title="行距",
        subtitle=function() return "当前行距："..tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end,
        hero=function()
            return {
                value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",
                on_decrease=function() self:_reader_adjust_line_spacing(-5) end,
                on_increase=function() self:_reader_adjust_line_spacing(5) end,
            }
        end,
        on_back=back_callback,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local current=math.floor(self:_reader_line_spacing_value()+.5)
            return {
                {title="常用预设",rows={
                    {label="紧凑",value="100%",checked=current==100,keep_open=true,callback=function() self:_reader_set_line_spacing(100) end},
                    {label="标准",value="120%",checked=current==120,keep_open=true,callback=function() self:_reader_set_line_spacing(120) end},
                    {label="舒展",value="140%",checked=current==140,keep_open=true,callback=function() self:_reader_set_line_spacing(140) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_weight_panel(back_callback)
    ReaderSettingsDialog.show{
        title="字体粗细",
        subtitle=function() return "当前粗细："..self:_reader_font_weight_label() end,
        hero=function()
            return {
                value=self:_reader_font_weight_label(),
                on_decrease=function() self:_reader_adjust_font_weight(-.25) end,
                on_increase=function() self:_reader_adjust_font_weight(.25) end,
            }
        end,
        on_back=back_callback,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local current=self:_reader_font_weight_value()
            return {
                {title="常用预设",rows={
                    {label="较细",value="-0.5",checked=math.abs(current+.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(-.5) end},
                    {label="默认",value="0",checked=math.abs(current)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(0) end},
                    {label="较粗",value="0.5",checked=math.abs(current-.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(.5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_thoughts_enabled()
    return (self.store:preferences().thoughts or {}).enabled~=false
end

function Plugin:_set_thoughts_enabled(enabled)
    enabled=enabled~=false
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    if (p.thoughts.enabled~=false)==enabled then return true end
    p.thoughts.enabled=enabled
    self:_save_ui_preferences(p,"thoughts_enabled")
    local current=self.sync and self.sync.current or nil
    local record=current and current.record or {}
    local variant=tostring(current and (current.variant or record.variant) or "")
    local annotation_book=current and (record.annotation_requested==true or variant:find("notes",1,true))
    if enabled then
        if annotation_book then self:_setup_thought_tap() end
        self:toast("阅读评论已开启",1.5)
    else
        self:_close_active_thought_popup("comments disabled")
        -- Keep the MiuRead internal-link guard installed. Hiding comments must
        -- not hand #miuthought links back to KOReader as invalid external links.
        if annotation_book then self:_setup_thought_tap() end
        self:toast("阅读评论已关闭，划线和评论数据不会删除",2)
    end
    return true
end

function Plugin:_toggle_thoughts_enabled()
    return self:_set_thoughts_enabled(not self:_thoughts_enabled())
end

function Plugin:_thoughts_enabled_label()
    return self:_thoughts_enabled() and "已开启" or "已关闭"
end

function Plugin:_thought_font_size_label()
    local level=tostring((self.store:preferences().thoughts or {}).font or "standard")
    local labels={small="小（18）",standard="标准（22）",large="大（26）",xlarge="特大（30）"}
    return labels[level] or labels.standard
end

function Plugin:_set_thought_font_size(level)
    local allowed={small=true,standard=true,large=true,xlarge=true}
    level=allowed[tostring(level or "")] and tostring(level) or "standard"
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.font=level
    self:_save_ui_preferences(p,"thought_font")
    self:_refresh_thought_display(p.thoughts)
    self:toast("评论字号已设为："..self:_thought_font_size_label(),2)
    return true
end

function Plugin:_refresh_thought_display(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    if ThoughtNativePopup and type(ThoughtNativePopup.refresh_font)=="function" then
        pcall(ThoughtNativePopup.refresh_font,
            self:_thought_font_size(prefs.font or "standard"),
            self:_thought_font_name(prefs))
    end
end

function Plugin:_toggle_thought_follow_body_font()
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
    self:_save_ui_preferences(p,"thought_font_follow")
    self:_refresh_thought_display(p.thoughts)
    return true
end

function Plugin:_show_reader_comment_settings(back_callback)
    local return_to_comments=function() self:_show_reader_comment_settings(back_callback) end
    ReaderSettingsDialog.show{
        title="评论显示",
        subtitle=function()
            if not self:_thoughts_enabled() then return "阅读评论已关闭, 划线与本地评论数据仍保留" end
            local prefs=self.store:preferences().thoughts or {}
            return (prefs.follow_body_font==true and "字体跟随正文" or self:_thought_font_face_label(prefs)).." · "..self:_thought_font_size_label()
        end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            local prefs=self.store:preferences().thoughts or {}
            local follow=prefs.follow_body_font==true
            local level=tostring(prefs.font or "standard")
            return {
                {label="阅读评论",value=self:_thoughts_enabled_label(),value_bold=true,keep_open=true,callback=function() self:_toggle_thoughts_enabled() end},
                {label="评论字体跟随正文",value=follow and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:_toggle_thought_follow_body_font() end},
                {label="固定字体",value=self:_thought_font_face_label(prefs),enabled=not follow,callback=function()
                    self:_show_reader_menu_table("评论字体",self:thought_font_face_menu(),return_to_comments)
                end},
                {label="小",value=level=="small" and "18 · 已选择" or "18",checked=level=="small",keep_open=true,callback=function() self:_set_thought_font_size("small") end},
                {label="标准",value=level=="standard" and "22 · 已选择" or "22",checked=level=="standard",keep_open=true,callback=function() self:_set_thought_font_size("standard") end},
                {label="大",value=level=="large" and "26 · 已选择" or "26",checked=level=="large",keep_open=true,callback=function() self:_set_thought_font_size("large") end},
                {label="特大",value=level=="xlarge" and "30 · 已选择" or "30",checked=level=="xlarge",keep_open=true,callback=function() self:_set_thought_font_size("xlarge") end},
            }
        end,
    }
    return true
end

function Plugin:_reader_font_label()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local name=font and font.font_face or (configurable and (configurable.font_face or configurable.font))
    name=U.trim(tostring(name or ""))
    return name~="" and name or "KOReader 默认"
end

function Plugin:_reader_font_size_label()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local current=font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
    return current and tostring(math.floor(current+.5)) or "未知"
end

function Plugin:_reader_toolbar_title()
    -- Never reload Store on a swipe. Sync already owns the current book record.
    local current=self.sync and self.sync:record() or nil
    local title=current and current.book and current.book.title or nil
    if not title or title=="" then
        local path=self:_current_document_path()
        title=path and path:match("([^/]+)$") or "正在阅读"
    end
    local percent=self:_reader_toolbar_cached_percent()
    local progress=percent and (tostring(math.floor(percent+.5)).."%") or "位置未知"
    local status=progress.." · "..tostring(self:progress_sync_label())
    return tostring(title),status,progress,percent
end

function Plugin:_reader_current_wifi_name(max_chars)
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr or type(NetworkMgr.getCurrentNetwork)~="function" then return nil end
    local ok,current=pcall(NetworkMgr.getCurrentNetwork,NetworkMgr)
    if not ok or type(current)~="table" then return nil end
    local ssid=U.trim(tostring(current.ssid or current.name or ""))
    if ssid=="" then return nil end
    return U.utf8_truncate(ssid,tonumber(max_chars) or 18,"…")
end

function Plugin:_reader_wifi_summary()
    local state=HomeData.cached_device_state() or {}
    if state.wifi_on==false then return "Wi-Fi关",false end
    if state.wifi_on==nil then return "Wi-Fi",true end
    local ssid=U.trim(tostring(state.wifi_name or ""))
    if ssid~="" then return U.utf8_truncate(ssid,18,"…"),false end
    if state.online==true then return "已连接",false end
    return "Wi-Fi!",true
end

function Plugin:_reader_sync_summary()
    local label=tostring(self:progress_sync_label() or "")
    if label:find("失败",1,true) or label:find("需要修复",1,true) or label:find("冲突",1,true) then
        return label=="需要修复" and "同步需修复" or "同步失败",true
    end
    if label:find("正在",1,true) or label:find("上传中",1,true) or label:find("确认",1,true) then
        return "同步中",false
    end
    if label:find("关闭",1,true) then return "同步关闭",false end
    if label:find("未登录",1,true) then return "同步未登录",true end
    if label:find("等待",1,true) or label:find("暂不处理",1,true) then return "同步待处理",false end
    if label=="已同步" or label=="已上传并确认" or label=="已采用云端位置" or label=="使用本机位置" then
        return "同步完成",false
    end
    return "同步已开启",false
end

function Plugin:_reader_battery_label()
    local state=HomeData.cached_device_state() or {}
    local value=tonumber(state.battery)
    if not value then return "" end
    return tostring(math.max(0,math.min(100,math.floor(value+.5)))).."%"
end

function Plugin:_reader_toolbar_header(title)
    local started=os.clock()
    local device_started=os.clock()
    local wifi_label,wifi_alert=self:_reader_wifi_summary()
    local wifi_text=wifi_label
    if wifi_label=="Wi-Fi关" then wifi_text="已关闭"
    elseif wifi_label=="Wi-Fi!" then wifi_text="未连接"
    elseif wifi_label=="Wi-Fi" then wifi_text="状态未知" end
    local battery=self:_reader_battery_label()
    local device_ms=math.floor((os.clock()-device_started)*1000+.5)

    local state_started=os.clock()
    local sync_text,sync_alert=self:_reader_sync_summary()
    local cache=self:_reader_toolbar_cache()
    local page,total=tonumber(cache.page),tonumber(cache.total)
    local chapter=U.trim(tostring(cache.chapter or ""))
    if chapter=="" then chapter="当前章节" end
    local progress_text=""
    if page and total and total>0 then
        progress_text=tostring(math.floor(page+.5)).." / "..tostring(math.floor(total+.5))
    else
        local percent=self:_reader_toolbar_cached_percent()
        progress_text=percent and (tostring(math.floor(percent+.5)).."%") or "阅读进度"
    end
    local state_ms=math.floor((os.clock()-state_started)*1000+.5)
    self._reader_toolbar_header_perf={
        device_ms=device_ms,
        state_ms=state_ms,
        chapter_cached=chapter~="当前章节" or tostring(cache.chapter or "")~="",
        cache_age=math.max(0,os.time()-(tonumber(cache.updated_at) or os.time())),
        total_ms=math.floor((os.clock()-started)*1000+.5),
    }
    return {
        title=tostring(title or "正在阅读"),
        home_label="首页",
        home_callback=function() return self:return_to_miuread_home("reader surface") end,
        book_callback=function() return self:_show_reader_current_book_panel(function() self:show_reader_quick_panel() end) end,
        wifi_label=wifi_text,wifi_alert=wifi_alert,
        wifi_callback=function() return self:_show_reader_wifi_quick_panel(function() self:show_reader_quick_panel() end) end,
        wifi_hold_callback=function() return self:_reader_wifi_settings(function() self:show_reader_quick_panel() end) end,
        sync_label=sync_text,sync_alert=sync_alert,
        sync_callback=function() return self:_show_reader_sync_panel(function() self:show_reader_quick_panel() end) end,
        battery_label=battery,
        more_label="更多",
        more_callback=function() return self:show_reader_control_center("reading") end,
        chapter_label=chapter,
        chapter_callback=function() return self:_show_reader_toc(function() self:show_reader_quick_panel() end) end,
        progress_label=progress_text,
        progress_callback=function() return self:_show_reader_progress_control(function() self:show_reader_quick_panel() end) end,
    }
end

function Plugin:_reader_record_recent_action() return false end

function Plugin:_reader_night_enabled()
    local enabled=false
    if G_reader_settings and type(G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(G_reader_settings.readSetting,G_reader_settings,"night_mode")
        if ok then enabled=value==true end
    end
    return enabled
end

function Plugin:_reader_night_label()
    return self:_reader_night_enabled() and "已开启" or "已关闭"
end

function Plugin:_reader_rotation_label()
    local screen=Device.screen
    local mode=screen and screen:getRotationMode() or nil
    if mode==screen.DEVICE_ROTATED_CLOCKWISE then return "向右横屏" end
    if mode==screen.DEVICE_ROTATED_UPSIDE_DOWN then return "倒置" end
    if mode==screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then return "向左横屏" end
    return "竖屏"
end

function Plugin:_reader_status_bar_label()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        if footer.disabled~=nil then return footer.disabled and "已关闭" or "已开启" end
        if footer.visible~=nil then return footer.visible and "已开启" or "已关闭" end
    end
    return "点击切换"
end

function Plugin:_reader_toggle_status_bar()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        for _,method in ipairs({"onToggleFooter","toggleFooter","onToggleVisibility"}) do
            if type(footer[method])=="function" then
                local ok=pcall(footer[method],footer)
                if ok then return true end
            end
        end
    end
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("ToggleFooter"))
        return true
    end
    self:info("当前 KOReader 版本暂时无法直接切换状态栏")
    return false
end

function Plugin:_reader_open_footer_settings()
    local ui=self.ui
    local footer=ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
    if footer then
        for _,method in ipairs({"onShowFooterMenu","onShowFooterSettings","showSettings"}) do
            if type(footer[method])=="function" then
                local ok=pcall(footer[method],footer)
                if ok then return true end
            end
        end
    end
    self:info("当前 KOReader 版本暂时无法直接打开状态栏设置")
    return false
end

function Plugin:_reader_menu_rows_from_table(source,title,back_callback)
    local rows={}
    for _,item in ipairs(type(source)=="table" and source or {}) do
        if type(item)=="table" then
            local visible=true
            if type(item.show_func)=="function" then
                local ok,value=pcall(item.show_func)
                visible=ok and value~=false
            end
            if visible then
                local label=item.text
                if type(item.text_func)=="function" then
                    local ok,value=pcall(item.text_func)
                    if ok then label=value end
                end
                label=U.trim(tostring(label or ""))
                if label~="" then
                    local value=item.post_text
                    if type(item.post_text_func)=="function" then
                        local ok,result=pcall(item.post_text_func)
                        if ok then value=result end
                    end
                    local checked=false
                    if type(item.checked_func)=="function" then
                        local ok,result=pcall(item.checked_func)
                        checked=ok and result==true
                    elseif item.checked==true then checked=true end
                    local enabled=item.enabled~=false
                    if type(item.enabled_func)=="function" then
                        local ok,result=pcall(item.enabled_func)
                        enabled=ok and result~=false
                    end
                    local submenu=item.sub_item_table
                    if type(item.sub_item_table_func)=="function" then
                        local ok,result=pcall(item.sub_item_table_func)
                        if ok then submenu=result end
                    end
                    local row={
                        label=label,
                        value=checked and ((value and tostring(value)~="") and (tostring(value).." · ✓") or "✓") or tostring(value or ""),
                        checked=checked, enabled=enabled,
                        keep_open=item.keep_menu_open==true,
                    }
                    if type(submenu)=="table" then
                        row.callback=function()
                            self:_show_reader_menu_table(label,submenu,function()
                                self:_show_reader_menu_table(title,source,back_callback)
                            end)
                        end
                    elseif type(item.callback)=="function" then
                        row.callback=item.callback
                    else
                        row.arrow=false
                    end
                    rows[#rows+1]=row
                end
            end
        end
    end
    return rows
end

function Plugin:_show_reader_menu_table(title,source,back_callback)
    ReaderListDialog.show{
        title=tostring(title or "阅读设置"),
        items=function() return self:_reader_menu_rows_from_table(source,title,back_callback) end,
        page_size=tonumber(type(source)=="table" and source.max_per_page) or 6,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_reader_annotation_type(item)
    return LocalAnnotationDatabase.annotation_kind(item)
end

function Plugin:_reader_annotation_xpointer(item)
    if type(item)~="table" then return nil end
    local xp=item.pos0 or item.start or item.xpointer
    if (xp==nil or xp=="") and type(item.page)=="string" and tonumber(item.page)==nil then
        xp=item.page
    end
    if type(xp)=="string" and xp~="" then return xp end
    return nil
end

function Plugin:_reader_annotation_page(item)
    if type(item)~="table" then return nil end
    local page=tonumber(item.page or item.pageno)
    if page then return math.floor(page+.5) end
    local xp=self:_reader_annotation_xpointer(item)
    local doc=self.ui and self.ui.document or nil
    if xp and doc and type(doc.getPageFromXPointer)=="function" then
        local ok,value=pcall(doc.getPageFromXPointer,doc,xp)
        if ok and tonumber(value) then return math.floor(tonumber(value)+.5) end
    end
    return nil
end

local function annotation_doc_text(doc, first_xp, last_xp)
    if not (doc and type(doc.getTextFromXPointers)=="function") then return "" end
    if type(first_xp)~="string" or first_xp=="" or type(last_xp)~="string" or last_xp=="" then return "" end
    local ok,text=pcall(doc.getTextFromXPointers,doc,first_xp,last_xp,false)
    if not ok then return "" end
    if type(text)=="table" then text=text.text or text[1] end
    return tostring(text or "")
end

function Plugin:_reader_annotation_selection_context(item,kind)
    if type(item)~="table" or (kind~="highlight" and kind~="thought") then
        return "", "", ""
    end
    local doc=self.ui and self.ui.document or nil
    local pos0=type(item.pos0)=="string" and item.pos0 or (type(item.start)=="string" and item.start or nil)
    local pos1=type(item.pos1)=="string" and item.pos1 or (type(item["end"])=="string" and item["end"] or nil)
    local selected=U.trim(tostring(item.text or item.notes or ""))

    -- Prefer the actual CREngine selection over the list label. This preserves
    -- the text the XPointer really covers when KOReader normalized the display.
    if doc and pos0 and pos1 then
        local extracted=U.trim(annotation_doc_text(doc,pos0,pos1))
        if extracted~="" then selected=extracted end
    end

    local before,after="",""
    if not (doc and pos0 and pos1) then return selected,before,after end

    -- Context is captured only for a manual sync. It is intentionally bounded:
    -- enough to distinguish repeated quotes without doing heavy work while the
    -- user is creating the annotation.
    local before_xp=pos0
    if type(doc.getPrevVisibleWordStart)=="function" then
        for _=1,12 do
            local ok,next_xp=pcall(doc.getPrevVisibleWordStart,doc,before_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==before_xp then break end
            before_xp=next_xp
        end
    elseif type(doc.getPrevVisibleChar)=="function" then
        for _=1,48 do
            local ok,next_xp=pcall(doc.getPrevVisibleChar,doc,before_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==before_xp then break end
            before_xp=next_xp
        end
    end
    local raw_before=annotation_doc_text(doc,before_xp,pos0)
    local before_len=U.utf8_len(raw_before)
    if before_len>0 then before=U.utf8_sub(raw_before,math.max(1,before_len-63),before_len) end

    local after_xp=pos1
    if type(doc.getNextVisibleWordEnd)=="function" then
        for _=1,12 do
            local ok,next_xp=pcall(doc.getNextVisibleWordEnd,doc,after_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==after_xp then break end
            after_xp=next_xp
        end
    elseif type(doc.getNextVisibleChar)=="function" then
        for _=1,48 do
            local ok,next_xp=pcall(doc.getNextVisibleChar,doc,after_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==after_xp then break end
            after_xp=next_xp
        end
    end
    local raw_after=annotation_doc_text(doc,pos1,after_xp)
    if raw_after~="" then after=U.utf8_sub(raw_after,1,64) end
    return selected,before,after
end

function Plugin:_reader_bookmark_anchor_text(item)
    local doc=self.ui and self.ui.document or nil
    local xp=self:_reader_annotation_xpointer(item)
    if not (doc and xp and type(doc.getTextFromXPointers)=="function") then return "" end
    if type(doc.isXPointerInDocument)=="function" then
        local ok,valid=pcall(doc.isXPointerInDocument,doc,xp)
        if ok and valid==false then return "" end
    end

    -- KOReader rolling bookmarks store the page XPointer itself. Build a short
    -- text anchor starting exactly at that XPointer, rather than using the
    -- bookmark list label (which is usually only the chapter name).
    local end_xp=xp
    local steps=0
    if type(doc.getNextVisibleWordEnd)=="function" then
        for _=1,24 do
            local ok,next_xp=pcall(doc.getNextVisibleWordEnd,doc,end_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==end_xp then break end
            end_xp=next_xp
            steps=steps+1
        end
    end
    if steps==0 and type(doc.getNextVisibleChar)=="function" then
        for _=1,32 do
            local ok,next_xp=pcall(doc.getNextVisibleChar,doc,end_xp)
            if not ok or type(next_xp)~="string" or next_xp=="" or next_xp==end_xp then break end
            end_xp=next_xp
            steps=steps+1
        end
    end
    if steps==0 then return "" end

    local ok,text=pcall(doc.getTextFromXPointers,doc,xp,end_xp,false)
    if not ok then return "" end
    if type(text)=="table" then text=text.text or text[1] end
    text=U.trim(tostring(text or ""):gsub("%s+"," "))
    if text=="" then return "" end
    return U.utf8_truncate(text,96)
end

function Plugin:_reader_annotation_excerpt(item,kind)
    if type(item)~="table" then return "" end
    local text
    if kind=="thought" then text=item.note or item.text or item.notes
    elseif kind=="highlight" then text=item.text or item.notes
    else text=item.text end
    text=U.trim(tostring(text or ""):gsub("%s+"," "))
    if text=="" and kind=="bookmark" then text="书页书签" end
    text=U.utf8_truncate(text,120)
    return text
end

function Plugin:_reader_goto_annotation(item)
    local bookmark=self.ui and self.ui.bookmark or nil
    if bookmark and type(bookmark.gotoBookmark)=="function" then
        local primary=item and (item.page or item.pos0 or item.start or item.xpointer) or nil
        local marker=item and (item.pos0 or item.start or item.xpointer) or nil
        local ok,result=pcall(bookmark.gotoBookmark,bookmark,primary,marker)
        if ok and result~=false then return true end
    end
    local ui=self.ui
    local target=item and (item.pos0 or item.start or item.xpointer)
    if ui and type(ui.handleEvent)=="function" then
        if type(target)=="string" and target~="" then ui:handleEvent(Event:new("GotoXPointer",target)); return true end
        local page=self:_reader_annotation_page(item)
        if page then ui:handleEvent(Event:new("GotoPage",page)); return true end
    end
    self:info("当前记录暂时无法定位")
    return false
end

function Plugin:_reader_record_rows(kind)
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    local rows={}
    for _,item in ipairs(type(annotations)=="table" and annotations or {}) do
        if self:_reader_annotation_type(item)==kind then
            local page=self:_reader_annotation_page(item)
            local excerpt=self:_reader_annotation_excerpt(item,kind)
            local target=item
            rows[#rows+1]={
                label=excerpt~="" and excerpt or (kind=="bookmark" and "书页书签" or "无文字内容"),
                value=page and ("第 "..tostring(page).." 页") or "",
                detail=tostring(item.datetime or item.date or ""),
                callback=function() self:_reader_goto_annotation(target) end,
            }
        end
    end
    return rows
end

function Plugin:_reader_annotation_counts()
    local annotations=(self.ui and self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui and self.ui.bookmark and self.ui.bookmark.bookmarks) or {}
    local counts={bookmark=0,highlight=0,thought=0,total=0}
    for _,item in ipairs(type(annotations)=="table" and annotations or {}) do
        local kind=self:_reader_annotation_type(item)
        if counts[kind]~=nil then
            counts[kind]=counts[kind]+1
            counts.total=counts.total+1
        end
    end
    return counts
end

function Plugin:_reader_annotation_summary_label()
    local counts=self:_reader_annotation_counts()
    if (counts.total or 0)<=0 then return "暂无批注" end
    return string.format("书签 %d · 划线 %d · 想法 %d",
        tonumber(counts.bookmark or 0),tonumber(counts.highlight or 0),tonumber(counts.thought or 0))
end

function Plugin:_enable_annotation_sync_and_sync_current()
    -- Compatibility shim for older callbacks. Manual sync is an explicit
    -- command and no longer changes a persistent enable/disable switch.
    UIManager:scheduleIn(.08,function()
        if self.ui and self.ui.document then self:sync_local_annotations_now() end
    end)
    return true
end

function Plugin:_show_reader_annotation_panel(back_callback)
    if not (self.ui and self.ui.document) then return false end
    -- Refresh only the local mirror when the user explicitly opens this panel.
    -- No network/range work runs during a normal highlight gesture or page turn.
    self:_capture_local_annotation_snapshot("annotation_panel")
    local current=(self.sync and self.sync:record()) or self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    local summary=book_id~="" and LocalAnnotationDatabase.summary(self.store,book_id) or nil
    summary=type(summary)=="table" and summary or {
        total=0,bookmark=0,highlight=0,thought=0,pending=0,synced=0,
        delete_pending=0,locate_failed=0,metadata_failed=0,coord_failed=0,unknown=0,legacy_synced=0,
    }
    local title=current and current.book and U.trim(tostring(current.book.title or "")) or ""
    if title=="" then title="当前书籍" end
    local function return_to_panel() self:_show_reader_annotation_panel(back_callback) end
    local visible_counts=self:_reader_annotation_counts()
    local pending_upload=tonumber(summary.pending or 0) or 0
    local pending_delete=tonumber(summary.delete_pending or 0) or 0
    local pending_work=pending_upload+pending_delete
    local failed=(tonumber(summary.locate_failed or 0) or 0)+(tonumber(summary.metadata_failed or 0) or 0)
        +(tonumber(summary.coord_failed or 0) or 0)+(tonumber(summary.unknown or 0) or 0)
    local legacy_synced=tonumber(summary.legacy_synced or 0) or 0
    ReaderSettingsDialog.show{
        title="批注",
        subtitle=U.utf8_truncate(title,42,"…").." · 书签 划线 想法统一管理",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            return {
                {title="本书批注",rows={
                    {icon="bookmark",label="书签",value=tostring(visible_counts.bookmark or 0),callback=function() self:_show_reader_records("bookmark",return_to_panel) end},
                    {icon="highlight",label="划线",value=tostring(visible_counts.highlight or 0),callback=function() self:_show_reader_records("highlight",return_to_panel) end},
                    {icon="thought",label="想法",value=tostring(visible_counts.thought or 0),callback=function() self:_show_reader_records("thought",return_to_panel) end},
                }},
                self:annotation_sync_diagnostic_only() and {title="批注坐标诊断 · beta.11",rows={
                    {icon="warning",label="云端批注写入",value="已暂停 · 防止错误 range",value_bold=true,enabled=false},
                    {icon="diagnostics",label="生成本书坐标诊断",value="导出 raw / coord / range",value_bold=true,callback=function()
                        self:sync_local_annotations_now()
                    end},
                    {label="诊断内容",value="含已同步与待同步本地批注",enabled=false},
                    {label="文件位置",value="books/<bookId>/annotation-coordinate-diagnostics",enabled=false},
                }} or {title="微信读书同步 · 手动",rows={
                    {icon="upload",label="立即同步本书批注",value="上传 删除 云端对账",value_bold=true,callback=function()
                        self:sync_local_annotations_now()
                    end},
                    {icon="sync",label="待处理",value=pending_work>0
                        and string.format("共 %d · 上传重试 %d · 删除 %d",pending_work,pending_upload,pending_delete)
                        or "0 · 仍可手动对账",enabled=false},
                    {label="同步详情",value=legacy_synced>0
                        and string.format("已同步 %d · 旧坐标 %d",tonumber(summary.synced or 0) or 0,legacy_synced)
                        or string.format("已同步 %d · 失败 %d",tonumber(summary.synced or 0) or 0,failed),
                        callback=function() self:show_local_annotation_sync_status() end},
                    {label="自动上传",value="暂未开启 · 先完成真机验证",enabled=false},
                    {icon="diagnostics",label="坐标诊断",value="导出 raw / coord / range",callback=function()
                        self:sync_local_annotations_now(true)
                    end},
                    {label="新想法可见范围",value=self:annotation_sync_visibility_label(),callback=function()
                        self:_show_reader_menu_table("新想法可见范围",self:annotation_sync_visibility_menu(),return_to_panel)
                    end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_records(initial_kind,back_callback)
    local labels={bookmark="书签",highlight="划线",thought="想法"}
    ReaderListDialog.show{
        title="阅读记录",
        initial_category=labels[initial_kind] and initial_kind or "bookmark",
        categories=function()
            return {
                {key="bookmark",label="书签",items=self:_reader_record_rows("bookmark"),empty_text="当前书籍还没有书签"},
                {key="highlight",label="划线",items=self:_reader_record_rows("highlight"),empty_text="当前书籍还没有划线"},
                {key="thought",label="想法",items=self:_reader_record_rows("thought"),empty_text="当前书籍还没有自己的想法"},
            }
        end,
        page_size=5,
        on_back=back_callback or (self:_home_enabled() and function() self:show_reader_quick_panel() end or function() self:_show_koreader_reader_menu() end),
        on_home=self:_home_enabled() and function() return self:return_to_miuread_home("reader surface") end or nil,
    }
    return true
end

function Plugin:_reader_show_bookmarks(back_callback)
    return self:_show_reader_records("bookmark",back_callback)
end

function Plugin:_reader_search_results(query,results,back_callback)
    local rows={}
    for _,item in ipairs(type(results)=="table" and results or {}) do
        local excerpt=table.concat({
            tostring(item.prev_text or ""), tostring(item.matched_word_prefix or ""),
            tostring(item.matched_text or ""), tostring(item.matched_word_suffix or ""),
            tostring(item.next_text or ""),
        },"")
        excerpt=U.trim(excerpt:gsub("%s+"," "))
        if excerpt=="" then excerpt="匹配结果" end
        excerpt=U.utf8_truncate(excerpt,150)
        local start_pos=item.start
        local page
        local doc=self.ui and self.ui.document or nil
        if tonumber(start_pos) then page=math.floor(tonumber(start_pos)+.5)
        elseif start_pos and doc and type(doc.getPageFromXPointer)=="function" then
            local ok,value=pcall(doc.getPageFromXPointer,doc,start_pos)
            if ok and tonumber(value) then page=math.floor(tonumber(value)+.5) end
        end
        local target=start_pos
        rows[#rows+1]={label=excerpt,value=page and ("第 "..page.." 页") or "",callback=function()
            local link=self.ui and self.ui.link or nil
            if link and type(link.addCurrentLocationToStack)=="function" then pcall(link.addCurrentLocationToStack,link) end
            local ui=self.ui
            if ui and type(ui.handleEvent)=="function" then
                if type(target)=="string" then ui:handleEvent(Event:new("GotoXPointer",target))
                elseif tonumber(target) then ui:handleEvent(Event:new("GotoPage",tonumber(target))) end
            end
        end}
    end
    ReaderListDialog.show{
        title="搜索结果",
        subtitle="“"..tostring(query).."” · "..tostring(#rows).." 处",
        items=rows,page_size=5,
        empty_text="没有找到匹配内容",
        on_back=function() self:_reader_show_search(back_callback) end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    return true
end

function Plugin:_reader_run_search(query,back_callback)
    local doc=self.ui and self.ui.document or nil
    if not doc or type(doc.findAllText)~="function" then
        self:info("当前书籍暂不支持全文搜索")
        if back_callback then UIManager:scheduleIn(.05,back_callback) end
        return false
    end
    local results
    local search=self.ui and self.ui.search or nil
    local context=tonumber(search and search.findall_nb_context_words) or 6
    local maximum=tonumber(search and search.findall_max_hits) or 100
    local flags=search and search.current_search_type and search.current_search_type.flags or nil
    local ok,value=pcall(doc.findAllText,doc,query,true,context,maximum,false,flags)
    if not ok then ok,value=pcall(doc.findAllText,doc,query,true,context,maximum) end
    if ok and type(value)=="table" then results=value else results={} end
    return self:_reader_search_results(query,results,back_callback)
end

function Plugin:_reader_show_search(back_callback)
    local dialog
    dialog=InputDialog:new{
        title="书内搜索",
        description="搜索当前书籍正文",
        input=tostring(self._reader_last_search or ""),
        buttons={{
            {text="取消",id="close",callback=function()
                UIManager:close(dialog)
                if back_callback then UIManager:scheduleIn(.05,back_callback) end
            end},
            {text="搜索",is_enter_default=true,callback=function()
                local query=U.trim(dialog:getInputText())
                UIManager:close(dialog)
                if query=="" then
                    if back_callback then UIManager:scheduleIn(.05,back_callback) end
                    return
                end
                self._reader_last_search=query
                self:status_toast("书内搜索","正在查找“"..query.."”",2)
                UIManager:nextTick(function() self:_reader_run_search(query,back_callback) end)
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function Plugin:_reader_go_back_location()
    local link=self.ui and self.ui.link or nil
    if link then
        for _,method in ipairs({"onGoBackLink","onGoBack","goBack"}) do
            if type(link[method])=="function" then
                local ok=pcall(link[method],link)
                if ok then return true end
            end
        end
    end
    local ui=self.ui
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("GoBackLink"))
        return true
    end
    return false
end

function Plugin:_reader_show_history(back_callback)
    local link=self.ui and self.ui.link or nil
    if not link then self:info("当前 KOReader 版本暂时无法直接打开阅读历史"); return false end
    return self:_reader_open_native_page("阅读历史",function()
        for _,method in ipairs({"onShowLinkHistory","onShowHistory","showHistory"}) do
            if type(link[method])=="function" then
                local ok=pcall(link[method],link)
                if ok then return true end
            end
        end
        return false
    end,back_callback or function() self:show_reader_quick_panel() end)
end
function Plugin:_show_reader_font_panel(back_callback)
    local return_to_font=function() self:_show_reader_font_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="字体",
        subtitle=function() return self:_reader_font_label().." · 字号 "..self:_reader_font_size_label() end,
        hero=function()
            return {
                value=self:_reader_font_size_label(),
                on_decrease=function() self:_reader_adjust_font_size(-1) end,
                on_increase=function() self:_reader_adjust_font_size(1) end,
            }
        end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            return {
                {title="字体",rows={
                    {label="正文字体",value=self:_reader_font_label(),callback=function() self:_show_reader_font_face_menu(return_to_font) end},
                    {label="字体粗细",value=self:_reader_font_weight_label(),callback=function() self:_show_reader_weight_panel(return_to_font) end},
                }},
                {title="更多",rows={
                    {label="高级排版",value="版式与字符间距",callback=function() self:_show_reader_advanced_typeset_panel(return_to_font) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_sync_diagnostics_panel(back_callback)
    local diagnostics=self:sync_diagnostics_menu()
    local current=self.sync and self.sync:record() or nil
    local logged_in=self.auth and type(self.auth.is_logged_in)=="function" and self.auth:is_logged_in() or nil
    ReaderSettingsDialog.show{
        title="同步诊断",
        subtitle="所有检查都在觅阅页面内完成",
        on_back=back_callback or function() self:_show_reader_sync_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local state=tostring(self:progress_sync_label() or "")
            return {
                {title="当前状态",rows={
                    {label="当前书籍识别",value=current and current.book and "正常" or "未识别",callback=diagnostics[1] and diagnostics[1].callback},
                    {label="登录状态",value=logged_in==false and "未登录" or "检查",callback=diagnostics[2] and diagnostics[2].callback},
                    {label="云端进度读取",value=state~="" and state or "检查",callback=diagnostics[3] and diagnostics[3].callback},
                    {label="当前进度上传",value="测试",callback=diagnostics[4] and diagnostics[4].callback},
                    {label="阅读时间上传",value="测试 30 秒",callback=diagnostics[5] and diagnostics[5].callback},
                }},
                {title="恢复",rows={
                    {label="重置当前书籍同步状态",value="不删除书籍与阅读数据",callback=diagnostics[7] and diagnostics[7].callback},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_sync_panel(back_callback)
    local return_to_sync=function() self:_show_reader_sync_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="阅读同步",
        subtitle=function() return "当前状态："..tostring(self:progress_sync_label()) end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local sync=self.store:preferences().sync or {}
            return {
                {title="当前状态",rows={
                    {label="同步状态",value=self:progress_sync_label(),value_bold=true,arrow=false},
                }},
                {title="立即操作",rows={
                    {icon="upload",label="上传当前进度",value="执行",callback=function() self:upload_local_progress(true) end},
                    {icon="download",label="读取云端进度",value="执行",callback=function() self:manual_sync() end},
                    {icon="repair",label="修复当前书籍同步",value="执行",callback=function() self:repair_current_sync() end},
                }},
                {title="自动同步",rows={
                    {label="阅读进度",value=sync.progress_enabled~=false and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:toggle_progress_sync() end},
                    {label="阅读时间",value=sync.time_enabled==true and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:toggle_time_sync() end},
                    {label="成功提醒",value=self:_sync_success_notice_enabled() and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:toggle_sync_success_notice() end},
                }},
                {title="诊断",rows={
                    {icon="diagnostics",label="同步诊断",value="检查与修复",callback=function() self:_show_reader_sync_diagnostics_panel(return_to_sync) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_current_book_panel(back_callback)
    return self:_show_reader_menu_table("当前书籍",self:current_book_menu(),back_callback)
end
function Plugin:_show_koreader_reader_menu(back_callback)
    local current_ui=self.ui
    if not (current_ui and current_ui.document) then return false end
    if self._reader_native_menu_opening then return true end
    self._reader_native_menu_opening=true
    return self:_reader_open_native_page("KOReader 高级菜单",function()
        local ui=self.ui
        local menu=ui and ui.menu or nil
        if not (ui and ui.document) then self._reader_native_menu_opening=false; return false end
        local ok,err=xpcall(function()
            if menu and type(menu.onShowMenu)=="function" then menu:onShowMenu()
            else ui:handleEvent(Event:new("ShowMenu")) end
        end,debug.traceback)
        self._reader_native_menu_opening=false
        if not ok then
            logger.warn("[MiuRead][Reader] native menu open failed",tostring(err))
            self:info("KOReader 菜单暂时无法打开")
            return false
        end
        return true
    end,back_callback or function() self:show_reader_quick_panel(true) end)
end
function Plugin:_reader_power_device()
    if not Device:hasFrontlight() or type(Device.getPowerDevice)~="function" then return nil end
    local ok,powerd=pcall(Device.getPowerDevice,Device)
    if ok then return powerd end
    return nil
end

function Plugin:_reader_frontlight_value()
    local powerd=self:_reader_power_device()
    if not powerd then return nil end
    local current
    if type(powerd.frontlightIntensity)=="function" then
        local ok,value=pcall(powerd.frontlightIntensity,powerd)
        if ok then current=tonumber(value) end
    end
    return current or tonumber(powerd.fl_intensity or powerd.hw_intensity) or tonumber(powerd.fl_min) or 0
end

function Plugin:_reader_frontlight_bounds()
    local powerd=self:_reader_power_device()
    if not powerd then return 0,100 end
    local minimum=tonumber(powerd.fl_min) or 0
    local maximum=tonumber(powerd.fl_max) or 100
    if maximum<=minimum then maximum=minimum+100 end
    return minimum,maximum
end

function Plugin:_reader_frontlight_enabled()
    local minimum=self:_reader_frontlight_bounds()
    return (self:_reader_frontlight_value() or minimum)>minimum
end

function Plugin:_reader_set_frontlight(value)
    local powerd=self:_reader_power_device()
    if not powerd then self:info("当前设备没有可调前光"); return false end
    local minimum,maximum=self:_reader_frontlight_bounds()
    local target=math.max(minimum,math.min(maximum,math.floor((tonumber(value) or minimum)+.5)))
    local current=self:_reader_frontlight_value() or minimum
    local ok=false
    if target<=minimum then
        if current>minimum then
            self._miuread_last_frontlight=current
            if type(powerd.turnOffFrontlight)=="function" then ok=pcall(powerd.turnOffFrontlight,powerd)
            elseif type(powerd.toggleFrontlight)=="function" then ok=pcall(powerd.toggleFrontlight,powerd)
            elseif type(powerd.setIntensity)=="function" then ok=pcall(powerd.setIntensity,powerd,minimum) end
        else
            ok=true
        end
    elseif type(powerd.setIntensity)=="function" then
        ok=pcall(powerd.setIntensity,powerd,target)
    elseif type(powerd.turnOnFrontlight)=="function" then
        ok=pcall(powerd.turnOnFrontlight,powerd)
    end
    if type(powerd.updateResumeFrontlightState)=="function" then pcall(powerd.updateResumeFrontlightState,powerd) end
    if ok then
        local actual=self:_reader_frontlight_value() or target
        if actual>minimum then self._miuread_last_frontlight=actual end
        if UIManager and type(UIManager.broadcastEvent)=="function" then
            pcall(UIManager.broadcastEvent,UIManager,Event:new("FrontlightStateChanged"))
        end
    else
        self:info("当前设备暂时无法直接调整前光")
    end
    return ok
end

function Plugin:_reader_toggle_frontlight()
    local minimum,maximum=self:_reader_frontlight_bounds()
    local current=self:_reader_frontlight_value() or minimum
    if current>minimum then
        self._miuread_last_frontlight=current
        return self:_reader_set_frontlight(minimum)
    end
    local fallback=math.min(maximum,minimum+math.max(1,math.ceil((maximum-minimum)/10)))
    local target=tonumber(self._miuread_last_frontlight) or fallback
    target=math.max(minimum+1,math.min(maximum,target))
    return self:_reader_set_frontlight(target)
end

function Plugin:_reader_adjust_frontlight(delta)
    local minimum,maximum=self:_reader_frontlight_bounds()
    local current=self:_reader_frontlight_value() or minimum
    local stride=math.max(1,math.ceil((maximum-minimum+1)/25))
    return self:_reader_set_frontlight(current+(tonumber(delta) or 0)*stride)
end

function Plugin:_reader_warmth_state()
    local powerd=self:_reader_power_device()
    local has_natural=type(Device.hasNaturalLight)=="function" and Device:hasNaturalLight()
    if not (powerd and has_natural) then return nil end
    local minimum=tonumber(powerd.fl_warmth_min) or 0
    local maximum=tonumber(powerd.fl_warmth_max) or 100
    local value
    if type(powerd.frontlightWarmth)=="function" then
        local ok,current=pcall(powerd.frontlightWarmth,powerd)
        if ok then value=tonumber(current) end
    end
    value=value or tonumber(powerd.fl_warmth) or minimum
    if type(powerd.toNativeWarmth)=="function" then
        local ok,native=pcall(powerd.toNativeWarmth,powerd,value)
        if ok and tonumber(native) then value=tonumber(native) end
    end
    value=math.max(minimum,math.min(maximum,value))
    return {min=minimum,max=maximum,value=value}
end

function Plugin:_reader_set_warmth(value)
    local powerd=self:_reader_power_device()
    local state=self:_reader_warmth_state()
    if not (powerd and state and type(powerd.setWarmth)=="function") then return false end
    local target=math.max(state.min,math.min(state.max,math.floor((tonumber(value) or state.value)+.5)))
    local device_value=target
    if type(powerd.fromNativeWarmth)=="function" then
        local ok,converted=pcall(powerd.fromNativeWarmth,powerd,target)
        if ok and tonumber(converted) then device_value=tonumber(converted) end
    end
    local ok=pcall(powerd.setWarmth,powerd,device_value)
    if ok and UIManager and type(UIManager.broadcastEvent)=="function" then
        pcall(UIManager.broadcastEvent,UIManager,Event:new("FrontlightStateChanged"))
    end
    return ok
end

function Plugin:_reader_adjust_warmth(delta)
    local state=self:_reader_warmth_state()
    if not state then return false end
    local stride=math.max(1,math.ceil((state.max-state.min+1)/25))
    return self:_reader_set_warmth(state.value+(tonumber(delta) or 0)*stride)
end

function Plugin:_show_frontlight_panel(options)
    options=type(options)=="table" and options or {}
    if not Device:hasFrontlight() then self:info("当前设备没有前光"); return false end
    local minimum,maximum=self:_reader_frontlight_bounds()
    local warmth=self:_reader_warmth_state()
    local dialog,err=ReaderFrontlightDialog.show{
        title="前光",
        placement=options.placement or "top",
        toggle=function()
            local enabled=self:_reader_frontlight_enabled()
            return {
                label="前光",
                value=enabled and "开" or "关",
                selected=enabled,
                callback=function() self:_reader_toggle_frontlight() end,
            }
        end,
        brightness=function()
            return {
                label="亮度",
                min=minimum,
                max=maximum,
                value=self:_reader_frontlight_value() or minimum,
                on_decrease=function() self:_reader_adjust_frontlight(-1) end,
                on_increase=function() self:_reader_adjust_frontlight(1) end,
                on_set=function(value)
                    if not self:_reader_set_frontlight(value) then return false end
                    return self:_reader_frontlight_value() or value
                end,
            }
        end,
        warmth=warmth and function()
            local current=self:_reader_warmth_state() or warmth
            return {
                label="色温",
                min=current.min,
                max=current.max,
                value=current.value,
                on_decrease=function() self:_reader_adjust_warmth(-1) end,
                on_increase=function() self:_reader_adjust_warmth(1) end,
                on_set=function(value)
                    if not self:_reader_set_warmth(value) then return false end
                    local state=self:_reader_warmth_state()
                    return state and state.value or value
                end,
            }
        end or nil,
        actions={
            {label="最低",callback=function() self:_reader_set_frontlight(math.min(maximum,minimum+1)) end},
            {
                label=function() return "夜间模式 · "..(self:_reader_night_enabled() and "开" or "关") end,
                selected=function() return self:_reader_night_enabled() end,
                callback=function() self:_home_toggle_night() end,
            },
            {label="最高",callback=function() self:_reader_set_frontlight(maximum) end},
        },
        on_back=options.on_back,
    }
    if not dialog then
        logger.warn("[MiuRead][ReaderFrontlight] custom dialog unavailable",tostring(err or "unknown"))
        return false
    end
    return true
end

function Plugin:_show_reader_frontlight_panel(back_callback)
    return self:_show_frontlight_panel{
        placement="top",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
    }
end

function Plugin:_reader_footer()
    local ui=self.ui
    return ui and ui.view and ui.view.footer or (ui and ui.footer) or nil
end

function Plugin:_reader_footer_setting_label(key,inverted)
    local footer=self:_reader_footer()
    local settings=footer and footer.settings or nil
    if type(settings)~="table" then return "不可用" end
    local enabled=settings[key]==true
    if inverted then enabled=not (settings[key]==true) end
    return enabled and "已开启" or "已关闭"
end

function Plugin:_reader_refresh_footer()
    local footer=self:_reader_footer()
    if footer then
        if type(footer.updateFooterTextGenerator)=="function" then pcall(footer.updateFooterTextGenerator,footer) end
        if type(footer.refreshFooter)=="function" then pcall(footer.refreshFooter,footer,true,true) end
        if type(footer.updateFooter)=="function" then pcall(footer.updateFooter,footer,true) end
        if G_reader_settings and type(G_reader_settings.saveSetting)=="function" and type(footer.settings)=="table" then
            pcall(G_reader_settings.saveSetting,G_reader_settings,"footer",footer.settings)
        end
    end
    if self.ui and type(self.ui.handleEvent)=="function" then
        pcall(self.ui.handleEvent,self.ui,Event:new("UpdateFooter",true,true))
    end
    return true
end

function Plugin:_reader_toggle_footer_setting(key,inverted)
    local footer=self:_reader_footer()
    if not (footer and type(footer.settings)=="table") then
        self:info("当前文档暂时无法直接调整状态栏项目")
        return false
    end
    footer.settings[key]=not (footer.settings[key]==true)
    self:_reader_refresh_footer()
    return true
end

function Plugin:_reader_refresh_rate_label()
    if type(UIManager.getRefreshRate)~="function" then return "系统默认" end
    local ok,rate=pcall(UIManager.getRefreshRate,UIManager)
    rate=ok and tonumber(rate) or nil
    if not rate then return "系统默认" end
    if rate<=1 then return "每页" end
    return "每 "..tostring(math.floor(rate+.5)).." 页"
end

function Plugin:_reader_cycle_refresh_rate()
    if type(UIManager.setRefreshRate)~="function" then
        self:info("当前设备暂时无法直接调整刷新频率")
        return false
    end
    local values={1,6,12,24,48}
    local current
    if type(UIManager.getRefreshRate)=="function" then
        local ok,value=pcall(UIManager.getRefreshRate,UIManager)
        if ok then current=tonumber(value) end
    end
    local target=values[1]
    for index,value in ipairs(values) do
        if current and current<=value then
            target=current<value and value or values[index%#values+1]
            break
        end
    end
    local ok=pcall(UIManager.setRefreshRate,UIManager,target)
    if not ok then self:info("刷新频率调整失败") end
    return ok
end

function Plugin:_show_reader_page_display_panel(back_callback)
    ReaderSettingsDialog.show{
        title="页面显示",
        subtitle="阅读中的常用显示项目",
        on_back=back_callback or function() self:show_reader_quick_panel(true) end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local info_rows={
                {label="状态栏",value=self:_reader_status_bar_label(),value_bold=true,keep_open=true,callback=function() self:_reader_toggle_status_bar() end},
                {label="阅读进度条",value=self:_reader_footer_setting_label("disable_progress_bar",true),keep_open=true,callback=function() self:_reader_toggle_footer_setting("disable_progress_bar",true) end},
                {label="阅读百分比",value=self:_reader_footer_setting_label("percentage"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("percentage") end},
                {label="当前时间",value=self:_reader_footer_setting_label("time"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("time") end},
                {label="剩余时间",value=self:_reader_footer_setting_label("chapter_time_to_read"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("chapter_time_to_read") end},
            }
            local has_battery=type(Device.hasBattery)~="function" or Device:hasBattery()
            if has_battery then
                info_rows[#info_rows+1]={label="电量",value=self:_reader_footer_setting_label("battery"),keep_open=true,callback=function() self:_reader_toggle_footer_setting("battery") end}
            end
            local behavior_rows={
                {label="刷新频率",value=self:_reader_refresh_rate_label(),value_bold=true,keep_open=true,callback=function() self:_reader_cycle_refresh_rate() end},
                {label="全屏刷新",value="立即执行",callback=function() self:_home_full_refresh() end},
                {label="屏幕方向",value=self:_reader_rotation_label(),keep_open=true,callback=function() self:_home_rotate() end},
                {label="夜间模式",value=self:_reader_night_label(),keep_open=true,callback=function() self:_home_toggle_night() end},
            }
            if Device:hasFrontlight() then
                behavior_rows[#behavior_rows+1]={label="前光与色温",value=tostring(math.floor((self:_reader_frontlight_value() or 0)+.5)),callback=function()
                    self:_show_reader_frontlight_panel(function() self:_show_reader_page_display_panel(back_callback) end)
                end}
            end
            return {
                {title="页面信息",rows=info_rows},
                {title="页面行为",rows=behavior_rows},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_page_panel(back_callback)
    local return_to_page=function() self:_show_reader_page_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="页面",
        subtitle="版面, 显示和刷新集中在这里",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="页边距",value=self:_reader_margin_label(),value_bold=true,callback=function() self:_show_reader_margin_panel(return_to_page) end},
                {label="页面显示",value="状态栏与阅读信息",callback=function() self:_show_reader_page_display_panel(return_to_page) end},
                {label="刷新与夜间",value=self:_reader_refresh_rate_label(),callback=function() self:_show_reader_refresh_panel(return_to_page) end},
            }
        end,
    }
    return true
end

function Plugin:_reader_recent_action_definitions()
    return {
        night={icon="☾",label="夜间模式",callback=function() self:_home_toggle_night() end},
        full_refresh={icon="↻",label="页面刷新",callback=function() self:_home_full_refresh() end},
        bookmark={icon="▯",label="书签",callback=function() self:_reader_show_bookmarks(function() self:show_reader_quick_panel() end) end},
        search={icon="⌕",label="全文搜索",callback=function() self:_reader_show_search(function() self:show_reader_quick_panel() end) end},
        frontlight={icon="☼",label="前光",enabled=Device:hasFrontlight(),callback=function() self:_show_reader_frontlight_panel() end},
        page_display={icon="▤",label="页面显示",callback=function() self:_show_reader_page_display_panel() end},
        current_book={icon="□",label="当前书籍",callback=function() self:_show_reader_current_book_panel(function() self:show_reader_quick_panel() end) end},
        downloads={icon="⇩",label="下载管理",callback=function() self:show_downloads(function() self:show_reader_quick_panel() end) end},
        rotation={icon="↻",label="屏幕方向",callback=function() self:_home_rotate() end},
    }
end

function Plugin:_reader_recent_buttons()
    local reader=self:_reader_preferences()
    if reader.show_recent==false then return {} end
    local definitions=self:_reader_recent_action_definitions()
    local keys={}
    for _,key in ipairs(reader.recent_actions or {}) do
        if definitions[key] and definitions[key].enabled~=false then keys[#keys+1]=key end
        if #keys>=3 then break end
    end
    if #keys==0 then keys={"night","full_refresh","bookmark"} end
    local buttons={}
    for _,key in ipairs(keys) do
        local item_key=key
        local source=definitions[item_key]
        if source and source.enabled~=false then
            local action=source.callback
            buttons[#buttons+1]={
                icon=source.icon,
                label=source.label,
                callback=function()
                    self:_reader_record_recent_action(item_key)
                    return action()
                end,
            }
        end
    end
    return buttons
end

function Plugin:_reader_config_value(name)
    local configurable=self.ui and self.ui.document and self.ui.document.configurable or nil
    return configurable and configurable[name] or nil
end

function Plugin:_reader_emit_config(event,value,value2)
    local ui=self.ui
    if not (ui and type(ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    if value2~=nil then ui:handleEvent(Event:new(event,value,value2))
    else ui:handleEvent(Event:new(event,value)) end
    return true
end

function Plugin:_reader_default(name,fallback)
    if G_defaults and type(G_defaults.readSetting)=="function" then
        local ok,value=pcall(G_defaults.readSetting,G_defaults,name)
        if ok and value~=nil then return value end
    end
    return fallback
end

function Plugin:_reader_margin_label()
    local h=self:_reader_config_value("h_page_margins")
    local t=tonumber(self:_reader_config_value("t_page_margin"))
    local b=tonumber(self:_reader_config_value("b_page_margin"))
    local left,right
    if type(h)=="table" then left=tonumber(h[1]); right=tonumber(h[2]) end
    if left and right and t and b then
        return string.format("左右 %d/%d · 上下 %d/%d",left,right,t,b)
    end
    return "使用当前书籍设置"
end

function Plugin:_reader_apply_margin_preset(kind)
    local presets={
        compact={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_SMALL",{5,5}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_SMALL",5),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_SMALL",5)},
        standard={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_MEDIUM",{10,10}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_LARGE",15),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_LARGE",15)},
        wide={h=self:_reader_default("DCREREADER_CONFIG_H_MARGIN_SIZES_XX_LARGE",{30,30}),t=self:_reader_default("DCREREADER_CONFIG_T_MARGIN_SIZES_XX_LARGE",30),b=self:_reader_default("DCREREADER_CONFIG_B_MARGIN_SIZES_XX_LARGE",30)},
    }
    local preset=presets[kind] or presets.standard
    self:_reader_emit_config("SetPageHorizMargins",preset.h)
    self:_reader_emit_config("SetPageTopMargin",preset.t)
    self:_reader_emit_config("SetPageBottomMargin",preset.b)
    return true
end

function Plugin:_reader_adjust_horizontal_margin(delta)
    local h=self:_reader_config_value("h_page_margins")
    local left,right=10,10
    if type(h)=="table" then left=tonumber(h[1]) or left; right=tonumber(h[2]) or right end
    delta=tonumber(delta) or 0
    return self:_reader_emit_config("SetPageHorizMargins",{math.max(0,math.min(140,left+delta)),math.max(0,math.min(140,right+delta))})
end

function Plugin:_reader_adjust_vertical_margin(delta)
    local t=tonumber(self:_reader_config_value("t_page_margin")) or 15
    local b=tonumber(self:_reader_config_value("b_page_margin")) or 15
    delta=tonumber(delta) or 0
    self:_reader_emit_config("SetPageTopMargin",math.max(0,math.min(140,t+delta)))
    self:_reader_emit_config("SetPageBottomMargin",math.max(0,math.min(140,b+delta)))
    return true
end

function Plugin:_show_reader_margin_panel(back_callback)
    local return_here=function() self:_show_reader_margin_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="页边距",
        subtitle=function() return self:_reader_margin_label() end,
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            return {
                {title="常用预设",rows={
                    {label="紧凑",value="更多正文空间",keep_open=true,callback=function() self:_reader_apply_margin_preset("compact") end},
                    {label="标准",value="推荐",value_bold=true,keep_open=true,callback=function() self:_reader_apply_margin_preset("standard") end},
                    {label="宽松",value="更大留白",keep_open=true,callback=function() self:_reader_apply_margin_preset("wide") end},
                }},
                {title="精细调整",rows={
                    {label="左右边距 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_horizontal_margin(-5) end},
                    {label="左右边距 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_horizontal_margin(5) end},
                    {label="上下边距 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_vertical_margin(-5) end},
                    {label="上下边距 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_vertical_margin(5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_reader_word_spacing_value()
    local value=self:_reader_config_value("word_spacing")
    if type(value)=="table" then return tonumber(value[1]) or 100,tonumber(value[2]) or 75 end
    return 100,75
end

function Plugin:_reader_word_spacing_label()
    local scaling,reduction=self:_reader_word_spacing_value()
    return tostring(math.floor(scaling+.5)).."% / "..tostring(math.floor(reduction+.5)).."%"
end

function Plugin:_reader_set_word_spacing(kind)
    local presets={
        small=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_SMALL",{90,75}),
        medium=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_MEDIUM",{100,75}),
        large=self:_reader_default("DCREREADER_CONFIG_WORD_SPACING_LARGE",{110,75}),
    }
    return self:_reader_emit_config("SetWordSpacing",presets[kind] or presets.medium)
end

function Plugin:_reader_adjust_cjk_width(delta)
    local current=tonumber(self:_reader_config_value("cjk_width_scaling")) or 100
    local target=math.max(100,math.min(150,current+(tonumber(delta) or 0)))
    return self:_reader_emit_config("SetCJKWidthScaling",target)
end

function Plugin:_show_reader_word_spacing_panel(back_callback)
    ReaderSettingsDialog.show{
        title="字符间距（高级）",
        subtitle=function() return "空格缩放/压缩 "..self:_reader_word_spacing_label() end,
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local cjk=tonumber(self:_reader_config_value("cjk_width_scaling")) or 100
            return {
                {title="空格",rows={
                    {label="紧凑",value="小",keep_open=true,callback=function() self:_reader_set_word_spacing("small") end},
                    {label="标准",value="推荐",value_bold=true,keep_open=true,callback=function() self:_reader_set_word_spacing("medium") end},
                    {label="宽松",value="大",keep_open=true,callback=function() self:_reader_set_word_spacing("large") end},
                }},
                {title="中文字符宽度",rows={
                    {label="当前宽度",value=tostring(math.floor(cjk+.5)).."%",value_bold=true,arrow=false},
                    {label="字符宽度 -5",value="缩小",keep_open=true,callback=function() self:_reader_adjust_cjk_width(-5) end},
                    {label="字符宽度 +5",value="增大",keep_open=true,callback=function() self:_reader_adjust_cjk_width(5) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_refresh_panel(back_callback)
    ReaderSettingsDialog.show{
        title="刷新与显示",
        subtitle="只保留阅读过程中真正需要的显示控制",
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="刷新频率",value=self:_reader_refresh_rate_label(),value_bold=true,keep_open=true,callback=function() self:_reader_cycle_refresh_rate() end},
                {label="全屏刷新",value="立即执行",callback=function() self:_home_full_refresh() end},
                {label="夜间模式",value=self:_reader_night_label(),keep_open=true,callback=function() self:_home_toggle_night() end},
                {label="页面显示",value="状态栏与阅读信息",callback=function() self:_show_reader_page_display_panel(function() self:_show_reader_refresh_panel(back_callback) end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_advanced_typeset_panel(back_callback)
    ReaderSettingsDialog.show{
        title="高级排版",
        subtitle="常用高级选项仍由觅阅直接提供, 不进入 KOReader 总菜单",
        on_back=back_callback or function() self:show_reader_control_center("typeset") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            local mode=tonumber(self:_reader_config_value("block_rendering_mode")) or 2
            local mode_labels={[0]="兼容",[1]="平面",[2]="书籍",[3]="网页"}
            return {
                {label="渲染模式",value=mode_labels[mode] or tostring(mode),value_bold=true,keep_open=true,callback=function()
                    self:_reader_emit_config("SetBlockRenderingMode",(mode+1)%4)
                end},
                {label="字符间距（高级）",value=self:_reader_word_spacing_label(),callback=function() self:_show_reader_word_spacing_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
                {label="页边距",value=self:_reader_margin_label(),callback=function() self:_show_reader_margin_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
                {label="页面显示",value="状态栏、进度与刷新",callback=function() self:_show_reader_page_display_panel(function() self:_show_reader_advanced_typeset_panel(back_callback) end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_wifi_quick_panel(back_callback)
    ReaderSettingsDialog.show{
        title="Wi-Fi",
        subtitle=function()
            local label=self:_reader_wifi_summary()
            return tostring(label)
        end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            local on=self:_reader_wifi_state()==true
            return {
                {label="Wi-Fi",value=on and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:_reader_wifi_toggle() end},
                {label="选择网络",value="打开网络列表",callback=function() self:_reader_wifi_settings(back_callback or function() self:show_reader_quick_panel() end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_sync_quick_panel(back_callback)
    ReaderSettingsDialog.show{
        title="阅读同步",
        subtitle=function() return "当前状态: "..tostring(self:progress_sync_label()) end,
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="立即同步",value="上传当前进度",value_bold=true,keep_open=true,callback=function() self:upload_local_progress(true) end},
                {label="同步详情",value=self:progress_sync_label(),callback=function() self:_show_reader_sync_panel(back_callback or function() self:show_reader_quick_panel() end) end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_gesture_panel(back_callback)
    ReaderSettingsDialog.show{
        title="手势与按键",
        subtitle="桌面模式只接管顶部下滑阅读面板, 正文阅读手势继续交给阅读器",
        on_back=back_callback or function() self:show_reader_control_center("device") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="顶部下滑",value="觅阅阅读快捷面板",arrow=false},
                {label="向上滑动",value="收起快捷面板",arrow=false},
                {label="正文区域",value="保持翻页与选词手势",arrow=false},
                {label="阅读评论",value=self:_thoughts_enabled_label(),keep_open=true,callback=function() self:_toggle_thoughts_enabled() end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_device_compat_panel(back_callback)
    ReaderSettingsDialog.show{
        title="系统与兼容",
        subtitle="日常阅读不需要进入 KOReader 原菜单",
        on_back=back_callback or function() self:show_reader_control_center("device") end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        rows=function()
            return {
                {label="KOReader 原生菜单",value="仅用于未覆盖功能与故障排查",callback=function()
                    self:_show_koreader_reader_menu(function() self:_show_reader_device_compat_panel(back_callback) end)
                end},
                {label="觅阅阅读界面设置",value="评论与控制中心",callback=function()
                    self:_show_reader_menu_table("阅读界面",self:reader_quick_panel_settings_menu(),function() self:_show_reader_device_compat_panel(back_callback) end)
                end},
            }
        end,
    }
    return true
end

function Plugin:_reader_control_categories()
    local function back_to(key) return function() self:show_reader_control_center(key) end end
    return {
        {key="reading",label="阅读",sections={{items={
            {icon="toc",label="目录",value="当前章节",callback=function() self:_show_reader_toc(back_to("reading")) end},
            {icon="progress",label="阅读进度",value=(self:_reader_progress_percent() and (tostring(math.floor(self:_reader_progress_percent()+.5)).."%") or ""),callback=function() self:_show_reader_progress_control(back_to("reading")) end},
            {icon="search",label="书内搜索",value="搜索当前书籍",callback=function() self:_reader_show_search(back_to("reading")) end},
            {icon="undo",label="回到阅读处",value="返回跳转前位置",callback=function() self:_reader_go_back_location() end},
            {icon="highlight",label="批注",value=self:_reader_annotation_summary_label(),callback=function() self:_show_reader_annotation_panel(back_to("reading")) end},
            {icon="comment",label="评论",value=self:_thoughts_enabled_label(),value_bold=true,callback=function() self:_show_reader_comment_settings(back_to("reading")) end},
        }}}},
        {key="typeset",label="排版",sections={{items={
            {icon="font",label="字体与字号",value=self:_reader_font_label().." · "..self:_reader_font_size_label(),callback=function() self:_show_reader_font_panel(back_to("typeset")) end},
            {icon="line-spacing",label="行距",value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",callback=function() self:_show_reader_spacing_panel(back_to("typeset")) end},
            {icon="display",label="页面",value="页边距与阅读信息",callback=function() self:_show_reader_page_panel(back_to("typeset")) end},
            {icon="settings",label="高级排版",value="字符间距与更多版式",callback=function() self:_show_reader_advanced_typeset_panel(back_to("typeset")) end},
        }}}},
        {key="book",label="书籍",sections={{items={
            {icon="current-book",label="当前书籍",value="信息与本地状态",callback=function() self:_show_reader_current_book_panel(back_to("book")) end},
            {icon="sync",label="阅读同步",value=self:progress_sync_label(),value_bold=true,callback=function() self:_show_reader_sync_panel(back_to("book")) end},
            {icon="download",label="下载与生成",value="任务、失败重试与重新生成",callback=function() self:show_downloads(back_to("book")) end},
            {icon="comment",label="评论数据",value="迁移与显示设置",callback=function()
                self:_show_reader_menu_table("评论数据",self:book_repair_settings_menu(),back_to("book"))
            end},
            {icon="repair",label="修复书籍",value="检查当前书籍",callback=function() self:repair_current_book() end},
        }}}},
        {key="device",label="设备",sections={{items={
            {icon="frontlight",label="前光与色温",value=Device:hasFrontlight() and "直接调节" or "当前设备不支持",enabled=Device:hasFrontlight(),callback=function() self:_show_reader_frontlight_panel(back_to("device")) end},
            {icon="wifi",label="Wi-Fi",value=(self:_reader_wifi_summary()),callback=function() self:_show_reader_wifi_quick_panel(back_to("device")) end},
            {icon="rotate",label="屏幕方向",value=self:_reader_rotation_label(),callback=function() self:_home_rotate() end},
            {icon="screenshot",label="截图",value="截取当前屏幕",callback=function() ScreenshotMode.start(self) end},
            {icon="full-refresh",label="全屏刷新",value="清除残影",callback=function() self:_home_full_refresh() end},
            {icon="sleep",label="休眠",value="立即休眠",enabled=Device:canSuspend(),callback=function() self:_home_sleep() end},
            {icon="tools",label="手势与按键",value="阅读手势说明",callback=function() self:_show_reader_gesture_panel(back_to("device")) end},
            {icon="settings",label="系统与兼容",value="高级与故障排查",callback=function() self:_show_reader_device_compat_panel(back_to("device")) end},
        }}}},
    }
end

function Plugin:show_reader_control_center(initial_category)
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    local panel,err=ReaderControlCenter.show{
        title="全部阅读功能",
        categories=self:_reader_control_categories(),
        initial_category=tostring(initial_category or "reading"),
        on_back=function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    if not panel then
        logger.warn("[MiuRead][ReaderControlCenter] unavailable",tostring(err or "unknown"))
        return false
    end
    return true
end

function Plugin:_show_reader_edge_guard_panel(back_callback)
    ReaderSettingsDialog.show{
        title="边缘翻页防误触",
        subtitle="左右边缘点击优先翻页，避免划线评论抢占翻页操作",
        on_back=back_callback or function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        sections=function()
            local enabled,percent=self:_reader_edge_guard_state()
            local rows={
                {label="边缘翻页防误触",value=enabled and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function()
                    self:_reader_toggle_edge_guard()
                end},
            }
            local range_rows={}
            for _,value in ipairs({5,10,15,20}) do
                local selected=value
                range_rows[#range_rows+1]={
                    label=tostring(selected).."%",
                    value=selected==10 and "推荐" or "左右各占屏幕宽度",
                    value_bold=percent==selected,
                    checked=percent==selected,
                    enabled=enabled,
                    keep_open=true,
                    callback=function() self:_reader_set_edge_guard_percent(selected) end,
                }
            end
            return {
                {title="状态",rows=rows},
                {title="保护范围",rows=range_rows},
            }
        end,
    }
    return true
end

function Plugin:_reader_quick_definitions()
    local edge_enabled=self:_reader_edge_guard_state()
    return {
        toc={key="toc",icon="toc",label="目录",callback=function() self:_show_reader_toc(function() self:show_reader_quick_panel() end) end},
        progress={key="progress",icon="progress",label="进度",callback=function() self:_show_reader_progress_control(function() self:show_reader_quick_panel() end) end},
        search={key="search",icon="search",label="搜索",icon_scale=.94,callback=function() self:_reader_show_search(function() self:show_reader_quick_panel() end) end},
        back={key="back",icon="undo",label="回到阅读",icon_scale=.98,callback=function() self:_reader_go_back_location() end},
        font={key="font",icon="font",label="字体",callback=function() self:_show_reader_font_panel(function() self:show_reader_quick_panel() end) end},
        spacing={key="spacing",icon="line-spacing",label="行距",callback=function() self:_show_reader_spacing_panel(function() self:show_reader_quick_panel() end) end},
        page={key="page",icon="display",label="页面",callback=function() self:_show_reader_page_panel(function() self:show_reader_quick_panel() end) end},
        comments={key="comments",icon="comment",label="评论",icon_scale=1.16,icon_nudge_y=-1,active=self:_thoughts_enabled(),callback=function()
            self:_show_reader_comment_settings(function() self:show_reader_quick_panel() end)
        end,hold_callback=function()
            self:_toggle_thoughts_enabled()
            UIManager:scheduleIn(.05,function() self:show_reader_quick_panel() end)
        end},
        annotations={key="annotations",icon="highlight",label="批注",icon_scale=1.28,icon_nudge_y=-2,callback=function() self:_show_reader_annotation_panel(function() self:show_reader_quick_panel() end) end},
        edge_guard={key="edge_guard",icon=edge_enabled and "edge-guard" or "edge-guard-off",label="防误触",icon_scale=1.02,active=edge_enabled,callback=function()
            self:_show_reader_edge_guard_panel(function() self:show_reader_quick_panel() end)
        end},
        sync={key="sync",icon="sync",label="同步",callback=function() self:_show_reader_sync_panel(function() self:show_reader_quick_panel() end) end},
    }
end

function Plugin:show_reader_more_panel()
    return self:show_reader_control_center("reading")
end

function Plugin:_reader_quick_panel_options()
    if not (self.ui and self.ui.document) then return nil end
    local started=os.clock()
    local title_started=os.clock()
    local title=self:_reader_toolbar_title()
    local title_ms=math.floor((os.clock()-title_started)*1000+.5)
    local header=self:_reader_toolbar_header(title)
    local definitions=self:_reader_quick_definitions()

    local actions={
        definitions.search,
        definitions.back,
        definitions.annotations,
        definitions.comments,
        definitions.edge_guard,
    }

    local typeset={
        font={
            label="字体",value=self:_reader_font_size_label(),
            callback=function() self:_show_reader_font_panel(function() self:show_reader_quick_panel() end) end,
            on_decrease=function()
                if self:_reader_adjust_font_size(-1) then return self:_reader_font_size_label() end
                return false
            end,
            on_increase=function()
                if self:_reader_adjust_font_size(1) then return self:_reader_font_size_label() end
                return false
            end,
        },
        spacing={
            label="行距",value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",
            callback=function() self:_show_reader_spacing_panel(function() self:show_reader_quick_panel() end) end,
            on_decrease=function()
                if self:_reader_adjust_line_spacing(-5) then return tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end
                return false
            end,
            on_increase=function()
                if self:_reader_adjust_line_spacing(5) then return tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%" end
                return false
            end,
        },
        page={label="页面",callback=function() self:_show_reader_page_panel(function() self:show_reader_quick_panel() end) end},
    }

    local frontlight
    local warmth
    if Device:hasFrontlight() then
        local minimum,maximum=self:_reader_frontlight_bounds()
        frontlight={
            icon="frontlight",label="前光",min=minimum,max=maximum,value=self:_reader_frontlight_value() or minimum,
            on_set=function(value)
                if not self:_reader_set_frontlight(value) then return false end
                return self:_reader_frontlight_value() or value
            end,
            on_decrease=function()
                if not self:_reader_adjust_frontlight(-1) then return false end
                return self:_reader_frontlight_value() or minimum
            end,
            on_increase=function()
                if not self:_reader_adjust_frontlight(1) then return false end
                return self:_reader_frontlight_value() or minimum
            end,
        }
        local state=self:_reader_warmth_state()
        if state then
            warmth={
                icon="warmth",label="色温",min=state.min,max=state.max,value=state.value,
                on_set=function(value)
                    if not self:_reader_set_warmth(value) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or value
                end,
                on_decrease=function()
                    if not self:_reader_adjust_warmth(-1) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or state.value
                end,
                on_increase=function()
                    if not self:_reader_adjust_warmth(1) then return false end
                    local current=self:_reader_warmth_state()
                    return current and current.value or state.value
                end,
            }
        end
    end

    local device_actions={
        {icon="night",label="夜间模式",active=self:_reader_night_enabled(),callback=function() self:_home_toggle_night() end},
        {icon="rotate",label="旋转",callback=function() self:_home_rotate() end},
        {icon="screenshot",label="截图",callback=function() ScreenshotMode.start(self) end},
        {icon="full-refresh",label="全屏刷新",callback=function() self:_home_full_refresh(true) end},
    }

    self._reader_toolbar_options_perf={
        title_ms=title_ms,
        options_ms=math.floor((os.clock()-started)*1000+.5),
    }
    return {
        header=header,
        actions=actions,
        typeset=typeset,
        frontlight=frontlight,
        warmth=warmth,
        device_actions=device_actions,
    }
end

function Plugin:_schedule_reader_toolbar_prewarm(_session,_delay)
    -- beta.18 avoids building reader UI in the background. The toolbar is
    -- created fresh on demand so an idle prewarm cannot contend with paging.
    if self._reader_toolbar_prewarm_task then
        UIManager:unschedule(self._reader_toolbar_prewarm_task)
        self._reader_toolbar_prewarm_task=nil
    end
    return false
end

function Plugin:_show_reader_quick_panel_now()
    if not (self.ui and self.ui.document) then return false end
    local started=monotonic_wall_time()
    self:_mark_reader_busy(2)
    local options=self:_reader_quick_panel_options()
    local options_done=monotonic_wall_time()
    if not options then return false end
    local panel,err=ReaderToolbar.show(options,tostring(HOME_SESSION.reader_session_generation or 0))
    local shown=monotonic_wall_time()
    if not panel then
        logger.warn("[MiuRead][ReaderToolbar] unavailable",tostring(err or "unknown"))
        return false
    end
    local header_perf=self._reader_toolbar_header_perf or {}
    local options_perf=self._reader_toolbar_options_perf or {}
    local total_ms=math.floor((shown-started)*1000+.5)
    logger.info("[MiuRead][ReaderToolbarPerf]",
        "title_ms=",tostring(options_perf.title_ms or 0),
        "device_ms=",tostring(header_perf.device_ms or 0),
        "state_ms=",tostring(header_perf.state_ms or 0),
        "options_ms=",tostring(math.floor((options_done-started)*1000+.5)),
        "show_ms=",tostring(math.floor((shown-options_done)*1000+.5)),
        "cache_age_s=",tostring(header_perf.cache_age or 0),
        "chapter_cached=",tostring(header_perf.chapter_cached==true),
        "total_ms=",tostring(total_ms))
    self:_record_performance("reader_toolbar",total_ms)
    return true
end

function Plugin:show_reader_quick_panel()
    -- UiScale is already applied when preferences are loaded/saved. Re-reading
    -- and normalizing the whole home preference tree on every swipe needlessly
    -- adds work to the most latency-sensitive reader gesture.
    if not (self.ui and self.ui.document) then return false end
    -- Only the visible downward-swipe path publishes a short shared busy marker
    -- for the read-report subprocess. Page turns themselves stay memory-only.
    self:_mark_reader_busy(2,true)
    if self._reader_quick_panel_pending==true then return true end
    self._reader_quick_panel_pending=true
    UIManager:nextTick(function()
        self._reader_quick_panel_pending=false
        if self.ui and self.ui.document then self:_show_reader_quick_panel_now() end
    end)
    return true
end

function Plugin:_close_miuread_transients()
    HomeQuickPanel.close()
    ReaderToolbar.close()
    ReaderListDialog.close()
    ReaderControlCenter.close()
    ReaderProgressDialog.close()
    ReaderSettingsDialog.close()
    ReaderTocDialog.close()
    ReaderFrontlightDialog.close()
    local pending={}
    for index=#(UIManager._window_stack or {}),1,-1 do
        local window=UIManager._window_stack[index]
        local widget=window and window.widget or nil
        if widget and widget~=HomeView.current() and widget._miuread_transient==true
            and widget._miuread_recovery_surface~=true and UIManager:isWidgetShown(widget) then
            pending[#pending+1]=widget
        end
    end
    for _,widget in ipairs(pending) do pcall(function() UIManager:close(widget) end) end
end

function Plugin:_reader_file(readerui,file)
    local path=normalized_reader_file(file)
    if path then return path end
    local document=readerui and readerui.document or nil
    if document then
        path=normalized_reader_file(document.file or (document.getFilePath and document:getFilePath()) or nil)
    end
    return path
end

function Plugin:_reader_should_return_home(readerui,file)
    sync_home_session()
    if not self:_home_enabled() or HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT
        or HOME_EXITING or UIManager._exit_code~=nil then return false end
    local path=self:_reader_file(readerui,file)
    if HOME_READER_ORIGIN then
        if path and not HOME_READER_FILE then mark_reader_origin(path) end
        return true
    end
    if path and HOME_READER_FILE and path==HOME_READER_FILE then
        mark_reader_origin(path)
        return true
    end
    return false
end

function Plugin:_install_reader_quick_panel_zone()
    if not self:_home_enabled() then return false end
    local readerui=self.ui
    if not readerui or not readerui.document then return false end
    -- Keep KOReader's own touch-zone geometry and priority. The menu bridge
    -- below redirects only the native menu handler after links, footnotes,
    -- highlights and normal page gestures have had their normal chance.
    if not readerui._miuread_native_menu_zone_preserved then
        readerui._miuread_native_menu_zone_preserved=true
        logger.info("[MiuRead][ReaderToolbar] native menu touch zones preserved")
    end
    return true
end

function Plugin:_install_reader_menu_bridge()
    if not self:_home_enabled() then return false end
    local readerui=self.ui
    local menu=readerui and readerui.menu or nil
    if not readerui or not readerui.document or not menu then return false end
    if menu._miuread_bridge_owner==self then return true end

    local original_tap=menu.onTapShowMenu
    local original_swipe=menu.onSwipeShowMenu
    local original_press=menu.onPressMenu
    local original_key=menu.onKeyPressShowMenu
    local plugin=self

    menu._miuread_bridge_owner=self
    menu._miuread_original_onTapShowMenu=original_tap
    menu._miuread_original_onSwipeShowMenu=original_swipe
    menu._miuread_original_onPressMenu=original_press
    menu._miuread_original_onKeyPressShowMenu=original_key

    menu.onTapShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            -- Desktop mode reserves the reader control center for a downward
            -- menu swipe. Ordinary taps remain part of the reading surface and
            -- never leave a persistent MiuRead bar behind.
            return nil
        end
        if type(original_tap)=="function" then return original_tap(native_menu,ges) end
    end
    menu.onSwipeShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            local activation=native_menu.activation_menu
                or (G_reader_settings and G_reader_settings:readSetting("activate_menu")) or "swipe_tap"
            if activation~="tap" and ges and ges.direction=="south" then
                local shown=plugin:show_reader_quick_panel()
                if shown then readerui:handleEvent(Event:new("HandledAsSwipe")) end
                return shown
            end
            return nil
        end
        if type(original_swipe)=="function" then return original_swipe(native_menu,ges) end
    end
    menu.onPressMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_press)=="function" then return original_press(native_menu,...) end
    end
    menu.onKeyPressShowMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_key)=="function" then return original_key(native_menu,...) end
    end
    logger.info("[MiuRead][ReaderToolbar] native menu handlers redirected; touch zones unchanged")
    return true
end

function Plugin:_install_reader_home_bridge()
    local readerui=self.ui
    if not readerui or not readerui.document or type(readerui.onHome)~="function" then return false end
    local plugin=self
    if not readerui._miuread_original_onHome then
        local original=readerui.onHome
        readerui._miuread_original_onHome=original
        readerui.onHome=function(ui,...)
            if plugin and plugin._reader_context and plugin:_reader_should_return_home(ui) then
                logger.info("[MiuRead][Reader] native bookshelf redirected before FileManager")
                return plugin:return_to_miuread_home()
            end
            return original(ui,...)
        end
    end
    if type(readerui.showFileManager)=="function" and not readerui._miuread_original_showFileManager then
        local original_show_filemanager=readerui.showFileManager
        readerui._miuread_original_showFileManager=original_show_filemanager
        readerui.showFileManager=function(ui,file,...)
            local args={n=select("#",...),...}
            local return_home=plugin and plugin:_reader_should_return_home(ui,file)
            local generation
            if return_home then
                local path=plugin:_reader_file(ui,file)
                HOME_RETURN_FILE=path or HOME_RETURN_FILE
                mark_reader_origin(path)
                generation=plugin:_begin_reader_return("native filemanager",path,false)
                READER_CLOSE.native_requested=true
                READER_CLOSE.state="native_surface_waiting"
                logger.info("[MiuRead][ReaderClose] native FileManager requested",
                    "generation=",tostring(generation))
            end
            -- Never suppress KOReader's native transition. It owns document
            -- teardown and FileManager creation; MiuRead only observes the
            -- stable docless surface and raises the parked home afterwards.
            local packed={xpcall(function()
                return original_show_filemanager(ui,file,unpack_args(args,1,args.n))
            end,debug.traceback)}
            if not packed[1] then error(packed[2]) end
            if return_home then plugin:_schedule_reader_return_finish(generation,.10,"native filemanager") end
            return unpack_args(packed,2,#packed)
        end
    end
    return true
end

function Plugin:onHome()
    if self.ui and self.ui.document and self:_reader_should_return_home(self.ui) then
        logger.info("[MiuRead][Reader] Home event redirected to MiuRead home")
        return self:return_to_miuread_home()
    end
    sync_home_session()
    if not (self.ui and self.ui.document) and self:_home_enabled()
        and HOME_NATIVE_VISIT and not HOME_EXITING then
        logger.info("[MiuRead][Home] FileManager Home event redirected to MiuRead home")
        return self:_return_from_native_filemanager()
    end
    return false
end

function Plugin:_reader_instance()
    local ok,ReaderUI=pcall(require,"apps/reader/readerui")
    if not ok or not ReaderUI then return nil end
    return ReaderUI.instance
end

function Plugin:_widget_in_window_stack(target)
    if not target then return false end
    for _,window in ipairs(UIManager._window_stack or {}) do
        if window and window.widget==target then return true end
    end
    if type(UIManager.isWidgetShown)=="function" then
        local ok,shown=pcall(UIManager.isWidgetShown,UIManager,target)
        if ok and shown==true then return true end
    end
    return false
end

function Plugin:_reader_in_window_stack(reader)
    reader=reader or self:_reader_instance()
    return reader~=nil and self:_widget_in_window_stack(reader)
end

function Plugin:_reader_lifecycle_state()
    local reader=self:_reader_instance()
    if reader and reader.document then return "active",reader end
    if reader and self:_reader_in_window_stack(reader) then return "closing",reader end
    return "closed",reader
end

function Plugin:_active_reader_ui()
    local state,reader=self:_reader_lifecycle_state()
    return state=="active" and reader or nil
end

function Plugin:_filemanager_instance()
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    return ok and FileManager and FileManager.instance or nil
end

function Plugin:_navigation_state()
    local state=tostring(NAVIGATION.state or "native")
    if not NAVIGATION_STATES[state] then state="native" end
    return state
end

function Plugin:_set_navigation_state(state,reason)
    state=tostring(state or "native")
    if not NAVIGATION_STATES[state] then state="recovering" end
    local previous=self:_navigation_state()
    if previous~=state then
        NAVIGATION.generation=(tonumber(NAVIGATION.generation) or 0)+1
        NAVIGATION.state=state
        NAVIGATION.changed_at=os.time()
        NAVIGATION.reason=tostring(reason or "state change")
        NAVIGATION.reader_session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0
        HOME_SESSION.navigation_state=state
        HOME_SESSION.navigation_generation=NAVIGATION.generation
        logger.info("[MiuRead][Navigation]",previous,"->",state,
            "generation=",tostring(NAVIGATION.generation),"reason=",NAVIGATION.reason)
    else
        HOME_SESSION.navigation_state=state
        HOME_SESSION.navigation_generation=tonumber(NAVIGATION.generation) or 0
    end
    return tonumber(NAVIGATION.generation) or 0,previous~=state
end

function Plugin:_navigation_token()
    return {
        generation=tonumber(NAVIGATION.generation) or 0,
        state=self:_navigation_state(),
        reader_session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
    }
end

function Plugin:_navigation_token_valid(token,allowed_states)
    if type(token)~="table" or tonumber(token.generation)~=(tonumber(NAVIGATION.generation) or 0) then return false end
    if allowed_states==nil then return true end
    local state=self:_navigation_state()
    if type(allowed_states)=="string" then return state==allowed_states end
    if type(allowed_states)=="table" then
        if allowed_states[state]==true then return true end
        for _,value in ipairs(allowed_states) do if state==value then return true end end
    end
    return false
end

function Plugin:_set_foreground(owner)
    local value=tostring(owner or "native")
    if HOME_SESSION.foreground~=value then
        HOME_SESSION.foreground=value
        HOME_SESSION.foreground_changed_at=os.time()
    end
    local state=navigation_state_from_foreground(value)
    if value=="home_pending" and not reader_close_active() then state="recovering" end
    if value=="reader_transition" and not reader_close_active() then state="opening_reader" end
    self:_set_navigation_state(state,"foreground "..value)
    return HOME_SESSION.foreground
end

function Plugin:_page_transition_active()
    return tostring(HOME_SESSION.page_transition_state or "idle")~="idle"
end

function Plugin:_begin_page_transition(kind)
    kind=tostring(kind or "transition")
    HOME_SESSION.page_transition_generation=(tonumber(HOME_SESSION.page_transition_generation) or 0)+1
    HOME_SESSION.page_transition_state=kind
    HOME_SESSION.page_transition_started_clock=monotonic_wall_time()
    HOME_SESSION.page_transition_started_kind=kind
    if kind=="opening_reader" then self:_set_navigation_state("opening_reader","page transition")
    elseif kind=="closing_reader" then self:_set_navigation_state("closing_reader","page transition")
    elseif kind=="native_menu" then self:_set_navigation_state("native_menu","page transition")
    else self:_set_navigation_state("recovering","page transition "..kind) end
    self._page_transition_generation=HOME_SESSION.page_transition_generation
    self._page_transition_state=HOME_SESSION.page_transition_state
    if self._page_transition_release_task then
        UIManager:unschedule(self._page_transition_release_task)
        self._page_transition_release_task=nil
    end
    -- pause() resolves the active descriptor from disk, so this works across
    -- the separate FileManager and ReaderUI plugin instances.
    if self.download_task then self.download_task:pause("page_transition") end
    logger.info("[MiuRead][Transition] begin",HOME_SESSION.page_transition_state,
        "generation=",tostring(HOME_SESSION.page_transition_generation))
    return HOME_SESSION.page_transition_generation
end

function Plugin:_finish_page_transition(delay,reason)
    local generation=tonumber(HOME_SESSION.page_transition_generation) or 0
    local transition_kind=tostring(HOME_SESSION.page_transition_started_kind or HOME_SESSION.page_transition_state or "")
    local transition_started=tonumber(HOME_SESSION.page_transition_started_clock) or 0
    if self._page_transition_release_task then
        UIManager:unschedule(self._page_transition_release_task)
        self._page_transition_release_task=nil
    end
    local task
    task=function()
        if self._page_transition_release_task~=task
            or generation~=(tonumber(HOME_SESSION.page_transition_generation) or 0) then return end
        self._page_transition_release_task=nil
        HOME_SESSION.page_transition_state="idle"
        self._page_transition_state="idle"
        if self.download_task then
            if HomeView.is_shown() and not self:_active_reader_ui() and self:_home_ui_busy() then
                logger.info("[MiuRead][HomePerf] download resume deferred after transition")
                self:_home_resume_visible_work_after_idle()
            else
                self.download_task:resume("page_transition")
            end
        end
        local reason_text=tostring(reason or "surface ready")
        logger.info("[MiuRead][Transition] complete",reason_text,
            "generation=",tostring(generation))
        if transition_kind=="opening_reader" and transition_started>0
            and reason_text:find("reader first page",1,true) then
            local elapsed_ms=math.floor((monotonic_wall_time()-transition_started)*1000+.5)
            logger.info("[MiuRead][Perf] interaction","kind=reader_open","elapsed_ms=",tostring(elapsed_ms))
            self:_record_performance("reader_open",elapsed_ms)
            if self._performance_prompt_pending then self:_schedule_performance_prompt(1.2) end
        end
        if generation==(tonumber(HOME_SESSION.page_transition_generation) or 0) then
            HOME_SESSION.page_transition_started_clock=0
            HOME_SESSION.page_transition_started_kind=nil
        end
    end
    self._page_transition_release_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or 0),task)
    return true
end

function Plugin:_schedule_download_resume_after_wake(delay)
    self._download_resume_generation=(tonumber(self._download_resume_generation) or 0)+1
    local generation=self._download_resume_generation
    if self._download_resume_task then
        UIManager:unschedule(self._download_resume_task)
        self._download_resume_task=nil
    end
    local task
    task=function()
        if self._download_resume_task~=task or generation~=self._download_resume_generation then return end
        self._download_resume_task=nil
        if HOME_SESSION.suspended==true or self._miuread_suspended==true or self:_page_transition_active() then
            self:_schedule_download_resume_after_wake(2.0)
            return
        end
        if self.download_task then self.download_task:on_resume() end
    end
    self._download_resume_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 3.5),task)
    return true
end

function Plugin:_ensure_reader_transition_guard(reason)
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or HOME_SESSION.suspended==true then return false end
    if not self:_home_enabled() or not HOME_READER_ORIGIN then return false end
    local reader=self:_active_reader_ui()
    if not reader and self.ui and self.ui.document then reader=self.ui end
    local shown=ReaderTransitionGuard.ensure(reader,reason or "reader session")
    if shown then HOME_SESSION.transition_guard=true end
    return shown
end

function Plugin:_release_reader_transition_guard(reason)
    HOME_SESSION.transition_guard=false
    return ReaderTransitionGuard.close(reason or "surface ready")
end

function Plugin:_close_reader_recovery_surface()
    local dialog=self._reader_recovery_dialog
    self._reader_recovery_dialog=nil
    if dialog and UIManager:isWidgetShown(dialog) then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:_show_reader_recovery_surface(detail)
    self:_set_navigation_state("recovering","reader recovery surface")
    if self._reader_recovery_dialog and UIManager:isWidgetShown(self._reader_recovery_dialog) then return true end
    local dialog
    local function try_home()
        if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        self._reader_recovery_dialog=nil
        self:_set_foreground("home_pending")
        self:_restore_home_after_reader_close(1)
    end
    local function try_native()
        if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        self._reader_recovery_dialog=nil
        if self:_ensure_filemanager_base(HOME_RETURN_FILE or HOME_READER_FILE) then
            self:_set_foreground("native")
            self:_release_reader_transition_guard("native recovery ready")
            self:_finish_page_transition(0,"native recovery ready")
            UIManager:setDirty("all","full")
        else
            UIManager:scheduleIn(.12,function() self:_show_reader_recovery_surface("KOReader 文件管理器仍未就绪") end)
        end
    end
    dialog=ButtonDialog:new{
        title="页面暂时无法恢复"..((detail and tostring(detail)~="") and ("\n\n"..tostring(detail)) or ""),
        title_align="center",
        buttons={
            {{text="返回觅阅主页",callback=try_home}},
            {{text="打开 KOReader 文件管理器",callback=try_native}},
            {{text="重启 KOReader",callback=function() self:_restart_koreader("reader-recovery") end}},
        },
    }
    dialog._miuread_recovery_surface=true
    self._reader_recovery_dialog=dialog
    UIManager:show(dialog)
    logger.warn("[MiuRead][Reader] recovery surface shown",tostring(detail or "unknown"))
    return true
end

function Plugin:_cancel_reader_close_settle(reason,reset_shared)
    self._reader_close_settle_generation=(tonumber(self._reader_close_settle_generation) or 0)+1
    if self._reader_close_settle_task then
        UIManager:unschedule(self._reader_close_settle_task)
        self._reader_close_settle_task=nil
    end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    self._reader_return_finish_task=nil
    if READER_CLOSE.state~="idle" then
        READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    end
    if reset_shared==true and READER_CLOSE.state~="idle" then
        READER_CLOSE.generation=(tonumber(READER_CLOSE.generation) or 0)+1
        READER_CLOSE.state="idle"
        READER_CLOSE.session_generation=0
        READER_CLOSE.reader_file=nil
        READER_CLOSE.requested_at=0
        READER_CLOSE.requested_clock=0
        READER_CLOSE.poll_state=nil
        READER_CLOSE.poll_count=0
        READER_CLOSE.close_event_received=false
        READER_CLOSE.native_requested=false
        READER_CLOSE.stable_samples=0
        READER_CLOSE.fallback_attempted=false
        READER_CLOSE.reason=nil
    end
    if reason then logger.info("[MiuRead][ReaderClose] watcher cancelled",tostring(reason)) end
    return true
end

function Plugin:_close_home_for_reader(reason)
    if not self:_home_enabled() then
        self:_set_foreground("reader")
        return true
    end
    self:_home_stop_background(reason or "reader active")
    self:_close_miuread_transients()
    if HomeView.is_shown() then
        HomeView.park()
        self._home_view=HomeView.current()
        logger.info("[MiuRead][Home] parked below reader",tostring(reason or "reader active"))
    end
    if self:_active_reader_ui() or (self.ui and self.ui.document) then
        self:_set_foreground("reader")
    else
        self:_set_foreground("reader_pending")
    end
    return true
end

function Plugin:_reader_close_snapshot()
    local state,reader=self:_reader_lifecycle_state()
    return {
        lifecycle=state,
        reader=reader,
        reader_in_stack=reader and self:_reader_in_window_stack(reader) or false,
        document_present=reader and reader.document~=nil or false,
        filemanager=self:_filemanager_instance(),
        opening=normalized_reader_file(HOME_SESSION.opening_file),
        session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0,
    }
end

function Plugin:_complete_reader_close(generation,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    local snapshot=self:_reader_close_snapshot()
    -- MiuRead keeps its rendered home parked under ReaderUI. Once ReaderUI has
    -- actually left the stack, that existing home can be restored immediately;
    -- FileManager is no longer a prerequisite for the visible return path.
    if snapshot.lifecycle~="closed" then return false end
    if not snapshot.filemanager and not HomeView.is_shown() then return false end
    READER_CLOSE.state="home_restoring"
    self:_ensure_reader_transition_guard("stable reader close")
    self:_close_miuread_transients()
    self:_set_foreground("home_pending")

    local shown=false
    if HomeView.is_shown() then
        HomeView.unpark(true,{
            on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        })
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),"ui")
        shown=true
    else
        shown=self:_show_miuread_home_now(false,false,true)==true
    end
    if not shown then
        READER_CLOSE.state="failed"
        self:_finish_page_transition(0,"home restore failed")
        self:_show_reader_recovery_surface("觅阅主页未能恢复")
        return false
    end

    HOME_SESSION.reader_session_active=false
    HOME_SESSION.return_requested=false
    HOME_SESSION.return_session_generation=0
    HOME_SESSION.return_request_file=nil
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    HOME_RETURN_FILE=nil
    persist_home_session()
    self:_set_foreground("home")
    self:_close_reader_recovery_surface()
    self:_release_reader_transition_guard("home restored after stable close")
    self:_home_enter_post_reader_priority_window(4.0,"stable reader close")
    self:_finish_page_transition(.18,"home restored after stable close")
    self:_resume_pending_post_reader_work("home restored after stable close",2.0)
    READER_CLOSE.state="completed"
    logger.info("[MiuRead][ReaderClose] home restored",
        "generation=",tostring(generation),"reason=",tostring(reason or READER_CLOSE.reason or "close"))
    local requested_clock=tonumber(READER_CLOSE.requested_clock) or 0
    if requested_clock>0 then
        local elapsed_ms=math.floor((monotonic_wall_time()-requested_clock)*1000+.5)
        logger.info("[MiuRead][ReaderClosePerf] return complete",
            "elapsed_ms=",tostring(elapsed_ms))
        self:_record_performance("reader_home",elapsed_ms)
        if self._performance_prompt_pending then self:_schedule_performance_prompt(.9) end
    end
    self:_clear_reader_return(generation,"home restored")
    return true
end

function Plugin:_schedule_reader_close_settle(path,session_generation,reason)
    local generation=self:_begin_reader_return(reason or "document closed",path,false,session_generation)
    READER_CLOSE.close_event_received=true
    if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
    return self:_schedule_reader_return_finish(generation,.10,reason or "document closed")
end

function Plugin:_home_prepare_hero_book(book)
    if type(book)~="table" then return nil end
    local hero=U.copy(book)
    hero.heading="最近阅读"
    hero.source_text=self:_home_source_text(hero)
    hero.last_read_text=self:_home_last_read_text(hero)
    hero.status_text=self:_home_status_text(hero,hero.source=="local" or hero.local_file==true)
    self:_home_apply_cached_network_metadata(hero)
    if U.trim(tostring(hero.format or ""))=="" then
        local extension=tostring(hero.file or ""):match("%.([%w]+)$")
        if extension then hero.format=extension:upper() end
    end
    local variant=tostring(hero.variant or "")
    if hero.annotation_requested==true or variant:find("notes",1,true) then
        hero.edition_text="含评论"
    elseif variant:find("clean",1,true) then
        hero.edition_text="纯净版"
    end
    hero.on_tap=function(anchor) self:_home_open_book(hero,anchor) end
    hero.on_refresh_metadata=function() self:_home_refresh_current_network_metadata(hero) end
    return hero
end

function Plugin:_home_refresh_recent_hero_cached()
    if self._home_recent_read_dirty~=true and HOME_SESSION.recent_read_dirty~=true then return false end
    if not HomeView.is_shown() or self:_active_reader_ui() then return false end
    local sections=self._home_sections or {}
    local local_rows=sections["local"] and sections["local"].rows or {}
    local account=sections.account and sections.account.rows or {}
    if #local_rows==0 and #account==0 then return false end
    self:_home_apply_recent_read_times({},local_rows,account)
    local hero=self:_home_prepare_hero_book(self:_home_recent_book({},local_rows,account))
    self._home_recent_read_dirty=false
    HOME_SESSION.recent_read_dirty=false
    if not hero then return false end
    local previous_key=self:_home_book_key(self._home_hero)
    local current_key=self:_home_book_key(hero)
    local previous_time=self:_home_book_time(self._home_hero)
    local current_time=self:_home_book_time(hero)
    self._home_hero=hero
    if previous_key~=current_key or previous_time~=current_time then
        HomeView.update_hero(hero)
        logger.info("[MiuRead][Recent] hero updated",
            "book=",tostring(current_key),"read_at=",tostring(current_time))
    end
    local current=HomeView.current()
    local shelf=(current and current.opts and current.opts.shelf_books) or {}
    local metadata_targets={hero}
    local cover_targets={hero}
    for _,book in ipairs(shelf) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    self._home_visible_metadata_targets=metadata_targets
    self._home_visible_cover_targets=cover_targets
    local home=self:_home_preferences()
    HOME_SESSION.lockscreen_recent_enabled=home.lockscreen_recent~=false
    HOME_SESSION.screensaver_file=home.lockscreen_recent~=false and self:_home_prepare_lockscreen_cover(hero) or nil
    if home.network_metadata~=false then
        local key=self:_home_network_metadata_key(hero)
        if key~="" then self._home_pending_network_metadata_key=key end
    end
    return true
end

function Plugin:_show_miuread_home_now(force_scan,from_refresh,quiet,refresh_kind,options)
    options=type(options)=="table" and options or {}
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or HOME_SESSION.suspended==true or self._miuread_suspended==true then return false end
    if READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed"
        and READER_CLOSE.state~="failed" and READER_CLOSE.state~="home_restoring" then
        logger.info("[MiuRead][ReaderClose] home rebuild blocked during close",READER_CLOSE.state)
        return false
    end
    if self:_home_background_blocked() and HomeView.is_shown() and not self:_active_reader_ui() then
        self:_home_defer_refresh_kind(refresh_kind or "content")
        HomeView.raise()
        return true
    end
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    -- The rendered home stays parked under ReaderUI. Keep the reader-origin
    -- token until ReaderUI has actually left so an explicit return can raise it.
    if not self:_active_reader_ui() then
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
    end
    persist_home_session()

    if force_scan==true then self:_home_reset_local_metadata() end
    local local_rows=self:_home_local_rows()
    local cached_books,cached_mp=self.library:cached()
    cached_books=type(cached_books)=="table" and cached_books or {}
    cached_mp=type(cached_mp)=="table" and cached_mp or {}

    local account_rows=self:_shelf_rows("account",false,cached_books,{},#cached_books>0)
    self:_prepare_shelf_rows(account_rows)
    for _,row in ipairs(account_rows) do
        self:_home_attach_local_record(row)
        row.source="account"
        row.description=row.description or row.intro or row.summary
        row.status_text=self:_home_status_text(row,false)
    end
    local mp_rows=self:_shelf_rows("account",true,{},cached_mp,#cached_mp>0)
    self:_prepare_shelf_rows(mp_rows)
    for _,row in ipairs(mp_rows) do
        row.source="mp"
        row.status_text=self:_home_status_text(row,false)
    end

    local home,home_preferences=self:_home_preferences()
    self:_home_apply_recent_read_times(local_rows,account_rows,mp_rows)
    local hero=self:_home_prepare_hero_book(self:_home_recent_book({},local_rows,account_rows))

    local sections={
        account={title="微信书架",rows=account_rows,empty="这里还没有微信书架内容"},
        ["local"]={title="本地书籍",rows=local_rows,empty=self:_home_local_empty_text()},
        mp={title="公众号",rows=mp_rows,empty="这里还没有公众号内容"},
    }
    self._home_data_revision=(tonumber(self._home_data_revision) or 0)+1
    self._home_sections=sections
    local visible_keys=self:_home_visible_section_keys(sections,home)
    self._home_visible_keys=visible_keys
    local active=visible_keys[1] or "account"
    for _,key in ipairs(visible_keys) do
        if key==home.active_section then active=key; break end
    end
    local selected=sections[active]
    if home.active_section~=active then
        home.active_section=active
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences_deferred(home,preferences)
    end
    self._home_active_section=active
    self._home_hero=hero
    local preview_limit=self:_home_page_limit()
    local selected_preview,shelf_page,shelf_pages=self:_home_preview_page(
        selected.rows,hero,home.page_by_section and home.page_by_section[active],preview_limit
    )
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    if tonumber(home.page_by_section[active])~=shelf_page then
        home.page_by_section[active]=shelf_page
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences_deferred(home,preferences)
    end
    local tabs=self:_home_build_tabs(active)

    local screensaver_file=home.lockscreen_recent~=false and self:_home_prepare_lockscreen_cover(hero) or nil
    HOME_SESSION.lockscreen_recent_enabled=home.lockscreen_recent~=false
    HOME_SESSION.screensaver_file=screensaver_file
    local home_alerts=self:_home_alerts()
    self._home_panel_sync_label=self:progress_sync_label()
    self._home_panel_download_detail=""
    self._home_panel_status_text=(home_alerts[1] and tostring(home_alerts[1].title or "")) or ""
    local view,err=HomeView.show({
        title="觅阅",
        wifi_text=self:_home_wifi_text(),
        sync_text=self:_home_sync_status_label(),
        time_text=self:_display_time("%H:%M"),
        battery_text=self:_home_battery_text(),
        account_name=self:_home_account_name(),
        layout_style=home.layout_style,
        display_size=home.display_size,
        hero=hero,
        tabs=tabs,
        shelf_title=active=="local" and self:_home_local_inline_title() or "",
        shelf_books=selected_preview,
        shelf_page=shelf_page,
        shelf_pages=shelf_pages,
        empty_text=selected.empty,
        -- Download progress belongs to the matching shelf card; only true
        -- account/health alerts occupy the home notice strip.
        alerts=home_alerts,
        lockscreen_enabled=home.lockscreen_recent~=false,
        screensaver_file=screensaver_file,
        on_quick_panel=function() self:show_home_quick_panel() end,
        on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        on_account=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end,
        on_menu=function() self:show_home_menu() end,
        on_back=function() return self:_home_handle_back() end,
        on_empty_account=function() self:_home_open_section(active) end,
        on_open_book=function(book,anchor) self:_home_open_book(book,anchor) end,
        on_hold_book=function(book,anchor) self:_home_hold_book(book,anchor) end,
        home_actions=self:_home_action_entries(),
        on_shelf_all=function()
            if active=="local" then self:show_home_local_library()
            else self:show_home_all_books() end
        end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
        section_cache_key=active,
        section_revision=self:_home_section_cache_revision(active,shelf_page),
        on_close=function(current)
            if self._home_view==current then self._home_view=nil end
            if current and (current._miu_suppress_restore==true or current._miu_superseded==true) then return end
            if HOME_EXPECTED_CLOSE or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil then return end
            if not self._home_reader_transition and not HOME_SESSION_SUPPRESSED and self:_home_enabled() then
                local token=self:_navigation_token()
                UIManager:scheduleIn(.6,function()
                    if not self:_navigation_token_valid(token,{home=true,native=true,recovering=true}) then return end
                    if HOME_EXPECTED_CLOSE or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil then return end
                    if not HomeView.is_shown() and not self:_active_reader_ui() and not HOME_SESSION_SUPPRESSED then
                        self:_restore_home_after_reader_close(1)
                    end
                end)
            end
        end,
    },refresh_kind)
    if not view then
        logger.warn("[MiuRead][Home] bookshelf unavailable",tostring(err or "unknown"))
        if not quiet then self:info("觅阅首页暂时无法显示：\n"..tostring(err or "未知错误")) end
        return false
    end
    self._home_view=view
    rawset(_G,HOME_OWNER_KEY,self)
    self:_set_foreground("home")
    self._home_refresh_pending=false
    self:_home_schedule_clock()
    if active=="local" then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and self._home_active_section=="local" then self:_home_ensure_local_inline_loaded() end
        end)
    end

    local metadata_targets={}
    local cover_targets={}
    if hero then
        metadata_targets[#metadata_targets+1]=hero
        cover_targets[#cover_targets+1]=hero
    end
    for _,book in ipairs(selected_preview) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    self._home_visible_metadata_targets=metadata_targets
    self._home_visible_cover_targets=cover_targets
    if options.skip_background~=true then
        self:_home_schedule_local_metadata(metadata_targets)
        self:_home_schedule_remote_covers(cover_targets)
        -- Existing covers are converted only after the home is already interactive.
        -- Newly downloaded covers schedule the same worker when their batch ends.
        UIManager:scheduleIn(.85,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_schedule_cover_derivatives(cover_targets) end
        end)
    end
    local hero_needs_network = hero and (
        U.trim(tostring(hero.description or hero.intro or hero.summary or ""))==""
        or U.trim(tostring(hero.category or ""))==""
        or U.trim(tostring(hero.publisher or ""))==""
        or U.trim(tostring(hero.published_date or ""))==""
        or U.trim(tostring(hero.isbn or ""))==""
    )
    local hero_key=hero and self:_home_network_metadata_key(hero) or ""
    local hero_recent_changed=hero_key~="" and tostring(home.last_network_metadata_recent_key or "")~=hero_key
    if hero_recent_changed then
        home.last_network_metadata_recent_key=hero_key
        self:_save_home_preferences_deferred(home,home_preferences)
    end
    if options.skip_background~=true
        and hero_recent_changed and hero_needs_network and home.network_metadata~=false then
        -- Only the newly changed recent-reading book may start an automatic
        -- network lookup. Successful results stay cached until manual refresh.
        UIManager:scheduleIn(2.5,function()
            if HomeView.is_shown() and not self:_active_reader_ui()
                and self._home_hero and self:_home_network_metadata_key(self._home_hero)==hero_key then
                self:_home_schedule_network_metadata(self._home_hero,false)
            end
        end)
    end

    if not from_refresh and options.skip_background~=true then
        if force_scan==true then self:_home_scan_local(true) end
        -- Startup remains cache-first. Stale cloud/local checks are allowed
        -- only after the interface is idle and their TTL has expired.
        self:_home_schedule_stale_checks(4.5)
    end
    return true
end

function Plugin:show_miuread_home(force_scan,from_refresh)
    local lifecycle=self:_reader_lifecycle_state()
    if lifecycle~="closed" then return self:return_to_miuread_home() end
    return self:_show_miuread_home_now(force_scan,from_refresh)
end

function Plugin:_ensure_filemanager_base(file,opts)
    opts=type(opts)=="table" and opts or {}
    local perf_started=monotonic_wall_time()
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not ok or not FileManager then return false end
    if FileManager.instance then
        if opts.conceal_under_home==true and HomeView.is_shown() then
            -- A native base may already have been inserted above the parked
            -- MiuRead root by another plugin instance. Put the existing home
            -- back on top before the UI loop can repaint that native page.
            HomeView.raise(true)
            UIManager:setDirty(HomeView.current(),opts.refresh_kind or "ui")
            logger.info("[MiuRead][Home] existing FileManager concealed below MiuRead home")
        end
        return true
    end
    local target=tostring(file or HOME_RETURN_FILE or "")
    local dir=target~="" and target:match("^(.*)/[^/]+$") or nil
    local selected=target~="" and target or nil
    local show_started=monotonic_wall_time()
    local shown,err=xpcall(function() FileManager:showFiles(dir,selected) end,debug.traceback)
    local show_ms=math.floor((monotonic_wall_time()-show_started)*1000+.5)
    if not shown then
        logger.warn("[MiuRead][Home] failed to recreate FileManager base",tostring(err))
        return false
    end
    if not FileManager.instance then
        logger.warn("[MiuRead][Home] FileManager base was not established")
        return false
    end
    if opts.conceal_under_home==true and HomeView.is_shown() then
        -- FileManager:showFiles queues a repaint, but does not need to be the
        -- visible surface. Raise the already-rendered, still-parked MiuRead
        -- home synchronously in the same callback. When UIManager flushes its
        -- dirty queue, the user sees MiuRead directly instead of a one-frame
        -- KOReader file browser flash.
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),opts.refresh_kind or "ui")
        logger.info("[MiuRead][Home] FileManager base concealed below MiuRead home")
    end
    logger.info("[MiuRead][Home] FileManager base ready")
    logger.info("[MiuRead][ReaderClosePerf] FileManager base created",
        "show_ms=",tostring(show_ms),
        "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
    return true
end

function Plugin:_restore_home_after_reader_close(attempt,generation)
    sync_home_session()
    attempt=tonumber(attempt) or 1
    if generation==nil then
        if HOME_SESSION.home_restore_active==true
            and (tonumber(HOME_SESSION.home_restore_generation) or 0)>0 then return true end
        HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
        HOME_SESSION.home_restore_active=true
        generation=HOME_SESSION.home_restore_generation
        self._home_restore_generation=generation
        if not reader_close_active() then self:_set_navigation_state("recovering","home restore requested") end
    else
        self._home_restore_generation=tonumber(HOME_SESSION.home_restore_generation) or 0
    end
    if generation~=(tonumber(HOME_SESSION.home_restore_generation) or 0) then return false end
    if HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil
        or HOME_SESSION.suspended==true or self._miuread_suspended==true or not self:_home_enabled() then
        HOME_SESSION.home_restore_active=false
        if HOME_SESSION.suspended~=true and self._miuread_suspended~=true then
            self:_finish_page_transition(.2,"home restore no longer required")
        end
        return false
    end
    if READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed"
        and READER_CLOSE.state~="failed" and READER_CLOSE.state~="home_restoring" then
        HOME_SESSION.home_restore_active=false
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.10,"home restore delegated")
        return false
    end
    local reader_state=self:_reader_lifecycle_state()
    if reader_state~="closed" then
        if attempt<40 then
            UIManager:scheduleIn(.15,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        else
            HOME_SESSION.home_restore_active=false
            if reader_state=="active" then self:_set_foreground("reader") end
            self:_finish_page_transition(0,"home restore cancelled by reader")
        end
        return false
    end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local has_base=ok_fm and FileManager and FileManager.instance~=nil
    if HomeView.is_shown() then
        if not has_base and attempt>=25 then
            has_base=self:_ensure_filemanager_base(HOME_RETURN_FILE or HOME_READER_FILE)==true
        end
        if not has_base then
            if attempt<40 then
                UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
            else
                HOME_SESSION.home_restore_active=false
                self:_finish_page_transition(0,"home base recovery required")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
            return false
        end
        -- FileManager provides KOReader's docless services and gesture manager,
        -- but it must stay below the MiuRead root. Restore the parked surface
        -- with one bounded UI repaint instead of rebuilding and full-refreshing.
        HomeView.unpark(true,{
            on_interaction=function(first,kind) self:_home_note_interaction(first,kind) end,
        })
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),"ui")
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
        persist_home_session()
        self:_set_foreground("home")
        self:_home_schedule_clock()
        self:_close_reader_recovery_surface()
        self:_release_reader_transition_guard("home already visible")
        self:_home_enter_post_reader_priority_window(4.0,"home revealed")
        self:_finish_page_transition(.18,"home revealed")
        self:_resume_pending_post_reader_work("home revealed",2.0)
        HOME_SESSION.home_restore_active=false
        return true
    end

    if not has_base and attempt>=25 then
        has_base=self:_ensure_filemanager_base(HOME_RETURN_FILE)==true
    end
    if not has_base then
            if attempt<40 then
                UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
            else
                HOME_SESSION.home_restore_active=false
                self:_finish_page_transition(0,"home base recovery required")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
            return false
        end

    local shown=self:_show_miuread_home_now(false,false,true)
    if not shown and attempt<2 then
        UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        return false
    end
    if shown then
        HOME_RETURN_FILE=nil
        self:_set_foreground("home")
        self:_close_reader_recovery_surface()
        self:_release_reader_transition_guard("home restored")
        self:_home_enter_post_reader_priority_window(4.0,"home rebuilt")
        self:_finish_page_transition(.18,"home rebuilt")
        self:_resume_pending_post_reader_work("home restored",2.0)
    else
        self:_set_navigation_state("recovering","home creation failed")
        self:_finish_page_transition(0,"home creation recovery required")
        self:_show_reader_recovery_surface("觅阅主页未能创建，已保留安全退路")
    end
    HOME_SESSION.home_restore_active=false
    return shown
end

function Plugin:_begin_reader_return(reason,file,request_close,session_generation)
    local expected_session=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
    local active=READER_CLOSE.state~="idle" and READER_CLOSE.state~="completed" and READER_CLOSE.state~="failed"
    if active and tonumber(READER_CLOSE.session_generation or 0)==expected_session then
        return tonumber(READER_CLOSE.generation) or 0,false
    end
    READER_CLOSE.generation=(tonumber(READER_CLOSE.generation) or 0)+1
    READER_CLOSE.state=request_close==false and "reader_closing" or "close_requested"
    READER_CLOSE.session_generation=expected_session
    READER_CLOSE.reader_file=normalized_reader_file(file) or normalized_reader_file(HOME_SESSION.reader_session_file)
    READER_CLOSE.requested_at=os.time()
    READER_CLOSE.requested_clock=monotonic_wall_time()
    READER_CLOSE.poll_state=nil
    READER_CLOSE.poll_count=0
    READER_CLOSE.close_event_received=false
    READER_CLOSE.native_requested=false
    READER_CLOSE.stable_samples=0
    READER_CLOSE.fallback_attempted=false
    READER_CLOSE.close_attempts=0
    READER_CLOSE.close_command_sent_at=0
    READER_CLOSE.foreground_stop_attempted=false
    READER_CLOSE.native_fallback_attempted=false
    READER_CLOSE.reason=tostring(reason or "return home")
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1

    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self._reader_return_generation=READER_CLOSE.generation
    self._reader_returning=true
    self._reader_return_started=READER_CLOSE.requested_at
    self._reader_return_reason=READER_CLOSE.reason
    self._reader_return_session_generation=expected_session
    self._home_reader_transition=true
    self:_begin_page_transition("closing_reader")
    self:_ensure_reader_transition_guard("reader close requested")
    HOME_SESSION.return_requested=true
    HOME_SESSION.return_session_generation=expected_session
    HOME_SESSION.return_request_file=READER_CLOSE.reader_file
    local path=READER_CLOSE.reader_file
    HOME_RETURN_FILE=path or HOME_RETURN_FILE
    if path then mark_reader_origin(path) end
    logger.info("[MiuRead][ReaderClose] requested",
        "generation=",tostring(READER_CLOSE.generation),
        "session=",tostring(expected_session),"reason=",READER_CLOSE.reason)
    return READER_CLOSE.generation,true
end

function Plugin:_clear_reader_return(generation,reason)
    if generation and generation~=(tonumber(READER_CLOSE.generation) or 0) then return false end
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    self._reader_returning=false
    self._reader_return_started=0
    self._reader_return_reason=nil
    self._home_reader_transition=false
    self._miuread_return_requested=false
    HOME_SESSION.return_requested=false
    HOME_SESSION.return_session_generation=0
    HOME_SESSION.return_request_file=nil
    READER_CLOSE.state="idle"
    READER_CLOSE.session_generation=0
    READER_CLOSE.reader_file=nil
    READER_CLOSE.requested_at=0
    READER_CLOSE.requested_clock=0
    READER_CLOSE.poll_state=nil
    READER_CLOSE.poll_count=0
    READER_CLOSE.close_event_received=false
    READER_CLOSE.native_requested=false
    READER_CLOSE.stable_samples=0
    READER_CLOSE.fallback_attempted=false
    READER_CLOSE.close_attempts=0
    READER_CLOSE.close_command_sent_at=0
    READER_CLOSE.foreground_stop_attempted=false
    READER_CLOSE.native_fallback_attempted=false
    READER_CLOSE.reason=nil
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    logger.info("[MiuRead][ReaderClose] state cleared",tostring(reason or "complete"))
    return true
end

local function reader_close_poll_delay(phase,elapsed)
    elapsed=math.max(0,tonumber(elapsed) or 0)
    if phase=="confirm" then return .10 end
    if phase=="opening" then return elapsed<1.5 and .18 or .32 end
    if elapsed<.8 then return .12 end
    if elapsed<2.5 then return .22 end
    if elapsed<5 then return .35 end
    return .55
end

function Plugin:_reader_close_poll_state(state,detail)
    state=tostring(state or "unknown")
    READER_CLOSE.poll_count=(tonumber(READER_CLOSE.poll_count) or 0)+1
    if READER_CLOSE.poll_state==state then return false end
    READER_CLOSE.poll_state=state
    logger.info("[MiuRead][ReaderClose] state",state,tostring(detail or ""),
        "poll=",tostring(READER_CLOSE.poll_count))
    return true
end

function Plugin:_schedule_reader_return_finish(generation,delay,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    if self._reader_close_watch_task then
        UIManager:unschedule(self._reader_close_watch_task)
        self._reader_close_watch_task=nil
    end
    READER_CLOSE.watch_token=(tonumber(READER_CLOSE.watch_token) or 0)+1
    local watch_token=READER_CLOSE.watch_token
    local task
    task=function()
        if self._reader_close_watch_task~=task
            or generation~=(tonumber(READER_CLOSE.generation) or 0)
            or watch_token~=(tonumber(READER_CLOSE.watch_token) or 0) then return end
        self._reader_close_watch_task=nil
        self:_finish_reader_return(generation,reason)
    end
    self._reader_close_watch_task=task
    self._reader_return_finish_task=task
    UIManager:scheduleIn(math.max(.05,tonumber(delay) or .12),task)
    return true
end

function Plugin:_finish_reader_return(generation,reason)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    self._reader_return_finish_task=nil
    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        self:_reader_close_poll_state("suspended","waiting for resume")
        return self:_schedule_reader_return_finish(generation,.6,"waiting after suspend")
    end
    local snapshot=self:_reader_close_snapshot()
    local requested_clock=tonumber(READER_CLOSE.requested_clock) or 0
    if requested_clock<=0 then
        requested_clock=monotonic_wall_time()
        READER_CLOSE.requested_clock=requested_clock
    end
    local elapsed=math.max(0,monotonic_wall_time()-requested_clock)
    local expected=tonumber(READER_CLOSE.session_generation) or 0

    if snapshot.session_generation~=expected and snapshot.lifecycle=="active" then
        logger.info("[MiuRead][ReaderClose] cancelled; new reader session",
            "expected=",tostring(expected),"current=",tostring(snapshot.session_generation))
        self:_clear_reader_return(generation,"new reader session")
        self:_set_foreground("reader")
        self:_finish_page_transition(1.0,"new reader session")
        return false
    end
    if snapshot.opening then
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("opening_another_document",snapshot.opening)
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("opening",elapsed),"another document opening")
    end
    if snapshot.lifecycle=="active" then
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("reader_active","waiting for CloseDocument")
        local attempts=tonumber(READER_CLOSE.close_attempts) or 0
        if elapsed>=.6 and attempts==0 then
            logger.warn("[MiuRead][ReaderClose] close command missing; retrying",
                "generation=",tostring(generation))
            self:_request_reader_close(generation,"watchdog initial")
            return true
        end
        if elapsed>=1.8 and attempts<2 then
            logger.warn("[MiuRead][ReaderClose] close not acknowledged; retrying",
                "generation=",tostring(generation),"attempts=",tostring(attempts))
            self:_close_miuread_transients()
            self:_request_reader_close(generation,"watchdog retry")
            return true
        end
        if elapsed>=5 and READER_CLOSE.foreground_stop_attempted~=true then
            READER_CLOSE.foreground_stop_attempted=true
            local stopped=self.download_task
                and self.download_task:stop_for_foreground("return_home_timeout") or false
            logger.warn("[MiuRead][ReaderClose] foreground recovery requested",
                "generation=",tostring(generation),"download_stopped=",tostring(stopped))
            self:_request_reader_close(generation,"foreground recovery")
            return true
        end
        if elapsed>=8 and READER_CLOSE.native_fallback_attempted~=true then
            READER_CLOSE.native_fallback_attempted=true
            local active=self:_active_reader_ui()
            if active and type(active.showFileManager)=="function" then
                logger.warn("[MiuRead][ReaderClose] using native FileManager fallback",
                    "generation=",tostring(generation))
                local ok_native,err_native=xpcall(function()
                    active:showFileManager(READER_CLOSE.reader_file or HOME_RETURN_FILE)
                end,debug.traceback)
                if not ok_native then
                    logger.warn("[MiuRead][ReaderClose] native fallback failed",tostring(err_native))
                end
                self:_schedule_reader_return_finish(generation,.18,"native fallback")
                return true
            end
        end
        if elapsed>=12 then
            logger.warn("[MiuRead][ReaderClose] reader still active after timeout",
                "generation=",tostring(generation))
            self:_clear_reader_return(generation,"reader close timed out")
            self:_set_foreground("reader")
            self:_finish_page_transition(0,"reader close timed out")
            self:info("暂时无法返回主页，请再次点击返回主页。")
            return false
        end
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("active",elapsed),"reader active")
    end
    if snapshot.lifecycle=="closing" then
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.stable_samples=0
        self:_reader_close_poll_state("reader_leaving_stack",
            snapshot.document_present and "document still attached" or "document released")
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("closing",elapsed),"reader closing")
    end

    if HomeView.is_shown() then
        READER_CLOSE.state="home_restoring"
        READER_CLOSE.stable_samples=1
        self:_reader_close_poll_state("home_surface_ready","restoring parked MiuRead home")
        return self:_complete_reader_close(generation,reason or "parked home ready")
    end

    if snapshot.filemanager then
        READER_CLOSE.state="native_surface_waiting"
        READER_CLOSE.stable_samples=(tonumber(READER_CLOSE.stable_samples) or 0)+1
        self:_reader_close_poll_state("native_surface_ready","confirming stable base")
        if READER_CLOSE.stable_samples>=2 then
            return self:_complete_reader_close(generation,reason)
        end
        return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("confirm",elapsed),"confirm native surface")
    end

    READER_CLOSE.stable_samples=0
    self:_reader_close_poll_state("native_surface_missing","waiting for FileManager")
    -- Once CloseDocument has been acknowledged and ReaderUI has left the
    -- stack, there is no benefit in exposing a blank/native interval for five
    -- seconds. Give KOReader one short tick to create its own FileManager; if
    -- it does not, establish the required native base immediately and keep it
    -- below the already-rendered MiuRead home.
    local can_build_concealed=READER_CLOSE.close_event_received==true and elapsed>=.35
    if (can_build_concealed or elapsed>=1.2) and READER_CLOSE.fallback_attempted~=true then
        READER_CLOSE.fallback_attempted=true
        logger.info("[MiuRead][ReaderClose] creating concealed FileManager base",
            "generation=",tostring(generation),"elapsed=",string.format("%.2f",elapsed))
        local ready=self:_ensure_filemanager_base(
            READER_CLOSE.reader_file or HOME_RETURN_FILE or HOME_READER_FILE,
            {conceal_under_home=true,refresh_kind="ui"})
        if not ready then
            logger.warn("[MiuRead][ReaderClose] concealed FileManager base failed",
                "generation=",tostring(generation))
        end
        return self:_schedule_reader_return_finish(generation,.10,"concealed FileManager")
    end
    if elapsed>=10 then
        READER_CLOSE.state="failed"
        self:_finish_page_transition(0,"reader close recovery required")
        self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
        return false
    end
    return self:_schedule_reader_return_finish(generation,reader_close_poll_delay("missing",elapsed),"waiting for native surface")
end

function Plugin:_request_reader_close(generation,source)
    if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return false end
    local state,active=self:_reader_lifecycle_state()
    if state~="active" or not active or not active.document then
        self:_schedule_reader_return_finish(generation,.10,"reader already closing")
        return false
    end
    READER_CLOSE.close_attempts=(tonumber(READER_CLOSE.close_attempts) or 0)+1
    READER_CLOSE.close_command_sent_at=monotonic_wall_time()
    logger.info("[MiuRead][ReaderClose] close command",
        "generation=",tostring(generation),"attempt=",tostring(READER_CLOSE.close_attempts),
        "source=",tostring(source or "direct"))
    pcall(function() active:handleEvent(Event:new("CloseReaderMenu")) end)
    pcall(function() active:handleEvent(Event:new("CloseConfigMenu")) end)
    local ok_close,err_close=xpcall(function() active:onClose(false) end,debug.traceback)
    if not ok_close then
        logger.warn("[MiuRead][ReaderClose] close request failed",tostring(err_close))
        self:_schedule_reader_return_finish(generation,.18,"close request failed")
        return false
    end
    self:_schedule_reader_return_finish(generation,.10,"close requested")
    return true
end

function Plugin:return_to_miuread_home(reason)
    sync_home_session()
    if self:_stream_active() then self:_close_stream_session() end
    if HOME_EXITING or UIManager._exit_code~=nil then return false end
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    self._miuread_return_requested=true
    persist_home_session()

    self:_ensure_reader_transition_guard("return entry")
    local lifecycle,readerui=self:_reader_lifecycle_state()
    if lifecycle=="active" and readerui then
        local file=self:_reader_file(readerui,HOME_RETURN_FILE)
        local generation,started=self:_begin_reader_return(reason or "explicit return",file,true)
        if not started then return true end
        -- The transition and its shared download pause are already active before
        -- closing any transient reader widget. This keeps the action independent
        -- from ReaderToolbar:onCloseWidget and gives foreground navigation priority.
        self:_close_miuread_transients()
        self:_schedule_reader_return_finish(generation,.12,"return requested")
        UIManager:nextTick(function()
            self:_request_reader_close(generation,"next tick")
        end)
        UIManager:scheduleIn(.35,function()
            if generation~=(tonumber(READER_CLOSE.generation) or 0) or READER_CLOSE.state=="idle" then return end
            if (tonumber(READER_CLOSE.close_attempts) or 0)==0 then
                logger.warn("[MiuRead][ReaderClose] deferred close command did not run; retrying",
                    "generation=",tostring(generation))
                self:_request_reader_close(generation,"entry watchdog")
            end
        end)
        return true
    end

    local generation=self:_begin_reader_return(reason or "reader already closing",HOME_RETURN_FILE,false)
    self:_close_miuread_transients()
    self:_set_foreground("home_pending")
    self:_schedule_reader_return_finish(generation,.10,"reader already closing")
    return true
end

function Plugin:search_dialog()
    if not self:require_login() then return end
    local d
    d=InputDialog:new{
        title=_("Search books"), input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q~="" then self:search(q) end
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_cancel_search(reason)
    self._search_generation=(tonumber(self._search_generation) or 0)+1
    if self.search_async then self.search_async:cancel(reason or "cancelled") end
    local dialog=self._search_dialog
    self._search_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:search(q)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.search_async and self.search_async:busy() then self:_cancel_search("new_search") end

    self._search_generation=(tonumber(self._search_generation) or 0)+1
    local generation=self._search_generation
    local closing=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在搜索《"..tostring(q).."》……\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function()
            if closing then return end
            closing=true
            if generation==self._search_generation and self.search_async then
                self.search_async:cancel("search_dialog_closed")
                self._search_generation=self._search_generation+1
            end
            self._search_dialog=nil
        end,
        buttons={
            {{text="取消搜索",callback=function()
                if closing then return end
                closing=true
                if generation==self._search_generation and self.search_async then
                    self.search_async:cancel("user_cancelled")
                end
                self._search_generation=self._search_generation+1
                self._search_dialog=nil
                UIManager:close(dialog)
            end}},
        },
    }
    self._search_dialog=dialog
    UIManager:show(dialog)

    local function finish(result)
        if generation~=self._search_generation then return end
        closing=true
        self._search_dialog=nil
        UIManager:close(dialog)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","搜索"))
            return
        end
        local data=result.value or {}
        local items={}
        local function add(r)
            local b=normalize(r)
            if b.bookId~="" then
                items[#items+1]={text=b.title,post_text=b.author,callback=function() self:book_menu(b) end}
            end
        end
        for _,g in ipairs(data.results or data.books or {}) do
            if g.books then for _,r in ipairs(g.books) do add(r) end else add(g) end
        end
        self:list(_("Search").." · "..q,items,"没有找到相关书籍")
    end

    local function run_on_main_thread()
        UIManager:scheduleIn(.10,function()
            if generation~=self._search_generation then return end
            local ok,value=xpcall(function() return self.api:search(q,0,40) end,debug.traceback)
            finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
        end)
    end

    if not self.search_async or not self.search_async:available() then
        run_on_main_thread()
        return
    end

    local auth=U.copy(self.store:auth())
    local started,err=self.search_async:run("book_search",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        local api=ApiChild:new(HttpChild:new(child_store),child_store)
        return api:search(q,0,40)
    end,finish,32)
    if not started then
        logger.warn("[MiuRead][Search] async unavailable; falling back",tostring(err or "worker busy"))
        run_on_main_thread()
    end
end
function Plugin:_variant_exists(book_id,kind)
    local r=self.store:variant(book_id,kind)
    return r and r.file and U.file_exists(r.file) and r or nil
end
function Plugin:_book_has_cache(book_id)
    local stored=self.store:book(book_id)
    if not stored then return false end
    for _,r in pairs(stored.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(stored.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end
function Plugin:_preferred_record(book_id)
    local session=self.store:session(book_id) or {}
    local last=tostring(session.last_read_path or "")
    local b=self.store:book(book_id)
    local fallback
    if not b then return nil end
    local function consider(record)
        if type(record)~="table" or not record.file then return end
        if tostring(record.file)==last or tostring(record.original_file or "")==last then fallback=record; return true end
        if not fallback then fallback=record end
    end
    for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
        if consider(b.variants and b.variants[kind]) then return fallback end
    end
    for _,row in pairs(b.chapters or {}) do
        for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
            if consider(row and row[kind]) then return fallback end
        end
    end
    return fallback
end
local function mp_date(value)
    value=tonumber(value or 0) or 0
    return value>0 and os.date("%Y-%m-%d",value) or ""
end

function Plugin:_mp_normalize_book(book)
    local original=type(book)=="table" and book or {}
    local normalized=U.merge(original,normalize(original))
    normalized.bookId=tostring(normalized.bookId or normalized.book_id or "")
    return normalized
end

function Plugin:_refresh_mp_articles(book,silent,on_done)
    book=self:_mp_normalize_book(book)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if not silent then self:info(_("Network unavailable")) end
        if on_done then on_done(nil,"网络不可用") end
        return false
    end
    if self.mp_async:busy() then
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在刷新文章列表",2) end
    local book_copy=U.copy(book)
    local started,err=self.mp_async:run("mp-articles",function()
        return self.mp:articles(book_copy.bookId,{force=true,title=book_copy.title})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
            if not silent then self:show_mp_articles(book_copy,result.value) end
        else
            local cached=self.mp:cached_articles(book_copy.bookId)
            local message=result and result.error or "文章列表刷新失败"
            logger.warn("[MiuRead][MP] article list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
            if not silent then
                if #cached>0 then self:toast("刷新失败，继续显示本地文章列表",3); self:show_mp_articles(book_copy,cached)
                else self:info(self:_friendly_remote_error(message,"公众号文章列表加载")) end
            end
        end
    end,75)
    if not started and not silent then self:info(self:_friendly_remote_error(err or "无法启动文章列表任务","公众号文章列表加载")) end
    return started
end

function Plugin:mp_account(book)
    book=self:_mp_normalize_book(book)
    if not Protocol.is_mp_account(book.bookId) then
        self:info("微信读书书架没有返回可用的公众号。")
        return
    end
    book.content_type="mp_account"
    self.store:save_book(book.bookId,{
        book_id=book.bookId,title=book.title,author=book.author,cover=book.cover,
        content_type="mp_account",updated_at=os.time(),
    })
    local cached=self.mp:cached_articles(book.bookId)
    if #cached>0 then
        self:show_mp_articles(book,cached)
        if self.mp:list_stale(book.bookId) and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_articles(book,true)
        end
    else
        self:_refresh_mp_articles(book,false)
    end
end

function Plugin:open_mp_account_by_id(book_id,title)
    local found
    local accounts=self.mp:cached_accounts()
    for _,book in ipairs(accounts or {}) do
        if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
    end
    if not found then
        local _,cached_mp=self.library:cached()
        for _,book in ipairs(cached_mp or {}) do
            if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
        end
    end
    found=found or {bookId=book_id,title=title or "公众号",author="公众号",content_type="mp_account"}
    self:mp_account(found)
end

function Plugin:show_mp_articles(book,articles,title_suffix)
    book=self:_mp_normalize_book(book)
    articles=type(articles)=="table" and articles or {}
    local items={
        {text="搜索文章",callback=function() self:mp_search_dialog(book,articles) end},
        {text="刷新文章列表",post_text="最近 100 篇",callback=function() self:_refresh_mp_articles(book,false) end},
        {text="管理本号缓存",callback=function()
            self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
        end},
    }
    for _,row in ipairs(articles) do
        local article=U.copy(row)
        local record=self.mp:article_record(book.bookId,article)
        local post=mp_date(article.createTime)
        if record then post=(post~="" and (post.." · ") or "").."已缓存" end
        items[#items+1]={
            text=tostring(article.title or "文章"),post_text=post,
            callback=function() self:open_or_download_mp_article(book,article) end,
        }
    end
    local title=tostring(book.title or "公众号").." · "..tostring(#articles).."篇"
    if title_suffix then title=title.." · "..tostring(title_suffix) end
    self:list(title,items,"暂无文章")
end

function Plugin:mp_search_dialog(book,articles)
    local dialog
    dialog=InputDialog:new{
        title="搜索本号文章",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local query=U.trim(dialog:getInputText()):lower()
                UIManager:close(dialog)
                if query=="" then return end
                local results={}
                for _,article in ipairs(articles or {}) do
                    if tostring(article.title or ""):lower():find(query,1,true) then results[#results+1]=article end
                end
                if #results==0 then self:info("没有找到相关文章") else self:show_mp_articles(book,results,"搜索结果") end
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:_close_mp_download_dialog()
    local dialog=self._mp_download_dialog
    self._mp_download_dialog=nil
    if dialog then pcall(function() UIManager:close(dialog) end) end
end

function Plugin:_start_mp_article_download(book,article,force)
    if self.mp_async:busy() then self:info("另一项公众号任务正在进行中。") return false end
    local title=tostring(article.title or "文章")
    local cancelled=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在下载公众号文章\n\n"..title.."\n\n文章通常较小，下载完成后会自动打开。",
        title_align="left",
        buttons={{{text="取消下载",callback=function()
            cancelled=true
            if self.mp_async and self.mp_async:busy() then self.mp_async:cancel("user_cancelled") end
            self:_close_mp_download_dialog()
            self:status_toast("公众号","已取消下载",3)
        end}}},
    }
    self._mp_download_dialog=dialog
    UIManager:show(dialog)

    local book_copy,article_copy=U.copy(book),U.copy(article)
    local prefs=self.store:preferences()
    local started,err=self.mp_async:run("mp-article",function()
        return self.mp:fetch_article(book_copy,article_copy,{images=prefs.mp_images==true,force=force==true})
    end,function(result)
        self:_close_mp_download_dialog()
        if cancelled then return end
        self.store:reload()
        if result and result.ok and type(result.value)=="table" and result.value.file then
            self:open_file(result.value.file)
            return
        end
        local fallback=self.mp:article_record(book_copy.bookId,article_copy)
        if fallback then
            self:status_toast("公众号","下载未完整完成，已打开原缓存",4)
            self:open_file(fallback.file)
        else
            logger.warn("[MiuRead][MP] article download failed",tostring(result and result.error))
            self:info("文章下载失败：\n"..U.first_line(result and result.error or "未知错误",180))
        end
    end,120)
    if not started then
        self:_close_mp_download_dialog()
        self:info("无法启动文章下载：\n"..tostring(err))
        return false
    end
    return true
end

function Plugin:open_or_download_mp_article(book,article,force)
    local record=self.mp:article_record(book.bookId,article)
    if record and force~=true then self:open_file(record.file); return end
    if not self:require_login() then return end
    if not self:is_online() then
        if record then self:open_file(record.file) else self:info(_("Network unavailable")) end
        return
    end
    if force==true then
        self:_start_mp_article_download(book,article,true)
        return
    end
    UIManager:show(ConfirmBox:new{
        text="《"..tostring(article.title or "文章").."》尚未缓存。\n\n是否下载并打开？公众号文章通常只需几秒。",
        ok_text="下载并打开",
        ok_callback=function() self:_start_mp_article_download(book,article,false) end,
    })
end

function Plugin:mp_cache_menu(book,articles)
    local items={}
    local cached_count=0
    for _,article in ipairs(articles or {}) do
        if self.mp:article_record(book.bookId,article) then cached_count=cached_count+1 end
    end
    items[#items+1]={text="已缓存文章",post_text=tostring(cached_count).." 篇",enabled=false}
    for _,row in ipairs(articles or {}) do
        local article=U.copy(row)
        if self.mp:article_record(book.bookId,article) then
            items[#items+1]={text=tostring(article.title or "文章"),post_text=mp_date(article.createTime),callback=function()
                self:mp_article_cache_menu(book,article)
            end}
        end
    end
    items[#items+1]={text="清理本号文章缓存",callback=function()
        UIManager:show(ConfirmBox:new{text="清理《"..tostring(book.title or "公众号").."》的文章列表和单篇缓存？",ok_callback=function()
            local ok,err=self.mp:clear_account(book.bookId)
            if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
            self:status_toast("公众号","本号缓存已清理",4)
            UIManager:scheduleIn(.15,function() self:show_mp_articles(book,articles,"缓存已清理") end)
        end})
    end}
    return items
end

function Plugin:mp_article_cache_menu(book,article)
    local items={
        {text="打开文章",callback=function() self:open_or_download_mp_article(book,article) end},
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(book,article,true) end},
        {text="删除单篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的单篇缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(book.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
                UIManager:scheduleIn(.15,function()
                    self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
                end)
            end})
        end},
    }
    self:list(article.title or "文章",items)
end

function Plugin:mp_global_cache_menu()
    return {
        {text="清理全部公众号缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="清理全部公众号列表和单篇文章缓存？",ok_callback=function()
                local ok,err=U.remove_tree(self.store:mp_root())
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                if not U.mkdir(self.store:mp_root()) then self:info("缓存目录重建失败，请重启 KOReader。") return end
                self:status_toast("公众号","全部缓存已清理",4)
            end})
        end},
    }
end

function Plugin:open_mp_neighbor(delta)
    local context=self.mp:identify_path(self:_current_document_path())
    if not context then self:info("当前不是觅阅公众号文章。") return end
    local articles=self.mp:cached_articles(context.bookId)
    local index
    for i,article in ipairs(articles or {}) do
        if tostring(article.reviewId or article.originalId)==tostring(context.reviewId) then index=i; break end
    end
    if not index then self:info("本地文章列表中找不到当前位置。") return end
    local target=articles[index+(tonumber(delta) or 0)]
    if not target then self:toast((delta or 0)<0 and "已经是第一篇" or "已经是最后一篇",2); return end
    self:open_or_download_mp_article({bookId=context.bookId,title=context.account_title or "公众号",author="公众号"},target)
end

function Plugin:book_menu(b)
    local original=type(b)=="table" and b or {}
    b=U.merge(original,normalize(original))
    if Protocol.is_mp_account(b.bookId) then self:mp_account(b); return end
    self:list(b.title,{
        {text="开始阅读",callback=function() self:_open_book_stream(b) end},
        {text="书籍详情",callback=function() self:book_details(b) end},
    })
end

function Plugin:book_details(b)
    b=U.copy(b or {})
    local id=tostring(b.bookId or b.book_id or "")
    if id=="" then self:info("当前书籍缺少可查询的图书编号。") return false end
    local auth=U.copy(self.store:auth())
    local data_dir,temp_dir=self.store.data_dir,self.store.temp_dir
    local context=self:_interactive_network_context()
    return self:_run_interactive_network("book-details:"..id,"details",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local child_store=interactive_child_store(auth,data_dir,temp_dir)
        local child_api=ApiChild:new(HttpChild:new(child_store),child_store)
        local request_ok,detail=pcall(child_api.book,child_api,id)
        local child_auth,auth_changed=child_store:snapshot()
        return {request_ok=request_ok,detail=request_ok and detail or nil,error=request_ok and nil or tostring(detail),
            auth=child_auth,auth_changed=auth_changed}
    end,function(result)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","书籍详情加载"))
            return
        end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed==true then self:_apply_interactive_auth{auth=payload.auth,changed=true} end
        if payload.request_ok~=true then
            self:info(self:_friendly_remote_error(payload.error or "未知错误","书籍详情加载"))
            return
        end
        local x=type(payload.detail)=="table" and payload.detail or {}
        local z=normalize(x)
        local title=z.title~="" and z.title or tostring(b.title or "书籍详情")
        local author=z.author~="" and z.author or tostring(b.author or "")
        self:info(title.."\n"..author.."\n\n"..tostring(x.intro or x.description or b.intro or b.description or "暂无简介"))
    end,{context=context,timeout=28,status_title="书籍详情",status_text="正在后台获取书籍信息…"})
end
function Plugin:_download_preflight(callback)
    local state=HomeData.device_state(true) or {}
    local function check_battery()
        local battery=tonumber(state.battery)
        if self:_notice_enabled("low_battery") and battery and battery<20 and state.charging~=true then
            local dialog
            dialog=ButtonDialog:new{title="当前电量较低。继续下载整本书可能明显缩短使用时间。",title_align="center",buttons={
                {{text="继续下载",callback=function() UIManager:close(dialog); callback() end}},
                {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_battery",false); callback() end}},
                {{text="取消",callback=function() UIManager:close(dialog) end}},
            }}
            UIManager:show(dialog)
            return true
        end
        callback()
        return true
    end
    local free=tonumber(state.storage_free)
    if free and free>0 and free<64*1024*1024 then
        self:info("剩余存储空间不足，无法安全开始下载。\n\n请先打开“下载”并进入存储清理。")
        return false
    end
    if self:_notice_enabled("low_storage") and free and free>0 and free<256*1024*1024 then
        local dialog
        dialog=ButtonDialog:new{title="剩余存储空间较少。下载图片或生成 EPUB 后可能无法正常保存。",title_align="center",buttons={
            {{text="继续下载",callback=function() UIManager:close(dialog); check_battery() end}},
            {{text="打开下载管理",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_storage",false); check_battery() end}},
        }}
        UIManager:show(dialog)
        return true
    end
    return check_battery()
end

function Plugin:choose_download_mode(b,opt,open_after)
    if b and open_after then return self:_open_book_stream(b) end
    return
end
function Plugin:choose_download(b,limit,open_after,uid)
    if b and open_after then return self:_open_book_stream(b) end
    return
end
function Plugin:_download_summary(rec,opt)
    local preview=tostring(rec and rec.access_scope or "")=="preview" and not (opt and opt.chapter_uid)
    local preview_mode=tostring(rec and rec.preview_mode or "complete")
    local heading=preview and (preview_mode=="info" and "试读信息版生成完成"
        or (preview_mode=="partial" and "部分试读版生成完成" or "试读版生成完成")) or "下载完成"
    local lines={heading}
    local annotation_note=DownloadResult.summary_note(rec)
    if annotation_note then lines[#lines+1]=annotation_note end
    lines[#lines+1]="保存位置："..tostring(rec.file or "")
    lines[#lines+1]="打开一次后会出现在 KOReader 最近阅读中"
    if rec and rec.partial_range==true then
        lines[#lines+1]="章节版不会上传整书阅读进度，避免局部比例覆盖云端位置。"
    end
    if preview and preview_mode=="info" then lines[#lines+1]="本文件只包含书籍信息和权限说明。" end
    return table.concat(lines,"\n")
end

function Plugin:_refresh_local_files()
    local ui=self.ui
    if not ui then return end
    local chooser=ui.file_chooser
    if chooser then
        if type(chooser.refreshPath)=="function" then pcall(chooser.refreshPath,chooser)
        elseif type(chooser.refresh)=="function" then pcall(chooser.refresh,chooser) end
    end
    if type(ui.onRefresh)=="function" then pcall(ui.onRefresh,ui) end
end
function Plugin:_update_open_shelf_download_status(book_id,status)
    local view=self._shelf_view
    if not view or view._miu_closed or type(view.item_table)~="table" then return false end
    local changed=false
    for _,entry in ipairs(view.item_table) do
        if tostring(entry.book_id or "")==tostring(book_id or "") then
            entry.status=tostring(status or "")
            changed=true
        end
    end
    if changed and type(view.updateItems)=="function" then pcall(view.updateItems,view,nil,true) end
    return changed
end
local DOWNLOAD_STAGE_LABELS={
    prepare="准备下载",catalog="读取目录",resume="恢复断点",content="下载正文",
    underlines="获取划线",thoughts="获取想法",footnotes="处理脚注",
    images="处理图片",package="生成 EPUB",restart="断点恢复",done="下载完成",error="下载失败",
    cancelled="下载已取消",
}
function Plugin:_download_dialog_is_shown(runtime)
    runtime=runtime or self._download_runtime
    local dialog=runtime and runtime.dialog or nil
    if not dialog then return false end
    local ok,shown=pcall(UIManager.isWidgetShown,UIManager,dialog)
    if ok and shown==true then return true end
    -- The widget may have been retired by a reader transition, suspend, resize
    -- or generic transient cleanup. A stale Lua reference must never be treated
    -- as a visible progress surface.
    if runtime.dialog==dialog then runtime.dialog=nil end
    logger.info("[MiuRead][DownloadUI] stale dialog reference cleared",
        "background=",tostring(runtime.background==true))
    return false
end
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if self:_download_dialog_is_shown(runtime) then
        runtime.dialog:set_state(state)
    end
    if state and state.network_ipv4_suggested==true
        and state.stage~="package" and state.stage~="done" and state.stage~="error"
        and state.stage~="cancelled" then
        self:_show_download_ipv4_suggestion(runtime,state)
    end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    local home_percent=self:_download_percent(state)
    local home_mark=math.floor(home_percent/5)*5
    if runtime.home_progress_mark~=home_mark then
        runtime.home_progress_mark=home_mark
        self:_home_update_download_card(runtime,state)
    end
    if state and state.stage=="rate_limit" then
        local wait=tonumber(state.wait_seconds) or 0
        self:_update_open_shelf_download_status(runtime.book.bookId,
            wait>0 and ("请求受限 · "..tostring(wait).."秒") or "请求受限 · 等待恢复")
    elseif state and state.stage=="restart" then
        self:_update_open_shelf_download_status(runtime.book.bookId,"从断点自动恢复")
    elseif state and state.waiting_network==true then
        self:_update_open_shelf_download_status(runtime.book.bookId,"等待网络")
    end
    if runtime.background and self.store:preferences().download_notice_enabled~=false then
        runtime.notified_milestones=runtime.notified_milestones or {}
        local percent=self:_download_percent(state)
        for _,mark in ipairs({25,50,75}) do
            if percent>=mark and not runtime.notified_milestones[mark] then
                runtime.notified_milestones[mark]=true
                self:_update_open_shelf_download_status(runtime.book.bookId,"生成中 "..tostring(mark).."%")
                self:status_toast("后台下载",tostring(runtime.book.title or "未命名").." · "..tostring(mark).."%",3)
            end
        end
    end
end
function Plugin:_finish_download_runtime(runtime,result)
    if self._download_runtime~=runtime then return end
    local b=runtime.book or {}
    local opt=runtime.options or {}
    local done=runtime.done
    local open_after=runtime.open_after==true
    local was_background=runtime.background==true
    self:_close_download_dialog("finished")
    if self.download_task then self.download_task:set_backgrounded(false) end
    self._download_runtime=nil
    if not result or result.ok~=true then
        local err=result and result.error or "未知下载错误"
        logger.warn("[MiuRead][Download] failed",tostring(err))
        if tostring(err)=="下载已取消" then
            self.store:clear_download_state()
            self:_update_open_shelf_download_status(b.bookId,"生成已取消")
            self:_notify_home_data_changed("content")
            if was_background then self:status_toast("觅阅","下载已取消",3) else self:toast("下载已取消",3) end
            self:_start_next_queued_download()
            return
        end
        local auth_required=Http.is_auth_error(err)
        local rate_limited=Http.is_rate_limit_error(err)
        local network_failed=Http.is_network_error and Http.is_network_error(err)
        local content_pending=tostring(err):find("[MiuReadAnnotationPending]",1,true)~=nil
        local image_missing=tostring(err):find("[MiuReadImageMissing]",1,true)~=nil
            or tostring(err):find("[MiuReadImageExternal]",1,true)~=nil
        local validation_failed=tostring(err):find("EPUB 完整性验证失败",1,true)~=nil
        local wait_seconds=tonumber(tostring(err):match("wait_seconds=(%d+)"))
        if auth_required then self:_mark_auth_problem("download",err,true) end
        self:_write_download_state("failed",{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),
            error=tostring(err),stage=runtime.last_state and runtime.last_state.stage,
            current=runtime.last_state and runtime.last_state.current,total=runtime.last_state and runtime.last_state.total,
            percent=runtime.last_state and runtime.last_state.percent,seen=false,
            auth_required=auth_required or nil,
            error_kind=auth_required and "authentication" or (rate_limited and "rate_limit"
                or (network_failed and "network" or (image_missing and "image_missing"
                or (content_pending and "content_pending" or (validation_failed and "validation" or nil))))),
            wait_seconds=rate_limited and wait_seconds or nil,
        },true)
        self:_update_open_shelf_download_status(b.bookId,
            auth_required and "等待重新登录" or (rate_limited and "请求受限 · 稍后继续"
                or (network_failed and "等待网络 · 可继续"
                or (image_missing and "正文图片待修复 · 断点已保留" or "生成未完成"))))
        self:_notify_home_data_changed("content")
        local first
        if auth_required then
            first="微信读书登录已失效。下载断点已经保留，请重新扫码登录后继续。"
        elseif rate_limited then
            first="微信读书暂时限制了请求频率。插件已停止继续请求，正文和断点均已保留，请稍后继续下载。"
        elseif network_failed then
            first="网络连接暂时中断。已完成章节和下载断点均已保留，网络恢复后可继续下载。"
        elseif image_missing then
            first="书籍正文图片仍有缺失。已完成章节和下载断点均已保留，可在“修复书籍”中只补缺失内容；原文件没有被覆盖。"
        elseif content_pending then
            first="生成未完成，原文件和下载进度已保留。请稍后使用“生成／更新书籍”重试。"
        elseif validation_failed then
            first="生成的书籍校验未通过，原文件和下载进度已保留。请重试；若仍失败，请反馈日志。"
        else
            first=U.first_line(err)
        end
        if was_background then
            local toast_title=auth_required and "下载登录验证失败" or (rate_limited and "请求受限"
                or (network_failed and "等待网络" or (image_missing and "书籍图片待修复" or "觅阅")))
            local toast_text=auth_required and "后台下载已暂停，重新扫码后自动继续"
                or (rate_limited and "已停止继续请求，下载断点已保留"
                or (network_failed and "下载断点已保留，网络恢复后可继续"
                or (image_missing and "已完成内容和断点已保留，可用修复书籍继续"
                or (content_pending and "生成未完成，原文件和进度已保留"
                or (tostring(b.title or "未命名").."下载未完成，进度已保留")))))
            self:status_toast(toast_title,toast_text,5)
        else self:info(first) end
        -- Any failed book pauses the single waiting task. The user decides whether
        -- to retry the current book or skip it, avoiding repeated requests after an
        -- account, network, validation or content problem.
        if #self.store:download_queue()>0 then
            self:status_toast("下载队列","等待任务已暂停，请先处理当前失败任务",5)
        end
        return
    end
    self:_mark_auth_channel_ok("download")
    local rec=self:_merge_download_result(result,b,opt)
    if opt.annotations==true then
        if DownloadResult.annotation_pending(rec) then
            local kind=tostring(rec.annotation_error_kind or ((rec.annotation_summary or {}).error_kind) or "incomplete")
            local errors=type(rec.annotation_summary)=="table" and rec.annotation_summary.errors or nil
            local detail="划线与想法未完整获取"
            if type(errors)=="table" and #errors>0 then
                local first=errors[1]
                detail=type(first)=="table" and tostring(first.error or detail) or tostring(first or detail)
            end
            if kind=="forbidden" then
                self:_mark_auth_access_denied("annotations",detail,true)
            elseif kind=="authentication" then
                self:_mark_auth_problem("annotations",detail,true)
            else
                self:_mark_auth_channel_error("annotations",detail)
            end
        else
            self:_mark_auth_channel_ok("annotations")
        end
    end
    if rec.pending_install and tostring(self:_current_document_path() or "")~=tostring(rec.file or "") then
        self:_install_pending_downloads(false)
        self.store:reload()
        local kind=rec.variant or (opt.annotations and "notes" or "clean")
        local refreshed=opt.chapter_uid and self.store:chapter_variant(b.bookId,opt.chapter_uid,kind)
            or self.store:variant(b.bookId,kind)
        if refreshed then rec=U.copy(refreshed) end
    end
    self:_refresh_local_files()
    local pending=rec.pending_install==true and rec.pending_file and U.file_exists(rec.pending_file)
    local annotation_pending=DownloadResult.annotation_pending(rec)
    local annotation_fallback=DownloadResult.annotation_fallback(rec)
    self:_update_open_shelf_download_status(b.bookId,DownloadResult.shelf_status(rec,pending))
    if pending or annotation_pending then
        self:_write_download_state(DownloadResult.state(rec,pending),{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),file=rec.file,
            pending_file=pending and rec.pending_file or nil,pending_install=pending or nil,percent=1,
            current=rec.chapter_count,total=rec.expected_chapter_count,completed_at=os.time(),
            annotation_pending=annotation_pending or nil,
            annotation_fallback=annotation_fallback or nil,
            annotation_error_kind=rec.annotation_error_kind,
        },true)
    else
        self.store:clear_download_state()
    end
    self:_notify_home_data_changed("content")
    if done then done(rec,was_background); self:_start_next_queued_download(); return end
    if pending then
        local text=DownloadResult.notice(b.title,rec,true)
        if was_background then self:status_toast("觅阅",text,5) else self:info(text) end
    elseif was_background then
        if self.store:preferences().download_complete_notice~=false or annotation_pending or annotation_fallback then
            self:status_toast("觅阅",DownloadResult.notice(b.title,rec,false),5)
        end
    elseif open_after and rec.file then
        if not annotation_pending then self.store:clear_download_state() end
        self:open_file(rec.file)
    else
        self:_show_download_complete(rec,opt,b)
    end
    self:_start_next_queued_download()
end
function Plugin:_recover_download_state()
    local state=self.store:download_state()
    if state.status~="active" then return false end
    local runtime={
        book=U.copy(state.book or {bookId=state.book_id,title=state.title}),
        options=U.copy(state.options or {}),
        last_state={stage=state.stage,current=state.current,total=state.total,percent=state.percent,
            chapter=state.chapter,message=state.message},
        background=true,dialog=nil,started_at=state.started_at,task=U.copy(state.task),
        open_after=false,done=nil,recovered=true,
    }
    if type(runtime.task)=="table" then
        self._download_runtime=runtime
        local ok,err=self.download_task:attach(runtime.task,
            function(progress) self:_on_download_progress(runtime,progress) end,
            function(result) self:_finish_download_runtime(runtime,result) end,
            runtime.book,runtime.options)
        if ok then
            runtime.task=self.download_task:descriptor() or runtime.task
            self.download_task:set_backgrounded(true)
            self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            logger.info("[MiuRead][Download] active task recovered","pid=",tostring(runtime.task.pid),
                "book=",tostring(runtime.book.bookId or ""))
            return true
        end
        self._download_runtime=nil
        logger.warn("[MiuRead][Download] active task recovery failed",tostring(err))
    end
    state.status="interrupted"
    state.error="上次下载已停止，已完成内容仍保存在断点缓存；再次下载时会继续。"
    state.updated_at=os.time()
    self.store:save_download_state(state)
    return false
end
function Plugin:_download_percent(state)
    state=state or {}
    local p=tonumber(state.percent)
    if not p then
        local current,total=tonumber(state.current) or 0,tonumber(state.total) or 0
        p=total>0 and current/total or 0
    elseif p>1 then p=p/100 end
    if p<0 then p=0 elseif p>1 then p=1 end
    return math.floor(p*100+0.5)
end
function Plugin:_download_state()
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() then
        local state=U.copy(runtime.last_state or {})
        state.status="active"
        state.title=runtime.book and runtime.book.title or state.title
        state.book_id=runtime.book and runtime.book.bookId or state.book_id
        state.background=runtime.background==true
        return state
    end
    return self.store:download_state()
end
function Plugin:_has_download_status()
    if self.download_task and self.download_task:busy() then return true end
    local state=self.store:download_state()
    if state.status=="completed" then self.store:clear_download_state(); return false end
    return state.status=="failed" or state.status=="interrupted" or state.status=="pending_install"
        or state.status=="annotation_pending"
end
function Plugin:_download_status_label()
    local state=self:_download_state()
    if state.status=="active" then
        if state.stage=="rate_limit" then
            local wait=tonumber(state.wait_seconds) or 0
            return wait>0 and ("后台下载 · 请求受限，"..tostring(wait).."秒后继续") or "后台下载 · 请求受限，等待恢复"
        end
        if state.stage=="restart" then return "后台下载 · 正在从断点恢复" end
        if state.waiting_network==true then return "后台下载 · 等待网络" end
        local title=U.utf8_truncate(state.title or "未命名",9)
        return "后台下载：《"..title.."》 "..tostring(self:_download_percent(state)).."%"
    end
    if state.status=="pending_install" then
        return "后台下载 · 等待更新"
    end
    if state.status=="annotation_pending" then return "后台下载 · 正文已完成，批注待修复" end
    if state.status=="completed" then return "后台下载 · 已完成" end
    if state.status=="failed" and state.auth_required==true then return "后台下载 · 等待重新登录" end
    if state.status=="failed" and state.error_kind=="network" then return "后台下载 · 等待网络，可继续" end
    if state.status=="failed" and state.error_kind=="image_missing" then return "后台下载 · 正文图片待修复" end
    if state.status=="failed" then return "后台下载 · 未完成" end
    if state.status=="interrupted" then return "后台下载 · 可继续" end
    return "后台下载"
end
function Plugin:_write_download_state(status,patch,force)
    local now=os.time()
    local stage=patch and patch.stage
    if not force and status=="active" and now-(self._download_state_last_write or 0)<2 and stage==self._download_state_last_stage then return end
    local state
    if force or status~="active" then state=U.copy(patch or {})
    else state=U.merge(self.store:download_state(),patch or {}) end
    state.status=status
    state.updated_at=now
    self.store:save_download_state(state)
    self._download_state_last_write=now
    self._download_state_last_stage=stage
end
function Plugin:_active_download_payload(runtime,state)
    local task=(self.download_task and self.download_task:descriptor()) or runtime.task
    return {
        title=runtime.book and runtime.book.title or "未命名",
        book_id=runtime.book and runtime.book.bookId or "",
        book=U.copy(runtime.book or {}),
        options=U.copy(runtime.options or {}),
        background=runtime.background==true,
        stage=state and state.stage or "prepare",
        current=state and state.current or 0,
        total=state and state.total or 0,
        percent=state and state.percent or 0,
        chapter=state and state.chapter or "",
        message=state and state.message or "",
        waiting_network=state and state.waiting_network==true or nil,
        wait_seconds=state and state.wait_seconds or nil,
        rate_limit_code=state and state.rate_limit_code or nil,
        started_at=runtime.started_at,
        task=U.copy(task),
    }
end
function Plugin:_close_download_dialog(reason)
    local runtime=self._download_runtime
    if not runtime or not runtime.dialog then return false end
    local dialog=runtime.dialog
    runtime.dialog=nil
    local shown=false
    local ok_shown,value=pcall(UIManager.isWidgetShown,UIManager,dialog)
    if ok_shown then shown=value==true end
    local ok,err=true,nil
    if shown then
        ok,err=pcall(dialog.close,dialog,reason or "programmatic")
        if not ok then
            logger.warn("[MiuRead][DownloadUI] dialog close failed",tostring(err))
            ok,err=pcall(UIManager.close,UIManager,dialog,"ui")
        end
    end
    logger.info("[MiuRead][DownloadUI] dialog retired",
        "reason=",tostring(reason or "programmatic"),
        "shown=",tostring(shown),"ok=",tostring(ok))
    return ok
end
function Plugin:_send_download_to_background()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then return end
    runtime.background=true
    if self.download_task then self.download_task:set_backgrounded(true) end
    self:_close_download_dialog("background")
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:status_toast("觅阅",tostring(runtime.book.title or "未命名").."已转入后台下载",3)
end
function Plugin:_show_active_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then self:show_download_status(); return end

    -- A non-nil reference is not proof that KOReader still shows the widget.
    -- If it is genuinely visible, keep the single instance and just make sure
    -- no newer MiuRead modal is covering it. Otherwise discard the stale ref.
    if self:_download_dialog_is_shown(runtime) then
        TransientGuard.close_all(runtime.dialog)
        UIManager:setDirty(runtime.dialog,"ui")
        logger.info("[MiuRead][DownloadUI] existing dialog reused")
        return
    end

    TransientGuard.close_all()
    local orphan_count=DownloadProgress.close_orphans and DownloadProgress.close_orphans() or 0
    if orphan_count>0 then
        logger.warn("[MiuRead][DownloadUI] orphan surfaces removed",tostring(orphan_count))
    end

    local dialog
    dialog=DownloadProgress:new{
        title="正在下载《"..tostring(runtime.book.title or "未命名").."》",
        on_cancel=function() if self.download_task then self.download_task:cancel() end end,
        on_background=function() self:_send_download_to_background() end,
        on_close=function(widget,reason)
            if self._download_runtime~=runtime then return end
            if runtime.dialog==widget then runtime.dialog=nil end
            local busy=self.download_task and self.download_task:busy() or false
            if busy and runtime.background~=true and reason~="finished" and reason~="cancelled" then
                -- Any external retirement (reader transition, suspend, resize,
                -- another MiuRead modal) means the task continues in background.
                runtime.background=true
                if self.download_task then self.download_task:set_backgrounded(true) end
                self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            end
            logger.info("[MiuRead][DownloadUI] closed",
                "reason=",tostring(reason),"busy=",tostring(busy),
                "background=",tostring(runtime.background==true))
        end,
    }
    runtime.dialog=dialog
    local shown=dialog:show()==true
    if not shown then
        if runtime.dialog==dialog then runtime.dialog=nil end
        runtime.background=true
        self.download_task:set_backgrounded(true)
        logger.warn("[MiuRead][DownloadUI] show failed; task kept in background")
        self:status_toast("下载","进度窗口未能打开，下载仍在后台继续",3)
        return
    end
    runtime.background=false
    self.download_task:set_backgrounded(false)
    if runtime.last_state then dialog:set_state(runtime.last_state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    logger.info("[MiuRead][DownloadUI] shown",
        "book=",tostring(runtime.book and runtime.book.bookId or ""),
        "percent=",tostring(self:_download_percent(runtime.last_state)))
end
function Plugin:_merge_download_result(result,book,opt)
    self.store:reload()
    if type(result.auth)=="table" then
        local current=self.store:auth()
        local current_account=type(current.account)=="table" and current.account or {}
        local child_account=type(result.auth.account)=="table" and result.auth.account or {}
        local snapshot=type(result.auth_snapshot)=="table" and result.auth_snapshot or {}
        local snapshot_session=tostring(snapshot.login_session_id or "")
        local snapshot_vid=tostring(snapshot.vid or child_account.vid or "")
        local snapshot_logged=tonumber(snapshot.logged_at or child_account.logged_at or 0) or 0
        local same_login=snapshot_session~=""
            and snapshot_session==tostring(current.login_session_id or "")
            and snapshot_vid~=""
            and snapshot_vid==tostring(current_account.vid or "")
        if same_login then
            local merged_cookies=U.copy(current.cookies or {})
            local core={wr_vid=true,wr_skey=true,wr_rt=true}
            local child_ticket_time=tonumber(result.auth.ticket_updated_at or 0) or 0
            local current_ticket_time=tonumber(current.ticket_updated_at or 0) or 0
            for name,value in pairs(result.auth.cookies or {}) do
                if not core[name] or child_ticket_time>=current_ticket_time then
                    merged_cookies[name]=value
                end
            end
            merged_cookies=Cookies.sanitize(merged_cookies)
            current.cookies=merged_cookies
            if tostring(result.auth.api_key or "")~="" then current.api_key=result.auth.api_key end
            if child_ticket_time>=current_ticket_time then
                if tostring(result.auth.wr_ticket or "")~="" then current.wr_ticket=result.auth.wr_ticket end
                if tostring(result.auth.wr_wrpa or "")~="" then current.wr_wrpa=result.auth.wr_wrpa end
                if child_ticket_time>current_ticket_time then current.ticket_updated_at=child_ticket_time end
            end
            self.store:save_auth(current)
        else
            logger.warn("[MiuRead][Download] child authentication merge skipped",
                "snapshot_session=",snapshot_session,
                "current_session=",tostring(current.login_session_id or ""),
                "snapshot_vid=",snapshot_vid,
                "current_vid=",tostring(current_account.vid or ""),
                "snapshot_logged_at=",tostring(snapshot_logged),
                "current_logged_at=",tostring(current_account.logged_at or 0))
        end
    end

    local rec=result.value or {}
    local kind=rec.variant or (opt.annotations and "notes" or "clean")
    if opt.chapter_uid then self.store:save_chapter_variant(book.bookId,opt.chapter_uid,kind,rec)
    else self.store:save_variant(book.bookId,kind,rec) end
    if rec.pending_install==true and rec.pending_file then
        self.store:add_pending_install(book.bookId,kind,opt.chapter_uid,rec)
    else
        self.store:remove_pending_install(book.bookId,kind,opt.chapter_uid)
    end
    local existing_book=self.store:book(book.bookId)
    local preserve_catalog=opt.chapter_uid~=nil or rec.partial_range==true
    local catalog=preserve_catalog and existing_book and existing_book.catalog or rec.chapter_map
    self.store:save_book(book.bookId,{
        book_id=tostring(book.bookId),title=book.title,author=book.author,cover=book.cover,
        directory=rec.directory,updated_at=os.time(),catalog=catalog,access=nil,
        content_type=book.content_type,
    })
    if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book.bookId) end
    self.access:unlock_book(book.bookId)

    if type(result.session)=="table" then
        local allowed={"psvts","pclts","token","reader_url","chapters","context_updated_at","app_id"}
        local patch={}
        for _,key in ipairs(allowed) do if result.session[key]~=nil then patch[key]=result.session[key] end end
        if next(patch) then self.store:save_session(book.bookId,patch) end
    end
    return rec
end
function Plugin:_show_download_complete(rec,opt,book)
    local dialog
    local buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self:open_file(rec.file) end}},
    }
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:show_download_status()
    if self.download_task and self.download_task:busy() then self:_show_active_download_dialog(); return end
    local state=self.store:download_state()
    if not state.status or state.status=="" then self:info("当前没有后台下载记录。") return end
    if state.status=="completed" then
        self.store:clear_download_state()
        self:info("下载已经完成，记录已自动清除。\n\n可在下载管理的已完成列表中打开书籍。")
        return
    end
    local title=tostring(state.title or "未命名")
    local lines={}
    if state.status=="completed" then lines[#lines+1]="下载完成"
    elseif state.status=="annotation_pending" then lines[#lines+1]="正文已生成，划线与想法待补全"
    elseif state.status=="pending_install" then
        if state.annotation_pending==true then lines[#lines+1]="新版本已下载完成"
        elseif state.annotation_fallback==true then lines[#lines+1]="新版本已下载完成"
        else lines[#lines+1]="新版本已下载完成" end
    elseif state.status=="failed" and state.auth_required==true then lines[#lines+1]="等待重新登录"
    elseif state.status=="failed" and state.error_kind=="rate_limit" then lines[#lines+1]="请求频率受限，稍后可继续"
    elseif state.status=="failed" and state.error_kind=="network" then lines[#lines+1]="网络中断，断点已保留"
    elseif state.status=="failed" and state.error_kind=="image_missing" then lines[#lines+1]="正文图片未完整，断点可修复"
    elseif state.status=="failed" then lines[#lines+1]="下载未完成"
    elseif state.status=="interrupted" then lines[#lines+1]="上次下载已中断"
    else lines[#lines+1]=tostring(state.status) end
    lines[#lines+1]="《"..title.."》"
    if state.current and state.total and tonumber(state.total)>0 then lines[#lines+1]="章节 "..tostring(state.current).." / "..tostring(state.total) end
    if state.error and state.error~="" then lines[#lines+1]="\n"..U.first_line(state.error) end
    if state.status=="pending_install" then lines[#lines+1]="\n关闭当前书籍后会自动安装新版本。" end
    local buttons={}
    local dialog
    if (state.status=="completed" or state.status=="annotation_pending") and state.file and U.file_exists(state.file) then
        buttons[#buttons+1]={{text="立即阅读",callback=function()
            UIManager:close(dialog)
            if state.status~="annotation_pending" then self.store:clear_download_state() end
            self:open_file(state.file)
        end}}
    end
    if state.status=="annotation_pending" and type(state.book)=="table" then
        buttons[#buttons+1]={{text="重新生成",callback=function()
            UIManager:close(dialog)
            self:choose_download(state.book,nil,false)
        end}}
    elseif state.status=="failed" and state.auth_required==true then
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    elseif state.status=="failed" and state.error_kind=="image_missing" and type(state.book)=="table" then
        buttons[#buttons+1]={{text="修复书籍",callback=function()
            UIManager:close(dialog); self:_repair_downloaded_book(state.book_id or state.book)
        end}}
    elseif (state.status=="failed" or state.status=="interrupted") and type(state.book)=="table" then
        buttons[#buttons+1]={{text="继续下载",callback=function() UIManager:close(dialog); self:download(state.book,state.options or {},false) end}}
    end
    if (state.status=="failed" or state.status=="interrupted") and #self.store:download_queue()>0 then
        buttons[#buttons+1]={{text="跳过并开始等待书籍",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self:_start_next_queued_download()
        end}}
        buttons[#buttons+1]={{text="停止全部下载",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self.store:save_download_queue({}); self:toast("下载任务已全部停止")
        end}}
    end
    buttons[#buttons+1]={{text="清除记录",callback=function() UIManager:close(dialog); self.store:clear_download_state() end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=table.concat(lines,"\n"),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_install_pending_record(book_id,kind,chapter_uid,record)
    local pending=tostring(record and record.pending_file or "")
    local target=tostring(record and record.file or "")
    if pending=="" or target=="" or not U.file_exists(pending) then return false,"等待安装文件不存在" end
    local validation={book_id=book_id,variant=record.variant or kind,chapters=record.chapter_map,
        previous_chapters=record.previous_chapter_map}
    local ok,mode_or_error=EpubInstaller.install(pending,target,validation)
    if not ok then return false,"无法安装新 EPUB："..tostring(mode_or_error) end
    local updated=U.copy(record)
    updated.pending_file=nil
    updated.pending_install=nil
    updated.previous_chapter_map=nil
    updated.installed_at=os.time()
    updated.file_size=U.file_size(target)
    if chapter_uid then self.store:save_chapter_variant(book_id,chapter_uid,kind,updated)
    else self.store:save_variant(book_id,kind,updated) end
    self.store:remove_pending_install(book_id,kind,chapter_uid)
    return true,updated
end

function Plugin:_install_pending_downloads(notify)
    -- Most reader closes have nothing to install. Avoid a full settings reload,
    -- integrity check and backup cycle on that hot path. A freshly opened Store
    -- already reflects disk state; download completion also updates this Store
    -- before requesting installation.
    local cached_pending=self.store:pending_installs()
    if type(cached_pending)~="table" or #cached_pending==0 then return false end

    local perf_started=monotonic_wall_time()
    local current=tostring(self:_current_document_path() or "")
    local reload_started=monotonic_wall_time()
    self.store:reload()
    local reload_ms=math.floor((monotonic_wall_time()-reload_started)*1000+.5)
    local prune_started=monotonic_wall_time()
    local pending=self.store:prune_pending_installs()
    local prune_ms=math.floor((monotonic_wall_time()-prune_started)*1000+.5)
    if #pending==0 then
        logger.info("[MiuRead][Download] pending install check",
            "pending=0","reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms))
        return false
    end
    local installed_records={}
    for _,item in ipairs(pending) do
        local book_id=tostring(item.book_id or "")
        local kind=tostring(item.kind or "")
        local chapter_uid=item.chapter_uid and tostring(item.chapter_uid) or nil
        local book=self.store:book(book_id)
        local record
        if chapter_uid then
            local row=book and book.chapters and book.chapters[chapter_uid]
            record=row and row[kind]
        else
            record=book and book.variants and book.variants[kind]
        end
        if not record or record.pending_install~=true or not U.file_exists(record.pending_file) then
            self.store:remove_pending_install(book_id,kind,chapter_uid)
        elseif tostring(record.file or "")~=current then
            local ok,value=self:_install_pending_record(book_id,kind,chapter_uid,record)
            if ok then
                value.book_id=value.book_id or book_id
                value._kind=kind
                value._chapter_uid=chapter_uid
                installed_records[#installed_records+1]=value
            else
                logger.warn("[MiuRead][Download] pending install failed",tostring(value))
            end
        end
    end
    local installed=#installed_records
    if installed>0 then
        local remaining=self.store:prune_pending_installs()
        local state=self.store:download_state()
        local aggregate=DownloadResult.aggregate(installed_records)
        local any_pending=aggregate.annotation_pending==true
        local any_fallback=aggregate.annotation_fallback==true
        local pending_record,last_record=nil,installed_records[#installed_records]
        for _,record in ipairs(installed_records) do
            if record.annotation_pending==true and not pending_record then pending_record=record end
        end
        if #remaining==0 then
            state.status=any_pending and "annotation_pending" or "completed"
            state.annotation_pending=any_pending or nil
            state.annotation_fallback=any_fallback or nil
            state.annotation_error_kind=pending_record and pending_record.annotation_error_kind or nil
            state.pending_install=nil
            state.pending_file=nil
            state.seen=false
            if installed==1 then
                local record=installed_records[1]
                state.file=record.file
                state.book_id=record.book_id
                local stored=self.store:book(record.book_id)
                state.title=stored and stored.title or record.title
                state.book=stored and {bookId=record.book_id,title=stored.title,author=stored.author,cover=stored.cover} or nil
                state.options=self:_annotation_retry_options(record._kind,record,record._chapter_uid)
            else
                state.file=pending_record and pending_record.file or (last_record and last_record.file)
                state.book=nil
                state.options=nil
                state.title="多个新版本"
            end
        else
            state.status="pending_install"
            state.pending_install=true
            state.annotation_pending=any_pending or state.annotation_pending
            state.annotation_fallback=any_fallback or state.annotation_fallback
        end
        state.updated_at=os.time()
        self.store:save_download_state(state)
        self:_refresh_local_files()
        if notify then
            local text
            if any_pending then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            elseif any_fallback then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            else text=installed>1 and "多个新版本已安装" or "新版本已安装" end
            self:status_toast("觅阅",text,4)
        end
        logger.info("[MiuRead][Download] pending install timing",
            "pending=",tostring(#pending),"installed=",tostring(installed),
            "reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms),
            "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
        return true
    end
    logger.info("[MiuRead][Download] pending install timing",
        "pending=",tostring(#pending),"installed=0",
        "reload_ms=",tostring(reload_ms),"prune_ms=",tostring(prune_ms),
        "total_ms=",tostring(math.floor((monotonic_wall_time()-perf_started)*1000+.5)))
    return false
end

function Plugin:_download_job_key(book,opt)
    opt=opt or {}
    local kind=opt.annotations and "notes" or "clean"
    return table.concat({
        tostring(book and book.bookId or ""),kind,tostring(opt.chapter_uid or "full"),
        tostring(opt.limit or "all"),tostring(opt.range_start_index or ""),
        tostring(opt.range_end_index or ""),
    },":")
end
function Plugin:_queue_download(book,opt,open_after,extra)
    extra=type(extra)=="table" and extra or {}
    local key=self:_download_job_key(book,opt)
    local book_id=tostring(book and (book.bookId or book.book_id) or "")
    local runtime=self._download_runtime
    local runtime_id=tostring(runtime and runtime.book and (runtime.book.bookId or runtime.book.book_id) or "")
    if runtime and ((book_id~="" and runtime_id==book_id) or self:_download_job_key(runtime.book,runtime.options)==key) then
        self:info("这本书已经在下载中。\n\n请在下载管理中查看当前状态。")
        return false
    end
    local queue=self.store:download_queue()
    for _,job in ipairs(queue) do
        local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
        if (book_id~="" and queued_id==book_id) or tostring(job.key or "")==key then
            self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
            return false
        end
    end
    local job={key=key,book=U.copy(book or {}),options=U.copy(opt or {}),open_after=open_after==true,
        queued_at=os.time(),defer_until_reader_closed=extra.defer_until_reader_closed==true or nil,
        wait_reason=extra.reason}
    local position,reason=self.store:enqueue_download(job)
    if not position then
        if reason=="full" then
            local waiting=queue[1] or {}
            local waiting_title=tostring(waiting.book and waiting.book.title or "未命名")
            local new_title=tostring(book and book.title or "未命名")
            local dialog
            dialog=ButtonDialog:new{title="等待位置中已有《"..waiting_title.."》。\n\n最多只能有一本正在下载、一本等待。",title_align="center",buttons={
                {{text="替换为《"..U.utf8_truncate(new_title,12).."》",callback=function()
                    UIManager:close(dialog)
                    self.store:save_download_queue({job})
                    self:status_toast("下载队列","等待任务已替换",3)
                    self:_notify_home_data_changed("content")
                end}},
                {{text="保留原等待任务",callback=function() UIManager:close(dialog) end}},
                {{text="查看下载",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            }}
            UIManager:show(dialog)
        else
            self:info("暂时无法加入下载队列。")
        end
        return false
    end
    local title=extra.defer_until_reader_closed and "已安排退出阅读后下载" or "新的任务已加入等待"
    self:status_toast("下载队列",title,3)
    self:_notify_home_data_changed("content")
    return true
end
function Plugin:_start_next_queued_download()
    if self.download_task and self.download_task:busy() then return false end
    if self._download_runtime then return false end
    local state=self.store:download_state()
    if state.status=="active" or state.status=="failed" or state.status=="interrupted" then
        return false
    end
    if not self:is_online() or not self:logged_in() then return false end
    local queue=self.store:download_queue()
    local next_job=queue[1]
    if not next_job then return false end
    if next_job.defer_until_reader_closed==true and self:_active_reader_ui() then return false end
    local job=self.store:dequeue_download()
    if not job then return false end
    UIManager:scheduleIn(.15,function()
        self:download(job.book or {},job.options or {},job.open_after==true,nil,true,true)
    end)
    return true
end
function Plugin:show_waiting_downloads()
    local queue=self.store:download_queue()
    if #queue==0 then self:info("当前没有等待下载的任务。") return end
    local job=queue[1]
    local title=tostring(job.book and job.book.title or "未命名")
    local variant=(job.options and job.options.annotations) and "划线与想法版" or "纯净版"
    if job.options and job.options.range_start_index then variant="章节版 · "..variant end
    if job.defer_until_reader_closed==true then variant=variant.." · 退出阅读后开始" end
    local items={
        {text=title,post_text=variant,callback=function()
            UIManager:show(ConfirmBox:new{text="从等待队列移除《"..title.."》？",ok_text="移除",cancel_text="保留",ok_callback=function()
                self.store:remove_queued_download(1); self:toast("已移出等待队列")
            end})
        end},
    }
    self:list("等待下载 · 最多一本",items)
end

function Plugin:download(b,opt,open_after,done,start_in_background,from_queue)
    if open_after and b then return self:_open_book_stream(b) end
    return false
end


function Plugin:_range_variant(book_id,kind)
    local record=self.store:variant(book_id,kind)
    if record and record.file and U.file_exists(record.file) and record.partial_range==true then return record end
end
function Plugin:_has_range_variant(book_id)
    return self:_range_variant(book_id,"range_notes")~=nil or self:_range_variant(book_id,"range_clean")~=nil
end
function Plugin:range_extend_menu(b)
    local items={}
    local clean=self:_range_variant(b.bookId,"range_clean")
    local notes=self:_range_variant(b.bookId,"range_notes")
    if clean then items[#items+1]={text="扩展章节版 · 纯净版",callback=function() self:show_range_extend_options(b,false,clean) end} end
    if notes then items[#items+1]={text="扩展章节版 · 划线与想法版",callback=function() self:show_range_extend_options(b,true,notes) end} end
    if #items==0 then return {{text="当前没有可扩展的章节版",enabled=false}} end
    return items
end
function Plugin:show_range_extend_options(b,annotations,record)
    local context=self:_interactive_network_context()
    self:_request_catalog(b,"range-extend",function(rows)
        rows=rows or {}
        local first=math.max(1,tonumber(record.range_start_index) or 1)
        local last=math.min(#rows,tonumber(record.range_end_index) or first)
        local items={}
        for _,count in ipairs({5,10,20}) do
            local target=math.min(#rows,last+count)
            items[#items+1]={text="追加后续 "..tostring(math.max(0,target-last)).." 章",enabled=target>last,
                callback=function()
                    self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                        range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
                end}
        end
        items[#items+1]={text="扩展到指定章节",enabled=last<#rows,callback=function()
            self:_chapter_list_menu(b,rows,"选择新的结束章节",function(target)
                self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                    range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
            end,last+1)
        end}
        items[#items+1]={text="重新选择章节范围",callback=function() self:chapters(b) end}
        self:list("扩展章节版 · 当前 "..tostring(last-first+1).." 章",items)
    end,{context=context,status_text="正在后台读取可扩展章节…"})
end
function Plugin:_current_catalog_index(record,rows)
    if not record or not record.record then return nil end
    local local_map=record.record.chapter_map or {}
    if #local_map==0 then return nil end
    local ratio=self.sync:local_ratio() or 0
    local position=self.sync:position(record,ratio,local_map)
    local uid=tostring(position and position.chapter_uid or "")
    if uid=="" then
        local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
        local chapter=local_map[local_index] or {}
        uid=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
    end
    if uid~="" then
        for index,chapter in ipairs(rows or {}) do
            if tostring(chapter.chapterUid or chapter.uid or "")==uid then return index end
        end
    end
    local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
    local hinted=tonumber(local_map[local_index] and local_map[local_index].index)
    if hinted and rows and rows[hinted] then return hinted end
    return nil
end
function Plugin:download_current_chapters(count)
    if self:_stream_active() then return self:_stream_go_next_chapter() end
    return
end

function Plugin:_chapter_state_text(book_id,chapter)
    local uid=tostring(chapter.chapterUid or chapter.uid or "")
    return tostring(chapter.wordCount or chapter.title or "")
end
function Plugin:_chapter_list_menu(b,rows,title,callback,start_index)
    local items={}
    for index,ch in ipairs(rows or {}) do
        if not start_index or index>=start_index then
            local chapter=ch
            items[#items+1]={
                text=chapter.title or tostring(chapter.chapterUid or chapter.uid or index),
                post_text=self:_chapter_state_text(b.bookId,chapter),
                callback=function() callback(index,chapter) end,
            }
        end
    end
    self:list(title,items,"没有可用章节")
end
function Plugin:_choose_range_version(b,rows,first,last,open_after)
    first=math.max(1,tonumber(first) or 1)
    last=math.min(#rows,tonumber(last) or first)
    if last<first then first,last=last,first end
    local first_ch,last_ch=rows[first],rows[last]
    local count=last-first+1
    local dialog
    local function choose(annotations)
        UIManager:close(dialog)
        self:choose_download_mode(b,{
            annotations=annotations,range_start_index=first,range_end_index=last,
            range_start_title=first_ch and first_ch.title,range_end_title=last_ch and last_ch.title,
        },open_after==true)
    end
    dialog=ButtonDialog:new{
        title="下载章节版\n"..tostring(first_ch and first_ch.title or ("第 "..first.." 章"))
            .." 至 "..tostring(last_ch and last_ch.title or ("第 "..last.." 章"))
            .."\n共 "..tostring(count).." 章",
        title_align="center",buttons={
            {{text="纯净版",callback=function() choose(false) end}},
            {{text="划线与想法版",callback=function() choose(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end
function Plugin:_range_count_menu(b,rows,first)
    local start_ch=rows[first]
    local items={}
    for _,count in ipairs({1,3,5,10,20}) do
        local actual=math.min(count,#rows-first+1)
        items[#items+1]={text="下载接下来 "..tostring(actual).." 章",post_text=actual<count and "已到全书末尾" or nil,
            callback=function() self:_choose_range_version(b,rows,first,first+actual-1,false) end}
    end
    items[#items+1]={text="选择结束章节",callback=function()
        self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
    end}
    self:list("从《"..tostring(start_ch and start_ch.title or "所选章节").."》开始",items)
end
function Plugin:chapters(b)
    self:_open_book_stream(b)
end

function Plugin:chapter_menu(b,ch)
    self:_open_book_stream(b)
end

function Plugin:_open_file_direct(path,options)
    options=type(options)=="table" and options or {}
    path=normalized_reader_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return false end
    if self:_should_open_book_stream(nil,path,options) then
        local book=self.store:identify_file(path,false)
        if self:_redirect_open_to_stream(book,path,"direct open") then return true end
    end
    sync_home_session()
    local now=os.time()
    local opening=tostring(HOME_SESSION.opening_file or "")
    local opening_age=now-(tonumber(HOME_SESSION.opening_at) or 0)
    if options.force_reopen~=true and opening~="" and opening_age>=0 and opening_age<12 then
        if opening==path then
            logger.info("[MiuRead][Reader] duplicate open ignored",opening)
            self:status_toast("正在打开书籍","请稍候",2)
            return true
        end
        logger.info("[MiuRead][Reader] replacing pending open target",opening,"with",path)
    end
    HOME_SESSION.opening_file=path
    HOME_SESSION.opening_at=now
    self:_cancel_interactive_network("reader opening")
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false

    if self:_home_enabled() and not HOME_NATIVE_VISIT and not HOME_SESSION_SUPPRESSED then
        HOME_RETURN_FILE=path
        mark_reader_origin(path)
        self._home_reader_transition=true
        self:_begin_page_transition("opening_reader")
        self:_home_stop_background("reader opening")
        -- Keep the rendered home underneath ReaderUI, but park all of its
        -- input handlers so it cannot leave stale gesture zones behind.
        self:_close_home_for_reader("reader opening")
        self:_set_foreground("reader_pending")
    end

    local function fail(err)
        if tostring(HOME_SESSION.opening_file or "")==path then
            HOME_SESSION.opening_file=nil
            HOME_SESSION.opening_at=0
        end
        self._home_reader_transition=false
        self:_finish_page_transition(0,"open failed")
        logger.warn("[MiuRead][Reader] open failed",path,tostring(err))
        local active=self:_active_reader_ui()
        if active and active.dialog then
            pcall(UIManager.setDirty,UIManager,active.dialog,"ui")
        else
            self:_ensure_filemanager_base(HOME_RETURN_FILE)
            self:_set_foreground("home_pending")
            self:_restore_home_after_reader_close(1)
        end
        self:info("书籍暂时无法打开：\n"..U.first_line(err,120))
        return false
    end

    if self.ui and self.ui.document and type(self.ui.switchDocument)=="function" then
        local ok,result=xpcall(function() return self.ui:switchDocument(path) end,debug.traceback)
        if not ok then return fail(result) end
        if result==false then return fail("KOReader 拒绝切换到目标书籍") end
        return result==nil and true or result
    end
    local ReaderUI=require("apps/reader/readerui")
    local ok,result=xpcall(function()
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        return ReaderUI:showReader(path)
    end,debug.traceback)
    if not ok then return fail(result) end
    if result==false then return fail("KOReader 拒绝打开目标书籍") end
    return result==nil and true or result
end

function Plugin:open_file(path)
    if not path then return end
    path=normalized_reader_file(path)
    local book=self.store:identify_file(path,false)
    local book_id=self:_stream_book_id_from_path(path,book)
    if self:_stream_enabled() and book_id~="" and not (book and (book.source=="local" or book.local_file==true)) then
        logger.warn("[MiuRead][Stream] open_file routed to stream","book=",book_id,"path=",path)
        return self:_open_book_stream({bookId=book_id,title=book and book.title,author=book and book.author})
    end
    local resolved=book_id~="" and self.access:resolve_path(book_id,path) or path
    if not resolved or not U.file_exists(resolved) then self:info(_("No cached file")); return end
    self:_open_file_direct(resolved)
end

function Plugin:_current_document_path()
    local doc=self.ui and self.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end
function Plugin:_variant_label(kind)
    kind=tostring(kind or "clean")
    local preview=kind:sub(1,8)=="preview_"
    local range=kind:sub(1,6)=="range_"
    local base=preview and kind:sub(9) or (range and kind:sub(7) or kind)
    local label=base=="notes" and "划线与想法版" or "纯净版"
    if preview then return "试读版 · "..label end
    if range then return "章节版 · "..label end
    return label
end
function Plugin:_close_download_menus()
    local detail=self._download_book_menu; self._download_book_menu=nil
    local root=self._downloads_menu; self._downloads_menu=nil
    if detail then pcall(function() UIManager:close(detail) end) end
    if root and root~=detail then pcall(function() UIManager:close(root) end) end
end
function Plugin:_cache_action_blocked()
    if self.download_task and self.download_task:busy() then self:info("下载任务进行中，暂时不能修改下载文件。") return true end
    local state=self.store:download_state()
    if state.status=="active" then self:info("后台下载状态正在恢复，暂时不能清理文件。") return true end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请勿重复操作。") return true end
    return false
end
local function human_size(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024*1024*1024 then return string.format("%.2f GB",bytes/(1024*1024*1024)) end
    if bytes>=1024*1024 then return string.format("%.1f MB",bytes/(1024*1024)) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end
local function path_name(path) return tostring(path or ""):match("([^/]+)$") or "" end
local function is_download_temp_name(name)
    name=tostring(name or "")
    return name=="download-task-owner.json"
        or name:match("^download%-settings%-.+%.lua$")
        or name:match("^download%-diagnostic%-.+%.txt$")
        or name:match("^download%-progress%-.+%.json$")
        or name:match("^download%-result%-.+%.json$")
        or name:match("^download%-recovery%-.+%.json$")
        or name:match("^download%-pause%-.+%.json$")
        or name:match("^download%-cancel%-.+")
end
local function is_epub_residue_name(name)
    name=tostring(name or "")
    return name:match("%.miuread%-new%-%d+%-%d+$")
        or name:match("%.miuread%-backup$")
        or name:match("%.miuread%-linkfix$")
        or name:match("%.miuread%-linkbak$")
end
local function is_pending_epub_name(name)
    return tostring(name or ""):match("%.miuread%-pending$")~=nil
end
function Plugin:_all_partial_cache_paths()
    local paths={}
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then paths[#paths+1]=path end
            end
        end
    end
    return paths
end
function Plugin:_download_residue_paths()
    local paths={}
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(U.list(self.store:books_root())) do
        if is_epub_residue_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(self:_all_partial_cache_paths()) do paths[#paths+1]=path end
    return paths
end
function Plugin:_storage_categories()
    local categories={books={},partial={},protected={},covers={self.store.covers_dir},temp={}}
    for _,path in ipairs(U.list(self.store:books_root())) do
        local name=path_name(path)
        if (name:lower():match("%.epub$") or name:lower():match("%.epub%.miuread%-locked$")) and not is_epub_residue_name(name) then
            categories.books[#categories.books+1]=path
        elseif is_epub_residue_name(name) or is_pending_epub_name(name) then
            categories.temp[#categories.temp+1]=path
        end
    end
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then
                    categories.partial[#categories.partial+1]=path
                else
                    categories.protected[#categories.protected+1]=path
                end
            end
        end
    end
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then categories.temp[#categories.temp+1]=path end
    end
    return categories
end
function Plugin:_run_cache_cleanup(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在清理，请稍候……")}
    self._cache_cleanup_dialog=dialog
    UIManager:show(dialog)

    local function close_progress()
        if self._cache_cleanup_dialog then pcall(function() UIManager:close(self._cache_cleanup_dialog) end) end
        self._cache_cleanup_dialog=nil
    end
    local function finish(result)
        local ok,unexpected=xpcall(function()
            close_progress()
            result=type(result)=="table" and result or {ok=false,error="未知错误"}
            result.finished_at=os.time()
            result.operation=tostring(options.operation or options.done_text or "缓存清理")
            self.store:reload()
            local commit_ok=true
            if result.ok==true and options.commit then
                local committed,err=xpcall(options.commit,debug.traceback)
                if not committed then
                    commit_ok=false
                    result.commit_error=tostring(err)
                    logger.err("[MiuRead][CacheCleanup] commit failed",tostring(err))
                    self.store:prune_missing_files()
                end
            elseif result.ok~=true then
                self.store:prune_missing_files()
            end
            U.mkdir(self.store.cache_books_dir); U.mkdir(self.store.covers_dir); U.mkdir(self.store.temp_dir)
            self.store:save_cleanup_result(result)
            self:_refresh_local_files()

            local freed=tonumber(result.freed_bytes or 0) or 0
            local removed=tonumber(result.removed or 0) or 0
            local message
            if result.ok==true and commit_ok then
                if freed>0 or removed>0 then
                    message=(options.done_text or _("Cache cleared"))
                        .."\n释放空间："..human_size(freed)
                        .."\n清理项目："..tostring(removed)
                elseif options.success_even_if_empty==true then
                    message=options.done_text or _("Cache cleared")
                else
                    message="没有可清理内容"
                end
            elseif result.ok==true then
                message="文件已清理，但记录刷新失败。重启 KOReader 后会自动重新检查。"
            else
                local err=result.error or table.concat(result.errors or {},"\n") or "未知错误"
                message="清理未完全完成"
                if freed>0 then message=message.."\n已释放："..human_size(freed) end
                message=message.."\n"..U.first_line(err,260)
            end
            self:toast(message,4)
            if options.refresh~=false then UIManager:scheduleIn(.30,function() self:show_downloads() end) end
        end,debug.traceback)
        if not ok then
            close_progress()
            logger.err("[MiuRead][CacheCleanup] result handling failed",tostring(unexpected))
            pcall(function() self:info("清理任务已经结束，但结果显示失败。请重启 KOReader 后检查存储占用。") end)
        end
    end
    if #unique==0 then finish({ok=true,removed=0,missing=0,freed_bytes=0,errors={}}); return end
    local ok,err=self.cache_cleanup_task:start(unique,finish,options.policy)
    if not ok then
        close_progress()
        self:info("无法开始清理：\n"..tostring(err))
        UIManager:scheduleIn(.15,function() self:show_downloads() end)
    end
end

function Plugin:_confirm_delete_variant(book_id,kind,title)
    if self:_cache_action_blocked() then return end
    local record=self.store:variant(book_id,kind)
    if not (record and record.file and U.file_exists(record.file)) then self.store:forget_variant(book_id,kind); self:toast("该版本已经不存在"); self:show_downloads(); return end
    local label=self:_variant_label(kind)
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的"..label.."？\n\n只删除这个 EPUB，其他版本和下载断点会保留。",
        ok_callback=function()
            local paths=self.store:variant_paths(book_id,kind)
            self:_run_cache_cleanup(paths,{
                progress_text="正在删除"..label.."……",
                done_text=label.."已删除",
                commit=function() self.store:forget_variant(book_id,kind) end,
                policy={mode="variant_delete"},operation="删除单个 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_delete_chapter_cache(book_id,uid,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:chapter_paths(book_id,uid)
    if #paths==0 then self.store:forget_chapter_all(book_id,uid); self:toast("本章文件已经不存在"); return end
    UIManager:show(ConfirmBox:new{
        text="删除“"..tostring(title or uid).."”的全部单章文件？",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:chapter_paths(book_id,uid),{
                progress_text="正在删除本章文件……",
                done_text="本章文件已删除",
                commit=function() self.store:forget_chapter_all(book_id,uid) end,
                policy={mode="chapter_delete"},operation="删除单章 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_clear_partial_cache(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:partial_cache_paths(book_id)
    if #paths==0 then self:toast("没有未完成下载缓存"); return end
    UIManager:show(ConfirmBox:new{
        text="清理《"..tostring(title or book_id).."》的未完成下载缓存？\n\n已生成的 EPUB 不会删除；下次下载将重新获取尚未完成的内容。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:partial_cache_paths(book_id),{
                progress_text="正在清理未完成下载缓存……",
                done_text="下载断点已清理",
                commit=function() self.store:prune_missing_files() end,
                policy={mode="download_residue"},operation="清理单本下载断点",
            })
        end,
    })
end
local function add_complete_delete_path(paths,seen,path)
    path=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    if #path>1 then path=path:gsub("/$","") end
    if path~="" and not seen[path] then seen[path]=true; paths[#paths+1]=path end
end

function Plugin:_complete_book_delete_plan(book_id)
    book_id=tostring(book_id or "")
    local paths,seen,documents={},{},{}
    local function add(path) add_complete_delete_path(paths,seen,path) end
    local function add_document(path)
        path=tostring(path or "")
        if path=="" then return end
        documents[#documents+1]=path
        add(path)
        local ok,DocSettings=pcall(require,"docsettings")
        if ok and DocSettings then
            local settings=DocSettings:open(path)
            if settings then
                add(settings:getSidecarDir(path,"doc"))
                add(settings:getSidecarDir(path,"dir"))
                if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
                    add(settings:getSidecarDir(path,"hash"))
                end
                add(settings:getHistoryPath(path))
            end
        end
    end

    local function add_record(record)
        if type(record)~="table" then return end
        add_document(record.file)
        add_document(record.original_file)
        add_document(record.pending_file)
    end
    local book=self.store:book(book_id)
    if book then
        for _,record in pairs(book.variants or {}) do add_record(record) end
        for _,row in pairs(book.chapters or {}) do
            for _,record in pairs(row or {}) do add_record(record) end
        end
    end
    add(self.store:book_cache_path(book_id))
    add(self.store:cover_path(book_id))
    local cover_index=self.store:get("cover_index",{})
    add(cover_index[book_id])
    for _,row in ipairs(self.store:pending_installs()) do
        if tostring(row.book_id or "")==book_id then
            add_document(row.file)
            add_document(row.pending_file)
        end
    end
    local state=self.store:download_state()
    local state_id=tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")
    if state_id==book_id then
        add_document(state.file); add_document(state.original_file); add_document(state.pending_file)
    end
    return paths,documents
end

function Plugin:_commit_complete_book_delete(book_id,documents)
    book_id=tostring(book_id or "")
    local ok_history,history=pcall(require,"readhistory")
    if ok_history and history and type(history.removeItemByPath)=="function" then
        for _,path in ipairs(documents or {}) do pcall(history.removeItemByPath,history,path) end
    end
    self.store:forget_book_local_state(book_id)
    if self._cover_index_pending then self._cover_index_pending[book_id]=nil end
    local repair_pending=self._book_repair_pending
    if type(repair_pending)=="table" then repair_pending[book_id]=nil end
    Thoughts.clear_memory_cache()
    if ThoughtNativePopup and type(ThoughtNativePopup.clear_cache)=="function" then
        pcall(ThoughtNativePopup.clear_cache)
    end
    self.store:prune_missing_files()
    self:_notify_home_data_changed("content")
end

function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    book_id=tostring(book_id or "")
    local paths,documents=self:_complete_book_delete_plan(book_id)
    local current=tostring(self:_current_document_path() or "")
    for _,path in ipairs(documents) do
        if current~="" and current==tostring(path) then
            self:info("请先退出正在阅读的《"..tostring(title or book_id).."》，再删除这本书。")
            return
        end
    end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》？\n\n将删除本机中的全部版本、单章文件、下载断点、封面、想法与评论缓存、阅读记录和本书设置。删除后无法恢复，重新阅读需要再次下载。\n\n微信读书云端书架、进度、划线和想法不会受到影响。",
        ok_text="删除全部",
        cancel_text="取消",
        ok_callback=function()
            self:_run_cache_cleanup(paths,{
                progress_text="正在完整删除本书……",
                done_text="本书及全部本机相关内容已删除",
                commit=function() self:_commit_complete_book_delete(book_id,documents) end,
                policy={mode="book_delete",allowed_paths=U.copy(paths)},
                operation="完整删除本书",
                success_even_if_empty=true,
            })
        end,
    })
end
function Plugin:_annotation_retry_options(kind,record,chapter_uid)
    record=type(record)=="table" and record or {}
    local opt={annotations=true}
    if chapter_uid then
        opt.chapter_uid=tostring(chapter_uid)
    elseif tostring(kind or ""):sub(1,6)=="range_" or record.partial_range==true then
        opt.range_start_index=tonumber(record.range_start_index)
        opt.range_end_index=tonumber(record.range_end_index)
        opt.range_start_title=record.range_start_title
        opt.range_end_title=record.range_end_title
    end
    return opt
end

function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
        end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do
        for _,r in pairs(row or {}) do
            if r.file and U.file_exists(r.file) then
                chapter_count=chapter_count+1
            end
        end
    end
    if chapter_count>0 then
        labels[#labels+1]="单章 "..tostring(chapter_count)
    end
    if self.store:book_has_partial_cache(b.book_id) then labels[#labels+1]="未完成缓存" end
    return labels,chapter_count
end

function Plugin:show_storage_usage()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍候。") return end
    local categories=self:_storage_categories()
    local dialog=InfoMessage:new{text="正在统计存储占用……"}
    UIManager:show(dialog)
    local function done(result)
        local ok,unexpected=xpcall(function()
            pcall(function() UIManager:close(dialog) end)
            if not (result and result.ok==true and type(result.sizes)=="table") then
                self:info("存储统计失败：\n"..U.first_line(result and result.error or "未知错误",220))
                return
            end
            local size=result.sizes
            self:info("存储占用\n\n已下载书籍："..human_size(size.books)
                .."\n下载断点："..human_size(size.partial)
                .."\n想法与章节数据（受保护）："..human_size(size.protected)
                .."\n封面缓存："..human_size(size.covers)
                .."\n临时与待安装文件："..human_size(size.temp))
        end,debug.traceback)
        if not ok then
            pcall(function() UIManager:close(dialog) end)
            logger.err("[MiuRead][Storage] result handling failed",tostring(unexpected))
            pcall(function() self:info("存储统计结果显示失败。") end)
        end
    end
    local started,err=self.cache_cleanup_task:start_scan(categories,done)
    if not started then pcall(function() UIManager:close(dialog) end); self:info("无法开始统计：\n"..tostring(err)) end
end
function Plugin:_clear_download_residue()
    if self:_cache_action_blocked() then return end
    local paths=self:_download_residue_paths()
    UIManager:show(ConfirmBox:new{text="清理全部下载断点和失败任务留下的临时文件？\n\n不会删除已生成 EPUB、想法与章节数据、待安装文件和封面。",ok_callback=function()
        self:_run_cache_cleanup(paths,{progress_text="正在清理下载断点与临时文件……",done_text="下载断点与临时文件已清理",operation="清理下载断点与临时文件",policy={mode="download_residue"},commit=function()
            U.mkdir(self.store.temp_dir); self.store:prune_missing_files()
            local state=self.store:download_state()
            if state.status=="failed" or state.status=="interrupted" then self.store:clear_download_state() end
        end})
    end})
end
function Plugin:_clear_cover_cache()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{text="清理全部封面缓存？\n\n不会删除书籍、想法、章节数据或阅读记录；下次进入书架时会按需重新下载封面。",ok_callback=function()
        self:_run_cache_cleanup({self.store.covers_dir},{progress_text="正在清理封面缓存……",done_text="封面缓存已清理",operation="清理封面缓存",policy={mode="cover_cache"},commit=function()
            U.mkdir(self.store.covers_dir); self.store:set("cover_index",{})
        end})
    end})
end
function Plugin:show_download_cleanup_dialog()
    if self:_cache_action_blocked() then return end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        return ActionSheet.show{
            title="存储清理",
            subtitle="不会删除书籍 划线 想法 阅读记录或已完成下载",
            actions={
                {icon="⌫",label="下载临时文件",detail="清理断点和失败任务残留",callback=function() self:_clear_download_residue() end},
                {icon="▧",label="失效封面缓存",detail="需要时会自动重新生成",callback=function() self:_clear_cover_cache() end},
            },
            footer_action={label="取消",callback=function() end},
        }
    end
    local dialog
    dialog=ButtonDialog:new{title="清理下载与缓存",title_align="center",buttons={
        {{text="清理下载断点与临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
        {{text="清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:show_downloads(back_callback)
    return
end
function Plugin:show_downloads_legacy(back_callback)
    if type(back_callback)=="function" then
        self._downloads_return_callback=back_callback
    elseif self.ui and self.ui.document and type(self._downloads_return_callback)=="function" then
        back_callback=self._downloads_return_callback
    else
        self._downloads_return_callback=nil
    end
    local source_document=self.ui and self.ui.document or nil
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请稍候。") return end
    self.store:reload(); self.store:prune_missing_files()
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end); self._download_book_menu=nil end
    if self._downloads_menu then
        self._downloads_menu._miuread_suppress_restore=true
        pcall(function() UIManager:close(self._downloads_menu) end)
        self._downloads_menu=nil
    end
    local items={}
    if self:_has_download_status() then items[#items+1]={text=self:_download_status_label(),callback=function() self:show_download_status() end} end
    items[#items+1]={text="下载设置",post_text="策略 目录与提醒",sub_item_table_func=function() return self:download_settings_menu() end}
    local queue=self.store:download_queue()
    items[#items+1]={text="等待下载",post_text=tostring(#queue).." 项",callback=function() self:show_waiting_downloads() end}
    items[#items+1]={text="存储占用",callback=function() self:show_storage_usage() end}
    items[#items+1]={text="存储与清理",callback=function() self:show_download_cleanup_dialog() end}
    items[#items+1]={text="已完成",enabled=false}
    for _,b in ipairs(self.store:all_books()) do
        local labels=self:_download_book_labels(b)
        if #labels>0 then
            local book_id=tostring(b.book_id)
            items[#items+1]={text=b.title or book_id,post_text=table.concat(labels," · "),callback=function() self:downloaded_book_menu(book_id) end}
        end
    end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self._downloads_menu=nil
        return self:_show_miuread_menu("下载管理",items,{on_back=back_callback,page_size=7})
    end
    local menu=Menu:new{title="下载管理",item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._downloads_menu=menu
    local function close_downloads()
        if menu._miuread_closing then return true end
        menu._miuread_closing=true
        local ok,err=pcall(UIManager.close,UIManager,menu)
        if not ok then
            menu._miuread_closing=false
            logger.warn("[MiuRead][Downloads] close failed",tostring(err))
            return false
        end
        if self._downloads_menu==menu then self._downloads_menu=nil end
        if type(back_callback)=="function" and menu._miuread_suppress_restore~=true and not menu._miuread_restore_scheduled then
            menu._miuread_restore_scheduled=true
            UIManager:scheduleIn(.06,function()
                self._downloads_return_callback=nil
                if self.ui and self.ui.document==source_document then
                    local restore_ok,restore_err=pcall(back_callback)
                    if not restore_ok then logger.warn("[MiuRead][Downloads] restore failed",tostring(restore_err)) end
                end
            end)
        end
        return true
    end
    menu.onClose=close_downloads
    menu.onCloseAllMenus=close_downloads
    UIManager:show(menu)
end

function Plugin:downloaded_chapters_menu(book_id)
    self.store:reload()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local order={}
    for index,ch in ipairs(b.catalog or {}) do
        order[tostring(ch.uid or ch.chapterUid or ch.chapter_uid or "")]=index
    end
    local rows={}
    for uid,row in pairs(b.chapters or {}) do
        local labels={}
        local title
        for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
            local r=row and row[kind]
            if r and r.file and U.file_exists(r.file) then
                labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
                title=title or r.title
            end
        end
        if #labels>0 then
            rows[#rows+1]={uid=tostring(uid),title=tostring(title or uid),labels=labels,index=order[tostring(uid)] or 999999}
        end
    end
    table.sort(rows,function(a,c)
        if a.index~=c.index then return a.index<c.index end
        return a.uid<c.uid
    end)
    local items={}
    local book={bookId=book_id,title=b.title,author=b.author,cover=b.cover}
    for _,entry in ipairs(rows) do
        local chapter={chapterUid=entry.uid,title=entry.title}
        items[#items+1]={text=entry.title,post_text=table.concat(entry.labels," · "),callback=function() self:chapter_menu(book,chapter) end}
    end
    self:list("单章文件 · "..tostring(b.title or book_id),items,"没有单章文件")
end

function Plugin:downloaded_book_menu(book_ref)
    local book_id=type(book_ref)=="table" and tostring(book_ref.book_id or book_ref.bookId) or tostring(book_ref)
    self.store:reload(); self.store:prune_missing_files()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    local variants={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            local label=DownloadResult.variant_label(self:_variant_label(kind),r)
            variants[#variants+1]={kind=kind,file=r.file,label=label,record=r}
        end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label; local record=variant.record
            items[#items+1]={text="阅读"..label,post_text="EPUB",callback=function() self:open_file(file) end}
            items[#items+1]={text="删除"..label,post_text="仅删除该版本",callback=function() self:_confirm_delete_variant(book_id,kind_key,b.title) end}
        end
    end
    local _,chapter_count=self:_download_book_labels(U.merge(b,{book_id=book_id}))
    local has_partial=self.store:book_has_partial_cache(book_id)
    if chapter_count>0 or has_partial then
        items[#items+1]={text="单章与断点",enabled=false}
        if chapter_count>0 then
            items[#items+1]={text="单章文件",post_text=tostring(chapter_count).." 个",callback=function() self:downloaded_chapters_menu(book_id) end}
        end
        if has_partial then
            local repairable=#BookIntegrity.partial_repairs(self.store,book_id)
            if repairable>0 then
                items[#items+1]={text="修复未完成下载",post_text=tostring(repairable).." 个断点",callback=function() self:_repair_downloaded_book(book_id) end}
            end
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除这本书",post_text="同时删除本机想法、评论与记录",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self._download_book_menu=nil
        return self:_show_home_bubble_menu(b.title or book_id,items,{page_size=7})
    end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end
function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if session and session.sync_repair_required==true then
        local kind=tostring(session.sync_repair_kind or "")
        if kind=="context" or kind=="position" then return "需要修复" end
    end
    local state=session and session.progress_sync_state or nil
    local labels={checking="正在检查",retrying="正在重试",mapping_pending="等待章节换算",aligned="已同步",local_selected="使用本机位置",local_uploaded="已上传并确认",uploading="正在上传",verifying_upload="正在确认",upload_failed="上传失败",upload_unconfirmed="云端未确认",source_conflict="云端来源冲突",remote_selected="已采用云端位置",different="等待选择",deferred="本次暂不处理",remote_unavailable="等待重新检查",remote_jump_unconfirmed="跳转待确认"}
    return labels[state] or "已开启"
end

function Plugin:_sync_success_notice_enabled()
    return (self.store:preferences().sync or {}).success_notice_enabled~=false
end
function Plugin:toggle_sync_success_notice()
    local p=self.store:preferences(); p.sync=p.sync or {}
    p.sync.success_notice_enabled=not (p.sync.success_notice_enabled~=false)
    self:_save_ui_preferences(p,"sync_success_notice")
    self:status_toast("同步成功提醒",p.sync.success_notice_enabled and "已开启" or "已关闭",3)
end
function Plugin:_show_auto_sync_success(text)
    if self._sync_success_notified==true or not self:_sync_success_notice_enabled() then return end
    self._sync_success_notified=true
    self:status_toast("同步完成",text or "已成功上传",3)
end
function Plugin:sync_diagnostics_menu()
    return {
        {text="检查当前书籍识别",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("当前文件未被识别为觅阅书籍。") return end
            self:info("当前书籍已识别\n\n书名："..tostring(r.book.title or "未命名")
                .."\n书籍 ID："..tostring(r.book.book_id or "")
                .."\n文件："..tostring(r.path or ""))
        end},
        {text="检查登录状态",callback=function() self:show_account_status() end},
        {text="测试云端进度读取",callback=function() self:manual_sync() end},
        {text="测试当前进度上传",callback=function() self:upload_local_progress(true) end},
        {text="测试上传 30 秒阅读时间",callback=function()
            if not self.sync:record() then self:info("请先打开一本觅阅下载的书籍。") return end
            self:status_toast("阅读时间测试","正在上传 30 秒……",3)
            self.sync:test_upload(function(ok,result,position,value)
                if ok then
                    self:status_toast("阅读时间测试","30 秒已成功上传",4)
                elseif type(value)=="table" and (value.uncertain==true or tostring(value.error_kind or "")=="unconfirmed") then
                    self:status_toast("阅读时间测试","已提交，等待微信读书确认",5)
                else
                    self:info("阅读时间测试失败\n\n"..tostring(result or "未知错误"))
                end
            end)
        end},
        {text="查看详细错误",callback=function() self:show_sync_status(true) end},
        {text="重置当前书籍同步状态",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("请先打开一本觅阅下载的书籍。") return end
            local id=tostring(r.book.book_id)
            UIManager:show(ConfirmBox:new{text="重置当前书籍的临时同步状态？\n\n不会删除书籍、本机阅读位置、划线、想法或账号。",ok_callback=function()
                self.sync:stop("manual_reset",0)
                local sessions=self.store:get("sessions",{})
                local session=sessions[id] or {}
                for _,key in ipairs({
                    "legacy_report_context","report_context","last_error","last_response_summary",
                    "last_http_code","last_http_length","last_payload_public","last_path","last_stage",
                    "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
                    "consecutive_failures"
                }) do session[key]=nil end
                -- Failed remote reading time is intentionally not queued for later replay.
                session.pending_report_seconds=0
                sessions[id]=session
                self.store:set("sessions",sessions)
                self.sync:clear_verified("manual_reset")
                self.sync.last_error=nil
                self.sync.consecutive_failures=0
                self._sync_success_notified=false
                self:status_toast("阅读同步","临时状态已重置",3)
                UIManager:scheduleIn(.5,function()
                    if not self.ui or not self.ui.document then return end
                    local prefs=self.store:preferences().sync or {}
                    if prefs.progress_enabled~=false then self:ensure_read_report_progress("manual_reset",true)
                    elseif prefs.time_enabled==true then self.sync:start("manual_reset") end
                end)
            end})
        end},
    }
end

function Plugin:_schedule_home_annotation_summary_refresh(force)
    local now=os.time()
    if force~=true and type(self._annotation_summary_cache)=="table"
        and now-(tonumber(self._annotation_summary_cache_at) or 0)<12 then return false end
    if self.sync_summary_async and self.sync_summary_async:busy() then return false end
    if self._home_sync_summary_task then return false end
    local task
    task=function()
        if self._home_sync_summary_task~=task then return end
        if self:_home_ui_busy() or self:_active_reader_ui() then
            UIManager:scheduleIn(.55,task)
            return
        end
        self._home_sync_summary_task=nil
        if not self.sync_summary_async or not self.sync_summary_async:available() then return end
        local started,err=self.sync_summary_async:run("annotation-summary",function()
            return LocalAnnotationDatabase.global_summary(self.store) or {}
        end,function(result)
            if result and result.ok and type(result.value)=="table" then
                self._annotation_summary_cache=result.value
                self._annotation_summary_cache_at=os.time()
                self._home_sync_summary_cache=nil
                self._home_sync_summary_cache_at=nil
                if HomeView.is_shown() and not self:_active_reader_ui() then
                    self:_notify_home_data_changed("header")
                end
            elseif result and result.error then
                logger.warn("[MiuRead][SyncSummary] refresh failed",tostring(result.error))
            end
        end,20)
        if not started then logger.warn("[MiuRead][SyncSummary] worker unavailable",tostring(err or "unknown")) end
    end
    self._home_sync_summary_task=task
    UIManager:scheduleIn(force==true and .12 or .70,task)
    return true
end

function Plugin:_home_sync_summary(force)
    -- Never walk every local annotation database from a home gesture. Session
    -- counters are cheap; annotation counters come from an asynchronously
    -- refreshed snapshot.
    local sessions=self.store:get("sessions",{}) or {}
    local progress,time_count,progress_failed=0,0,0
    local pending_progress_states={
        waiting_network=true,uploading=true,upload_unconfirmed=true,upload_failed=true,
        verifying_upload=true,deferred=true,verification_required=true,remote_jump_unconfirmed=true,
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            local state=tostring(session.progress_sync_state or "")
            if pending_progress_states[state] then progress=progress+1 end
            if state=="upload_failed" or state=="upload_unconfirmed" or state=="remote_jump_unconfirmed" then
                progress_failed=progress_failed+1
            end
            if tonumber(session.pending_report_seconds or 0)>0 then time_count=time_count+1 end
        end
    end
    local annotations=type(self._annotation_summary_cache)=="table" and self._annotation_summary_cache or {}
    local highlight=tonumber(annotations.highlight or 0) or 0
    local thought=tonumber(annotations.thought or 0) or 0
    local bookmark=tonumber(annotations.bookmark or 0) or 0
    local total=progress+time_count+highlight+thought+bookmark
    local checking=type(self._annotation_summary_cache)~="table"
        or (self.sync_summary_async and self.sync_summary_async:busy())==true
    local summary={
        progress=progress,time=time_count,highlight=highlight,thought=thought,bookmark=bookmark,
        annotation_pending=tonumber(annotations.pending or 0) or 0,
        annotation_failed=tonumber(annotations.failed or 0) or 0,
        failed=progress_failed+(tonumber(annotations.failed or 0) or 0),
        total=total,books=tonumber(annotations.books or 0) or 0,checking=checking,
    }
    self._home_sync_summary_cache=summary
    self._home_sync_summary_cache_at=os.time()
    self:_schedule_home_annotation_summary_refresh(force==true)
    return summary
end

function Plugin:_home_sync_status_label(force)
    local summary=self:_home_sync_summary(force)
    if summary.failed>0 then return "失败 "..tostring(summary.failed) end
    if summary.total>0 then return "待同步 "..tostring(summary.total) end
    if self.annotation_async and self.annotation_async:busy() then return "同步中" end
    if summary.checking==true then return "同步检查中" end
    return "已同步"
end

function Plugin:_sync_all_pending_annotations(on_done)
    local pending=LocalAnnotationDatabase.pending_books(self.store,80) or {}
    if #pending==0 then if on_done then on_done(true,{synced=0,deleted=0,failed=0}) end; return true end
    if not self:logged_in() then if on_done then on_done(false,{error="请先登录微信读书账号"}) end; return false end
    if self.annotation_async and self.annotation_async:busy() then
        if on_done then on_done(false,{error="批注同步正在运行"}) end
        return false
    end
    local jobs={}
    for _,item in ipairs(pending) do
        local id=tostring(item.book_id or "")
        if id~="" then
            local book=U.copy(self.store:book(id) or {book_id=id})
            book.book_id=tostring(book.book_id or book.bookId or id)
            local record=U.copy(self:_preferred_record(id) or {})
            jobs[#jobs+1]={book=book,record=record}
        end
    end
    if #jobs==0 then if on_done then on_done(true,{synced=0,deleted=0,failed=0}) end; return true end
    local prefs=U.copy(self:_annotation_sync_preferences())
    local service=self.annotation_sync
    local started,err=self.annotation_async:run("annotation-sync-all",function()
        local total={ok=true,synced=0,deleted=0,failed=0,locate_failed=0,metadata_failed=0,coord_failed=0,unknown=0,books=0}
        for _,job in ipairs(jobs) do
            local result=service:sync_book(job.book,job.record,{preferences=prefs,limit=200}) or {}
            total.books=total.books+1
            if result.ok==false then total.failed=total.failed+1; total.ok=false
            else
                for _,key in ipairs({"synced","deleted","failed","locate_failed","metadata_failed","coord_failed","unknown"}) do
                    total[key]=total[key]+(tonumber(result[key] or 0) or 0)
                end
                if tonumber(result.failed or 0)>0 then total.ok=false end
            end
        end
        return total
    end,function(worker_result)
        if not worker_result or worker_result.ok~=true then
            if on_done then on_done(false,{error=worker_result and worker_result.error or "后台任务失败"}) end
            return
        end
        local result=worker_result.value or {}
        if on_done then on_done(result.ok~=false,result) end
    end,220)
    if not started then if on_done then on_done(false,{error=err or "后台任务不可用"}) end; return false end
    return true
end

function Plugin:_sync_home_pending()
    local function proceed(summary)
        summary=summary or self:_home_sync_summary(false)
        if summary.total<=0 and summary.checking~=true then
            self:toast("所有待处理内容都已同步",2)
            return true
        end
        if not self:logged_in() then self:info("请先登录微信读书账号。") return false end
        self:toast("正在同步待处理内容…",2)
        local annotation_count=tonumber(summary.annotation_pending or 0) or 0
        local function finish(ok,result)
            self._home_sync_summary_cache=nil
            self._home_sync_summary_cache_at=nil
            if ok then
                -- The annotation worker has just completed successfully, so use
                -- an immediate zero snapshot instead of rescanning every book on
                -- the UI thread merely to paint a success message.
                self._annotation_summary_cache={pending=0,failed=0,delete_pending=0,bookmark=0,highlight=0,thought=0,books=0}
                self._annotation_summary_cache_at=os.time()
            else
                self._annotation_summary_cache=nil
                self._annotation_summary_cache_at=0
            end
            self:_schedule_home_annotation_summary_refresh(true)
            if HomeView.is_shown() then self:_notify_home_data_changed("header") end
            local after=self:_home_sync_summary(false)
            if ok and after.total<=0 then
                self:status_toast("同步完成","进度 时间 划线和想法已处理",3)
            elseif ok then
                local message="仍有 "..tostring(after.total).." 项待处理"
                if after.progress>0 or after.time>0 then message=message.."\n阅读进度或时间将在对应书籍同步环境恢复后继续处理" end
                self:info(message)
            else
                self:info("同步未全部完成\n\n"..tostring(result and result.error or "失败项目已保留 可稍后重试"))
            end
        end
        if annotation_count>0 then return self:_sync_all_pending_annotations(finish) end
        -- Progress/time are normally submitted as the reader closes. If a stale
        -- pending state remains, keep it visible instead of fabricating a current
        -- book from the home screen.
        finish(true,{})
        return true
    end

    local age=os.time()-(tonumber(self._annotation_summary_cache_at) or 0)
    if type(self._annotation_summary_cache)=="table" and age<=6 then
        return proceed(self:_home_sync_summary(false))
    end
    -- A manual sync must never claim "已同步" from an unknown annotation
    -- snapshot. Do the exact multi-book SQLite count in a subprocess, then
    -- continue with the result without blocking the tap animation.
    if self.sync_summary_async and self.sync_summary_async:available() and not self.sync_summary_async:busy() then
        self:toast("正在检查待同步内容…",2)
        local started,err=self.sync_summary_async:run("annotation-summary-manual",function()
            return LocalAnnotationDatabase.global_summary(self.store) or {}
        end,function(result)
            if result and result.ok and type(result.value)=="table" then
                self._annotation_summary_cache=result.value
                self._annotation_summary_cache_at=os.time()
                proceed(self:_home_sync_summary(false))
            else
                self:info("无法检查本地划线与想法\n\n"..tostring(result and result.error or "后台检查失败"))
            end
        end,20)
        if started then return true end
        logger.warn("[MiuRead][SyncSummary] manual start failed",tostring(err or "unknown"))
    elseif self.sync_summary_async and self.sync_summary_async:busy() then
        self:toast("正在检查同步状态…",2)
        local generation=(tonumber(self._home_sync_manual_wait_generation) or 0)+1
        self._home_sync_manual_wait_generation=generation
        local wait
        wait=function()
            if generation~=self._home_sync_manual_wait_generation then return end
            if self.sync_summary_async and self.sync_summary_async:busy() then UIManager:scheduleIn(.45,wait); return end
            if type(self._annotation_summary_cache)=="table" then proceed(self:_home_sync_summary(false))
            else self:info("同步状态检查未完成 请稍后重试") end
        end
        UIManager:scheduleIn(.45,wait)
        return true
    end
    -- Subprocess support is expected on Kindle. If it is unavailable, keep the
    -- UI responsive and make the limitation explicit rather than performing a
    -- potentially long full-database scan on the main thread.
    self:info("当前环境无法在后台检查本地划线与想法 请稍后重试")
    return false
end

function Plugin:sync_settings_menu()
    return {
        {text="阅读进度",post_text=self.store:preferences().sync.progress_enabled~=false and "已开启" or "已关闭",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="阅读时间",post_text=self.store:preferences().sync.time_enabled==true and "已开启" or "已关闭",checked_func=function() return self.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="本地划线与想法",post_text="手动同步待处理内容",enabled=false},
        {text="新想法云端可见范围",post_text=self:annotation_sync_visibility_label(),sub_item_table_func=function() return self:annotation_sync_visibility_menu() end},
        {text="同步成功提醒",checked_func=function() return self:_sync_success_notice_enabled() end,keep_menu_open=true,callback=function() self:toggle_sync_success_notice() end},
        {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
    }
end

function Plugin:sync_menu()
    local rows={
        {text="同步状态",post_text=self:_home_sync_status_label(),callback=function() self:show_sync_status(false) end},
        {text="同步待处理内容",post_text="进度 时间 划线 想法",callback=function() self:_sync_home_pending() end},
    }
    for _,row in ipairs(self:sync_settings_menu()) do rows[#rows+1]=row end
    if self:_current_book_record() then
        rows[#rows+1]={text="修复当前书籍同步",callback=function() self:repair_current_sync() end}
        rows[#rows+1]={text="重新读取当前书籍云端进度",callback=function() self:manual_sync() end}
    end
    return rows
end

function Plugin:toggle_time_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.time_enabled==true and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，觅阅不会上传后续阅读时长，其他设备上的阅读统计可能不完整。",
            ok_text="关闭时间同步",cancel_text="保持开启",ok_callback=function() self:toggle_time_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled
    self:_save_ui_preferences(p,"time_sync_toggle")
    if p.sync.time_enabled then
        local record=self.sync:record()
        if record and p.sync.progress_enabled~=false and not self.sync:is_current_verified() then
            self:ensure_read_report_progress("time_sync_enabled",false)
        else
            self.sync:start("enabled")
        end
        if self:_original_weread_plugin_present() then
            self:info("阅读时间同步已开启。\n\n检测到原作者 WeRead 插件目录（weread.koplugin）。它与觅阅是两个独立插件；若两边都开启阅读时间同步，可能重复上报。可按自己的需要在插件管理中关闭其中一边。")
        else
            self:status_toast("阅读时间同步","已开启",3)
        end
    else
        self.sync:stop("disabled")
        self:status_toast("阅读时间同步","已关闭",3)
    end
end





function Plugin:_show_progress_success(_text)
    local prefs=self.store:preferences().sync or {}
    -- When reading-time sync is active, its first accepted report contains the
    -- current position too, so one combined notice is enough.
    if prefs.time_enabled==true then return end
    self:_show_auto_sync_success("阅读进度已上传")
end
function Plugin:toggle_progress_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.progress_enabled~=false and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，其他设备将无法自动接续本书的阅读位置。本机阅读位置不会被删除。",
            ok_text="关闭进度同步",cancel_text="保持开启",ok_callback=function() self:toggle_progress_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled
    self:_save_ui_preferences(p,"progress_sync_toggle")
    local r=self.sync:record()
    if p.sync.progress_enabled then
        self.sync:clear_verified("progress_sync_enabled")
        self:toast("阅读进度同步已开启",3)
        if r then UIManager:scheduleIn(.1,function() self:ensure_read_report_progress("enabled",false) end) end
    else
        if r then self.store:save_session(r.book.book_id,{progress_sync_state="disabled",progress_sync_message="阅读进度同步已关闭"}) end
        self.sync.progress_hold=false
        self.sync:start("progress_disabled")
        self:toast("阅读进度同步已关闭",3)
    end
end

function Plugin:_save_progress_state(id,state,message,localp,remotep)
    self.store:save_session(id,{
        progress_sync_state=state,
        progress_sync_message=message,
        progress_local_percent=localp,
        progress_remote_percent=remotep,
        progress_decided_at=os.time(),
    })
end
function Plugin:ensure_read_report_progress(reason,automatic)
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then
        if not automatic then self:info("阅读进度同步已关闭。") end
        self.sync:start("progress_disabled")
        return false
    end
    local r=self.sync:record()
    if not r then
        if not automatic then self:info(_("No matching MiuRead book is open.")) end
        return false
    end
    local id=tostring(r.book.book_id)
    if not self:is_online() then
        self:_save_progress_state(id,"waiting_network","等待 Wi-Fi 恢复后读取云端位置",nil,nil)
        self.sync:end_progress_sync("等待网络恢复")
        if automatic then
            self:_wait_for_network("progress-"..id,function(ready)
                if ready and self.ui and self.ui.document then
                    self:ensure_read_report_progress("network_ready",true)
                end
            end,{minimum_delay=2,max_wait=90,interval=3})
        else
            self:info("Wi-Fi 尚未恢复。\n\n本地阅读位置已保留。阅读时间失败部分不会补传，联网后会重新确认当前进度。")
        end
        return false
    end
    if self._progress_check_running then
        if not automatic then self:toast("正在读取云端位置……",2) end
        return false
    end
    self._progress_check_running=true
    local local_position=self.sync:local_position()
    if not local_position or local_position.safe~=true or local_position.progress==nil then
        local chapter_percent=local_position and local_position.chapter_percent
            or math.floor((self.sync:local_ratio() or 0)*100+.5)
        self:_save_progress_state(id,"mapping_pending","正在取得完整目录以换算单章进度",chapter_percent,nil)
        self._progress_check_running=false
        self.sync:end_progress_sync("单章位置等待完整目录")
        if not automatic then
            self:info("当前打开的是单章文件。\n\n正在等待完整目录用于换算整书进度；在换算完成前，不会把本章百分比直接上传成整书百分比。")
        end
        return false
    end
    local localp=math.floor((tonumber(local_position.progress) or 0)+.5)
    self:_save_progress_state(id,"checking","正在读取云端位置",localp,nil)
    self.sync:begin_progress_sync(reason or "读取云端进度")
    self.sync:remote(id,function(remote,remote_err)
        self._progress_check_running=false
        self._progress_remote_retries=self._progress_remote_retries or {}
        if not remote then
            local retries=tonumber(self._progress_remote_retries[id] or 0) or 0
            if automatic and retries<1 and self.ui and self.ui.document then
                self._progress_remote_retries[id]=retries+1
                self:_save_progress_state(id,"retrying","云端位置读取失败，准备重试",localp,nil)
                self.sync:end_progress_sync("云端位置读取失败，等待重试")
                UIManager:scheduleIn(2.5,function()
                    if self.ui and self.ui.document then
                        self:ensure_read_report_progress("remote_progress_retry",true)
                    end
                end)
                return
            end
            self:_save_progress_state(id,"remote_unavailable","暂时无法读取云端位置",localp,nil)
            self.sync:end_progress_sync("云端位置暂时不可用，阅读时间等待确认")
            if not automatic then
                self:info("暂时无法读取云端位置。\n\n为了避免覆盖其他设备上的位置，本次阅读时间会等待位置确认后再上传。")
            end
            logger.warn("[MiuRead][Sync] remote position unavailable", tostring(remote_err or "unknown"))
            return
        end
        self._progress_remote_retries[id]=0
        if remote.conflict then
            local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
            local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
            self:_save_progress_state(id,"source_conflict","云端两个来源的位置不一致",localp,webp or agentp)
            self.sync.state="verification_required"
            self.sync.last_stage="等待选择云端位置来源"
            self:on_remote_source_conflict(id,localp,remote,automatic==true)
            return
        end
        local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
        local cmp=self.sync:compare(localp,remote)
        if cmp=="same" then
            self.sync:mark_verified(id,"positions_aligned",localp,remotep)
            self:_save_progress_state(id,"aligned","本机与云端位置接近",localp,remotep)
            self.sync:end_progress_sync("位置接近，阅读时间开始同步")
            if not automatic then self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n位置接近，无需处理。") end
            return
        end
        self:_save_progress_state(id,"different","检测到本机与云端位置不同",localp,remotep)
        self.sync.state="verification_required"
        self.sync.last_stage="等待选择本机或云端位置"
        self:on_remote_progress(id,localp,remote,automatic==true)
    end)
    return true
end

function Plugin:manual_sync()
    return self:ensure_read_report_progress("manual_progress_sync",false)
end

function Plugin:_remote_matches(remote,target)
    local threshold=tonumber(self.store:preferences().sync.threshold) or 2
    target=tonumber(target)
    if not target or not remote then return false,nil,nil end
    local function match(candidate)
        local percent=candidate and tonumber(candidate.percent)
        return percent and math.abs(percent-target)<=threshold,percent,candidate and candidate.source
    end
    if remote.conflict then
        local ok,p,source=match(remote.web); if ok then return true,p,source end
        ok,p,source=match(remote.agent); if ok then return true,p,source end
        return false,nil,nil
    end
    return match(remote)
end

function Plugin:upload_local_progress(manual,callback)
    local r=self.sync:record()
    if not r then
        if manual then self:info("请先打开一本觅阅下载的书籍。") end
        if callback then callback(false,"未识别当前书籍") end
        return false
    end
    local position=self.sync:local_position()
    if not position or position.safe~=true or position.progress==nil then
        local err="当前文件暂时无法安全换算整书进度。"
        if manual then self:info(err) end
        if callback then callback(false,err) end
        return false
    end
    local id=tostring(r.book.book_id)
    local session=self.store:session(id) or {}
    if session.sync_repair_required==true
        and (tostring(session.sync_repair_kind or "")=="context" or tostring(session.sync_repair_kind or "")=="position") then
        if manual then self:_show_sync_repair_prompt(session.sync_repair_error,"context",id) end
        if callback then callback(false,session.sync_repair_error or "当前书籍需要修复同步") end
        return false
    end
    local target=math.floor((tonumber(position.progress) or 0)+.5)
    self.sync:begin_progress_sync("主动上传本机阅读进度")
    self:_save_progress_state(id,"uploading","正在上传本机阅读进度",target,nil)
    if manual then self:status_toast("阅读进度同步","正在上传 "..target.."%……",3) end
    local started=self.sync:upload_progress(function(ok,result,submitted)
        if not ok then
            local current_session=self.store:session(id) or {}
            local repair=current_session.sync_repair_required==true
                and (tostring(current_session.sync_repair_kind or "")=="context" or tostring(current_session.sync_repair_kind or "")=="position")
            local kind=tostring(current_session.last_error_kind or self.sync.last_error_kind or "")
            local state=(kind=="transport" or kind=="server" or kind=="unconfirmed") and "upload_unconfirmed" or "upload_failed"
            self:_save_progress_state(id,state,repair and "当前书籍同步信息需要修复" or "本次上传暂未完成",target,nil)
            self.sync:end_progress_sync(repair and "当前书籍同步信息需要修复" or "本次上传暂未完成，稍后可继续")
            if manual then
                if repair then self:_show_sync_repair_prompt(result,"context",id)
                elseif kind=="authentication" then self:status_toast("阅读进度同步","登录状态需要重新验证",4)
                else self:status_toast("阅读进度同步","本次未获确认，稍后可再次同步",4) end
            end
            if callback then callback(false,result) end
            return
        end
        target=math.floor((tonumber(submitted and submitted.progress) or target)+.5)
        self:_save_progress_state(id,"verifying_upload","请求已接收，正在确认云端位置",target,nil)
        local function verify(attempt)
            UIManager:scheduleIn(attempt==1 and 1.5 or 2.5,function()
                if not self.ui or not self.ui.document then return end
                self.sync:remote(id,function(remote,remote_err)
                    local matched,actual,source=self:_remote_matches(remote,target)
                    if matched then
                        actual=math.floor((tonumber(actual) or target)+.5)
                        self.sync:mark_verified(id,"local_progress_uploaded",target,actual)
                        self:_save_progress_state(id,"local_uploaded","本机进度已上传并确认",target,actual)
                        self.store:save_session(id,{progress_upload_state="verified",progress_upload_verified_at=os.time(),progress_upload_source=source})
                        self.sync:end_progress_sync("本机阅读进度已上传并确认")
                        if manual then
                            self:status_toast("阅读进度同步","已上传并确认："..target.."%",4)
                        else
                            self:_show_progress_success("已同步："..target.."%")
                        end
                        if callback then callback(true,remote) end
                    elseif attempt<2 then
                        verify(attempt+1)
                    else
                        self:_save_progress_state(id,"upload_unconfirmed","请求已发送，但云端位置尚未更新",target,remote and remote.percent)
                        self.store:save_session(id,{progress_upload_state="unconfirmed",progress_upload_error=remote_err})
                        self.sync:end_progress_sync("进度请求已发送，云端尚未确认")
                        if manual then self:info("上传请求已发送，但云端位置尚未更新。\n\n本机位置："..target.."%") end
                        if callback then callback(false,remote_err or "云端位置尚未更新") end
                    end
                end,{force=true})
            end)
        end
        verify(1)
    end)
    if not started then
        self.sync:end_progress_sync("无法启动阅读进度上传")
        if manual then self:info("无法启动阅读进度上传：同步任务正在运行。") end
        if callback then callback(false,"同步任务正在运行") end
        return false
    end
    return true
end

function Plugin:_use_remote_position(id,localp,remote)
    local remotep=math.floor((tonumber(remote and remote.percent) or 0)+.5)
    local jumped,jump_error=self.sync:jump_remote(remote)
    if not jumped then
        self:_save_progress_state(id,"remote_jump_unconfirmed","无法跳转到云端位置",localp,remotep)
        self.sync:end_progress_sync("云端位置跳转失败，阅读时间暂缓上传")
        self:info(tostring(jump_error or "无法跳转到云端位置。").."\n\n当前位置未确认，因此暂不上传阅读时间。")
        return false
    end
    UIManager:scheduleIn(1.2,function()
        local actual_position=self.sync:local_position()
        local actual=actual_position and actual_position.progress and math.floor(actual_position.progress+.5) or localp
        local threshold=tonumber(self.store:preferences().sync.threshold) or 2
        if math.abs(actual-remotep)<=threshold then
            self.sync:mark_verified(id,"remote_position_selected",actual,remotep)
            self:_save_progress_state(id,"remote_selected","已采用云端位置",actual,remotep)
            self.sync:end_progress_sync("已采用云端位置，阅读时间开始同步")
            self:status_toast("阅读进度同步","已切换到云端进度："..remotep.."%",4)
        else
            self:_save_progress_state(id,"remote_jump_unconfirmed","已请求跳转，位置仍待确认",actual,remotep)
            self.sync:end_progress_sync("云端位置仍待确认，阅读时间暂缓上传")
            self:info("已请求跳到云端位置，但当前显示位置为 "..actual.."%。\n\n为避免覆盖云端位置，暂不上传阅读时间。")
        end
    end)
    return true
end

function Plugin:on_remote_source_conflict(id,localp,remote,automatic)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("云端来源冲突等待用户处理")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
    local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
    local title="云端阅读位置来源不一致\n\n本机："..localp.."%"
        .."\n微信读书网页："..tostring(webp or "未获取").."%"
        .."\n官方接口："..tostring(agentp or "未获取").."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","云端来源不一致，本次暂不处理",localp,webp or agentp)
        self.sync:end_progress_sync("云端来源冲突尚未确认")
    end
    local buttons={}
    if remote.web then buttons[#buttons+1]={{text="使用网页云端 "..webp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.web)
    end}} end
    if remote.agent then buttons[#buttons+1]={{text="使用官方云端 "..agentp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.agent)
    end}} end
    buttons[#buttons+1]={{text="使用本机并上传 "..localp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
    end}}
    buttons[#buttons+1]={{text="本次暂不处理",callback=function()
        closing_for_action=true; UIManager:close(dialog); defer()
    end}}
    dialog=ButtonDialog:new{title=title,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_remote_progress(id,localp,remote,automatic)
    local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("已提示位置差异，等待用户选择")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local source=remote.source=="web_cookie" and "网页云端" or (remote.source=="agent_gateway" and "官方云端" or "云端")
    local text="检测到阅读位置不同\n\n本机位置："..localp.."%\n"..source.."位置："..remotep.."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","本次暂不处理位置差异",localp,remotep)
        self.sync:end_progress_sync("位置差异尚未确认，阅读时间暂缓上传")
    end
    dialog=ButtonDialog:new{title=text,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons={
        {{text="使用云端位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote)
        end}},
        {{text="使用本机位置并上传",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
        end}},
        {{text="本次暂不同步位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); defer()
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_relative_time(ts)
    ts=tonumber(ts or 0) or 0
    if ts<=0 then return "尚未同步" end
    local delta=math.max(0,os.time()-ts)
    if delta<10 then return "刚刚" end
    if delta<60 then return tostring(delta).."秒前" end
    if delta<3600 then return tostring(math.floor(delta/60)).."分钟前" end
    if delta<86400 then return tostring(math.floor(delta/3600)).."小时前" end
    return U.now_text(ts)
end
function Plugin:show_sync_status(detail)
    local s=self.sync:status()
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."%") or "—")
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif s.state=="verification_required" or s.state=="fetching_remote" or s.state=="progress_sync" then time_text="等待位置确认"
    elseif s.state=="repair_required" then time_text="需要修复同步"
    elseif s.state=="paused" then time_text="已暂停"
    elseif tostring(s.last_error_kind or "")=="authentication" then time_text="登录待验证"
    elseif tostring(s.last_error_kind or "")=="transport" then time_text="等待网络恢复"
    elseif tostring(s.last_error_kind or "")=="server" then time_text="等待自动重试"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end

    if HomeView.is_shown() and not self:_active_reader_ui() then
        local pending=self:_home_sync_summary(true)
        local function pending_text(count,normal)
            count=tonumber(count or 0) or 0
            return count>0 and ("待同步 "..tostring(count)) or tostring(normal or "已同步")
        end
        local rows={
            {text="总状态",post_text=self:_home_sync_status_label(),enabled=false,bold=true},
            {text="阅读进度",post_text=pending_text(pending.progress,self:progress_sync_label()),enabled=false},
            {text="阅读时间",post_text=pending_text(pending.time,time_text),enabled=false},
            {text="本地划线",post_text=pending_text(pending.highlight,"已同步"),enabled=false},
            {text="本地想法",post_text=pending_text(pending.thought,"已同步"),enabled=false},
        }
        if pending.bookmark>0 then rows[#rows+1]={text="本地书签",post_text="待同步 "..tostring(pending.bookmark),enabled=false} end
        rows[#rows+1]={text="上次同步",post_text=self:_relative_time(s.last_upload),enabled=false}
        if detail then
            rows[#rows+1]={text="详细信息",separator=true,enabled=false}
            rows[#rows+1]={text="后台服务版本",post_text=tostring(s.service_version or "—"),enabled=false}
            if s.last_stage then rows[#rows+1]={text="当前阶段",post_text=U.first_line(s.last_stage,80),enabled=false} end
            if s.last_error then rows[#rows+1]={text="最近错误",post_text=U.first_line(s.last_error,80),enabled=false} end
        end
        return self:_show_miuread_menu("同步状态",rows,{page_size=7})
    end

    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..self:progress_sync_label(),"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    if detail then
        lines[#lines+1]=""
        lines[#lines+1]="详细信息"
        lines[#lines+1]="单次阅读时间上限：30 秒"
        lines[#lines+1]="后台服务版本："..tostring(s.service_version or "—")
        if s.last_elapsed then lines[#lines+1]="上次提交时长："..tostring(s.last_elapsed).." 秒" end
        if s.last_stage then lines[#lines+1]="当前阶段："..U.first_line(s.last_stage,160) end
        if s.last_error then lines[#lines+1]="最近错误："..U.first_line(s.last_error,200) end
        if s.last_response_summary then lines[#lines+1]="响应摘要："..U.first_line(s.last_response_summary,200) end
        if s.last_http_code then lines[#lines+1]="HTTP："..tostring(s.last_http_code) end
        if s.last_path then lines[#lines+1]="上传路径："..tostring(s.last_path) end
    end
    self:info(table.concat(lines,"\n"))
end

function Plugin:repair_current_sync()
    local r=self:_current_book_record()
    if not r or not r.book then self:info("请先打开一本觅阅下载的书籍。"); return false end
    local title=tostring(r.book.title or "当前书籍")
    self:status_toast("修复阅读同步","正在检查《"..title.."》的登录和章节同步状态",4)
    local started=self.sync:repair_current(function(ok,result)
        if ok then
            self._sync_repair_prompt_book=nil
            self:status_toast("阅读同步已修复","当前进度已同步 阅读时间从现在重新开始同步",5)
        else
            local err=tostring(result or "未知错误")
            local record=self.sync:record()
            local book_id=record and record.book and tostring(record.book.book_id or "") or ""
            local session=book_id~="" and (self.store:session(book_id) or {}) or {}
            local kind=tostring(session.sync_repair_kind or self.sync.last_error_kind or "")
            if kind=="authentication" or Http.is_auth_error(err) then
                local dialog
                dialog=ButtonDialog:new{title="微信读书登录已失效",buttons={
                    {{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}},
                    {{text="稍后",callback=function() UIManager:close(dialog) end}},
                }}
                UIManager:show(dialog)
            elseif kind=="context" then
                self:info("当前书籍同步修复失败\n\n登录状态正常 但无法可靠识别当前章节。\n\n已暂停这本书的阅读时间同步 其他书籍不受影响。")
            elseif kind=="transport" then
                self:info("阅读同步修复失败\n\n当前网络连接仍不可用。\n\n本次失败的阅读时间不会补传 可以稍后再次修复。")
            else
                self:info("阅读同步修复失败\n\n微信读书未确认本次同步。\n\n本次失败的阅读时间不会补传 可以稍后再次修复。")
            end
        end
    end)
    if not started then self:info("暂时无法启动同步修复 请稍后再试。") end
    return started
end

function Plugin:_show_sync_repair_prompt(err,kind,book_id)
    kind=tostring(kind or "")
    if kind~="context" and kind~="position" then return false end
    local r=self:_current_book_record()
    local current_id=r and r.book and tostring(r.book.book_id or "") or ""
    book_id=tostring(book_id or current_id)
    if book_id=="" or (current_id~="" and book_id~=current_id) then return end
    if self._sync_repair_prompt_book==book_id then return end
    self._sync_repair_prompt_book=book_id
    local title=tostring(r and r.book and r.book.title or "当前书籍")
    local detail=(tostring(kind or "")=="context")
        and "当前书籍的章节同步信息无法可靠识别。"
        or ((tostring(kind or "")=="authentication") and "当前登录或同步状态已失效。" or "本次阅读同步未成功。")
    local dialog
    local function close()
        self._sync_repair_prompt_book=nil
        if dialog then UIManager:close(dialog) end
    end
    dialog=ConfirmBox:new{
        text="《"..title.."》阅读同步失败\n\n"..detail
            .."\n\n本次失败的阅读时间不会补传。其他书籍不受影响。",
        ok_text="修复同步", cancel_text="稍后",
        ok_callback=function() close(); self:repair_current_sync() end,
        cancel_callback=close,
    }
    UIManager:show(dialog)
end

function Plugin:on_auth_required(channel,err)
    local notify=tostring(channel or "")~="read_report"
    local marked=self:_mark_auth_problem(channel,err,notify)
    if marked and not notify then
        self:status_toast("阅读时间上传","登录验证暂时失败，本次时间不补传；下载不受影响",5)
    end
    return marked
end
function Plugin:on_auth_channel_ok(channel)
    self:_mark_auth_channel_ok(channel)
end

function Plugin:on_read_report_ready()
    -- Background sync starts silently.
end
function Plugin:on_read_report_success(path)
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if r and session.progress_sync_state=="mapping_pending"
        and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("catalog_ready",true) end
        end)
    elseif r and self.store:preferences().sync.progress_enabled~=false then
        -- Automatic background reports already carry the latest position. Do not
        -- immediately query the cloud again: the extra read caused avoidable I/O
        -- and UI stalls on slower devices. Manual uploads still perform full
        -- confirmation through upload_local_progress().
        local position=self.sync:local_position()
        if position and position.safe==true and position.progress~=nil then
            local target=math.floor((tonumber(position.progress) or 0)+.5)
            self.store:save_session(r.book.book_id,{
                progress_upload_state="submitted",
                progress_upload_at=os.time(),
                progress_upload_percent=target,
            })
        end
    end
end
function Plugin:on_read_report_interval_success(status)
    if status and (status.recovery_probe==true or tonumber(status.elapsed_seconds or 0)<=0) then return end
    local prefs=self.store:preferences().sync or {}
    if prefs.time_enabled~=true then return end
    if prefs.progress_enabled~=false then
        self:_show_auto_sync_success("阅读进度和阅读时间已上传")
    else
        self:_show_auto_sync_success("阅读时间已上传")
    end
end
function Plugin:on_read_report_failure(err,kind,book_id)
    kind=tostring(kind or "")
    if kind=="authentication" or Http.is_auth_error(err) then
        self:_mark_auth_problem("read_report",err,false)
        return
    end
    if kind=="context" or kind=="position" then self:_show_sync_repair_prompt(err,"context",book_id) end
end
function Plugin:_current_book_record()
    self.store:reload()
    local r=self.sync:record()
    if r then return r end
    local doc=self.ui and self.ui.document
    local path=doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    local b,rec,variant=self.store:file_record(path)
    if b then return {book=b,record=rec,variant=variant,path=path} end
    local raw=path and U.read_file(path,true)
    local id=raw and (raw:match('"book_id"%s*:%s*"([^"]+)"') or raw:match('miuread://book/([^<"]+)'))
    local fallback=id and self.store:book(id)
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean or fallback.variants.range_notes or fallback.variants.range_clean or fallback.variants.preview_notes or fallback.variants.preview_clean),variant=nil,path=path} end
end

function Plugin:redownload_current()
    local r=self:_current_book_record()
    if not r or not r.book then self:info(_("No matching MiuRead book is open.")); return end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    local dialog
    local buttons={}
    buttons[#buttons+1]={{text="生成纯净版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=false},false) end}}
    buttons[#buttons+1]={{text="生成划线与想法版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=true},false) end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title="重新生成《"..tostring(b.title or "本书").."》",title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_repair_preferences()
    local preferences=self.store:preferences()
    preferences.repair=type(preferences.repair)=="table" and preferences.repair or {}
    if preferences.repair.auto_check==nil then preferences.repair.auto_check=true end
    return preferences.repair,preferences
end

function Plugin:_repair_context(current)
    if type(current)=="table" and current.book then
        return {
            book=current.book,
            record=current.record or {},
            variant=current.variant,
            path=current.path,
            title=current.book and current.book.title,
        }
    end
    local row=self:_current_book_record()
    if not row then return nil end
    return {
        book=row.book,
        record=row.record or {},
        variant=row.variant,
        path=row.path,
        title=row.book and row.book.title,
    }
end

function Plugin:_repair_state()
    local state=self.store:get("book_repair_state",{})
    return type(state)=="table" and state or {}
end

function Plugin:_save_repair_state(book_id,row)
    local state=self:_repair_state()
    state[tostring(book_id or "")]=row
    self.store:set("book_repair_state",state)
end

function Plugin:_record_repair_history(result,status)
    local history=self.store:get("book_repair_history",{})
    if type(history)~="table" then history={} end
    table.insert(history,1,{
        at=os.time(),
        title=tostring(result and result.title or "书籍"),
        book_id=tostring(result and result.book_id or ""),
        status=tostring(status or ((result and result.ok) and "已完成" or "失败")),
    })
    while #history>20 do table.remove(history) end
    self.store:set("book_repair_history",history)
end

function Plugin:_repair_message(report)
    local lines={"检测到本书仍有旧版 JSON 想法与评论数据。"}
    lines[#lines+1]=""
    lines[#lines+1]="迁移后将直接使用 SQLite，旧评论索引不再需要。"
    lines[#lines+1]="迁移不会重新下载书籍，也不会改动 EPUB 正文。"
    if tonumber(report and report.pending or 0)>0 then
        lines[#lines+1]=""
        lines[#lines+1]="待迁移章节："..tostring(report.pending)
    end
    return table.concat(lines,"\n")
end

function Plugin:_close_migration_progress(token)
    if token and self._migration_token~=token then return end
    if self._migration_progress_poll then
        UIManager:unschedule(self._migration_progress_poll)
        self._migration_progress_poll=nil
    end
    if self._migration_progress_delay then
        UIManager:unschedule(self._migration_progress_delay)
        self._migration_progress_delay=nil
    end
    if self._migration_progress_widget then
        self._migration_progress_widget:close()
        self._migration_progress_widget=nil
    end
    local active_token=self._migration_token
    if active_token then DownloadDatabase.clear_task(DownloadDatabase.runtime_path(self.store),active_token) end
    self._migration_token=nil
end

function Plugin:_schedule_migration_progress(token,title)
    self:_close_migration_progress()
    self._migration_token=token
    local path=DownloadDatabase.runtime_path(self.store)
    local function poll()
        if self._migration_token~=token then return end
        local state=DownloadDatabase.get_task_value(path,token,"migration_progress",nil)
        if self._migration_progress_widget and type(state)=="table" then
            self._migration_progress_widget:set_state(state)
        end
        if self.repair_async and self.repair_async:busy() then
            self._migration_progress_poll=poll
            UIManager:scheduleIn(.7,poll)
        end
    end
    local delay
    delay=function()
        if self._migration_token~=token or not (self.repair_async and self.repair_async:busy()) then return end
        self._migration_progress_delay=nil
        local widget=MigrationProgress:new{
            title="正在迁移《"..tostring(title or "当前书籍").."》",
            on_cancel=function()
                DownloadDatabase.set_cancelled(path,token,true)
            end,
        }
        self._migration_progress_widget=widget
        widget:show()
        local state=DownloadDatabase.get_task_value(path,token,"migration_progress",nil)
        if type(state)=="table" then widget:set_state(state) end
        poll()
    end
    self._migration_progress_delay=delay
    UIManager:scheduleIn(1.0,delay)
end

function Plugin:_run_book_repair(context,report,force)
    context=context or self:_repair_context()
    if not context or not context.book then self:info("当前没有可迁移的觅阅书籍"); return false end
    if self.repair_async and self.repair_async:busy() then self:toast("已有迁移任务正在进行"); return false end
    if type(report)~="table" then
        local repair=self.book_repair
        self:toast("正在检查本书旧评论数据",2)
        local started,err=self.repair_async:run("book-migration-check",function()
            return repair:inspect(context)
        end,function(result)
            if not result or result.ok~=true or type(result.value)~="table" then
                self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
            end
            self:_run_book_repair(context,result.value,force)
        end,120)
        if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
        return started
    end
    if #(report.issues or {})==0 then
        self:info("当前书籍已经使用 SQLite，无需迁移。")
        return true
    end
    local title=tostring((context.book or {}).title or context.title or "当前书籍")
    local token="migration-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))
    local path=DownloadDatabase.runtime_path(self.store)
    DownloadDatabase.clear_task(path,token)
    self:_schedule_migration_progress(token,title)
    local repair=self.book_repair
    local started,err=self.repair_async:run("book-data-migration",function()
        return repair:migrate(context,report,{
            force=force==true,
            archive_legacy=false,
            progress=function(state)
                DownloadDatabase.set_task_value(path,token,"migration_progress",state)
            end,
            cancelled=function()
                return DownloadDatabase.is_cancelled(path,token)
            end,
        })
    end,function(result)
        self:_close_migration_progress(token)
        if not result or result.ok~=true or type(result.value)~="table" then
            local message=tostring(result and result.error or "迁移任务未完成")
            self:_record_repair_history({title=title,book_id=(context.book or {}).book_id},"失败")
            self:info("迁移失败：\n"..message)
            return
        end
        local value=result.value
        local status=value.cancelled and "已停止" or (value.ok and "已完成" or "部分失败")
        self:_record_repair_history(value,status)
        self:_save_repair_state(value.book_id,{
            signature=value.signature,
            status=value.ok and "fixed" or (value.cancelled and "pending" or "failed"),
            checked_at=os.time(),
        })
        Thoughts.clear_memory_cache()
        if ThoughtNativePopup and type(ThoughtNativePopup.clear_cache)=="function" then
            pcall(ThoughtNativePopup.clear_cache)
        end
        if value.cancelled then
            self:info("迁移已停止。已完成的章节会保留，下次可继续。")
        elseif value.ok then
            self:info("迁移完成。\n\n已处理 "..tostring(value.processed or 0).." 个章节、新迁移 "
                ..tostring(value.comments or 0).." 条评论。以后将直接使用 SQLite。")
        else
            self:info("部分章节迁移失败，成功数据已保留，可稍后继续迁移。")
        end
    end,900)
    if not started then
        self:_close_migration_progress(token)
        self:info("无法开始迁移：\n"..tostring(err or "未知原因"))
        return false
    end
    return true
end

function Plugin:_show_book_repair_prompt(context,report)
    if self._repair_prompt_open then return end
    self._repair_prompt_open=true
    local book_id=tostring(report and report.book_id or ((context.book or {}).book_id or ""))
    local signature=tostring(report and report.signature or self.book_repair:signature(context))
    local dialog
    dialog=ButtonDialog:new{title=self:_repair_message(report),title_align="center",buttons={
        {{text="立即迁移",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
            self:_run_book_repair(context,report,false)
        end}},
        {{text="稍后处理",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
        end}},
        {{text="本书不再自动提示",callback=function()
            UIManager:close(dialog); self._repair_prompt_open=false
            self:_save_repair_state(book_id,{signature=signature,status="ignored",checked_at=os.time()})
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_schedule_current_book_repair_check(current,urgent)
    local prefs=self:_repair_preferences()
    if prefs.auto_check==false then return false end
    local context=self:_repair_context(current)
    if not context or not context.book then return false end
    local book_id=tostring((context.book or {}).book_id or (context.book or {}).bookId or "")
    if book_id=="" then return false end
    local previous=self:_repair_state()[book_id]
    if urgent~=true and type(previous)=="table"
        and (previous.status=="ok" or previous.status=="fixed" or previous.status=="ignored")
        and os.time()-(tonumber(previous.checked_at) or 0)<7*24*60*60 then
        return false
    end
    if self.repair_async and self.repair_async:busy() then return false end
    local repair=self.book_repair
    local delay=urgent==true and .05 or 1.4
    UIManager:scheduleIn(delay,function()
        local active=self:_current_document_path()
        if tostring(active or "")~=tostring(context.path or "") then return end
        if self.repair_async:busy() then return end
        local started=self.repair_async:run("book-migration-check",function()
            return repair:inspect(context)
        end,function(result)
            if not result or result.ok~=true or type(result.value)~="table" then return end
            local report=result.value
            if tostring(self:_current_document_path() or "")~=tostring(context.path or "") then return end
            if #(report.issues or {})==0 then
                self:_save_repair_state(book_id,{signature=report.signature,status="ok",checked_at=os.time()})
                return
            end
            local row=self:_repair_state()[book_id]
            if urgent~=true and type(row)=="table" and tostring(row.signature or "")==tostring(report.signature or "")
                and row.status=="ignored" then return end
            self:_show_book_repair_prompt(context,report)
        end,120)
        if not started then logger.dbg("[MiuRead][Migration] check deferred") end
    end)
    return true
end

function Plugin:_repair_partial_download(book_id,repair,confirmed)
    local id=tostring(book_id or "")
    if id=="" or type(repair)~="table" then self:info("没有找到可继续修复的下载断点") return false end
    self.store:reload()
    local stored=self.store:book(id)
    if not stored then self:info("这本书的下载记录已经不存在") return false end
    if type(repair.options)~="table" then
        self:info("这个旧下载断点缺少必要信息，无法安全地只补缺失内容。\n\n现有缓存没有删除，可以保留后重新下载。")
        return false
    end
    local title=tostring(stored.title or "本书")
    if confirmed~=true then
        local progress=""
        if tonumber(repair.total or 0)>0 then
            progress="\n\n已完成 "..tostring(repair.complete or 0).." / "..tostring(repair.total).." 个章节"
            if tonumber(repair.failed or 0)>0 then progress=progress.."，仍有 "..tostring(repair.failed).." 个章节待补" end
        end
        UIManager:show(ConfirmBox:new{
            text="《"..title.."》存在未完成下载。"..progress
                .."\n\n修复时会复用现有断点，只重新获取缺失内容；新文件验证成功前不会替换原文件。",
            ok_text="开始修复",cancel_text="取消",
            ok_callback=function() self:_repair_partial_download(id,repair,true) end,
        })
        return true
    end
    if self.download_task and self.download_task:busy() then
        self:info("已有下载或修复任务正在进行，请完成后再试。")
        return false
    end
    local book={bookId=id,title=stored.title,author=stored.author,cover=stored.cover}
    local options=U.copy(repair.options)
    options.repair_only=true
    options.repair_source="partial_cache"
    self:status_toast("修复书籍","正在复用断点并补全缺失内容",4)
    return self:download(book,options,false,function(new_record)
        self.store:reload()
        if type(new_record)=="table" and new_record.pending_install==true then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_pending_install=true})
            self:info("修复内容已经生成。\n\n当前正在阅读这本书，新文件会在关闭本书后自动替换；原文件目前没有改变。")
            self:_notify_home_data_changed("content")
            return
        end
        local remaining=BookIntegrity.partial_repairs(self.store,id)
        local same_pending=false
        for _,row in ipairs(remaining) do
            if tostring(row.root or "")==tostring(repair.root or "") then same_pending=true break end
        end
        if same_pending then
            self.store:save_session(id,{book_integrity_error="partial_pending",book_integrity_checked_at=os.time()})
            self:info("书籍仍有未完成内容。\n\n已完成章节和下载断点继续保留，下次使用“修复书籍”会从现有进度继续。")
        else
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_error=false})
            local reused=tonumber(repair.complete or 0) or 0
            local suffix=reused>0 and ("\n\n已复用 "..tostring(reused).." 个已完成章节，没有重新下载整本书。") or ""
            self:info("书籍修复完成。\n\n缺失内容已经补全，新文件通过检查后才替换原文件。"..suffix)
        end
        self:_notify_home_data_changed("content")
    end,false)
end

function Plugin:_repair_downloaded_book(book_ref,confirmed)
    local id=tostring(type(book_ref)=="table" and (book_ref.bookId or book_ref.book_id) or book_ref or "")
    if id=="" then self:info("没有找到可修复的书籍") return false end
    self.store:reload()
    local stored=self.store:book(id)
    if not stored then self:info("这本书还没有可修复的下载记录") return false end

    local partials=BookIntegrity.partial_repairs(self.store,id)
    if #partials==1 then return self:_repair_partial_download(id,partials[1],confirmed) end
    if #partials>1 then
        local rows={}
        for _,candidate in ipairs(partials) do
            local repair=candidate
            local detail=tonumber(repair.total or 0)>0
                and (tostring(repair.complete or 0).."/"..tostring(repair.total).." 章已完成") or "可继续修复"
            rows[#rows+1]={text=repair.label or "未完成缓存",post_text=detail,
                callback=function() self:_repair_partial_download(id,repair) end}
        end
        self:list("选择要修复的未完成下载",rows)
        return true
    end

    local record=self:_preferred_record(id)
    if not record then self:info("这本书还没有可修复的已下载版本") return false end
    local report=BookIntegrity.inspect(self.store,id,record)
    if report.repair_kind=="none" then
        local session=self.store:session(id) or {}
        if session.sync_repair_required==true then
            self:info("书籍内容完整。\n\n当前异常来自阅读同步，请打开这本书后使用“修复同步”。")
        else
            self:info("检查完成，没有发现需要修复的书籍内容或批注。")
        end
        return true
    end
    local annotations_only=report.repair_kind=="annotations"
    local title=tostring(stored.title or record.title or "本书")
    if confirmed~=true then
        local text
        if annotations_only then
            text="《"..title.."》正文已经生成，但部分划线与想法未完整下载。\n\n修复时只补缺失内容，已完成正文和阅读位置会保留。"
        else
            text="《"..title.."》的书籍内容或章节映射需要修复。\n\n将优先使用现有断点，只补缺失内容；新文件验证成功前不会替换原文件。"
        end
        UIManager:show(ConfirmBox:new{
            text=text,ok_text="开始修复",cancel_text="取消",
            ok_callback=function() self:_repair_downloaded_book(id,true) end,
        })
        return true
    end
    if self.download_task and self.download_task:busy() then
        self:info("已有下载或修复任务正在进行，请完成后再试。")
        return false
    end
    local book={bookId=id,title=stored.title or record.title,author=stored.author or record.author,cover=stored.cover}
    local options=BookIntegrity.repair_options(record)
    self:status_toast("修复书籍",annotations_only and "正在补全缺失的划线与想法" or "正在检查并补全书籍内容",4)
    return self:download(book,options,false,function(new_record)
        self.store:reload()
        if type(new_record)=="table" and new_record.pending_install==true then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_pending_install=true})
            self:info("修复内容已经生成。\n\n当前正在阅读这本书，新文件会在关闭本书后自动替换；替换后阅读同步会重新验证。")
            self:_notify_home_data_changed("content")
            return
        end
        local refreshed=self:_preferred_record(id) or new_record
        local checked=BookIntegrity.inspect(self.store,id,refreshed)
        if checked.repair_kind=="none" then
            self.store:save_session(id,{book_integrity_repaired_at=os.time(),book_integrity_error=false})
            local session=self.store:session(id) or {}
            local extra=session.sync_repair_required==true and "\n\n书籍已修复。阅读同步仍需在打开本书后重新验证。" or ""
            self:info((annotations_only and "书籍修复完成。\n\n已补全缺失的划线与想法，正文和阅读位置未重新下载。"
                or "书籍修复完成。\n\n缺失内容已补全，新文件已经通过检查。")..extra)
        else
            self.store:save_session(id,{book_integrity_error=checked.error or checked.repair_kind,book_integrity_checked_at=os.time()})
            self:info("书籍仍有未完成内容：\n"..tostring(checked.error or (checked.annotation_pending and "部分划线与想法仍待修复" or "完整性检查未通过")))
        end
        self:_notify_home_data_changed("content")
    end,false)
end

function Plugin:repair_current_book()
    local current=self:_current_book_record()
    if not current or not current.book then self:info("请先打开一本觅阅书籍") return false end
    return self:_repair_downloaded_book(current.book.book_id)
end

function Plugin:scan_downloaded_books_for_integrity_repair()
    self.store:reload()
    local rows={}
    for _,book in ipairs(self.store:all_books()) do
        local id=tostring(book.book_id or book.bookId or "")
        if id~="" then
            local partials=BookIntegrity.partial_repairs(self.store,id)
            local record=self:_preferred_record(id)
            local book_id=id
            if #partials>0 then
                rows[#rows+1]={text=tostring(book.title or (record and record.title) or id),
                    post_text=tostring(#partials).." 个未完成断点",
                    callback=function() self:_repair_downloaded_book(book_id) end}
            elseif record then
                local report=BookIntegrity.inspect(self.store,id,record)
                if report.repair_kind~="none" then
                    local label=report.repair_kind=="annotations" and "批注待修复" or "书籍待修复"
                    rows[#rows+1]={text=tostring(book.title or record.title or id),post_text=label,
                        callback=function() self:_repair_downloaded_book(book_id) end}
                end
            end
        end
    end
    if #rows==0 then self:info("检查完成，没有发现需要修复的已下载书籍或未完成下载。") return true end
    self:list("需要修复的书籍 · "..tostring(#rows).." 本",rows)
    return true
end

function Plugin:migrate_current_book_comments(confirmed)
    local context=self:_repair_context()
    if not context then self:info("请先打开一本觅阅书籍"); return end
    if confirmed~=true and self:_active_reader_ui() and self:_notice_enabled("repair_while_reading") then
        local dialog
        dialog=ButtonDialog:new{title="迁移会读取本书旧评论数据。大书可能短暂变慢，但不会重新下载正文。",title_align="center",buttons={
            {{text="继续迁移",callback=function() UIManager:close(dialog); self:migrate_current_book_comments(true) end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("repair_while_reading",false); self:migrate_current_book_comments(true) end}},
            {{text="稍后处理",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    self:_run_book_repair(context,nil,true)
end

function Plugin:scan_downloaded_books_for_repair(confirmed)
    if confirmed~=true and self:_notice_enabled("library_scan") then
        self:_confirm_library_scan(function() self:scan_downloaded_books_for_repair(true) end)
        return
    end
    if self.repair_async:busy() then self:toast("已有检查或迁移任务正在进行"); return end
    self:toast("正在检查已下载书籍",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("scan-book-migration",function()
        return repair:scan_downloaded()
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
        end
        local scan=result.value
        if tonumber(scan.affected or 0)==0 then
            self:info("检查完成，没有发现需要迁移的已下载书籍。")
            return
        end
        UIManager:show(ConfirmBox:new{
            text="发现 "..tostring(scan.affected).." 本书仍有旧版评论数据。\n\n是否全部迁移到 SQLite？",
            ok_text="全部迁移",cancel_text="暂不处理",
            ok_callback=function()
                if self.repair_async:busy() then self:toast("已有迁移任务正在进行"); return end
                local token="migration-batch-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))
                local path=DownloadDatabase.runtime_path(self.store)
                DownloadDatabase.clear_task(path,token)
                self:_schedule_migration_progress(token,"已下载书籍评论")
                local ok_start,error_start=self.repair_async:run("migrate-downloaded-books",function()
                    local output={checked=0,migrated=0,failed=0,cancelled=false,details={},groups=0,comments=0}
                    local total_chapters=0
                    for _,row in ipairs(scan.contexts or {}) do
                        total_chapters=total_chapters+#((row.report or {}).files or {})
                    end
                    local completed=0
                    for _,row in ipairs(scan.contexts or {}) do
                        if DownloadDatabase.is_cancelled(path,token) then output.cancelled=true; break end
                        local book_title=tostring(((row.context or {}).book or {}).title or (row.context or {}).title or "书籍")
                        local value=repair:migrate(row.context,row.report,{
                            archive_legacy=false,
                            cancelled=function() return DownloadDatabase.is_cancelled(path,token) end,
                            progress=function(state)
                                state=type(state)=="table" and state or {}
                                DownloadDatabase.set_task_value(path,token,"migration_progress",{
                                    current=completed+(tonumber(state.current) or 0),
                                    total=total_chapters,
                                    chapter=book_title.." · "..tostring(state.chapter or ""),
                                    groups=output.groups+(tonumber(state.groups) or 0),
                                    comments=output.comments+(tonumber(state.comments) or 0),
                                    percent=total_chapters>0 and (completed+(tonumber(state.current) or 0))/total_chapters or 1,
                                })
                            end,
                        })
                        output.checked=output.checked+1
                        output.groups=output.groups+(tonumber(value.groups) or 0)
                        output.comments=output.comments+(tonumber(value.comments) or 0)
                        completed=completed+#((row.report or {}).files or {})
                        if value.cancelled then output.cancelled=true end
                        if value.ok then output.migrated=output.migrated+1 else output.failed=output.failed+1 end
                        output.details[#output.details+1]=value
                        if output.cancelled then break end
                    end
                    output.ok=output.failed==0 and output.cancelled~=true
                    return output
                end,function(fixed)
                    self:_close_migration_progress(token)
                    if not fixed or fixed.ok~=true or type(fixed.value)~="table" then
                        self:info("批量迁移失败：\n"..tostring(fixed and fixed.error or "未知原因")); return
                    end
                    local value=fixed.value
                    local status=value.cancelled and "已停止" or (value.ok and "已完成" or "部分失败")
                    self:_record_repair_history({title="批量迁移",book_id=""},status)
                    if value.cancelled then
                        self:info("批量迁移已停止。已完成的数据会保留，下次可继续。")
                    elseif value.ok then
                        self:info("全部迁移完成。\n\n新迁移 "..tostring(value.comments or 0).." 条评论。")
                    else
                        self:info("部分书籍迁移失败，可稍后重试。")
                    end
                end,1800)
                if not ok_start then
                    self:_close_migration_progress(token)
                    self:info("无法开始批量迁移：\n"..tostring(error_start or "未知原因"))
                end
            end,
        })
    end,240)
    if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
end

function Plugin:clear_invalid_comment_indexes()
    if self.repair_async:busy() then self:toast("已有检查或迁移任务正在进行"); return end
    local repair=self.book_repair
    local started,err=self.repair_async:run("clear-legacy-comment-data",function()
        return repair:remove_verified_legacy_downloaded()
    end,function(result)
        if result and result.ok==true then
            self:info("已清理 "..tostring(result.value or 0).." 本书的旧 JSON 备份。SQLite 数据不会受到影响。")
        else
            self:info("清理失败：\n"..tostring(result and result.error or "未知原因"))
        end
    end,300)
    if not started then self:info("无法开始清理：\n"..tostring(err or "未知原因")) end
end

function Plugin:show_repair_history()
    local history=self.store:get("book_repair_history",{})
    local items={}
    for _,row in ipairs(type(history)=="table" and history or {}) do
        items[#items+1]={text=tostring(row.title or "书籍"),
            post_text=self:_display_time("%m-%d %H:%M",tonumber(row.at) or os.time()).." · "..tostring(row.status or ""),enabled=false}
    end
    if #items==0 then items[1]={text="还没有迁移记录",enabled=false} end
    self:list("迁移记录",items)
end

function Plugin:_confirm_library_scan(callback)
    if not self:_notice_enabled("library_scan") then callback(); return true end
    local dialog
    dialog=ButtonDialog:new{title="扫描大量本地书籍可能暂时增加耗电，并使主页响应变慢。",title_align="center",buttons={
        {{text="开始扫描",callback=function() UIManager:close(dialog); callback() end}},
        {{text="开始并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("library_scan",false); callback() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:book_repair_settings_menu()
    return {
        {text="打开书籍时检查旧评论数据",checked_func=function()
            return (self.store:preferences().repair or {}).auto_check~=false
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.repair=p.repair or {}
            p.repair.auto_check=p.repair.auto_check==false
            self.store:save_preferences(p)
        end},
        {text="迁移当前书籍评论",callback=function() self:migrate_current_book_comments() end},
        {text="扫描所有待迁移书籍",callback=function() self:scan_downloaded_books_for_repair() end},
        {text="重新扫描本地书籍与封面",callback=function() self:show_miuread_home(true) end},
        {text="清理已验证的旧 JSON 备份",callback=function() self:clear_invalid_comment_indexes() end},
        {text="迁移记录",callback=function() self:show_repair_history() end},
        {text="重置迁移提示状态",callback=function()
            self.store:set("book_repair_state",{})
            self:toast("已重置评论迁移提示状态")
        end},
    }
end

function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end




function Plugin:_thought_display_label()
    return self:_thoughts_enabled() and ("已开启 · "..self:_thought_font_size_label()) or "已关闭"
end

function Plugin:_toggle_home_network_metadata()
    local home,preferences=self:_home_preferences()
    home.network_metadata=home.network_metadata==false
    home.network_metadata_user_set=true
    home.network_metadata_defaults_version=2
    self:_save_home_preferences(home,preferences)
    if home.network_metadata and self._home_hero then
        self:_home_schedule_network_metadata(self._home_hero,true,true,nil,true)
    end
    self:toast(home.network_metadata and "已开启网络补全图书信息" or "已关闭网络补全图书信息",2)
end

function Plugin:_local_root_index(path)
    path=LocalLibrary.normalize(path)
    local home,preferences=self:_home_preferences()
    for index,root in ipairs(home.local_roots or {}) do
        if LocalLibrary.normalize(root.path)==path then return index,root,home,preferences end
    end
    return nil,nil,home,preferences
end

function Plugin:_save_local_roots(home,preferences)
    home.local_root=(home.local_roots and home.local_roots[1] and home.local_roots[1].path) or ""
    local enabled={}
    for _,root in ipairs(home.local_roots or {}) do if root.enabled~=false then enabled[#enabled+1]=root end end
    local current=LocalLibrary.normalize(home.local_inline_path or "")
    local matched=self:_home_local_root_for_path(current,enabled)
    if not matched then
        if #enabled==1 then home.local_inline_path=enabled[1].path; home.local_inline_root=enabled[1].path
        else home.local_inline_path=""; home.local_inline_root="" end
    end
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_notify_home_data_changed("content") end
end

function Plugin:_validate_local_root(path)
    path=LocalLibrary.normalize(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    if path=="/" or path=="/mnt" or path=="/mnt/us" then return nil,"请选择实际存放书籍的子文件夹" end
    if lfs.attributes(path,"mode")~="directory" then return nil,"文件夹不存在" end
    for _,root in ipairs(self:_home_local_roots(false)) do
        local existing=LocalLibrary.normalize(root.path)
        if existing==path then return nil,"这个目录已经添加" end
        if path:sub(1,#existing+1)==existing.."/" or existing:sub(1,#path+1)==path.."/" then
            return nil,"这个目录与现有书库目录重叠"
        end
    end
    return true,path
end

function Plugin:_add_local_root_path(path)
    local ok,normalized_or_error=self:_validate_local_root(path)
    if not ok then self:info("无法添加此目录：\n"..tostring(normalized_or_error)); return false end
    path=normalized_or_error
    local function save()
        local home,preferences=self:_home_preferences()
        home.local_roots=type(home.local_roots)=="table" and home.local_roots or {}
        home.local_roots[#home.local_roots+1]={path=path,name=LocalLibrary.basename(path),enabled=true,readonly=true}
        self:_save_local_roots(home,preferences)
        self:toast("已添加本地书库目录",2)
        if home.local_library_mode=="direct" then
            self:_home_refresh_local_directory(path,function()
                if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            end,true)
        elseif home.local_library_mode=="auto" then
            UIManager:scheduleIn(.35,function() self:_home_scan_local(true) end)
        end
    end
    if path=="/mnt/us/documents" or path=="/mnt/onboard" then
        local dialog
        dialog=ConfirmBox:new{
            text=(self:_home_preferences().local_library_mode=="direct"
                and "这个目录可能包含很多文件。文件夹浏览只读取当前层，但仍建议选择实际存放书籍的子文件夹。"
                or "这个目录可能包含很多文件。建立书库索引时耗时会更长，更建议选择实际存放书籍的子文件夹。"),
            ok_text="仍然添加",ok_callback=function() UIManager:close(dialog); save() end,
        }
        UIManager:show(dialog)
        return true
    end
    save(); return true
end

function Plugin:add_local_root_dialog()
    local current="/mnt/us/documents"
    if lfs.attributes(current,"mode")~="directory" then
        current=lfs.attributes("/mnt/onboard","mode")=="directory" and "/mnt/onboard" or "/mnt/us"
    end
    local chooser=PathChooser:new{
        title="选择本地书库目录",select_directory=true,select_file=false,show_files=false,path=current,
        onConfirm=function(path) self:_add_local_root_path(path) end,
    }
    UIManager:show(chooser)
end

function Plugin:rename_local_root(path)
    local index,root,home,preferences=self:_local_root_index(path)
    if not index then return end
    local dialog
    dialog=InputDialog:new{
        title="书库显示名称",input=tostring(root.name or LocalLibrary.basename(path)),
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text="保存",is_enter_default=true,callback=function()
                local name=U.trim(dialog:getInputText())
                if name=="" then return end
                UIManager:close(dialog)
                home.local_roots[index].name=name
                self:_save_local_roots(home,preferences)
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:remove_local_root(path)
    local index,root,home,preferences=self:_local_root_index(path)
    if not index then return end
    local dialog
    dialog=ConfirmBox:new{
        text="从觅阅中移除“"..tostring(root.name or LocalLibrary.basename(path)).."”？\n\n不会删除目录或其中的书籍。",
        ok_text="移除",ok_callback=function()
            UIManager:close(dialog)
            table.remove(home.local_roots,index)
            self:_save_local_roots(home,preferences)
            local tree=self:_home_local_tree_cache()
            local prefix=LocalLibrary.normalize(path).."/"
            for key in pairs(tree.dirs or {}) do
                local normalized=LocalLibrary.normalize(key)
                if normalized==LocalLibrary.normalize(path) or normalized:sub(1,#prefix)==prefix then tree.dirs[key]=nil end
            end
            self.store:set("home_local_tree_index",tree)
            local index_cache=self:_home_local_cache()
            local kept={}
            local normalized_root=LocalLibrary.normalize(path)
            for _,book in ipairs(index_cache.books or {}) do
                if LocalLibrary.normalize(book.library_root or index_cache.root or "")~=normalized_root then
                    kept[#kept+1]=book
                end
            end
            index_cache.books=kept
            self.store:set("home_local_index",index_cache)
            self:toast("已移除本地书库目录",2)
        end,
    }
    UIManager:show(dialog)
end

function Plugin:local_root_settings_menu(path)
    local _,root=self:_local_root_index(path)
    if not root then return {{text="目录已不存在",enabled=false}} end
    return {
        {text="浏览此目录",post_text=tostring(root.path),callback=function() self:show_local_browser(root.path,root,{},false) end},
        {text="启用此目录",checked_func=function()
            local _,current=self:_local_root_index(path); return current and current.enabled~=false
        end,keep_menu_open=true,callback=function()
            local index,current,home,preferences=self:_local_root_index(path); if not index then return end
            home.local_roots[index].enabled=current.enabled==false
            self:_save_local_roots(home,preferences)
        end},
        {text="修改显示名称",callback=function() self:rename_local_root(path) end},
        {text="刷新当前层",callback=function()
            self:_home_refresh_local_directory(path,function() self:toast("当前层已刷新",2) end,true)
        end},
        {text="从觅阅移除",callback=function() self:remove_local_root(path) end},
    }
end

local LOCAL_LIBRARY_MODE_LABELS={auto="自动管理",manual="手动扫描",direct="文件夹浏览"}

function Plugin:_local_library_mode_label(mode)
    return LOCAL_LIBRARY_MODE_LABELS[tostring(mode or self:_home_preferences().local_library_mode or "direct")] or "文件夹浏览"
end

function Plugin:_set_local_library_mode(mode)
    if mode~="auto" and mode~="manual" and mode~="direct" then return false end
    local home,preferences=self:_home_preferences()
    if home.local_library_mode==mode then return true end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    if self.home_async then self.home_async:cancel("local library mode changed") end
    self:_cancel_home_directory_request("local library mode changed")
    self._home_refreshing=false
    home.local_library_mode=mode
    home.auto_scan=mode=="auto"
    self:_save_home_preferences(home,preferences)
    if HomeView.is_shown() then self:_notify_home_data_changed("content") end
    self:toast("本地书籍已切换为"..self:_local_library_mode_label(mode),2)
    if mode=="auto" then
        UIManager:scheduleIn(.35,function()
            if not self:_active_reader_ui() and HOME_SESSION.suspended~=true then self:_home_scan_local(true) end
        end)
    end
    return true
end

function Plugin:local_library_mode_menu()
    local rows={}
    local details={
        auto="自动维护索引，适合书籍较少",
        manual="只在点击扫描时更新，推荐大书库",
        direct="不递归扫描，按文件夹直接查看",
    }
    for _,mode in ipairs({"auto","manual","direct"}) do
        local key=mode
        rows[#rows+1]={
            text=self:_local_library_mode_label(key),post_text=details[key],radio=true,
            checked_func=function() return self:_home_preferences().local_library_mode==key end,
            callback=function() self:_set_local_library_mode(key) end,
        }
    end
    return rows
end

function Plugin:_toggle_local_library_auto_update()
    local home,preferences=self:_home_preferences()
    home.local_auto_update=home.local_auto_update~=true
    home.auto_scan=home.local_auto_update==true
    self:_save_home_preferences(home,preferences)
    self:toast(home.local_auto_update and "本地书库自动更新已开启" or "本地书库自动更新已关闭",2)
    if home.local_auto_update and HomeView.is_shown() then
        UIManager:scheduleIn(.25,function() self:_home_scan_local(false) end)
    end
    return home.local_auto_update
end

function Plugin:local_library_settings_menu()
    local home=self:_home_preferences()
    local items={
        {text="自动更新本地书库",post_text=home.local_auto_update==true and "已开启" or "已关闭",
            checked_func=function() return self:_home_preferences().local_auto_update==true end,keep_menu_open=true,
            callback=function() self:_toggle_local_library_auto_update() end},
        {text="按文件夹浏览",post_text="书籍与文件夹分开查看",callback=function() self:_open_local_library_folders() end},
    }
    for _,root in ipairs(self:_home_local_roots(false)) do
        local path=root.path
        items[#items+1]={
            text=tostring(root.name or LocalLibrary.basename(path)),post_text=root.enabled~=false and "已启用" or "已停用",
            sub_item_table_func=function() return self:local_root_settings_menu(path) end,
        }
    end
    if #self:_home_local_roots(false)==0 then items[#items+1]={text="尚未添加本地书库目录",enabled=false} end
    items[#items+1]={text="添加本地书库目录",post_text="选择实际存放书籍的文件夹",callback=function() self:add_local_root_dialog() end}
    local cache=self:_home_local_cache()
    local scanned=tonumber(cache.scanned_at or 0) or 0
    items[#items+1]={text="上次更新",post_text=scanned>0 and self:_display_time("%m-%d %H:%M",scanned) or "尚未更新",enabled=false}
    items[#items+1]={text="说明",post_text="主页只显示书籍 文件夹浏览不会混进书架",enabled=false}
    return items
end

function Plugin:display_settings_menu()
    local home=self:_home_preferences()
    local size_labels={compact="紧凑",standard="标准",large="大号"}
    return {
        {text="页面布局",post_text=(home.layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return self:home_layout_settings_menu() end},
        {text="觅阅显示大小",post_text=size_labels[home.display_size] or "标准",sub_item_table_func=function() return self:home_display_size_menu() end},
        {text="觅阅界面字体",post_text=self:_home_ui_font_label(home),sub_item_table_func=function() return self:home_ui_font_menu() end},
        {text="首页书架来源",post_text="选择显示项目",sub_item_table_func=function() return self:home_source_settings_menu() end},
        {text="本地书籍",post_text=home.local_auto_update==true and "自动更新" or "手动更新",sub_item_table_func=function() return self:local_library_settings_menu() end},
        {text="公众号阅读",post_text="图片与缓存",sub_item_table_func=function() return self:mp_settings_menu() end},
        {text="主页快捷工具",post_text="最多六项",sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="下滑工具栏",post_text="设备与 KOReader",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="网络补全图书信息",post_text="只补充缺失资料",checked_func=function() return self:_home_preferences().network_metadata~=false end,keep_menu_open=true,callback=function() self:_toggle_home_network_metadata() end},
        {text="主页锁屏显示最近阅读封面",checked_func=function() return self:_home_preferences().lockscreen_recent~=false end,keep_menu_open=true,callback=function() self:_toggle_home_lockscreen() end},
        {text="显示书架封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
end

function Plugin:_performance_mode_label()
    local status=self.performance_mode:status()
    return status.enabled and "轻量模式" or "标准模式"
end

function Plugin:_lightweight_enabled()
    return self.performance_mode and self.performance_mode:enabled() or false
end

function Plugin:_set_performance_mode(enabled)
    self.performance_mode:set_enabled(enabled==true)
    if enabled then
        if self.ui and self.ui.document then self:_mark_reader_busy(3) end
        self:info("轻量模式已开启。\n\n阅读和菜单操作会优先；后台下载、封面、书籍资料和自动更新会更保守地执行。阅读、下载和同步功能不会关闭。")
    else
        if self.download_task then self.download_task:resume("reader_interaction") end
        self:info("已恢复标准模式。")
    end
end

function Plugin:_toggle_performance_auto_detect()
    local status=self.performance_mode:status()
    self.performance_mode:set_auto_detect(not status.auto_detect)
    self:toast((not status.auto_detect) and "性能问题检测已开启" or "性能问题检测已关闭",2)
end

function Plugin:_record_performance(kind,elapsed_ms)
    if not self.performance_mode then return nil end
    local result=self.performance_mode:record(kind,elapsed_ms)
    if result then self._performance_prompt_pending=result end
    return result
end

function Plugin:_schedule_performance_prompt(delay)
    if not self._performance_prompt_pending then return false end
    local pending=self._performance_prompt_pending
    local attempts=0
    local task
    task=function()
        if self._performance_prompt_pending~=pending then return end
        if HOME_EXITING or UIManager._exit_code~=nil
            or HOME_SESSION.suspended==true or self._miuread_suspended==true then return end
        if reader_close_active() or self._thought_popup_busy==true then
            attempts=attempts+1
            if attempts<8 then UIManager:scheduleIn(.6,task) end
            return
        end
        self:_show_performance_prompt()
    end
    UIManager:scheduleIn(math.max(.25,tonumber(delay) or .9),task)
    return true
end

function Plugin:_show_performance_prompt()
    local pending=self._performance_prompt_pending
    if not pending or not self.performance_mode then return false end
    self._performance_prompt_pending=nil
    if self.performance_mode:enabled() then return false end
    if self._performance_prompt_dialog then
        pcall(UIManager.close,UIManager,self._performance_prompt_dialog)
        self._performance_prompt_dialog=nil
    end
    local dialog
    dialog=ButtonDialog:new{
        title="检测到运行较慢\n\n觅阅检测到近期多次明显操作延迟。开启轻量模式后，阅读和菜单操作会优先，后台下载、封面、书籍资料和自动更新会更保守地执行；阅读、下载和同步功能不会关闭。",
        title_align="center",
        buttons={
            {{text="开启轻量模式",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
                self:_set_performance_mode(true)
            end}},
            {{text="暂不开启",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
            end}},
            {{text="不再提醒",callback=function()
                UIManager:close(dialog); self._performance_prompt_dialog=nil
                self.performance_mode:disable_reminders()
                self:toast("已关闭性能问题提醒",2)
            end}},
        },
    }
    self._performance_prompt_dialog=dialog
    UIManager:show(dialog)
    return true
end

function Plugin:performance_settings_menu()
    local status=self.performance_mode:status()
    local memory_status=self.memory_mode:status()
    local items={
        {text="轻量模式",post_text=self:_performance_mode_label(),checked_func=function()
            return self.performance_mode:enabled()
        end,callback=function() self:_set_performance_mode(not self.performance_mode:enabled()) end},
        {text="自动检测性能问题",post_text=status.reminders_disabled and "不再提醒" or nil,
            checked_func=function() return self.performance_mode:status().auto_detect end,
            keep_menu_open=true,callback=function() self:_toggle_performance_auto_detect() end},
        {text="低内存保护",post_text=self:_memory_mode_label(),checked_func=function()
            return (self.store:preferences().memory_mode or {}).enabled==true
        end,callback=function() self:toggle_memory_mode() end},
    }
    if memory_status.enabled or memory_status.residual then
        items[#items+1]={text="恢复缓存设置",callback=function() self:restore_memory_mode() end}
    end
    items[#items+1]={text="模式说明",callback=function()
        self:info("轻量模式用于改善明显卡顿：阅读操作优先，后台下载更保守。\n\n低内存保护用于避免内存不足：会减少 KOReader 页面缓存，可能让 PDF、漫画和快速跳页稍慢。两个模式可以独立开启。")
    end}
    return items
end

function Plugin:_memory_mode_label()
    local status=self.memory_mode:status()
    if not status.available then return status.enabled and "配置异常" or "不可用" end
    if status.enabled then return status.matches and "已开启" or "配置异常" end
    if status.residual then return "外部或残留设置" end
    return "关闭"
end

function Plugin:_set_memory_mode(enabled)
    local ok,result_or_error=self.memory_mode:set_enabled(enabled)
    if not ok then
        self:info("无法修改低内存保护：\n"..tostring(result_or_error))
        return
    end
    local result=result_or_error or {}
    if enabled then
        self:info("低内存保护已开启。\n\n完整退出并重新启动 KOReader 后生效。PDF、漫画和快速跳页可能稍慢。")
    elseif result.external_change then
        self:info("低内存保护已关闭。\n\n检测到缓存设置已被其他配置修改，因此没有覆盖当前值。完整重启 KOReader 后生效。")
    else
        self:info("低内存保护已关闭，原有缓存设置已恢复。\n\n完整退出并重新启动 KOReader 后生效。")
    end
end


function Plugin:restore_memory_mode()
    local status=self.memory_mode:status()
    if not status.enabled and not status.residual then
        self:info("当前没有检测到低内存设置，无需恢复。")
        return
    end
    local text
    if status.enabled then
        text="恢复开启低内存保护前的缓存设置？\n\n恢复后需要完整重启 KOReader。卸载觅阅前建议先执行恢复。"
    else
        text="检测到外部或旧版本遗留的低内存设置。是否恢复缓存策略？\n\n无法确认它是否由觅阅写入；恢复后需要完整重启 KOReader。"
    end
    UIManager:show(ConfirmBox:new{
        text=text,ok_text="恢复",ok_callback=function()
            if status.enabled then self:_set_memory_mode(false); return end
            local ok,result_or_error=self.memory_mode:restore_detected()
            if not ok then self:info("无法恢复缓存设置：\n"..tostring(result_or_error)); return end
            local result=result_or_error or {}
            self:info(result.used_default and "低内存设置已清除，将恢复 KOReader 默认缓存策略。\n\n完整重启 KOReader 后生效。"
                or "低内存设置已恢复。\n\n完整重启 KOReader 后生效。")
        end,
    })
end

function Plugin:toggle_memory_mode()
    local status=self.memory_mode:status()
    local state=(self.store:preferences().memory_mode or {}).enabled==true
    if state then
        self:_set_memory_mode(false)
        return
    end
    if status.residual then
        self:info("检测到外部或旧版本遗留的低内存设置。请先使用“恢复缓存设置”，再由觅阅重新开启。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="低内存保护适合下载大书时容易闪退或卡死的设备。\n\n开启后会减少 KOReader 页面缓存，PDF、漫画和快速跳页可能稍慢。需要完整重启 KOReader 后生效。",
        ok_text="开启",
        ok_callback=function() self:_set_memory_mode(true) end,
    })
end

function Plugin:download_settings_menu()
    local policy=tostring(self.store:preferences().download_reader_policy or "ask")
    local policy_label=policy=="allow" and "允许后台下载" or (policy=="after_reading" and "退出阅读后下载" or "每次询问")
    local items={
        {text="阅读时下载策略",post_text=policy_label,sub_item_table_func=function() return self:download_reader_policy_menu() end},
        {text="下载网络",post_text=self:_download_network_mode_label(),sub_item_table_func=function() return self:download_network_mode_menu() end},
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提醒",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
    }
    items[#items+1]={text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end}
    items[#items+1]={text="存储清理",post_text="临时文件与失效封面",callback=function() self:show_download_cleanup_dialog() end}
    return items
end
function Plugin:mp_settings_menu()
    return {
        {text="下载文章图片",checked_func=function() return self.store:preferences().mp_images==true end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_global_cache_menu() end},
    }
end
function Plugin:account_sync_settings_menu()
    -- Keep desktop mode and plugin mode on the same settings source.  beta.7
    -- had a second desktop-only menu here, so the annotation-sync controls
    -- added in plugin_settings.lua were invisible from the desktop UI.
    return PluginSettings.account_sync(self)
end

function Plugin:more_settings_menu()
    return {
        {text="提醒与确认",sub_item_table_func=function() return self:notice_settings_menu() end},
        {text="评论数据迁移",sub_item_table_func=function() return self:book_repair_settings_menu() end},
        {text="更新设置",sub_item_table_func=function() return self:update_settings_menu() end},
        {text="关于觅阅",callback=self:safe("about",function() self:show_about() end)},
    }
end

function Plugin:_download_settings_summary()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    if state.status=="active" then return tostring(self:_download_percent(state)).."%" end
    if self:_has_download_status() then return self:_download_status_label():gsub("^后台下载%s*[·：]?%s*","") end
    if #queue>0 then return tostring(#queue).." 项等待" end
    return nil
end

function Plugin:settings_menu()
    -- "更多" is the complete MiuRead menu.  It may point to the same
    -- underlying pages as home shortcuts, but it never owns a second copy of
    -- those settings.
    local rows={
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
    }
    if self:_home_enabled() then
        rows[#rows+1]={text="首页与书架",post_text="布局 书架与快捷入口",sub_item_table_func=function() return self:display_settings_menu() end}
        rows[#rows+1]={text="阅读界面",post_text="显示与快捷控制",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end}
    end
    rows[#rows+1]={text="评论 划线与想法",post_text=self:_thought_display_label(),sub_item_table_func=function() return PluginSettings.comments(self) end}
    rows[#rows+1]={text="本地书库",post_text=(self:_home_preferences().local_auto_update==true and "自动更新" or "手动更新"),sub_item_table_func=function() return self:local_library_settings_menu() end}
    rows[#rows+1]={text="账户",post_text=self:logged_in() and "已登录" or "未登录",callback=function() self:show_account_status() end}
    rows[#rows+1]={text="阅读同步",post_text=self:_home_sync_status_label(),sub_item_table_func=function() return self:sync_settings_menu() end}
    rows[#rows+1]={text="下载管理",post_text=self:_download_menu_text(),callback=function() self:show_downloads() end}
    rows[#rows+1]={text="时间与时区",post_text=TimeZone.label((self:_time_preferences())),sub_item_table_func=function() return self:time_display_settings_menu() end}
    rows[#rows+1]={text="性能与兼容性",post_text=self:_performance_mode_label(),sub_item_table_func=function() return self:performance_settings_menu() end}
    rows[#rows+1]={text="公众号阅读",sub_item_table_func=function() return self:mp_settings_menu() end}
    rows[#rows+1]={text="更新与关于",sub_item_table_func=function() return PluginSettings.update_about(self) end}
    rows[#rows+1]={text="工具与维护",sub_item_table_func=function() return self:maintenance_menu() end}
    return rows
end

function Plugin:thought_font_settings_menu()
    local prefs=self.store:preferences().thoughts or {}
    return {
        {text="阅读评论",post_text=self:_thoughts_enabled_label(),checked_func=function() return self:_thoughts_enabled() end,keep_menu_open=true,callback=function() self:_toggle_thoughts_enabled() end},
        {text="评论字体跟随正文",checked_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font==true
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
            self.store:save_preferences(p)
            self:_refresh_thought_display(p.thoughts)
            if p.thoughts.follow_body_font then
                self:toast("评论字体将跟随正文")
            else
                self:toast("评论字体已改为固定字体")
            end
        end},
        {text="固定字体",post_text=self:_thought_font_face_label(prefs),enabled_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font~=true
        end,sub_item_table_func=function() return self:thought_font_face_menu() end},
        {text="字体大小",sub_item_table_func=function() return self:thought_font_menu() end},
    }
end

function Plugin:_thought_font_face_label(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    local name=U.trim(tostring(prefs.font_face or ""))
    return name~="" and name or "KOReader 默认"
end
function Plugin:_reader_font_face_choices()
    local choices={}
    local seen={}
    local font=self.ui and self.ui.font or nil
    if font and type(font.setupFaceMenuTable)=="function" then
        pcall(font.setupFaceMenuTable,font)
    end
    for _,item in ipairs(font and type(font.face_table)=="table" and font.face_table or {}) do
        local name=U.trim(tostring(item.menu_item_id or ""))
        if name~="" and not seen[name] then
            seen[name]=true
            local label=name
            if type(item.text_func)=="function" then
                local ok,value=pcall(item.text_func)
                if ok and U.trim(tostring(value or ""))~="" then label=tostring(value) end
            elseif U.trim(tostring(item.text or ""))~="" then
                label=tostring(item.text)
            end
            choices[#choices+1]={name=name,label=label,font_func=item.font_func}
        end
    end
    if #choices>0 then return choices end

    -- Compatibility fallback for older KOReader versions that do not expose
    -- ReaderFont.face_table. This is the same CRE font source used by KOReader.
    local ok,faces=pcall(function()
        local cre=require("document/credocument"):engineInit()
        return cre and cre.getFontFaces and cre.getFontFaces() or {}
    end)
    if ok and type(faces)=="table" then
        for _,value in ipairs(faces) do
            local name=U.trim(tostring(value or ""))
            if name~="" and not seen[name] then
                seen[name]=true
                choices[#choices+1]={name=name,label=name}
            end
        end
        table.sort(choices,function(a,b) return a.name:lower()<b.name:lower() end)
    end
    return choices
end

function Plugin:thought_font_face_menu()
    local rows={
        {text="KOReader 默认字体",radio=true,menu_item_id="__default__",checked_func=function()
            return U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))==""
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=""; p.thoughts.follow_body_font=false
            self.store:save_preferences(p)
            self:_refresh_thought_display(p.thoughts)
            self:toast("评论字体已设为 KOReader 默认字体")
        end},
    }
    local choices=self:_reader_font_face_choices()
    if #choices==0 then
        rows[#rows+1]={text="无法读取正文字体列表",enabled=false}
        return rows
    end
    for _,choice in ipairs(choices) do
        local selected=choice.name
        rows[#rows+1]={
            text=choice.label,
            font_func=choice.font_func,
            radio=true,
            menu_item_id=selected,
            checked_func=function()
                return tostring((self.store:preferences().thoughts or {}).font_face or "")==selected
            end,
            callback=function()
                local p=self.store:preferences(); p.thoughts=p.thoughts or {}
                p.thoughts.font_face=selected; p.thoughts.follow_body_font=false
                self.store:save_preferences(p)
                self:_refresh_thought_display(p.thoughts)
                self:toast("评论字体已设为："..selected)
            end,
        }
    end
    rows.max_per_page=5
    rows.open_on_menu_item_id_func=function()
        local face=U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))
        return face~="" and face or "__default__"
    end
    return rows
end
function Plugin:thought_font_menu()
    local choices={{"small","小"},{"standard","标准（默认）"},{"large","大"},{"xlarge","特大"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return tostring((self.store:preferences().thoughts or {}).font or "standard")==key end,callback=function()
            self:_set_thought_font_size(key)
        end}
    end
    return rows
end
function Plugin:_download_dir_path()
    local custom=U.trim((self.store:preferences() or {}).download_dir or "")
    if custom~="" then return custom end
    return self.store.default_books_dir
end
function Plugin:_download_dir_label()
    local path=self:_download_dir_path()
    if path==self.store.default_books_dir then return "默认 · "..tostring(path) end
    return tostring(path)
end
function Plugin:_validate_download_dir(path)
    path=U.trim(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="directory" then return nil,"文件夹不存在" end
    local probe=path.."/.miuread-write-test-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f=io.open(probe,"wb")
    if not f then return nil,"该文件夹不可写" end
    f:write("ok"); f:close(); os.remove(probe)
    return true
end
function Plugin:directory_dialog()
    local current=self:_download_dir_path()
    if lfs.attributes(current,"mode")~="directory" then
        if lfs.attributes("/mnt/us/documents","mode")=="directory" then current="/mnt/us/documents"
        elseif lfs.attributes("/mnt/us","mode")=="directory" then current="/mnt/us"
        else current="/" end
    end
    local chooser=PathChooser:new{
        title="选择下载文件夹",
        select_directory=true,
        select_file=false,
        show_files=false,
        path=current,
        onConfirm=function(path)
            local ok,err=self:_validate_download_dir(path)
            if not ok then self:info("无法使用此文件夹：\n"..tostring(err)); return end
            local old=self:_download_dir_path()
            local p=self.store:preferences(); p.download_dir=path; self.store:save_preferences(p)
            local note="下载目录已设置为：\n"..tostring(path)
            if old~=path then note=note.."\n\n只影响以后下载的书籍；已下载内容保留在原位置。" end
            self:info(note)
        end,
    }
    UIManager:show(chooser)
end

function Plugin:_update_preferences()
    local p=self.store:preferences()
    p.update=U.merge({manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,
        last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},p.update or {})
    return p,p.update
end
function Plugin:_save_update_preferences(update)
    local p=self.store:preferences(); p.update=U.merge(p.update or {},update or {})
    self:_save_ui_preferences(p,"update_preferences")
end
function Plugin:_update_interval_label(seconds)
    seconds=tonumber(seconds) or Config.AUTO_UPDATE_INTERVAL
    if seconds<=86400 then return "每天" end
    if seconds<=3*86400 then return "每 3 天" end
    return "每 7 天"
end
function Plugin:update_frequency_menu()
    local values={{86400,"每天"},{3*86400,"每 3 天"},{7*86400,"每 7 天"}}
    local rows={}
    for _,entry in ipairs(values) do
        local seconds,label=entry[1],entry[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tonumber(u.interval)==seconds
        end,callback=function()
            local _,u=self:_update_preferences(); u.interval=seconds; self:_save_update_preferences(u); self:toast("更新检查频率已设为"..label)
        end}
    end
    return rows
end
function Plugin:update_restart_menu()
    local choices={{"ask","安装后询问（推荐）"},{"auto","安装后自动重启"},{"never","稍后手动重启"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tostring(u.restart_mode)==key
        end,callback=function()
            local _,u=self:_update_preferences(); u.restart_mode=key; self:_save_update_preferences(u); self:toast("更新完成后："..label)
        end}
    end
    return rows
end
function Plugin:update_settings_menu()
    local _,update=self:_update_preferences()
    return {
        {text="自动检查更新",checked_func=function()
            local _,u=self:_update_preferences(); return u.auto_check~=false
        end,keep_menu_open=true,callback=function()
            local _,u=self:_update_preferences(); u.auto_check=u.auto_check==false; self:_save_update_preferences(u)
        end},
        {text="检查频率 · "..self:_update_interval_label(update.interval),sub_item_table_func=function() return self:update_frequency_menu() end},
        {text="安装完成后 · "..(update.restart_mode=="auto" and "自动重启" or (update.restart_mode=="never" and "稍后手动重启" or "询问是否重启")),sub_item_table_func=function() return self:update_restart_menu() end},
        {text="检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."更新",callback=self:safe("update",function() self:check_update(false) end)},
        {text="当前运行版本 · "..tostring(self.version),enabled=false},
        {text="更新通道 · "..tostring(Config.UPDATE_CHANNEL_LABEL),enabled=false},
        {text="当前版本 · AGPL-3.0-only",enabled=false},
    }
end
function Plugin:_restart_koreader(source)
    if self._koreader_restart_requested then return true end
    if (self.download_task and self.download_task:busy()) or self._download_runtime~=nil then
        self:info("当前任务尚未完成，暂不重启。\n\n请等待任务结束，或先在下载管理中取消任务。")
        return false
    end
    if #self.store:download_queue()>0 then
        self:info("当前还有一个排队任务，暂不重启。\n\n请先取消排队任务或等待它完成。")
        return false
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then
        self:info("缓存任务尚未完成，暂不重启。")
        return false
    end
    if Device and Device.isAndroid and Device:isAndroid() then
        self:info("Android 版 KOReader 无法保证由插件自动重新启动。\n\n请关闭并重新打开 KOReader。")
        return false
    end
    if Device and type(Device.canRestart)=="function" and not Device:canRestart() then
        self:info("当前设备不支持由 KOReader 自动重新启动。\n\n请关闭并重新打开 KOReader。")
        return false
    end

    self._koreader_restart_requested=true
    source=tostring(source or "manual")
    logger.info("[MiuRead][Restart] KOReader restart requested","source=",source,"expected_exit=85")

    -- Save everything before asking KOReader to restart. Do not call
    -- the native menu close helper here: on a replacement home it closes the native
    -- root first, which can empty UIManager's stack and turn the request into
    -- a normal exit (code 0) before the Restart event gets handled.
    pcall(function() self:_flush_home_preferences() end)
    pcall(function() self:onFlushSettings() end)
    if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end

    local dispatched,dispatch_error=pcall(function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
    if not dispatched then
        logger.warn("[MiuRead][Restart] Restart event failed",tostring(dispatch_error))
    end

    -- KOReader's launcher recognises exit code 85 as "restart KOReader".
    -- Keep a direct fallback because custom full-screen homes may leave no
    -- native root widget to consume the broadcast event. This never calls the
    -- device Reboot event and therefore cannot request a Kindle/Kobo reboot.
    if tonumber(UIManager._exit_code)~=85 then
        logger.info("[MiuRead][Restart] enforcing KOReader exit code 85")
        if not HOME_EXITING then self:_begin_koreader_exit("restart fallback") end
        UIManager:quit(85)
    end
    return true
end
function Plugin:_show_update_complete_dialog(version,allow_restart)
    if self._update_complete_dialog then
        pcall(function() UIManager:close(self._update_complete_dialog) end)
        self._update_complete_dialog=nil
    end
    local dialog
    local buttons={}
    if allow_restart~=false then
        buttons[#buttons+1]={{text="立即重启 KOReader",callback=function()
            -- Keep this dialog on the stack until the restart request has
            -- been accepted. It prevents an empty-stack normal exit.
            self:_restart_koreader("update-confirmed")
        end}}
    end
    buttons[#buttons+1]={{text="稍后重启",callback=function()
        UIManager:close(dialog)
        self._update_complete_dialog=nil
        self:toast("新版本将在下次启动 KOReader 时生效",3)
    end}}
    dialog=ButtonDialog:new{
        title="更新文件已安装："..tostring(version).."。\n\n当前仍在运行 "..tostring(self.version).."，重启 KOReader 后才会切换到新版本。",
        title_align="center",
        buttons=buttons,
    }
    self._update_complete_dialog=dialog
    UIManager:show(dialog)
end
function Plugin:_after_update_installed(manifest)
    local _,update=self:_update_preferences()
    local version=tostring(manifest and manifest.version or "新版本")
    logger.info("[MiuRead][Updater] presenting installed update","version=",version,"restart_mode=",tostring(update.restart_mode))
    if update.restart_mode=="never" then
        self:_show_update_complete_dialog(version,false)
    elseif update.restart_mode=="auto" then
        self:status_toast("更新完成","正在重启 KOReader",3)
        UIManager:scheduleIn(.35,function() self:_restart_koreader("update-auto") end)
    else
        self:_show_update_complete_dialog(version,true)
    end
end
function Plugin:_present_update(manifest,automatic)
    if manifest.current then
        if not automatic then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)) end
        return
    end
    local _,update=self:_update_preferences()
    if automatic and tostring(update.last_prompted_version or "")==tostring(manifest.version or "") then return end
    update.last_prompted_version=tostring(manifest.version or "")
    self:_save_update_preferences(update)
    local text="发现"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本 "..tostring(manifest.version)
    local notes=tostring(manifest.summary or "")
    if notes=="" then notes=tostring(manifest.notes or "") end
    if notes~="" then
        text=text.."\n\n更新内容\n"..notes
    end
    text=text.."\n\n是否下载并安装"
    UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
        if not self:is_online() then self:info("当前网络不可用"); return end
        if not self.updater_async or not self.updater_async:available() then
            self:info("当前环境无法在后台下载安装包，请稍后重试。")
            return
        end
        if self.updater_async:busy() then self:toast("更新任务正在进行",2); return end
        self:status_toast("更新","正在后台下载并校验安装包……",4)
        local started,err=self.updater_async:run("update-download",function()
            return self.updater:download(manifest)
        end,function(result)
            if not result or result.ok~=true or tostring(result.value or "")=="" then
                self:info("更新下载失败：\n"..tostring(result and result.error or "后台下载失败"))
                return
            end
            local path=tostring(result.value)
            self:status_toast("更新","安装包校验完成，正在安装……",4)
            UIManager:nextTick(function()
                local ok,install_err=self.updater:install(path,manifest)
                if ok then self:_after_update_installed(manifest)
                else self:info("更新失败：\n"..tostring(install_err)) end
            end)
        end,210)
        if not started then self:info("无法启动更新下载：\n"..tostring(err or "后台任务不可用")) end
    end})
end
function Plugin:_run_update_check(automatic,on_done)
    if not self.updater_async or not self.updater_async:available() then
        return false,"后台更新检查不可用"
    end
    if self.updater_async:busy() then
        return false,"已有更新任务正在运行"
    end
    local started,err=self.updater_async:run(automatic and "auto-update-check" or "update-check",function()
        local manifest,check_err=self.updater:check()
        if not manifest then error(tostring(check_err or "无法读取更新清单")) end
        return manifest
    end,function(result)
        if result and result.ok==true and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
        else
            if on_done then on_done(nil,tostring(result and result.error or "后台更新检查失败")) end
        end
    end,70)
    if not started then return false,tostring(err or "后台任务不可用") end
    return true
end

function Plugin:maybe_auto_check_update(force)
    local _,update=self:_update_preferences()
    if not force and update.auto_check==false then return false end
    if self._auto_update_check_running then return false end
    local now=os.time()
    local interval=math.max(21600,tonumber(update.interval) or Config.AUTO_UPDATE_INTERVAL)
    local last=tonumber(update.last_attempt_at) or 0
    if not force and now-last<interval then return false end
    if not self:is_online() then return false end
    if self.updater_async and self.updater_async:busy() then return false end
    self._auto_update_check_running=true
    update.last_attempt_at=now
    self:_save_update_preferences(update)
    local started,start_err=self:_run_update_check(true,function(manifest,err)
        self._auto_update_check_running=false
        local _,fresh=self:_update_preferences()
        if manifest then
            fresh.last_success_at=os.time()
            self:_save_update_preferences(fresh)
            self:_present_update(manifest,true)
        else
            logger.warn("[MiuRead][Updater] passive check failed",tostring(err))
            fresh.last_attempt_at=os.time()-math.max(0,interval-(Config.AUTO_UPDATE_RETRY_INTERVAL or 21600))
            self:_save_update_preferences(fresh)
        end
    end)
    if not started then
        self._auto_update_check_running=false
        logger.warn("[MiuRead][Updater] passive check not started",tostring(start_err or "unknown"))
    end
    return started
end
function Plugin:check_update(automatic)
    if automatic then return self:maybe_auto_check_update(true) end
    if not self:is_online() then self:info("当前网络不可用"); return false end
    if self.updater_async and self.updater_async:busy() then self:toast("更新任务正在进行",2); return false end
    self:status_toast("更新","正在后台检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本……",3)
    local started,start_err=self:_run_update_check(false,function(manifest,err)
        local _,update=self:_update_preferences()
        update.last_attempt_at=os.time()
        if manifest then update.last_success_at=os.time() end
        self:_save_update_preferences(update)
        if not manifest then self:info("检查更新失败：\n"..tostring(err)); return end
        self:_present_update(manifest,false)
    end)
    if not started then self:info("无法启动后台更新检查：\n"..tostring(start_err or "后台任务不可用")) end
    return started
end
function Plugin:show_about()
    local memory_note=""
    local memory_status=self.memory_mode:status()
    if memory_status.enabled then
        memory_note="\n\n低内存保护当前已开启。卸载觅阅前，请在“性能与兼容性”中恢复缓存设置。"
    elseif memory_status.residual then
        memory_note="\n\n检测到外部或遗留的低内存设置，可在“性能与兼容性”中检查并恢复。"
    end
    self:info(Config.NAME.." "..self.version
        .."\n\n为 KOReader 提供微信读书书架、书籍下载、阅读同步与本地书籍管理。"
        .."\n\n支持阅读进度、划线、想法、评论及阅读记录等功能。"
        .."\n\n许可证：AGPL-3.0-only。"
        ..memory_note
        .."\n\n非官方社区项目，与微信读书及 KOReader 无官方隶属或合作关系。")
end
function Plugin:onExit()
    self:_cancel_interactive_network("exit")
    self:_close_stream_session()
    if not HOME_EXITING then self:_begin_koreader_exit("external exit") end
    return false
end
function Plugin:onRestart()
    if not HOME_EXITING then self:_begin_koreader_exit("external restart") end
    return false
end
function Plugin:onShowMiuRead()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
end
function Plugin:onMiuReadReturnHome()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
    return true
end
function Plugin:onToggleMiuReadProgressSync()
    if self:require_login() then self:toggle_progress_sync() end
    return true
end
function Plugin:onToggleMiuReadTimeSync()
    self:toggle_time_sync()
    return true
end
function Plugin:onShowMiuReadDownloads()
    self:show_downloads()
    return true
end
function Plugin:onShowMiuReadSyncStatus()
    self:show_sync_status(false)
    return true
end
function Plugin:onMiuReadQRLogin()
    if self:logged_in() then self:show_account_status() else self.auth_flow:start() end
    return true
end
function Plugin:onMiuReadLogout()
    self:confirm_logout()
    return true
end
function Plugin:onMiuReadReaderPanel()
    self:show_reader_quick_panel()
    return true
end
function Plugin:onMiuReadReaderFont()
    self:_show_reader_font_panel()
    return true
end
function Plugin:onMiuReadReaderTypeset()
    self:_show_reader_advanced_typeset_panel()
    return true
end
function Plugin:onMiuReadReaderProgress()
    self:_show_reader_progress_control()
    return true
end
function Plugin:onMiuReadUploadProgress()
    self:upload_local_progress(true)
    return true
end
function Plugin:onMiuReadPullProgress()
    self:manual_sync()
    return true
end
function Plugin:onMiuReadCurrentBook()
    self:_show_reader_current_book_panel()
    return true
end
function Plugin:onMiuReadCloseBook()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    local ReaderUI=require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        local readerui=ReaderUI.instance
        local file=readerui.document.file
        UIManager:nextTick(function()
            readerui:onClose()
            if file then readerui:showFileManager(file) end
        end)
    end
    return true
end
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"miuread_thought_href","xpointer","marker_xpointer","a_xpointer","href","url","target","link","uri","dest","destination"}) do
        local found=extract_thought_href(value[key],seen,depth+1); if found then return found end
    end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end

local function thought_href_from_html(html)
    html=tostring(html or "")
    if html=="" then return nil end
    local href=html:match('href="(#miuthought%-[%x%.]+)"')
        or html:match("href='(#miuthought%-[%x%.]+)'")
        or html:match('href="(miuthought%-[%x%.]+)"')
        or html:match("href='(miuthought%-[%x%.]+)'")
    if href then
        if href:sub(1,1)~="#" then href="#"..href end
        return href
    end
    local anchor=html:match('id="(miuthought%-[%x%.]+)"') or html:match("id='(miuthought%-[%x%.]+)'")
    if anchor then return "#"..anchor end
    return nil
end

local function thought_range_from_html(html)
    html=tostring(html or "")
    if html=="" then return nil end
    return html:match('data%-miu%-range="([^"]+)"') or html:match("data%-miu%-range='([^']+)'")
end

local function html_is_thought_target(html)
    html=tostring(html or "")
    if html=="" then return false end
    if html:find("miu-thought-link", 1, true) then return true end
    if html:find("miu-thought-mark", 1, true) then return true end
    if html:find("miuthought%-", 1, true) then return true end
    return false
end

function Plugin:_reader_thought_context()
    local stream=STREAM_SESSION.reader
    if stream and stream.active==true and stream.book then
        local book_id=tostring(stream.book.bookId or stream.book.book_id or "")
        local chapter_uid=tostring(stream.current_uid or "")
        if chapter_uid=="" and type(stream.current_chapter)=="table" then
            chapter_uid=tostring(stream.current_chapter.chapterUid or stream.current_chapter.uid or "")
        end
        if book_id~="" and chapter_uid~="" then return book_id,chapter_uid end
    end
    local path=self:_current_document_path()
    if not path then return "","" end
    local identity=self.store:epub_identity_light(path) or {}
    local book_id=tostring(identity.book_id or "")
    local chapter_uid=tostring(identity.chapter_uid or "")
    if book_id~="" and chapter_uid~="" then return book_id,chapter_uid end
    local book,record=self.store:identify_file(path,false)
    return tostring(book and (book.book_id or book.bookId) or ""),
        tostring(record and record.chapter_uid or "")
end

function Plugin:_thought_html_at_xpointer(xpointer)
    local doc=self.ui and self.ui.document
    xpointer=tostring(xpointer or "")
    if not doc or xpointer=="" or type(doc.getHTMLFromXPointer)~="function" then return nil end
    for _,from_parent in ipairs({true,false}) do
        local ok,html=pcall(doc.getHTMLFromXPointer,doc,xpointer,0x1001,from_parent)
        if ok and type(html)=="string" and html~="" then return html end
    end
    return nil
end

function Plugin:_thought_info_from_html(html)
    html=tostring(html or "")
    if html=="" or not html_is_thought_target(html) then return nil end
    local href=thought_href_from_html(html)
    local info=href and Thoughts.parse_href(href) or nil
    if info then return info end
    local range_key=thought_range_from_html(html)
    if not range_key then return nil end
    local book_id,chapter_uid=self:_reader_thought_context()
    if book_id=="" or chapter_uid=="" then return nil end
    return {book_id=book_id,chapter_uid=chapter_uid,range=range_key,
        anchor=Thoughts.anchor(book_id,chapter_uid,range_key)}
end

function Plugin:_lookup_thought_group(info)
    info=type(info)=="table" and info or nil
    if not info then return nil,"无效的想法定位",nil end
    local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
    if group then return group,err,token end

    local stream=STREAM_SESSION.reader
    local annotation=stream and stream.active==true and stream.last_annotation or nil
    if type(annotation)~="table" then return nil,err,token end
    if tostring(annotation.book_id or "")~=tostring(info.book_id or "") then return nil,err,token end
    local ann_uid=tostring(annotation.chapter_uid or "")
    local info_uid=tostring(info.chapter_uid or "")
    if ann_uid=="" or info_uid=="" then return nil,err,token end
    if U.id_name(ann_uid)~=U.id_name(info_uid) then return nil,err,token end

    local range_key=tostring(info.range or "")
    if range_key=="" then return nil,err,token end
    for _,item in ipairs(annotation.review_groups or {}) do
        if type(item)=="table" and tostring(item.range or "")==range_key and #(item.texts or {})>0 then
            return item,nil,{stream_cache=true,index_hit=true,cache_hit=true}
        end
    end
    local texts=annotation.review_map and annotation.review_map[range_key]
    if type(texts)=="table" and #texts>0 then
        return {range=range_key,texts=texts},nil,{stream_cache=true,index_hit=true,cache_hit=true}
    end
    local rows=select(1,Thoughts.load(self.store,info.book_id,info.chapter_uid))
    if type(rows)=="table" then
        for _,group in ipairs(rows) do
            if type(group)=="table" and tostring(group.range or "")==range_key and #(group.texts or {})>0 then
                return group,nil,{chapter_cache=true,index_hit=true,cache_hit=true}
            end
        end
    end
    return nil,err,token
end

function Plugin:_thought_info_from_link(link)
    link=type(link)=="table" and link or nil
    if not link then return nil end
    local href=extract_thought_href(link,{},0)
    local info=href and Thoughts.parse_href(href) or nil
    if info then return info end
    for _,xp in ipairs({link.a_xpointer,link.xpointer,link.marker_xpointer,link.from_xpointer}) do
        info=self:_thought_info_from_html(self:_thought_html_at_xpointer(xp))
        if info then return info end
    end
    return nil
end

function Plugin:_resolve_thought_from_ges(ges)
    local ui=self.ui
    local doc=ui and ui.document
    if not doc or not ges or not ges.pos then return nil end

    if ui.link and type(ui.link.getLinkFromGes)=="function" then
        local ok,link=pcall(ui.link.getLinkFromGes,ui.link,ges)
        if ok and link then
            local info=self:_thought_info_from_link(link)
            if info then return info end
        end
    end

    if type(doc.getLinkFromPosition)=="function" then
        local ok,link_xpointer,a_xpointer=pcall(doc.getLinkFromPosition,doc,ges.pos)
        if ok then
            local info=self:_thought_info_from_link({
                xpointer=tostring(link_xpointer or ""),
                a_xpointer=a_xpointer,
                marker_xpointer=tostring(link_xpointer or ""),
            })
            if info then return info end
        end
    end

    local xpointers={}
    local function remember(xpointer)
        xpointer=tostring(xpointer or "")
        if xpointer=="" then return end
        for _,existing in ipairs(xpointers) do
            if existing==xpointer then return end
        end
        xpointers[#xpointers+1]=xpointer
    end
    if type(doc.getTextFromPositions)=="function" then
        local ok,range=pcall(doc.getTextFromPositions,doc,ges.pos.x,ges.pos.y,ges.pos.x,ges.pos.y,false,false)
        if ok and type(range)=="table" then
            remember(range.pos0)
            remember(range.pos1)
        end
    end
    if type(doc.getWordFromPosition)=="function" then
        local ok,word=pcall(doc.getWordFromPosition,doc,ges.pos,true)
        if ok and type(word)=="table" then
            remember(word.pos0)
            remember(word.pos1)
        end
    end
    for _,xpointer in ipairs(xpointers) do
        local info=self:_thought_info_from_html(self:_thought_html_at_xpointer(xpointer))
        if info then return info end
    end
    return nil
end

function Plugin:_show_thought_info(info)
    info=type(info)=="table" and info or nil
    if not info then return false end
    local anchor=tostring(info.anchor or "")
    if anchor=="" and info.book_id and info.chapter_uid and info.range then
        anchor=Thoughts.anchor(info.book_id,info.chapter_uid,info.range)
    end
    if anchor=="" then return false end
    return self:_show_thought_href("#"..anchor)
end
function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then
        pcall(function()
            self.ui:unRegisterTouchZones({{
                id="miuread_thought_popup",
                overrides={"tap_link"},
            }})
        end)
    end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    -- These are final KOReader font-size values, matching the scale used by
    -- document text. Each level is scaled exactly once for the current device;
    -- no hidden ratio or legacy level conversion is applied afterwards.
    local nominal={small=18,standard=22,large=26,xlarge=30}
    local value=nominal[tostring(level or "standard")] or nominal.standard
    return math.max(value,Device.screen:scaleBySize(value))
end
local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end
function Plugin:_thought_font_name(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    if prefs.follow_body_font~=true then
        return usable_font_name(prefs.font_face)
    end
    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end

    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end

    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok then return usable_font_name(value) end
    end
    return nil
end
function Plugin:_write_thought_popup_marker(stage, info, extra)
    local path=tostring(self._thought_popup_marker_path or "")
    if path=="" then return false end
    local payload={
        version=tostring(self.version or Config.VERSION),
        stage=tostring(stage or "unknown"),
        timestamp=os.time(),
        book_id=info and tostring(info.book_id or "") or nil,
        chapter_uid=info and tostring(info.chapter_uid or "") or nil,
        range=info and tostring(info.range or "") or nil,
    }
    for key,value in pairs(type(extra)=="table" and extra or {}) do payload[key]=value end
    local ok,encoded=pcall(Json.encode,payload)
    if not ok then return false end
    return U.atomic_write(path,encoded,true)==true
end

function Plugin:_clear_thought_popup_marker()
    local path=tostring(self._thought_popup_marker_path or "")
    if path~="" then os.remove(path) end
end

function Plugin:_flush_reader_checkpoint(reason, force)
    if not (self.ui and self.ui.document) then return false end
    -- KOReader already saves the current reading position during its own
    -- suspend/close lifecycle. MiuRead only needs an additional full settings
    -- flush when annotations or document settings actually changed. Avoiding a
    -- redundant save removes the most visible lock/close pause.
    if self._reader_checkpoint_dirty~=true and force~=true then
        logger.dbg("[MiuRead][ReaderCheckpoint] clean; extra save skipped","reason=",tostring(reason or "unspecified"))
        return true
    end
    local now=os.time()
    if force~=true and now-(tonumber(self._reader_checkpoint_last) or 0)<1 then return true end
    local ok,err=xpcall(function()
        if type(self.ui.saveSettings)=="function" then
            self.ui:saveSettings()
        elseif type(self.ui.handleEvent)=="function" then
            self.ui:handleEvent(Event:new("SaveSettings"))
            if self.ui.doc_settings and type(self.ui.doc_settings.flush)=="function" then
                self.ui.doc_settings:flush()
            end
        end
    end,debug.traceback)
    if ok then
        self._reader_checkpoint_last=now
        self._reader_checkpoint_dirty=false
        logger.info("[MiuRead][ReaderCheckpoint] saved","reason=",tostring(reason or "unspecified"))
        return true
    end
    logger.warn("[MiuRead][ReaderCheckpoint] save failed","reason=",tostring(reason or "unspecified"),tostring(err))
    return false
end

function Plugin:_schedule_reader_checkpoint(reason, delay)
    if not (self.ui and self.ui.document) then return false end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    local task
    task=function()
        if self._reader_checkpoint_task~=task then return end
        self._reader_checkpoint_task=nil
        self:_flush_reader_checkpoint(reason,false)
    end
    self._reader_checkpoint_task=task
    UIManager:scheduleIn(math.max(.2,tonumber(delay) or 2.0),task)
    return true
end

function Plugin:_finish_thought_popup(generation)
    if generation and generation~=self._thought_popup_generation then return end
    self._thought_popup=nil
    self._thought_popup_busy=false
    self:_clear_thought_popup_marker()
    if self.download_task then self.download_task:resume("thought_popup") end
    self:_mark_reader_busy(2)
    if self._performance_prompt_pending then
        UIManager:scheduleIn(.45,function() self:_show_performance_prompt() end)
    end
    UIManager:scheduleIn(1.2,function() collectgarbage("step",48) end)
end

function Plugin:_close_active_thought_popup(reason)
    local popup=self._thought_popup
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    self._thought_popup=nil
    self._thought_popup_busy=false
    self:_clear_thought_popup_marker()
    if self.download_task then self.download_task:resume("thought_popup") end
    if popup and popup~=true then
        pcall(UIManager.close,UIManager,popup)
        logger.info("[MiuRead][ThoughtPopup] closed","reason=",tostring(reason or "forced"))
    end
end

function Plugin:_open_thought_info(info,generation)
    if generation~=self._thought_popup_generation or not (self.ui and self.ui.document) then
        self:_finish_thought_popup(generation)
        return
    end
    local started=monotonic_wall_time()
    local popup,notice
    local ok,unexpected=xpcall(function()
        -- The tap marker already proves a popup was active if KOReader exits
        -- abnormally. Keep intermediate stages in the log instead of rewriting
        -- the same flash file several times during one visible tap.
        local lookup_started=monotonic_wall_time()
        local group,err,token=self:_lookup_thought_group(info)
        local lookup_ms=math.floor((monotonic_wall_time()-lookup_started)*1000+.5)
        if not group then notice=tostring(err or "没有想法内容"); return end
        local prefs=self.store:preferences().thoughts or {}
        local function on_close() self:_finish_thought_popup(generation) end
        local parts_started=monotonic_wall_time()
        local source,comments,count,native_cache_hit,native_signature=Thoughts.native_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        local parts_ms=math.floor((monotonic_wall_time()-parts_started)*1000+.5)
        if tostring(source or "")=="" and #(comments or {})==0 then notice="没有想法内容"; return end
        local show_started=monotonic_wall_time()
        popup=ThoughtNativePopup.show{
            source_text=source,
            comments=comments,
            cache_key=table.concat({
                tostring(info.book_id or ""), tostring(info.chapter_uid or ""),
                tostring(info.range or ""), tostring(native_signature or ""),
            }, "|"),
            font_size=self:_thought_font_size(prefs.font),
            font_name=self:_thought_font_name(prefs),
            width_ratio=tonumber(prefs.width_ratio) or 0.91,
            height_ratio=tonumber(prefs.height_ratio) or 0.55,
            on_close=on_close,
            on_interact=function() self:_mark_reader_busy(30) end,
            on_error=function()
                self:info("评论显示失败，窗口已安全关闭。当前阅读位置不会丢失。")
            end,
        }
        local show_ms=math.floor((monotonic_wall_time()-show_started)*1000+.5)
        local elapsed_ms=math.floor((monotonic_wall_time()-started)*1000+.5)
        logger.info("[MiuRead][ThoughtPopup] opened",
            "mode=","native_rounded_paged_swipe",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(count or 0),
            "source=",token and token.index_hit and "compact_index" or "chapter_cache",
            "cache=",token and token.cache_hit and "hit" or "miss",
            "native_cache=",native_cache_hit and "hit" or "miss",
            "lookup_ms=",tostring(lookup_ms),
            "parts_ms=",tostring(parts_ms),
            "show_ms=",tostring(show_ms),
            "elapsed_ms=",tostring(elapsed_ms))
        if not popup then error("评论窗口未能加入界面") end
        self._thought_popup=popup
        self:_record_performance("thought_popup",elapsed_ms)
        if token and token.index_hit~=true then
            UIManager:scheduleIn(.2,function() self:_schedule_current_book_repair_check(nil,true) end)
        end
    end,debug.traceback)
    if not ok then
        logger.err("[MiuRead][ThoughtPopup] open failed",tostring(unexpected))
        self:_finish_thought_popup(generation)
        self:info("评论暂时无法显示。当前阅读批注已先保存，请稍后重试。")
    elseif not popup then
        self:_finish_thought_popup(generation)
        if notice then self:info(notice) end
    end
end

function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href)
    if not info then
        logger.warn("[MiuRead][ThoughtPopup] invalid href", U.first_line(href, 120))
        return false
    end
    -- A disabled comment layer still owns its internal links. Consume them
    -- silently instead of letting KOReader report #miuthought as invalid.
    if not self:_thoughts_enabled() then return true end
    if self._thought_popup_busy or self._thought_popup then return true end
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() and runtime.comment_slow_notice~=true then
        runtime.comment_slow_notice=true
        self:status_toast("后台正在下载","评论打开和翻页可能稍慢",3)
    end
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    local generation=self._thought_popup_generation
    self._thought_popup_busy=true
    self:_write_thought_popup_marker("tap",info)
    if self.download_task then self.download_task:pause("thought_popup") end
    self:_mark_reader_busy(30)
    -- Only write document metadata here when annotations really changed.
    -- Repeatedly opening comments must not force a storage flush every time.
    if self._reader_checkpoint_dirty and os.time()-(tonumber(self._reader_checkpoint_last) or 0)>=5 then
        self:_flush_reader_checkpoint("before_thought_popup",false)
    end
    UIManager:nextTick(function()
        self:_open_thought_info(info,generation)
    end)
    return true
end

function Plugin:_thought_edge_page_turn(ges)
    local enabled,percent=self:_reader_edge_guard_state()
    if not enabled then return false end
    local pos=ges and ges.pos
    local x=pos and tonumber(pos.x)
    local width=Device.screen and Device.screen:getWidth()
    if not x or not width or width<=0 then return false end

    local ratio=math.max(.05,math.min(.20,(tonumber(percent) or 10)/100))
    local inverse=self.ui and self.ui.view and self.ui.view.inverse_reading_order==true
    local diff
    if x<=width*ratio then
        diff=inverse and 1 or -1
    elseif x>=width*(1-ratio) then
        diff=inverse and -1 or 1
    else
        return false
    end

    -- Keep KOReader's own tap-turn preference authoritative. The guard only
    -- resolves a collision between an edge annotation link and a page turn.
    if _G.G_reader_settings and type(G_reader_settings.nilOrFalse)=="function"
        and not G_reader_settings:nilOrFalse("page_turns_disable_tap") then
        return false
    end
    if not self.ui or type(self.ui.handleEvent)~="function" then return false end

    local ok,handled=pcall(self.ui.handleEvent,self.ui,Event:new("GotoViewRel",diff))
    if not ok or handled~=true then return false end
    self:_mark_reader_busy(2)
    logger.dbg("[MiuRead][ThoughtPopup] edge annotation tap converted to page turn",
        "percent=",tostring(percent),"direction=",diff<0 and "backward" or "forward")
    return true
end

function Plugin:_on_thought_tap(ges)
    local info=self:_resolve_thought_from_ges(ges)
    if not info then return false end
    if self:_thought_edge_page_turn(ges) then return true end
    logger.info("[MiuRead][ThoughtPopup] tap",
        "book=",tostring(info.book_id or ""),"chapter=",tostring(info.chapter_uid or ""),
        "range=",U.first_line(tostring(info.range or ""),80))
    return self:_show_thought_info(info)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup then return true end
    if not self.ui or not self.ui.registerTouchZones then
        logger.warn("[MiuRead][ThoughtPopup] tap setup skipped",
            "ui=",tostring(self.ui~=nil),
            "registerTouchZones=",tostring(self.ui and self.ui.registerTouchZones~=nil))
        return false
    end
    local owner=self
    self.ui:registerTouchZones({{
        id="miuread_thought_popup",ges="tap",
        screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
        overrides={"tap_link"},
        handler=function(ges) return owner:_on_thought_tap(ges) end,
    }})
    self._thought_tap_setup=true
    self:_install_thought_link_guard()
    logger.info("[MiuRead][ThoughtPopup] tap zone registered")
    return true
end

function Plugin:_record_recent_read(path,book,record)
    path=normalized_reader_file(path) or tostring(path or "")
    local book_id=tostring((book and (book.book_id or book.bookId))
        or (record and (record.book_id or record.bookId)) or "")
    if path=="" and book_id=="" then return false end
    local stamp=os.time()
    if self.store.record_recent_read then
        self.store:record_recent_read(book_id,path,stamp)
    elseif book_id~="" then
        self.store:mark_last_read(book_id,path,nil,false,stamp)
    end
    self:_home_share_recent_read(book_id,path,stamp)
    self._home_recent_read_dirty=true
    HOME_SESSION.recent_read_dirty=true
    local owner=home_owner()
    if owner and owner~=self then
        -- Keep the parked Home instance's in-memory view current too. These are
        -- deferred settings writes; no synchronous disk I/O is added to
        -- ReaderReady or the page-turn path.
        if owner.store and owner.store.record_recent_read then
            owner.store:record_recent_read(book_id,path,stamp)
        elseif owner.store and book_id~="" then
            owner.store:mark_last_read(book_id,path,nil,false,stamp)
        end
        owner._home_recent_read_dirty=true
    end
    logger.info("[MiuRead][Recent] reader recorded",
        "book=",book_id~="" and book_id or "local","file=",tostring(path),
        "shared=true")
    return true
end

function Plugin:on_sync_record_ready(current)
    self:_teardown_thought_tap()
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        local record=current.record or {}
        local variant=tostring(current.variant or record.variant or "")
        local stream_session=STREAM_SESSION.reader and STREAM_SESSION.reader.active==true
        if stream_session or self:_stream_active()
            or record.annotation_requested==true or variant:find("notes",1,true) then
            self:_setup_thought_tap()
            self:_install_thought_link_guard()
        end
        -- ReaderReady already records the file immediately in LuaSettings
        -- memory. Once Sync resolves the canonical book id, backfill that id
        -- without a synchronous disk flush or another delayed timer.
        self:_record_recent_read(path,current.book,current.record)
        self:_schedule_current_book_repair_check(current,false)
    end
    if self.store:preferences().sync.progress_enabled~=false then
        self:_wait_for_network("reader-ready-progress",function(ready)
            if ready and self.ui and self.ui.document then
                self:ensure_read_report_progress("reader_ready",true)
            elseif self.ui and self.ui.document then
                self:_save_progress_state(tostring(current.book.book_id),"waiting_network",
                    "等待 Wi-Fi 恢复后读取云端位置",nil,nil)
            end
        end,{minimum_delay=4.0,max_wait=60,interval=2.5})
    end
end
function Plugin:on_sync_record_missing()
    logger.dbg("[MiuRead][Sync] external EPUB ignored")
end
function Plugin:_reader_rebuild_cancel(reason,clear_shared)
    local owner=READER_REBUILD.owner
    if owner and owner._reader_rebuild_task then
        pcall(UIManager.unschedule,UIManager,owner._reader_rebuild_task)
        owner._reader_rebuild_task=nil
    end
    if self._reader_rebuild_task then
        UIManager:unschedule(self._reader_rebuild_task)
        self._reader_rebuild_task=nil
    end
    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    if clear_shared~=false then
        READER_REBUILD.state="idle"
        READER_REBUILD.session_generation=0
        READER_REBUILD.reader_file=nil
        READER_REBUILD.started_at=0
        READER_REBUILD.started_clock=0
        READER_REBUILD.max_wait=0
        READER_REBUILD.reason=nil
        READER_REBUILD.owner=nil
        READER_REBUILD.pending_width=nil
        READER_REBUILD.pending_height=nil
        READER_REBUILD.pending_rotation=nil
    end
    if reason then logger.info("[MiuRead][Lifecycle] rebuild watcher cancelled",tostring(reason)) end
    return true
end

function Plugin:_prepare_reader_disappearance(reason)
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint(reason or "reader_disappeared",true)
    end
    self:_mark_reader_busy(4)
    self:_close_active_thought_popup(reason or "reader disappeared")
    if ThoughtNativePopup and type(ThoughtNativePopup.cleanup)=="function" then
        pcall(ThoughtNativePopup.cleanup)
    end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    self:_cancel_network_waits()
    self:_cancel_interactive_network(reason or "reader disappeared")
    if self.repair_async and self.repair_async.job and self.repair_async.job.label=="book-migration-check" then
        self.repair_async:cancel(reason or "reader disappeared")
        if self.annotation_async then self.annotation_async:cancel(reason or "reader disappeared") end
    end
    self._repair_prompt_open=false
    self:_teardown_thought_tap()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    return true
end

function Plugin:_finalize_reader_instance_close(closing_path,session_generation,options)
    options=type(options)=="table" and options or {}
    local explicit_return=options.explicit_return==true
    local document_switch=options.document_switch==true
    closing_path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(HOME_READER_FILE)
    session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0

    self:_prepare_reader_disappearance(options.reason or "document closed")
    if self.sync then self.sync:on_close() end

    -- A confirmed switch has a new ReaderUI already alive. Never clear shared
    -- reader markers or start Home/post-reader work from the old plugin instance.
    if document_switch then
        logger.info("[MiuRead][Lifecycle] previous reader finalized after document switch",
            "book=",tostring(closing_path or ""),"session=",tostring(session_generation))
        return true
    end

    if self._reader_active_path then os.remove(self._reader_active_path) end
    if self._reader_busy_path then
        local busy_path=self._reader_busy_path
        UIManager:scheduleIn(4,function() os.remove(busy_path) end)
    end
    self:_schedule_post_reader_work("document closed",1.4)
    sync_home_session()
    HOME_SESSION.reader_session_active=false

    if explicit_return then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end

    if self:_home_enabled() and HOME_READER_ORIGIN and not HOME_SESSION_SUPPRESSED
        and not HOME_NATIVE_VISIT and not HOME_EXITING then
        self:_set_foreground("reader_transition")
        if explicit_return then
            READER_CLOSE.close_event_received=true
            if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
            self._miuread_return_requested=false
            logger.info("[MiuRead][ReaderClose] CloseDocument received",
                "generation=",tostring(READER_CLOSE.generation))
            self:_schedule_reader_return_finish(READER_CLOSE.generation,.10,"explicit close document")
        else
            self:_schedule_reader_close_settle(closing_path,session_generation,"confirmed document close")
        end
    else
        self:_set_foreground("native")
        UIManager:scheduleIn(.12,function()
            if self:_reader_lifecycle_state()~="closed" then return end
            if self:_filemanager_instance() or self:_ensure_filemanager_base(closing_path) then
                if ReaderTransitionGuard.is_shown() then
                    self:_release_reader_transition_guard("native surface restored")
                end
                UIManager:setDirty(nil,"ui")
                self:_finish_page_transition(.8,"native surface restored")
            else
                self:_finish_page_transition(0,"native restore failed")
                self:_show_reader_recovery_surface("KOReader 文件管理器未能恢复")
            end
        end)
    end
    return true
end

function Plugin:_finish_reader_rebuild_candidate(generation,reason)
    if generation~=(tonumber(READER_REBUILD.generation) or 0)
        or not reader_rebuild_active() then return false end
    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        READER_REBUILD.state="suspended_pending"
        self._reader_rebuild_task=nil
        return false
    end
    local active=self:_active_reader_ui()
    if active and active.document then
        local current=normalized_reader_file(self:_reader_file(active))
        local expected=normalized_reader_file(READER_REBUILD.reader_file)
        if current and expected and current==expected then
            local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
            logger.info("[MiuRead][Lifecycle] reader rebuild completed",
                "same_book=true","session=",tostring(READER_REBUILD.session_generation or 0),
                "ms=",tostring(math.max(0,elapsed)))
            self:_reader_rebuild_cancel("same reader returned",true)
            return true
        end
        local old_owner=READER_REBUILD.owner
        local old_path=READER_REBUILD.reader_file
        local old_session=READER_REBUILD.session_generation
        self:_reader_rebuild_cancel("different reader returned",true)
        if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
            pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
                {document_switch=true,reason="reader switched during rebuild candidate"})
        end
        return true
    end

    local elapsed=math.max(0,monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))
    if elapsed<(tonumber(READER_REBUILD.max_wait) or 2.4) then
        local task
        task=function()
            if self._reader_rebuild_task~=task then return end
            self._reader_rebuild_task=nil
            self:_finish_reader_rebuild_candidate(generation,reason)
        end
        self._reader_rebuild_task=task
        UIManager:scheduleIn(elapsed<1.0 and .18 or .28,task)
        return false
    end

    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("candidate confirmed closed",true)
    logger.info("[MiuRead][Lifecycle] rebuild candidate became real close",
        "book=",tostring(old_path or ""),"wait_ms=",tostring(math.floor(elapsed*1000+.5)))
    return self:_finalize_reader_instance_close(old_path,old_session,
        {reason=reason or "rebuild candidate timeout"})
end

function Plugin:_start_reader_rebuild_candidate(closing_path,session_generation,reason)
    self:_reader_rebuild_cancel(nil,true)
    local now=monotonic_wall_time()
    local path=normalized_reader_file(closing_path)
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(HOME_READER_FILE)
    if path and READER_REBUILD.recent_book==path and now-(tonumber(READER_REBUILD.recent_started_at) or 0)<=10 then
        READER_REBUILD.recent_count=(tonumber(READER_REBUILD.recent_count) or 0)+1
    else
        READER_REBUILD.recent_book=path
        READER_REBUILD.recent_count=1
    end
    READER_REBUILD.recent_started_at=now
    if READER_REBUILD.recent_count>=3 then READER_REBUILD.safe_until=now+15 end

    READER_REBUILD.generation=(tonumber(READER_REBUILD.generation) or 0)+1
    local generation=READER_REBUILD.generation
    READER_REBUILD.state="pending"
    READER_REBUILD.session_generation=tonumber(session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
    READER_REBUILD.reader_file=path
    READER_REBUILD.started_at=os.time()
    READER_REBUILD.started_clock=now
    READER_REBUILD.reason=tostring(reason or "CloseDocument without explicit return")
    READER_REBUILD.owner=self

    local recent_dimension=now-(tonumber(HOME_SESSION.last_dimension_event_clock) or 0)<=5
    local recent_resume=now-(tonumber(HOME_SESSION.last_resume_clock) or 0)<=8
    local fuse=(tonumber(READER_REBUILD.safe_until) or 0)>now
    READER_REBUILD.max_wait=fuse and 5.5 or ((recent_dimension or recent_resume) and 4.2 or 2.4)
    self:_set_foreground("reader")
    logger.info("[MiuRead][Lifecycle] rebuild candidate",
        "book=",tostring(path or ""),"session=",tostring(READER_REBUILD.session_generation),
        "recent_dimensions=",tostring(recent_dimension),"recent_resume=",tostring(recent_resume),
        "fuse=",tostring(fuse),"deadline_ms=",tostring(math.floor(READER_REBUILD.max_wait*1000+.5)))

    local task
    task=function()
        if self._reader_rebuild_task~=task then return end
        self._reader_rebuild_task=nil
        self:_finish_reader_rebuild_candidate(generation,READER_REBUILD.reason)
    end
    self._reader_rebuild_task=task
    UIManager:scheduleIn(.22,task)
    return true
end

function Plugin:_reader_rebuild_ready_state()
    if not reader_rebuild_active() then return false,false end
    local ready_path=normalized_reader_file(self:_current_document_path())
    local expected=normalized_reader_file(READER_REBUILD.reader_file)
    if ready_path and expected and ready_path==expected then
        local preserved_session=tonumber(READER_REBUILD.session_generation) or tonumber(HOME_SESSION.reader_session_generation) or 0
        local elapsed=math.floor((monotonic_wall_time()-(tonumber(READER_REBUILD.started_clock) or monotonic_wall_time()))*1000+.5)
        self:_reader_rebuild_cancel("ReaderReady same book",true)
        HOME_SESSION.reader_session_generation=preserved_session
        HOME_SESSION.reader_session_active=true
        HOME_SESSION.reader_session_file=ready_path
        logger.info("[MiuRead][Lifecycle] reader returned",
            "same_book=true","preserved_session=",tostring(preserved_session),
            "ms=",tostring(math.max(0,elapsed)))
        return true,true
    end
    local old_owner=READER_REBUILD.owner
    local old_path=READER_REBUILD.reader_file
    local old_session=READER_REBUILD.session_generation
    self:_reader_rebuild_cancel("ReaderReady different book",true)
    if old_owner and type(old_owner._finalize_reader_instance_close)=="function" then
        pcall(old_owner._finalize_reader_instance_close,old_owner,old_path,old_session,
            {document_switch=true,reason="different ReaderReady"})
    end
    logger.info("[MiuRead][Lifecycle] reader returned","same_book=false",
        "old=",tostring(old_path or ""),"new=",tostring(ready_path or ""))
    return true,false
end

function Plugin:onReaderReady()
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self:_teardown_thought_tap()

    local ready_path=normalized_reader_file(self:_current_document_path())
    -- If the same Reader unexpectedly reappears while an explicit Home return
    -- is already in progress, do not cancel that user request. Close the
    -- transiently recreated Reader again and keep the existing close watchdog.
    if reader_close_active() and HOME_SESSION.return_requested==true
        and ready_path and normalized_reader_file(READER_CLOSE.reader_file)==ready_path then
        logger.warn("[MiuRead][Lifecycle] reader reappeared during explicit return",
            "generation=",tostring(READER_CLOSE.generation),"book=",tostring(ready_path))
        READER_CLOSE.state="reader_closing"
        READER_CLOSE.close_event_received=false
        self:_set_foreground("reader_transition")
        self:_ensure_reader_transition_guard("reader reappeared during explicit return")
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.08,"reader reappeared")
        UIManager:nextTick(function()
            if reader_close_active() and HOME_SESSION.return_requested==true then
                self:_request_reader_close(READER_CLOSE.generation,"reappeared during explicit return")
            end
        end)
        return
    end

    local had_candidate,preserve_session=self:_reader_rebuild_ready_state()
    self:_cancel_reader_close_settle("reader ready")
    if READER_CLOSE.state~="idle" then
        self:_clear_reader_return(READER_CLOSE.generation,"reader ready cancelled stale return")
        self:_finish_page_transition(1.0,"reader ready")
    elseif not preserve_session then
        HOME_SESSION.return_requested=false
        HOME_SESSION.return_session_generation=0
        HOME_SESSION.return_request_file=nil
    end
    if not preserve_session then
        HOME_SESSION.reader_session_generation=(tonumber(HOME_SESSION.reader_session_generation) or 0)+1
    end
    HOME_SESSION.reader_session_active=true
    HOME_SESSION.reader_session_file=ready_path
    self._reader_session_generation=HOME_SESSION.reader_session_generation
    local ready_session=self._reader_session_generation
    self._home_reader_transition=false
    self:_close_reader_recovery_surface()
    self:_close_home_for_reader("reader ready")
    self:_ensure_reader_transition_guard("reader ready")
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    -- Give EPUB opening and the first visible page priority over background
    -- work, but do not keep cloud/state workers blocked for a fixed eight
    -- seconds. Three seconds is enough to protect the first interactions; the
    -- idle gate below keeps extending the delay while the user is active.
    self:_mark_reader_busy(3)
    logger.info("[MiuRead][Sync] reader ready","session=",tostring(self._reader_session_generation or 0),
        "rebuild=",tostring(had_candidate==true),"preserved=",tostring(preserve_session==true))
    -- ReaderUI already paints its first page. Avoid a second forced full-screen
    -- refresh, which was the visible extra flash after opening a book.
    self:_finish_page_transition(1.2,"reader first page")
    UIManager:scheduleIn(.05,function()
        if not (self.ui and self.ui.document)
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=ready_session
            or reader_close_active() then return end
        self:_install_reader_menu_bridge()
        self:_install_reader_quick_panel_zone()
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
        local path=self:_current_document_path()
        local book,record,variant
        if path then
            book,record,variant=self.store:identify_file(path,false)
            self:_record_recent_read(path,book,record)
        end
        if self:_should_open_book_stream(book,path,{reader_ready=true}) then
            if self:_redirect_open_to_stream(book,path,"reader ready") then return end
        end
        if record and (record.annotation_requested==true or tostring(variant or record.variant or ""):find("notes",1,true)) then
            self:_setup_thought_tap()
            self:_install_thought_link_guard()
            logger.info("[MiuRead][ThoughtPopup] local tap ready before cloud sync")
        end
        local stream_session=STREAM_SESSION.reader and STREAM_SESSION.reader.active==true
        if self:_stream_active() or stream_session then
            self:_setup_thought_tap()
            self:_install_thought_link_guard()
            self:_patch_stream_end_of_book()
            if self:_stream_active() then
                self:_apply_stream_pending_position()
            elseif stream_session then
                self:_ensure_stream_reader_hooks(1)
            end
        end
    end)
    -- Prime only lightweight page/chapter data. No toolbar widget survives a
    -- close or page turn; every visible panel is created fresh and destroyed.
    ReaderToolbar.invalidate()
    self:_reset_reader_toolbar_state_cache()
    self:_schedule_reader_toolbar_state_refresh(nil,.35)
    self:_schedule_reader_toolbar_prewarm(ready_session,1.1)
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self._progress_remote_retries={}
    self._sync_success_notified=false
    self._last_progress_submit_notice=nil
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    local task
    task=function()
        if self._reader_sync_ready_task~=task then return end
        if not self:_reader_background_idle() then
            UIManager:scheduleIn(.65,task)
            return
        end
        self._reader_sync_ready_task=nil
        if self.ui and self.ui.document
            and tonumber(HOME_SESSION.reader_session_generation or 0)==ready_session
            and not reader_close_active() then self.sync:on_reader_ready() end
    end
    self._reader_sync_ready_task=task
    -- Let KOReader paint the first page and restore input before identity and
    -- cloud-progress work begins. Local comment taps are already installed by
    -- the next-tick block above, so this does not delay reading interaction.
    UIManager:scheduleIn(.60,task)
    local device_task
    device_task=function()
        if self._miuread_suspended==true or HOME_SESSION.suspended==true then return end
        if not (self.ui and self.ui.document) or reader_close_active()
            or tonumber(HOME_SESSION.reader_session_generation or 0)~=ready_session then return end
        if not self:_reader_background_idle() then UIManager:scheduleIn(.75,device_task); return end
        HomeData.quick_device_state(true)
    end
    UIManager:scheduleIn(1.8,device_task)
    if had_candidate then
        UIManager:scheduleIn(.18,function()
            if self.ui and self.ui.document
                and tonumber(HOME_SESSION.reader_session_generation or 0)==ready_session
                and not reader_close_active() then self:onSetDimensions() end
        end)
    end
end
function Plugin:onSetDimensions()
    local now=monotonic_wall_time()
    HOME_SESSION.last_dimension_event_clock=now
    self._reader_dimension_last_event_clock=now
    self._reader_dimension_event_count=(tonumber(self._reader_dimension_event_count) or 0)+1
    local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
    local rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil

    if HOME_SESSION.suspended==true or self._miuread_suspended==true then
        READER_REBUILD.pending_width,READER_REBUILD.pending_height=sw,sh
        READER_REBUILD.pending_rotation=rotation
        return true
    end
    if reader_close_active() then
        HOME_SESSION.pending_dimension_width=sw
        HOME_SESSION.pending_dimension_height=sh
        HOME_SESSION.pending_dimension_rotation=rotation
        logger.info("[MiuRead][Rotation] deferred during reader close",
            "state=",tostring(READER_CLOSE.state),"size=",tostring(sw).."x"..tostring(sh))
        return true
    end
    if reader_rebuild_active() then
        READER_REBUILD.pending_width,READER_REBUILD.pending_height=sw,sh
        READER_REBUILD.pending_rotation=rotation
        logger.info("[MiuRead][Rotation] deferred during reader rebuild",
            "size=",tostring(sw).."x"..tostring(sh))
        return true
    end

    if not (self.ui and self.ui.document) then
        -- HomeWidget owns Home geometry. Avoid a second plugin-level rebuild.
        return true
    end

    self:_set_foreground("reader")
    self._reader_dimension_generation=(tonumber(self._reader_dimension_generation) or 0)+1
    local generation=self._reader_dimension_generation
    local event_count=self._reader_dimension_event_count
    if self._reader_dimension_task then
        UIManager:unschedule(self._reader_dimension_task)
        self._reader_dimension_task=nil
    end
    logger.info("[MiuRead][Rotation] event","generation=",tostring(generation),
        "size=",tostring(sw).."x"..tostring(sh),"rotation=",tostring(rotation))

    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._reader_dimension_task~=task or generation~=self._reader_dimension_generation then return end
        if HOME_SESSION.suspended==true or self._miuread_suspended==true then
            self._reader_dimension_task=nil
            return
        end
        if reader_close_active() or reader_rebuild_active() then
            self._reader_dimension_task=nil
            HOME_SESSION.pending_dimension_width=Device.screen:getWidth()
            HOME_SESSION.pending_dimension_height=Device.screen:getHeight()
            HOME_SESSION.pending_dimension_rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
            return
        end
        attempts=attempts+1
        local cw,ch=Device.screen:getWidth(),Device.screen:getHeight()
        local cr=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
        if cw==last_w and ch==last_h and cr==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=cw,ch,cr,0
        end
        if stable<2 and attempts<8 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._reader_dimension_task=nil
        if not (self.ui and self.ui.document) then return end
        local changed=cw~=self._reader_dimension_width or ch~=self._reader_dimension_height
            or cr~=self._reader_dimension_rotation
        self._reader_dimension_width,self._reader_dimension_height=cw,ch
        self._reader_dimension_rotation=cr
        if changed then
            self:_close_miuread_transients()
            ReaderToolbar.invalidate()
            self:_reset_reader_toolbar_state_cache()
            self:_schedule_reader_toolbar_state_refresh(nil,.10)
            -- Menu method bridges are geometry-independent; only the gesture
            -- zone needs to be rebound after a real size commit.
            self:_install_reader_quick_panel_zone()
            local reader=self:_active_reader_ui()
            UIManager:setDirty(reader or nil,"full")
        end
        logger.info("[MiuRead][Rotation] committed",
            "generation=",tostring(generation),"coalesced=",tostring(math.max(1,(tonumber(self._reader_dimension_event_count) or event_count)-event_count+1)),
            "samples=",tostring(attempts),"changed=",tostring(changed),
            "size=",tostring(cw).."x"..tostring(ch),"rotation=",tostring(cr))
    end
    self._reader_dimension_task=task
    UIManager:scheduleIn(.30,task)
    return true
end

function Plugin:onScreenResize() return self:onSetDimensions() end
function Plugin:onRotation() return self:onSetDimensions() end
function Plugin:onPageUpdate(page)
    self:_mark_reader_busy(2)
    local cache=self:_reader_toolbar_cache()
    local current=tonumber(page)
    if current then cache.page=current end
    -- Page turns only update the in-memory position immediately. Chapter/ToC
    -- lookup is delayed until the reader has been idle, keeping the flip path
    -- free of optional work.
    self:_schedule_reader_toolbar_state_refresh(current,.55)
    self.sync:on_page(page)
end
function Plugin:_annotation_sync_preferences()
    local p=self.store:preferences()
    p.annotation_sync=type(p.annotation_sync)=="table" and p.annotation_sync or {}
    if p.annotation_sync.enabled==nil then p.annotation_sync.enabled=false end
    if tostring(p.annotation_sync.review_visibility or "")=="" then p.annotation_sync.review_visibility="private" end
    p.annotation_sync.highlight_style=tonumber(p.annotation_sync.highlight_style) or 1
    p.annotation_sync.highlight_color=tonumber(p.annotation_sync.highlight_color) or 0
    return p.annotation_sync,p
end

function Plugin:annotation_sync_diagnostic_only()
    return Config.ANNOTATION_COORD_DIAGNOSTIC_ONLY == true
end

function Plugin:annotation_sync_enabled()
    local prefs=self:_annotation_sync_preferences()
    return prefs.enabled==true
end

function Plugin:toggle_annotation_sync()
    local prefs,all=self:_annotation_sync_preferences()
    prefs.enabled=prefs.enabled~=true
    all.annotation_sync=prefs
    self.store:save_preferences(all)
    logger.info("[MiuRead][AnnotationSync] enabled changed",
        "enabled=",tostring(prefs.enabled==true),"mode=manual")
    if prefs.enabled then
        self:toast("本地批注云同步已开启；当前为手动上传",2.5)
    else
        self:toast("本地批注云同步已关闭",2)
    end
    return prefs.enabled
end

function Plugin:annotation_sync_visibility_label()
    local prefs=self:_annotation_sync_preferences()
    local labels={public="公开",friendship="关注可见",private="私密",friends_hidden="屏蔽好友",one_book="共读"}
    return labels[tostring(prefs.review_visibility or "private")] or "私密"
end

function Plugin:set_annotation_sync_visibility(mode)
    local allowed={public=true,friendship=true,private=true,friends_hidden=true,one_book=true}
    mode=allowed[tostring(mode or "")] and tostring(mode) or "private"
    local prefs,all=self:_annotation_sync_preferences()
    prefs.review_visibility=mode
    all.annotation_sync=prefs
    self.store:save_preferences(all)
    self:toast("新想法云端可见范围："..self:annotation_sync_visibility_label(),2)
end

function Plugin:annotation_sync_visibility_menu()
    local labels={{"public","公开"},{"friendship","关注可见"},{"private","私密"},{"friends_hidden","屏蔽好友"},{"one_book","共读"}}
    local rows={}
    for _,item in ipairs(labels) do
        local key,label=item[1],item[2]
        rows[#rows+1]={text=label,checked_func=function()
            local prefs=self:_annotation_sync_preferences(); return tostring(prefs.review_visibility)==key
        end,keep_menu_open=true,callback=function() self:set_annotation_sync_visibility(key) end}
    end
    return rows
end

function Plugin:show_local_annotation_sync_status()
    local current=self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then self:info("请先打开一本觅阅生成的书籍。") return false end
    self:_capture_local_annotation_snapshot("sync_status")
    local summary,err=LocalAnnotationDatabase.summary(self.store,book_id)
    if not summary then self:info("读取本地批注状态失败："..tostring(err or "未知错误")); return false end
    local lines={
        "《"..tostring(current.book.title or "当前书籍").."》",
        "",
        "书签："..tostring(summary.bookmark or 0),
        "划线："..tostring(summary.highlight or 0),
        "想法："..tostring(summary.thought or 0),
        "",
        "已同步："..tostring(summary.synced or 0),
        "待上传及重试："..tostring(summary.pending or 0),
        "待删除："..tostring(summary.delete_pending or 0),
        "待处理合计："..tostring((tonumber(summary.pending or 0) or 0)+(tonumber(summary.delete_pending or 0) or 0)),
        "定位失败："..tostring(summary.locate_failed or 0),
        "元数据失败："..tostring(summary.metadata_failed or 0),
        "坐标校验失败："..tostring(summary.coord_failed or 0),
        "结果未知："..tostring(summary.unknown or 0),
        "旧坐标已同步："..tostring(summary.legacy_synced or 0),
    }
    local failures=LocalAnnotationDatabase.failures(self.store,book_id,5)
    if type(failures)=="table" and #failures>0 then
        lines[#lines+1]=""
        lines[#lines+1]="最近失败："
        local kind_label={bookmark="书签",highlight="划线",thought="想法"}
        for _,failure in ipairs(failures) do
            lines[#lines+1]=string.format("- %s [%s] %s",
                kind_label[failure.kind] or tostring(failure.kind or "批注"),
                tostring(failure.stage or failure.state or "unknown"),
                U.utf8_truncate(tostring(failure.error or ""),72,""))
        end
    end
    self:info(table.concat(lines,"\n"))
    return true
end

function Plugin:sync_local_annotations_now(force_diagnostic)
    local diagnostic_only=force_diagnostic==true or self:annotation_sync_diagnostic_only()
    logger.info("[MiuRead][AnnotationSync] manual sync requested",
        diagnostic_only and "mode=coordinate_diagnostic" or "mode=manual", "explicit=true")
    if not self:logged_in() then self:info("请先登录微信读书账号。") return false end
    local current=self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then self:info("请先打开一本觅阅生成的书籍。") return false end
    if self.annotation_async and self.annotation_async:busy() then
        self:toast("本地批注正在同步",1.5)
        return false
    end
    if not self:_capture_local_annotation_snapshot("manual_sync") then
        self:info("保存本地批注状态失败，本次未执行云同步。")
        return false
    end
    local prefs=U.copy(self:_annotation_sync_preferences())
    local book=U.copy(current.book or {})
    local record=U.copy(current.record or {})
    local service=self.annotation_sync
    self:toast(diagnostic_only and "正在生成批注坐标诊断…" or "正在同步本地批注…",2)
    local started,err=self.annotation_async:run("annotation-sync",function()
        return service:sync_book(book,record,{preferences=prefs,limit=200,diagnostic_only=diagnostic_only})
    end,function(worker_result)
        if not worker_result or worker_result.ok~=true then
            self:info("本地批注同步失败："..tostring(worker_result and worker_result.error or "后台任务失败"))
            return
        end
        local result=worker_result.value or {}
        if result.ok==false then
            self:info("本地批注同步失败："..tostring(result.error or "未知错误"))
            return
        end
        if result.diagnostic_only==true then
            local lines={
                "批注坐标诊断完成",
                "",
                "云端批注写入：已暂停",
                "导出章节："..tostring(result.diagnostic_exported or 0),
                "检查本地批注："..tostring(result.total or 0),
            }
            if tonumber(result.failed or 0)>0 then
                lines[#lines+1]="定位异常："..tostring(result.failed or 0)
            end
            lines[#lines+1]=""
            lines[#lines+1]="文件目录："
            lines[#lines+1]=tostring(result.diagnostic_root or "")
            lines[#lines+1]=""
            lines[#lines+1]="请把对应章节文件夹、thoughts.sqlite3、local_annotations.sqlite3 和生成的 EPUB 一起给 AI。"
            self:info(table.concat(lines,"\n"))
            return
        end
        local lines={
            "本地批注同步完成",
            "",
            "已同步："..tostring(result.synced or 0),
            "已删除："..tostring(result.deleted or 0),
            "云端已存在："..tostring(result.reconciled or 0),
            "定位失败："..tostring(result.locate_failed or 0),
            "元数据失败："..tostring(result.metadata_failed or 0),
            "坐标校验失败："..tostring(result.coord_failed or 0),
            "结果未知："..tostring(result.unknown or 0),
            "旧坐标已同步："..tostring(result.legacy_synced or 0).."（不会自动重传）",
        }
        if tonumber(result.failed or 0)>0 then lines[#lines+1]="待处理合计："..tostring(result.failed or 0) end
        if type(result.errors)=="table" and #result.errors>0 then
            lines[#lines+1]=""
            lines[#lines+1]="未上传："
            local kind_label={bookmark="书签",highlight="划线",thought="想法"}
            for index,item in ipairs(result.errors) do
                if index>6 then break end
                if type(item)=="table" then
                    lines[#lines+1]=string.format("- %s [%s] %s",
                        kind_label[item.kind] or tostring(item.kind or "批注"),
                        tostring(item.stage or "unknown"),
                        U.utf8_truncate(tostring(item.error or ""),72,""))
                else
                    lines[#lines+1]="- "..U.utf8_truncate(tostring(item),88,"")
                end
            end
            lines[#lines+1]=""
            lines[#lines+1]="以上记录仍保留在本地，没有猜测错误位置。"
        end
        self:info(table.concat(lines,"\n"))
    end,180)
    if not started then self:info("无法启动本地批注同步："..tostring(err or "后台任务不可用")); return false end
    return true
end

function Plugin:_local_annotation_chapter_context(item,current,kind,reason,prepared)
    if type(current)~="table" then return {} end
    local record=type(current.record)=="table" and current.record or {}
    local book=type(current.book)=="table" and current.book or {}
    local manual=reason=="manual_sync"
    local selected,before,after="","",""
    if manual and (kind=="highlight" or kind=="thought") then
        selected,before,after=self:_reader_annotation_selection_context(item,kind)
    end
    local anchor=(kind=="bookmark" and manual) and self:_reader_bookmark_anchor_text(item) or ""

    local standalone_uid=tostring(record.chapter_uid or "")
    if standalone_uid~="" then
        return {
            chapter_uid=standalone_uid,
            chapter_idx=tonumber((record.chapter_map or {})[1] and (record.chapter_map or {})[1].index) or 1,
            selected_text=selected, context_before=before, context_after=after,
            anchor_text=anchor,
        }
    end

    prepared=type(prepared)=="table" and prepared or {}
    local chapter_map=type(prepared.chapter_map)=="table" and prepared.chapter_map
        or (type(record.chapter_map)=="table" and record.chapter_map
        or (type(book.catalog)=="table" and book.catalog or {}))
    if #chapter_map==0 then
        return {selected_text=selected,context_before=before,context_after=after,anchor_text=anchor}
    end

    local toc=prepared.toc or (self.ui and self.ui.toc or nil)
    local toc_index

    -- Prefer the annotation XPointer: for rolling documents it identifies the
    -- real spine position more precisely than an estimated rendered page.
    local xp=self:_reader_annotation_xpointer(item)
    if xp and toc and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,xp)
        if ok then toc_index=tonumber(value) end
    end

    local page=self:_reader_annotation_page(item)
    if not toc_index and page and toc and type(toc.getTocIndexByPage)=="function" then
        local ok,value=pcall(toc.getTocIndexByPage,toc,page)
        if ok then toc_index=tonumber(value) end
    end
    local toc_rows=type(prepared.toc_rows)=="table" and prepared.toc_rows
        or (toc and type(toc.toc)=="table" and toc.toc or {})
    if page and not toc_index then
        local page_rows=type(prepared.toc_page_rows)=="table" and prepared.toc_page_rows or nil
        if page_rows and #page_rows>0 then
            local lo,hi,best=1,#page_rows,nil
            while lo<=hi do
                local mid=math.floor((lo+hi)/2)
                if page_rows[mid].page<=page then best=page_rows[mid].index; lo=mid+1
                else hi=mid-1 end
            end
            toc_index=best
        else
            local best=-math.huge
            for index,entry in ipairs(toc_rows) do
                local p=tonumber(entry.page or entry.pageno)
                if p and p<=page and p>=best then best=p; toc_index=index end
            end
        end
    end

    local index=math.max(1,math.min(#chapter_map,math.floor(tonumber(toc_index) or 1)))
    local chapter=chapter_map[index] or {}
    local uid=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
    return {
        chapter_uid=uid,
        chapter_idx=tonumber(chapter.index) or index,
        selected_text=selected, context_before=before, context_after=after,
        anchor_text=anchor,
    }
end

function Plugin:_capture_local_annotation_snapshot(reason)
    if not (self.ui and self.ui.document) then return false end
    local total_started=monotonic_wall_time()
    -- During reading Sync already owns the current book record. Avoid a full
    -- Store:reload() before every local snapshot; only fall back when the
    -- reader has not established a sync record yet.
    local current=(self.sync and self.sync:record()) or self:_current_book_record()
    local book_id=current and current.book and tostring(current.book.book_id or current.book.bookId or "") or ""
    if book_id=="" then return false end
    local annotations=(self.ui.annotation and self.ui.annotation.annotations)
        or (self.ui.bookmark and self.ui.bookmark.bookmarks) or {}

    local record=type(current.record)=="table" and current.record or {}
    local book=type(current.book)=="table" and current.book or {}
    local chapter_map=type(record.chapter_map)=="table" and record.chapter_map
        or (type(book.catalog)=="table" and book.catalog or {})
    local prepared={chapter_map=chapter_map,toc_prepare_ms=0}
    if tostring(record.chapter_uid or "")=="" and #chapter_map>0 then
        local toc_started=monotonic_wall_time()
        local toc=self.ui and self.ui.toc or nil
        if toc and type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
        local toc_rows=toc and type(toc.toc)=="table" and toc.toc or {}
        local page_rows={}
        for index,entry in ipairs(toc_rows) do
            local page=tonumber(entry.page or entry.pageno)
            if page then page_rows[#page_rows+1]={page=page,index=index} end
        end
        table.sort(page_rows,function(a,b)
            if a.page==b.page then return a.index<b.index end
            return a.page<b.page
        end)
        prepared.toc=toc
        prepared.toc_rows=toc_rows
        prepared.toc_page_rows=page_rows
        prepared.toc_prepare_ms=math.floor((monotonic_wall_time()-toc_started)*1000+.5)
    end

    local snapshot_started=monotonic_wall_time()
    local ok,result=xpcall(function()
        return LocalAnnotationDatabase.snapshot(self.store,book_id,annotations,current.path,function(item,kind)
            return self:_local_annotation_chapter_context(item,current,kind,reason,prepared)
        end)
    end,debug.traceback)
    local snapshot_ms=math.floor((monotonic_wall_time()-snapshot_started)*1000+.5)
    local total_ms=math.floor((monotonic_wall_time()-total_started)*1000+.5)
    if ok and result then
        logger.info("[MiuRead][LocalAnnotations] snapshot saved",
            "book=",book_id,"count=",tostring(result.count or 0),
            "toc_ms=",tostring(prepared.toc_prepare_ms or 0),
            "snapshot_ms=",tostring(snapshot_ms),
            "total_ms=",tostring(total_ms),
            "reason=",tostring(reason or "quiet"))
        return true
    end
    logger.warn("[MiuRead][LocalAnnotations] snapshot failed",
        "book=",book_id,"toc_ms=",tostring(prepared.toc_prepare_ms or 0),
        "snapshot_ms=",tostring(snapshot_ms),"total_ms=",tostring(total_ms),
        "reason=",tostring(reason or "quiet"),tostring(result))
    return false
end

function Plugin:_schedule_local_annotation_snapshot(reason,delay)
    if not (self.ui and self.ui.document) then return false end
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    local task
    task=function()
        if self._local_annotation_snapshot_task~=task then return end
        self._local_annotation_snapshot_task=nil
        self:_capture_local_annotation_snapshot(reason)
    end
    self._local_annotation_snapshot_task=task
    UIManager:scheduleIn(math.max(.5,tonumber(delay) or 2.4),task)
    return true
end

function Plugin:onAnnotationsModified()
    self._reader_checkpoint_dirty=true
    -- KOReader emits this for new, edited and deleted highlights/notes. Save
    -- once after a short quiet period so a later crash cannot discard a whole
    -- reading session, without writing on every pen movement.
    self:_schedule_reader_checkpoint("annotations_modified",2.0)
    -- Mirror KOReader's local records after the same quiet period. This phase is
    -- local-only: no range calculation and no network request runs in the pen/
    -- gesture callback.
    self:_schedule_local_annotation_snapshot("annotations_modified",2.4)
end
function Plugin:onSuspend()
    self._miuread_suspended=true
    HOME_SESSION.suspended=true
    HOME_SESSION.foreground_before_suspend=HOME_SESSION.foreground
    HOME_SESSION.navigation_before_suspend=self:_navigation_state()
    self:_set_foreground("suspended")
    StatusToast.set_blocked(true)
    StatusToast.close()
    self:_cancel_interactive_network("suspend")
    if self._local_annotation_snapshot_task then
        UIManager:unschedule(self._local_annotation_snapshot_task)
        self._local_annotation_snapshot_task=nil
    end
    self:_close_miuread_transients()
    self:_cancel_reader_close_settle("suspend")
    if self._home_resume_surface_task then
        UIManager:unschedule(self._home_resume_surface_task)
        self._home_resume_surface_task=nil
    end
    if reader_rebuild_active() then
        local owner=READER_REBUILD.owner
        if owner and owner._reader_rebuild_task then
            pcall(UIManager.unschedule,UIManager,owner._reader_rebuild_task)
            owner._reader_rebuild_task=nil
        end
        if owner and owner~=self and owner.sync and type(owner.sync.on_suspend)=="function" then
            pcall(owner.sync.on_suspend,owner.sync)
        end
        READER_REBUILD.state="suspended_pending"
    end
    if HomeView.suspend then HomeView.suspend() end
    if READER_CLOSE.state=="idle" then
        HOME_SESSION.return_requested=false
        HOME_SESSION.return_session_generation=0
        HOME_SESSION.return_request_file=nil
    end
    if self._reader_dimension_task then
        UIManager:unschedule(self._reader_dimension_task)
        self._reader_dimension_task=nil
    end
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint("suspend",true)
    end
    -- Freeze every home producer before KOReader paints the lock screen.  The
    -- visible home widget is preserved; only stale work and callbacks are
    -- invalidated, so wake-up never has to rebuild the page before showing it.
    if HomeView.is_shown() and not self:_active_reader_ui() then
        self:_home_freeze_for_suspend()
    end
    -- Stop the download child at its next safe boundary before KOReader paints
    -- the lock screen. The process and chapter checkpoints remain intact.
    if self.download_task then self.download_task:on_suspend() end
    if self._download_resume_task then
        UIManager:unschedule(self._download_resume_task)
        self._download_resume_task=nil
    end
    -- No interaction/helper timer is allowed to wake or poll background work
    -- after Suspend has taken ownership.  Clear the temporary reader pause only
    -- after the stronger suspend pause is installed, so resume starts cleanly.
    self._reader_interaction_resume_generation=(tonumber(self._reader_interaction_resume_generation) or 0)+1
    if self._reader_interaction_resume_task then
        UIManager:unschedule(self._reader_interaction_resume_task)
        self._reader_interaction_resume_task=nil
    end
    if self.download_task then self.download_task:resume("reader_interaction") end
    if self._reader_toolbar_state_task then
        UIManager:unschedule(self._reader_toolbar_state_task)
        self._reader_toolbar_state_task=nil
    end
    if self._post_reader_work_task then
        UIManager:unschedule(self._post_reader_work_task)
        self._post_reader_work_task=nil
        HOME_SESSION.post_reader_work_deferred_phase="suspend:"..tostring(HOME_SESSION.post_reader_work_phase or "")
    end
    self:_mark_reader_busy(10)
    self._suspended_at=os.time()
    logger.info("[MiuRead][Suspend] lifecycle timers cancelled",
        "rebuild=",tostring(reader_rebuild_active()),"rotation=true","resume=true")
    self.sync:on_suspend()
end
function Plugin:onResume()
    self._miuread_suspended=false
    HOME_SESSION.suspended=false
    StatusToast.set_blocked(false)
    local close_pending=reader_close_active()
    local native_menu_pending=NATIVE_MENU_GUARD.active==true
    if close_pending then
        self:_set_foreground("reader_transition")
        self:_schedule_reader_return_finish(READER_CLOSE.generation,.25,"resume close watcher")
    elseif native_menu_pending then
        self:_set_navigation_state("native_menu","resume into KOReader menu")
    end
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    self:_mark_reader_busy(5)
    local slept=self._suspended_at and os.time()-self._suspended_at or 0
    self._suspended_at=nil
    HOME_SESSION.last_resume_clock=monotonic_wall_time()
    self._resume_lifecycle_generation=(tonumber(self._resume_lifecycle_generation) or 0)+1
    local resume_generation=self._resume_lifecycle_generation

    local reader_active=self.ui and self.ui.document
    if reader_rebuild_active() then
        if reader_active then
            self:_reader_rebuild_ready_state()
        else
            local owner=READER_REBUILD.owner
            if owner and type(owner._finish_reader_rebuild_candidate)=="function" then
                READER_REBUILD.state="pending"
                local generation=READER_REBUILD.generation
                UIManager:scheduleIn(.35,function()
                    if resume_generation~=self._resume_lifecycle_generation or HOME_SESSION.suspended==true then return end
                    pcall(owner._finish_reader_rebuild_candidate,owner,generation,"resume rebuild re-evaluation")
                end)
            end
        end
    end
    if close_pending then
        self:_ensure_reader_transition_guard("resume during reader close")
        self:_schedule_download_resume_after_wake(3.5)
    elseif native_menu_pending then
        self:_schedule_download_resume_after_wake(3.5)
    end
    if reader_active and not close_pending and not native_menu_pending then
        self:_close_home_for_reader("resume into reader")
        self:_ensure_reader_transition_guard("resume into reader")
        self:_set_foreground("reader")
        UIManager:nextTick(function()
            if self.ui and self.ui.document then
                self:_install_reader_menu_bridge()
                self:_install_reader_quick_panel_zone()
            end
        end)
        self:_schedule_download_resume_after_wake(3.5)
    end
    if not close_pending and not native_menu_pending and not reader_active and HomeView.is_shown() then
        self:_set_foreground("home")
        -- Restore the already-built surface and its input ranges first.  Shelf
        -- refresh, scans, covers and metadata remain behind the interaction
        -- barrier until the page has been released and idle.
        UIManager:nextTick(function()
            if resume_generation~=self._resume_lifecycle_generation
                or HOME_SESSION.suspended==true or self._miuread_suspended==true then return end
            self:_home_begin_resume(slept)
        end)
        UIManager:scheduleIn(1.0,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then
                self:_resume_pending_post_reader_work("resume home",2.0)
            end
        end)
        return
    end

    if not close_pending and not native_menu_pending and not reader_active and not HomeView.is_shown() then
        sync_home_session()
        if self:_home_enabled() and HOME_READER_ORIGIN and not HOME_NATIVE_VISIT
            and not HOME_SESSION_SUPPRESSED and not HOME_EXITING then
            self:_set_foreground("home_pending")
            UIManager:scheduleIn(.12,function()
                if not self:_active_reader_ui() and HOME_SESSION.suspended~=true then
                    self:_restore_home_after_reader_close(1)
                end
            end)
        else
            self:_set_foreground("native")
            UIManager:scheduleIn(.05,function() UIManager:setDirty(nil,"ui") end)
        end
        self:_schedule_download_resume_after_wake(3.5)
    end
    local prefs=self.store:preferences().sync or {}
    local recheck=prefs.progress_enabled~=false and slept>=math.max(60,tonumber(prefs.resume_after) or 300)
    if recheck then
        self._progress_prompted_book_id=nil
        -- Keep the last verified state visible while wake-up revalidation runs.
        -- A transient Wi-Fi delay must not turn a healthy book into an error.
    end
    self.sync:on_resume(slept)
    if recheck then
        self:_wait_for_network("resume-progress",function(ready)
            if ready and self.ui and self.ui.document then
                self:ensure_read_report_progress("resume_recheck",true)
            elseif self.ui and self.ui.document then
                local r=self.sync:record()
                if r then self:_save_progress_state(tostring(r.book.book_id),"waiting_network",
                    "设备已唤醒，等待 Wi-Fi 完全恢复",nil,nil) end
            end
        end,{minimum_delay=6,max_wait=75,interval=3})
    end
end
function Plugin:_post_reader_work_needed()
    local pending=self.store:pending_installs()
    if type(pending)=="table" and #pending>0 then return "install",#pending end
    local queue=self.store:download_queue()
    if type(queue)=="table" and #queue>0 then return "queue",#queue end
    return nil,0
end

function Plugin:_resume_pending_post_reader_work(reason,delay)
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if phase=="" or self._post_reader_work_task then return false end
    if self:_active_reader_ui() or ReaderTransitionGuard.is_shown() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        return false
    end
    return self:_schedule_post_reader_work(reason or "surface ready",delay or 2.0,phase)
end

function Plugin:_run_post_reader_work(generation)
    if generation~=(tonumber(HOME_SESSION.post_reader_work_generation) or 0) then return false end
    self._post_reader_work_task=nil
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if self._miuread_suspended==true or HOME_SESSION.suspended==true then
        if phase~="" then HOME_SESSION.post_reader_work_deferred_phase="suspend:"..phase end
        return false
    end
    if phase=="" then
        HOME_SESSION.post_reader_work_deferred_phase=nil
        return true
    end

    local function reschedule(delay)
        local task
        task=function()
            if self._post_reader_work_task~=task then return end
            self._post_reader_work_task=nil
            self:_run_post_reader_work(generation)
        end
        self._post_reader_work_task=task
        UIManager:scheduleIn(math.max(.25,tonumber(delay) or .8),task)
        return false
    end

    if self:_active_reader_ui() or ReaderTransitionGuard.is_shown() then
        -- Do not poll while the user is reading. The next stable home/native
        -- surface or CloseDocument event resumes this exact pending phase.
        if tostring(HOME_SESSION.post_reader_work_deferred_phase or "")~=phase then
            logger.info("[MiuRead][Download] post-reader work deferred until reader closes",phase)
            HOME_SESSION.post_reader_work_deferred_phase=phase
        end
        return false
    end

    -- Returning to the bookshelf is latency-sensitive. Never let install or
    -- queue maintenance run before the page-transition barrier has released.
    if tostring(HOME_SESSION.page_transition_state or "idle")~="idle" then
        if tostring(HOME_SESSION.post_reader_work_deferred_phase or "")~="transition:"..phase then
            logger.info("[MiuRead][Download] post-reader work waiting for transition",phase)
            HOME_SESSION.post_reader_work_deferred_phase="transition:"..phase
        end
        return reschedule(.7)
    end

    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        logger.info("[MiuRead][Download] post-reader work waiting for stable surface",phase)
        return reschedule(.8)
    end
    if HomeView.is_shown() and self:_home_ui_busy() then
        logger.info("[MiuRead][Download] post-reader work yielded to active home",phase)
        return reschedule(.8)
    end

    -- If the user touched the restored home after this work was queued, yield
    -- once more. This prevents a background install/check from stealing the
    -- first interaction after returning from a book.
    local interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    local scheduled_generation=tonumber(HOME_SESSION.post_reader_work_interaction_generation) or 0
    if interaction_generation~=scheduled_generation then
        HOME_SESSION.post_reader_work_interaction_generation=interaction_generation
        logger.info("[MiuRead][Download] post-reader work yielded to home interaction",phase)
        return reschedule(1.5)
    end

    HOME_SESSION.post_reader_work_deferred_phase=nil
    local phase_started=monotonic_wall_time()
    if phase=="install" then
        local ok,err=pcall(self._install_pending_downloads,self,true)
        if not ok then logger.warn("[MiuRead][Download] pending install failed",tostring(err)) end
        local queue=self.store:download_queue()
        if type(queue)=="table" and #queue>0 then
            HOME_SESSION.post_reader_work_phase="queue"
            HOME_SESSION.post_reader_work_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
            logger.info("[MiuRead][Download] post-reader phase complete",
                "phase=install","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
                "next=queue")
            return reschedule(.8)
        end
        HOME_SESSION.post_reader_work_phase=nil
        logger.info("[MiuRead][Download] post-reader phase complete",
            "phase=install","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
            "next=none")
        return true
    end
    if phase=="queue" then
        local ok,err=pcall(self._start_next_queued_download,self)
        if not ok then logger.warn("[MiuRead][Download] queued start failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase=nil
        logger.info("[MiuRead][Download] post-reader phase complete",
            "phase=queue","ms=",tostring(math.floor((monotonic_wall_time()-phase_started)*1000+.5)),
            "next=none")
        return true
    end
    HOME_SESSION.post_reader_work_phase=nil
    return true
end

function Plugin:_schedule_post_reader_work(reason,delay,phase)
    phase=tostring(phase or HOME_SESSION.post_reader_work_phase or "")
    if phase=="" then
        local needed=self:_post_reader_work_needed()
        phase=tostring(needed or "")
    end
    if phase=="" then
        HOME_SESSION.post_reader_work_phase=nil
        HOME_SESSION.post_reader_work_deferred_phase=nil
        if self._post_reader_work_task then
            UIManager:unschedule(self._post_reader_work_task)
            self._post_reader_work_task=nil
        end
        logger.info("[MiuRead][Download] post-reader work skipped",tostring(reason or "close"),"nothing pending")
        return false
    end

    HOME_SESSION.post_reader_work_phase=phase
    HOME_SESSION.post_reader_work_deferred_phase=nil
    HOME_SESSION.post_reader_work_interaction_generation=tonumber(HOME_SESSION.home_interaction_generation) or 0
    HOME_SESSION.post_reader_work_generation=(tonumber(HOME_SESSION.post_reader_work_generation) or 0)+1
    self._post_reader_work_generation=HOME_SESSION.post_reader_work_generation
    local generation=self._post_reader_work_generation
    if self._post_reader_work_task then
        UIManager:unschedule(self._post_reader_work_task)
        self._post_reader_work_task=nil
    end
    local task
    task=function()
        if self._post_reader_work_task~=task then return end
        self._post_reader_work_task=nil
        self:_run_post_reader_work(generation)
    end
    self._post_reader_work_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or 2.0),task)
    logger.info("[MiuRead][Download] post-reader work scheduled",tostring(reason or "close"),phase)
    return true
end

function Plugin:onCloseDocument()
    local closing_path=normalized_reader_file(self:_current_document_path())
        or normalized_reader_file(HOME_SESSION.reader_session_file)
        or normalized_reader_file(HOME_READER_FILE)
    local opening_path=normalized_reader_file(HOME_SESSION.opening_file)
    local session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0
    local explicit_return=reader_close_active()
        and (self._miuread_return_requested==true or HOME_SESSION.return_requested==true)
    sync_home_session()
    local expected_close=HOME_EXPECTED_CLOSE or HOME_EXITING
        or HOME_SESSION.expected_close==true or HOME_SESSION.exiting==true or UIManager._exit_code~=nil

    -- Preserve a genuine switch target. It is distinct from an unexplained
    -- disappearance of the current ReaderUI.
    local switching_document=opening_path and closing_path and opening_path~=closing_path
    if not switching_document and (opening_path==nil or opening_path==closing_path) then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end

    if explicit_return or expected_close then
        if tostring(HOME_SESSION.page_transition_state or "")~="closing_reader" and not expected_close then
            self:_begin_page_transition("closing_reader")
        end
        if not expected_close then self:_ensure_reader_transition_guard("close document") end
        self:_reader_rebuild_cancel("explicit/expected close",true)
        return self:_finalize_reader_instance_close(closing_path,session_generation,
            {explicit_return=explicit_return,reason=expected_close and "expected document close" or "explicit document close"})
    end

    if switching_document then
        self:_reader_rebuild_cancel("explicit document switch",true)
        self:_prepare_reader_disappearance("document switch")
        if self.sync then self.sync:on_close() end
        logger.info("[MiuRead][Lifecycle] document switch observed",
            "old=",tostring(closing_path or ""),"new=",tostring(opening_path or ""))
        return true
    end

    -- No MiuRead/Home request exists. Treat this first as an internal ReaderUI
    -- rebuild candidate and stay out of Home/FileManager lifecycle until KOReader
    -- either returns a Reader or the bounded deadline proves it really closed.
    self:_prepare_reader_disappearance("reader rebuild candidate")
    logger.info("[MiuRead][Lifecycle] document disappeared","cause=unknown",
        "book=",tostring(closing_path or ""),"session=",tostring(session_generation))
    return self:_start_reader_rebuild_candidate(closing_path,session_generation,
        "CloseDocument without explicit return")
end

function Plugin:onFlushSettings()
    self:_mark_ui_preferences_flushed()
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    self:_flush_reader_checkpoint("flush_settings",true)
    self:_flush_cover_index()
    self.store:flush()
end
return Plugin
