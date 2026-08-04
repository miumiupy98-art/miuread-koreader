local RawButtonDialog=require("ui/widget/buttondialog")
local RawConfirmBox=require("ui/widget/confirmbox")
local RawInfoMessage=require("ui/widget/infomessage")
local RawInputDialog=require("ui/widget/inputdialog")
local RawMenu=require("ui/widget/menu")
local RawPathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local Device=require("device")
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
local Downloader=require("miuread.downloader")
local DownloadProgress=require("miuread.download_progress")
local DownloadTask=require("miuread.download_task")
local DownloadResult=require("miuread.download_result")
local EpubInstaller=require("miuread.epub_installer")
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local MemoryMode=require("miuread.memory_mode")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local FullShelfView=require("miuread.full_shelf_view")
local LocalBrowserView=require("miuread.local_browser_view")
local HomeView=require("miuread.home_view")
local HomeQuickPanel=require("miuread.home_quick_panel")
local ActionSheet=require("miuread.action_sheet")
local ScreenshotMode=require("miuread.screenshot_mode")
local NativeMenuBackdrop=require("miuread.native_menu_backdrop")
local GestureBridge=require("miuread.gesture_bridge")
local HomeData=require("miuread.home_data")
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
local ReaderProgressDialog=require("miuread.reader_progress_dialog")
local ReaderSettingsDialog=require("miuread.reader_settings_dialog")
local ReaderControlCenter=require("miuread.reader_control_center")
local ReaderTocDialog=require("miuread.reader_toc_dialog")
local ReaderFrontlightDialog=require("miuread.reader_frontlight_dialog")
local BookRepair=require("miuread.book_repair")
local StatusToast=require("miuread.status_toast")
local ReaderTransitionGuard=require("miuread.reader_transition_guard")
local Actions=require("miuread.actions")
local function gesture_aware_class(base, attributes)
    local class=base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base,self,event)
    end
    return class
end
local ButtonDialog=gesture_aware_class(RawButtonDialog,{_miuread_transient=true})
local ConfirmBox=gesture_aware_class(RawConfirmBox,{_miuread_transient=true})
local InfoMessage=gesture_aware_class(RawInfoMessage,{_miuread_transient=true})
local InputDialog=gesture_aware_class(RawInputDialog,{_miuread_transient=true})
local Menu=gesture_aware_class(RawMenu,{_miuread_transient=true})
local PathChooser=gesture_aware_class(RawPathChooser,{_miuread_transient=true})
local _=Text.tr
local unpack_args=unpack or table.unpack
local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60
local COVER_GUARD_WINDOW=6*60*60
local HOME_LOCAL_CACHE_TTL=4*60*60
local HOME_SHELF_REFRESH_TTL=90
local HOME_SECTION_ORDER={"account","generated","local","mp"}
local HOME_QUICK_ITEM_LEGACY_ORDER={"wifi","frontlight","refresh_shelf","full_refresh","settings","koreader_menu","downloads","sync","night","rotate","sleep","restart","quit"}
local HOME_QUICK_ITEM_LEGACY_DEFAULT={wifi=true,frontlight=true,refresh_shelf=true,full_refresh=true,settings=true,koreader_menu=true,downloads=true,sync=true,night=false,rotate=false,sleep=true,restart=false,quit=false}

-- 3.5 separates the always-visible home actions from the pull-down control
-- center. Defaults intentionally avoid duplicates, while both areas remain
-- fully configurable.
local HOME_ACTION_ITEM_ORDER={"refresh","search","downloads","sync","frontlight","miuread_settings","all_books","history","file_manager","screenshot"}
local HOME_ACTION_ITEM_DEFAULT={refresh=true,search=true,downloads=true,sync=true,frontlight=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false}
local HOME_PANEL_ITEM_ORDER={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"}
local HOME_PANEL_ITEM_DEFAULT={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false}
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
    HOME_SESSION={suppressed=false,native_visit=false,expected_close=false,exiting=false,return_file=nil,reader_origin=false,reader_file=nil,runtime_home_enabled=nil,
        foreground="native",suspended=false,reader_session_generation=0,reader_session_file=nil,reader_session_active=false,
        return_requested=false,return_session_generation=0,return_request_file=nil}
    rawset(_G,"__MIUREAD_HOME_SESSION",HOME_SESSION)
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
local THOUGHT_MAINTENANCE=rawget(_G,"__MIUREAD_THOUGHT_MAINTENANCE")
if type(THOUGHT_MAINTENANCE)~="table" then
    THOUGHT_MAINTENANCE={running=false,last_at=0}
    rawset(_G,"__MIUREAD_THOUGHT_MAINTENANCE",THOUGHT_MAINTENANCE)
end
-- Track a temporary KOReader menu visit globally because FileManager and
-- ReaderUI use different plugin instances. MiuRead remains visible underneath
-- native menus and is raised again after the last native page closes.
local NATIVE_MENU_GUARD=rawget(_G,"__MIUREAD_NATIVE_MENU_GUARD")
if type(NATIVE_MENU_GUARD)~="table" then
    NATIVE_MENU_GUARD={token=0,active=false,finishing=false,menu=nil,container=nil,watch=nil,backdrop=nil}
    rawset(_G,"__MIUREAD_NATIVE_MENU_GUARD",NATIVE_MENU_GUARD)
end
local DIRECT_MENU_INSERTED=false
local SCREENSAVER_PATCHED=false

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
    if HOME_SESSION.runtime_home_enabled==nil then
        local configured=((self.store:preferences().home_ui or {}).enabled~=false)
        HOME_SESSION.runtime_home_enabled=configured
    end
    self._reader_context=self.ui and self.ui.document~=nil
    if self._reader_context then
        local document=self.ui.document
        local path=normalized_reader_file(document and (document.file or (document.getFilePath and document:getFilePath())) or nil)
        if HOME_READER_ORIGIN or (path and HOME_READER_FILE==path) then
            mark_reader_origin(path)
            logger.info("[MiuRead][Home] reader origin restored",tostring(path or "unknown"))
        end
    end
    HomeView.prune_duplicates()
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
    self._thought_index_pause_path=self.store.temp_dir.."/thought-index.pause"
    self._reader_active_path="/tmp/miuread-reader-active.flag"
    self._reader_busy_path="/tmp/miuread-reader-busy.until"
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
        U.atomic_write(self._thought_index_pause_path,"1",true)
        U.atomic_write(self._reader_active_path,"1",true)
        U.atomic_write(self._reader_busy_path,tostring(os.time()+3),true)
    else
        os.remove(self._thought_index_pause_path)
        os.remove(self._reader_active_path)
        os.remove(self._reader_busy_path)
    end
    self.memory_mode=MemoryMode:new(self.store)
    self.book_repair=BookRepair:new(self.store)
    logger.info("[MiuRead] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.reader=Reader:new(self.http,self.store)
    self.api=Api:new(self.http,self.store,self.reader)
    self.mp=MP:new(self.reader,self.http,self.store,self.api)
    self.annotations=Annotations:new(self.api)
    self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http)
    self.download_task=DownloadTask:new(self.store)
    self.cache_cleanup_task=CacheCleanupTask:new(self.store)
    self.library=Library:new(self.api,self.http,self.store)
    self.access=Access:new(self.library,self.api,self.reader,self.store)
    self.async=Async:new(self.store,{allow_android=true,disable_fallback=true})
    self.mp_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.search_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.shelf_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.identity_async=Async:new(self.store,{poll_interval=.20,allow_android=true,
        disable_fallback=true})
    self.thought_index_async=Async:new(self.store,{poll_interval=.75,allow_android=true,
        disable_fallback=true})
    self.repair_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.home_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
    -- Directory navigation has its own worker. A root refresh or metadata job
    -- must never force a folder tap back onto the UI thread.
    self.local_browser_async=Async:new(self.store,{poll_interval=.20,allow_android=true,disable_fallback=true})
    self.home_metadata_async=Async:new(self.store,{poll_interval=.35,allow_android=true,disable_fallback=true})
    self.home_cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
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
    self._home_interaction_generation=0
    self._home_data_revision=0
    self._home_section_revisions={account=0,generated=0,["local"]=0,mp=0}
    self._home_directory_generation=0
    self._home_directory_active_path=nil
    self._home_directory_request_owner=nil
    self._local_browser_fallback_task=nil
    self._local_browser_fallback_scanner=nil
    self._home_inline_navigation_generation=0
    self._home_cover_inflight={}
    self._home_suspended=false
    self._home_resume_generation=0
    self._home_resume_barrier=false
    self._home_resume_first_frame=false
    self._home_resume_background_task=nil
    self._home_resume_pending_kind=nil
    self._home_resume_pending_work=nil
    self._home_resume_started_clock=nil
    self._home_resume_sleep_seconds=0
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
    install_home_screensaver_patch()
    if not DIRECT_MENU_INSERTED then
        local ok_insert, inserter = pcall(require, "ui/plugin/insert_menu")
        if ok_insert and inserter and type(inserter.add) == "function" then
            pcall(inserter.add, "miuread_return_home_direct")
        end
        DIRECT_MENU_INSERTED = true
    end
    self.ui.menu:registerToMainMenu(self)
    if self._reader_context then self:_install_reader_home_bridge() end
    if not self._reader_context then
        local state=self.updater:startup()
        if state=="updated" then
            UIManager:scheduleIn(1,function() self:status_toast("更新完成","当前运行版本 "..tostring(self.version),4) end)
        elseif state=="mismatch" then
            UIManager:scheduleIn(1,function() self:info("更新文件已经替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。\n当前运行："..tostring(self.version)) end)
        end
        UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
        UIManager:scheduleIn(1.2,function() self:_show_auth_notice() end)
        UIManager:scheduleIn(5.0,function() self:maybe_auto_check_update(false) end)
        if self:_home_enabled() and not HOME_SESSION_SUPPRESSED then
            self:_schedule_home_startup(.65)
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
        sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end,
    }
end
function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
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
    for _, item in ipairs(items) do
        if type(item)=="table" and (item.sub_item_table_func or item.sub_item_table) then
            return self:_show_standalone_menu(title,items)
        end
    end
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
    self:online("account-status-check",function()
        self:status_toast("账号状态","正在检查基础账号和书架访问",3)
        local shelf_ok,shelf_result=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
        if shelf_ok then
            self:_mark_auth_channel_ok("shelf")
        elseif Http.is_auth_error(shelf_result) then
            self:_mark_auth_problem("shelf",shelf_result,false)
        else
            self:_mark_auth_channel_error("shelf",shelf_result)
        end
        self:show_account_status()
    end)
end
function Plugin:confirm_logout()
    if not self:logged_in() then self:toast("当前没有登录微信读书账号",3); return end
    local downloading=self.download_task and self.download_task:busy()
    local text="退出当前微信读书账号？\n\n已下载书籍、本地阅读记录和下载断点都会保留。"
    if downloading then text=text.."\n\n当前下载会停止；重新登录后可从断点继续。" end
    UIManager:show(ConfirmBox:new{text=text,ok_text="退出登录",ok_callback=function()
        if downloading and self.download_task then self.download_task:cancel() end
        self.auth_flow:cancel()
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
    self._auth_transitioning=true
    if self.sync and self.sync.invalidate_login_session then
        self.sync:invalidate_login_session("new_login")
    end
    if self.store.clear_login_bound_sessions then self.store:clear_login_bound_sessions("new_login") end
    if self.store.clear_account_shelf_cache then self.store:clear_account_shelf_cache() end
end

function Plugin:show_account_status()
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
    local out={
        {text=(HOME_NATIVE_VISIT or HomeView.is_shown()) and "返回觅阅主页" or "打开觅阅首页",callback=self:safe("home-ui",function()
            self:_open_miuread_home_entry()
        end)},
        {text="我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)},
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text=self:_download_menu_text(),callback=self:safe("downloads",function() self:show_downloads() end)},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        account,
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_native_koreader_menu() end},
    }
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
    local label=annotations and "划线与想法版" or "纯净版"
    UIManager:show(ConfirmBox:new{
        text="重新生成当前书籍的"..label.."？\n\n新文件会在生成完成后替换对应版本。",
        ok_text="重新生成",
        cancel_text="取消",
        ok_callback=function() self:choose_download_mode(book,{annotations=annotations},false) end,
    })
end

function Plugin:current_book_download_menu(book)
    local items={
        {text="下载当前章",callback=function() self:download_current_chapters(1) end},
        {text="当前章及后续 5 章",callback=function() self:download_current_chapters(6) end},
        {text="当前章及后续 10 章",callback=function() self:download_current_chapters(11) end},
        {text="选择章节范围",callback=function() self:chapters(book) end},
    }
    if self:_has_range_variant(book.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(book) end}
    end
    return items
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
        {text="下载章节",sub_item_table_func=function() return self:current_book_download_menu(b) end},
        {text="重新生成与修复",sub_item_table_func=function() return self:current_book_rebuild_menu(b) end},
        {text="管理本地文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end},
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
        return {
            {text="返回文章列表",callback=self:safe("mp-back",function() self:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=self:safe("mp-prev",function() self:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=self:safe("mp-next",function() self:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return self:current_mp_article_menu(mp_context) end},
            {text=self:_download_menu_text(),callback=function() self:show_downloads() end},
            {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
            {text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end},
        }
    end
    return {
        {text=self:_home_enabled() and "退出阅读并返回觅阅主页" or "返回书架",callback=self:safe("shelf",function()
            if self:_home_enabled() then self:return_to_miuread_home()
            else self:show_shelf(false,false,"account") end
        end)},
        {text="当前书籍",sub_item_table_func=function() return self:current_book_menu() end},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        {text=self:_download_menu_text(),callback=function() self:show_downloads() end},
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end},
    }
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
            if download_state.status=="active" then b.download_status="生成中 "..tostring(self:_download_percent(download_state)).."%"
            elseif download_state.status=="pending_install" then
                b.download_status=DownloadResult.shelf_status(download_state,true)
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
            elseif download_state.status=="annotation_pending" then b.download_status="生成未完成"
            elseif download_state.status=="completed" and download_state.annotation_fallback==true then b.download_status="已生成"
            elseif download_state.status=="completed" and download_state.seen~=true then b.download_status="刚刚生成完成" end
        end
        b.status_text=self:_shelf_status_text(b)
    end
    if cover_index_changed then self.store:set("cover_index",cover_index) end
    return rows
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
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        self:open_file(record.file)
    else
        self:book_menu(b)
    end
end
function Plugin:_shelf_hold(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    self:book_menu(b)
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
        -- Older builds enabled full local scans, network metadata and global
        -- thought-index maintenance by default. On e-ink devices these jobs
        -- compete with first paint and touch handling, so beta.8 migrates once
        -- to the cache-first defaults. Users may still enable optional jobs.
        home.performance_defaults_version=1
        home.auto_scan=false
        home.network_metadata=false
        home.background_thought_index=false
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
    if home.auto_scan==nil then home.auto_scan=false; changed=true end
    if home.local_check_on_open==nil then home.local_check_on_open=true; changed=true end
    if home.local_library_mode==nil then
        local legacy_index=self.store:get("home_local_index",{})
        local had_index=type(legacy_index)=="table" and type(legacy_index.books)=="table" and #legacy_index.books>0
        -- Existing indexed libraries migrate to manual control; new installs
        -- default to zero-index folder browsing. Nothing starts scanning merely
        -- because the plugin was upgraded.
        home.local_library_mode=(home.auto_scan==true or had_index) and "manual" or "direct"
        changed=true
    end
    if home.local_library_mode~="auto" and home.local_library_mode~="manual"
        and home.local_library_mode~="direct" then
        home.local_library_mode="direct"; changed=true
    end
    local should_auto_scan=home.local_library_mode=="auto"
    if home.auto_scan~=should_auto_scan then home.auto_scan=should_auto_scan; changed=true end
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
            home[items_key]={}
            for _,key in ipairs(item_order) do home[items_key][key]=item_defaults[key]==true end
            home[order_key]=U.copy(item_order)
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
    normalize_quick_group("action_items","action_order","action_layout_version",1,HOME_ACTION_ITEM_ORDER,HOME_ACTION_ITEM_DEFAULT)
    normalize_quick_group("panel_items","panel_order","panel_layout_version",1,HOME_PANEL_ITEM_ORDER,HOME_PANEL_ITEM_DEFAULT)
    -- Unsupported hardware controls disappear instead of leaving dead slots.
    if not Device:hasFrontlight() then
        if home.action_items.frontlight==true then home.action_items.frontlight=false; changed=true end
        if home.panel_items.frontlight==true then home.panel_items.frontlight=false; changed=true end
        local action_count=0
        for _,key in ipairs(HOME_ACTION_ITEM_ORDER) do if home.action_items[key]==true then action_count=action_count+1 end end
        if action_count<6 and home.action_items.history~=true then home.action_items.history=true; changed=true end
    end
    if not Device:canSuspend() and home.panel_items.sleep==true then home.panel_items.sleep=false; changed=true end
    if type(home.hidden_local_files)~="table" then home.hidden_local_files={}; changed=true end
    if home.more_expanded==nil then home.more_expanded=false; changed=true end
    if home.network_metadata==nil then home.network_metadata=false; changed=true end
    if home.background_thought_index==nil then home.background_thought_index=false; changed=true end
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
    return home,preferences
end

function Plugin:_save_home_preferences(home,preferences)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    self.store:save_preferences(preferences)
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

function Plugin:_set_runtime_home_enabled(enabled, quiet)
    enabled=enabled==true
    HOME_SESSION.runtime_home_enabled=enabled
    HOME_SESSION_SUPPRESSED=not enabled
    if enabled then
        HOME_NATIVE_VISIT=false
        HOME_EXPECTED_CLOSE=false
        HOME_EXITING=false
    end
    persist_home_session()
    if not quiet then self:toast(enabled and "本次运行已启用觅阅桌面" or "本次运行已关闭觅阅桌面",2) end
    return enabled
end

function Plugin:_open_miuread_home_entry()
    local now=os.clock()
    if now<(tonumber(self._home_entry_busy_until) or 0) then return true end
    self._home_entry_busy_until=now+.45
    self:_set_runtime_home_enabled(true,true)
    sync_home_session()
    if HomeView.is_shown() then
        HomeView.raise()
        return true
    end
    if not (self.ui and self.ui.document) and HOME_NATIVE_VISIT then
        return self:_return_from_native_filemanager()
    end
    if self:_active_reader_ui() then return self:return_to_miuread_home() end
    return self:show_miuread_home(false)
end

function Plugin:_disable_runtime_home()
    self:_set_runtime_home_enabled(false,true)
    if HomeView.is_shown() then
        HOME_SESSION_SUPPRESSED=true
        HOME_NATIVE_VISIT=true
        HOME_EXPECTED_CLOSE=true
        persist_home_session()
        self:_ensure_filemanager_base(HOME_RETURN_FILE)
        HomeQuickPanel.close()
        ActionSheet.close()
        HomeView.close(true)
        self._home_view=nil
        HOME_EXPECTED_CLOSE=false
        persist_home_session()
    end
    self:toast("本次运行已切回插件模式",2)
    return true
end

function Plugin:_home_enabled()
    if HOME_SESSION.runtime_home_enabled~=nil then
        return HOME_SESSION.runtime_home_enabled~=false
    end
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_configured_home_enabled()
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_home_mode_label()
    local configured=self:_configured_home_enabled()
    local running=self:_home_enabled()
    local configured_label=configured and "默认觅阅桌面" or "默认插件模式"
    if configured~=running then
        return configured_label..(running and " · 本次已启用觅阅" or " · 本次已关闭觅阅")
    end
    return configured_label
end

function Plugin:_set_home_mode(use_miuread_home)
    local enabled=use_miuread_home==true
    local home,preferences=self:_home_preferences()
    if (home.enabled~=false)==enabled then
        self:toast(enabled and "已选择觅阅桌面模式" or "已选择插件模式",2)
        return false
    end
    home.enabled=enabled
    home.layout_version=21
    self:_save_home_preferences(home,preferences)
    local text
    if enabled then
        text="重启后将使用觅阅桌面。KOReader 启动及关闭从觅阅打开的书籍后，会优先返回觅阅主页。其他桌面插件可能不会自动显示。"
    else
        text="重启后将使用插件模式。觅阅不会替代 KOReader 或其他美化界面，下载、评论、同步、修复和账号功能仍可使用。"
    end
    if not self:_notice_enabled("mode_switch") then
        self:toast("运行模式已保存，重启 KOReader 后生效",3)
        return true
    end
    local dialog
    dialog=ButtonDialog:new{title=text,title_align="center",buttons={
        {{text="立即重启",callback=function() UIManager:close(dialog); self:_restart_koreader() end}},
        {{text="稍后重启",callback=function() UIManager:close(dialog); self:toast("运行模式将在重启后生效",3) end}},
        {{text="稍后重启并不再提示",callback=function()
            UIManager:close(dialog); self:_set_notice_enabled("mode_switch",false); self:toast("运行模式将在重启后生效",3)
        end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:home_mode_menu()
    return {
        {text="默认使用觅阅桌面",post_text="每次启动及关书后返回觅阅主页",checked_func=function() return self:_configured_home_enabled() end,callback=function()
            self:_set_home_mode(true)
        end},
        {text="默认使用插件模式",post_text="保留 KOReader 或其他美化界面",checked_func=function() return not self:_configured_home_enabled() end,callback=function()
            self:_set_home_mode(false)
        end},
        {text="本次启用觅阅桌面",post_text=self:_home_enabled() and "已启用，可反复打开" or "未启用",checked_func=function() return self:_home_enabled() end,keep_menu_open=true,callback=function()
            if self:_home_enabled() then self:_disable_runtime_home() else self:_set_runtime_home_enabled(true) end
        end},
        {text="打开觅阅首页",post_text="始终可用，不需要重启",callback=function() self:_open_miuread_home_entry() end},
    }
end

function Plugin:_home_refresh_priority(kind)
    local priority={header=1,section=2,content=3,full=4}
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

    self._home_resume_pending_work={
        scan=self._home_refreshing==true or (self.home_async and self.home_async:busy()) or false,
        remote=self._home_remote_refreshing==true or (self.shelf_async and self.shelf_async:busy()) or false,
        metadata=(self.home_metadata_async and self.home_metadata_async:busy()) or false,
        covers=(self.home_cover_async and self.home_cover_async:busy()) or false,
        thoughts=(self.thought_index_async and self.thought_index_async:busy()) or THOUGHT_MAINTENANCE.running==true,
    }
    if self._home_refresh_pending_kind then self:_home_defer_refresh_kind(self._home_refresh_pending_kind) end

    self:_home_unschedule_task("_home_refresh_task")
    self:_home_unschedule_task("_home_render_refresh_task")
    self:_home_unschedule_task("_home_resume_background_task")
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
    if self.shelf_async and self._home_resume_pending_work.remote then self.shelf_async:cancel("device suspended") end
    if self.thought_index_async then self.thought_index_async:cancel("device suspended") end
    THOUGHT_MAINTENANCE.running=false
    if self._thought_index_pause_path then U.atomic_write(self._thought_index_pause_path,"1",true) end

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
    if self._thought_index_pause_path then os.remove(self._thought_index_pause_path) end

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
            if pending.covers then self:_home_schedule_remote_covers(cover_targets) end
        end)
    end
    if pending.thoughts then
        UIManager:scheduleIn(2.0,function()
            if generation==self._home_resume_generation and not self:_home_background_blocked() and HomeView.is_shown() then
                self:_start_thought_index_maintenance()
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
    self._home_interaction_generation=(tonumber(self._home_interaction_generation) or 0)+1
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

    logger.info("[MiuRead][Resume] event received",
        "generation=",tostring(generation),"slept=",tostring(self._home_resume_sleep_seconds))
    local raised=HomeView.resume{
        on_interaction=function(first,kind)
            self:_home_resume_interaction(generation,first,kind)
        end,
    }
    if not raised then
        self._home_resume_barrier=false
        self.sync:on_resume(slept)
        self:_schedule_home_startup(.12)
        logger.warn("[MiuRead][Resume] existing home unavailable; startup scheduled")
        return false
    end

    -- The existing widget is raised and dirtied without rebuilding it. Old
    -- scans, cover callbacks and shelf refreshes were invalidated on suspend,
    -- so this is the next bounded UI operation after wake.
    UIManager:nextTick(function()
        if generation~=self._home_resume_generation or self._home_suspended==true then return end
        self._home_resume_first_frame=true
        local elapsed=math.floor((os.clock()-self._home_resume_started_clock)*1000+.5)
        logger.info("[MiuRead][Resume] first surface released","ms=",tostring(elapsed))
        UIManager:scheduleIn(.10,function()
            if generation==self._home_resume_generation and self._home_suspended~=true then
                self.sync:on_resume(slept)
            end
        end)
        self:_home_schedule_resume_background(3.5,generation)
    end)
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
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then
                self:_show_miuread_home_now(false,true,true,refresh_kind or "content")
            end
        end)
    end
end

function Plugin:_notify_home_data_changed(refresh_kind)
    local requested=self:_home_defer_refresh_kind(refresh_kind or "content")
    if self:_home_background_blocked() then
        logger.info("[MiuRead][Resume] data refresh deferred",tostring(requested))
        return true
    end
    self._home_refresh_debounce_generation=(tonumber(self._home_refresh_debounce_generation) or 0)+1
    local generation=self._home_refresh_debounce_generation
    local interaction_generation=tonumber(self._home_interaction_generation) or 0
    local task
    task=function()
        if generation~=self._home_refresh_debounce_generation then return end
        self._home_refresh_task=nil
        local kind=self._home_refresh_pending_kind or "content"
        self._home_refresh_pending_kind=nil
        if HomeView.is_shown() and not self:_active_reader_ui() then
            if interaction_generation~=(tonumber(self._home_interaction_generation) or 0) then
                self:_notify_home_data_changed(kind)
                return
            end
            self._home_refresh_pending=false
            self:_refresh_home_view(nil,kind)
        end
    end
    self._home_refresh_task=task
    UIManager:scheduleIn(.70,task)
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
            changed=true
        end
    end
    local hero_id=tostring(self._home_hero and (self._home_hero.bookId or self._home_hero.book_id) or "")
    apply(self._home_hero)
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book) end
    end
    if hero_id==book_id then
        local current=HomeView.current()
        if current and current.opts then current.opts.screensaver_file=path end
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
    local age=math.max(0,os.time()-(tonumber(updated_at) or 0))
    if force~=true and age<HOME_SHELF_REFRESH_TTL then return false end
    if not self:logged_in() then
        if user_requested then self:toast("登录后才能刷新微信书架",3) end
        return false
    end
    if not self:is_online() then
        if user_requested then self:toast("当前没有网络连接",3) end
        return false
    end
    self._home_remote_refreshing=true
    if user_requested then self:toast("正在刷新书架…",2) end
    local started=self:_refresh_shelf_async(function(_,_,err)
        self._home_remote_refreshing=false
        if err then
            if user_requested then self:toast(self:_friendly_remote_error(err,"书架刷新"),4) end
            return
        end
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_notify_home_data_changed("content")
        end
        if user_requested then self:toast("书架已刷新",2) end
    end,true)
    if not started then self._home_remote_refreshing=false end
    return started==true
end

function Plugin:_home_manual_refresh()
    -- One action refreshes the visible home state: shelves, local files,
    -- progress, download state, metadata and the final e-ink surface.
    self.store:reload()
    self.store:prune_missing_files()
    self:toast("正在刷新主页…",2)
    local remote=self:_home_refresh_remote(true,false)
    local mode=tostring(self:_home_preferences().local_library_mode or "direct")
    -- Manual mode updates its index only from the dedicated scan action.
    local local_started=mode=="manual" and false or self:_home_scan_local(true)
    if not remote and not local_started then self:_notify_home_data_changed("content") end
    return remote or local_started or true
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
    if self:_home_preferences().local_library_mode~="manual" then self:_home_scan_local(true) end
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
    self._home_interaction_generation=(tonumber(self._home_interaction_generation) or 0)+1
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
        on_open_book=function(book) self:_home_open_book(book) end,
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
    self._home_interaction_generation=(tonumber(self._home_interaction_generation) or 0)+1
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
    end
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
    self:_refresh_home_view("主页显示大小已切换为"..(labels[mode] or "标准"),"full")
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
    refresh="刷新",search="搜索",downloads="下载管理",sync="阅读同步",frontlight="前光",
    miuread_settings="觅阅设置",all_books="全部书籍",history="阅读历史",file_manager="文件管理",screenshot="截图",
}
local HOME_PANEL_LABELS={
    wifi="Wi-Fi",rotate="旋转屏幕",screenshot="截图",koreader_settings="KOReader 设置",
    return_koreader="返回 KOReader",quit="退出 KOReader",frontlight="前光",sync="阅读同步",
    miuread_settings="觅阅设置",downloads="下载管理",restart="重启 KOReader",sleep="休眠",full_refresh="全屏刷新",
}

function Plugin:_home_toggle_group_item(group,key)
    local home,preferences=self:_home_preferences()
    local is_action=group=="action"
    local items_key=is_action and "action_items" or "panel_items"
    local order=is_action and HOME_ACTION_ITEM_ORDER or HOME_PANEL_ITEM_ORDER
    local max_count=is_action and 6 or 8
    local min_count=4
    local items=home[items_key] or {}
    local currently=items[key]==true
    local count=0
    for _,name in ipairs(order) do if items[name]==true then count=count+1 end end
    if not currently and count>=max_count then
        self:toast((is_action and "主页快捷栏最多显示六项" or "下滑工具栏最多显示八项"),2)
        return false
    end
    items[key]=not currently
    count=count+(currently and -1 or 1)
    if count<min_count then
        items[key]=true
        self:toast("至少保留四项",2)
        return false
    end
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
        home[version_key]=1
        self:_save_home_preferences(home,preferences)
        if HomeView.is_shown() then self:_refresh_home_view(nil,"content") end
        self:toast("已恢复推荐布局")
    end}
    return rows
end

function Plugin:home_action_settings_menu() return self:_home_group_settings_menu("action") end
function Plugin:home_panel_settings_menu() return self:_home_group_settings_menu("panel") end

local READER_QUICK_LABELS={
    toc="目录",progress="阅读进度",font="字体排版",frontlight="前光",sync="阅读同步",
    comment_font="评论字号",page_display="页面显示",home="觅阅书架",typeset="高级排版",
    current_book="当前书籍",downloads="下载管理",full_refresh="全屏刷新",
    koreader_menu="KOReader 高级菜单",sleep="休眠",
}

function Plugin:_reader_preferences()
    local preferences=self.store:preferences()
    local reader=type(preferences.reader_ui)=="table" and preferences.reader_ui or {}
    local changed=false
    if reader.enabled==nil then reader.enabled=true; changed=true end
    if reader.plugin_mode_enabled==nil then reader.plugin_mode_enabled=false; changed=true end
    if reader.show_title==nil then reader.show_title=true; changed=true end
    if reader.show_status==nil then reader.show_status=true; changed=true end
    if reader.show_recent==nil then reader.show_recent=true; changed=true end
    if type(reader.recent_actions)~="table" then reader.recent_actions={}; changed=true end
    if type(reader.quick_items)~="table" then reader.quick_items={}; changed=true end
    if type(reader.quick_order)~="table" then reader.quick_order={}; changed=true end

    local version=tonumber(reader.quick_layout_version) or 0
    if version<4 then
        local empty_items=next(reader.quick_items)==nil
        local empty_order=#reader.quick_order==0
        local legacy_default=quick_boolean_layout_matches(reader.quick_items,READER_QUICK_ITEM_LEGACY_DEFAULT,READER_QUICK_ITEM_LEGACY_ORDER)
            and quick_order_matches(reader.quick_order,READER_QUICK_ITEM_LEGACY_ORDER)
        local v2_default=quick_boolean_layout_matches(reader.quick_items,READER_QUICK_ITEM_V2_DEFAULT,READER_QUICK_ITEM_V2_ORDER)
            and quick_order_matches(reader.quick_order,READER_QUICK_ITEM_V2_ORDER)
        local v3_default=quick_boolean_layout_matches(reader.quick_items,READER_QUICK_ITEM_V3_DEFAULT,READER_QUICK_ITEM_V3_ORDER)
            and quick_order_matches(reader.quick_order,READER_QUICK_ITEM_V3_ORDER)
        if empty_items or empty_order or legacy_default or v2_default or v3_default then
            reader.quick_items={}
            for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
                reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true
            end
            reader.quick_order=U.copy(READER_QUICK_ITEM_ORDER)
        else
            -- Preserve genuinely customised layouts. New entries start hidden
            -- so an update never displaces a user's chosen shortcuts.
            reader.quick_items.more=nil
            if reader.quick_items.all_functions==nil then reader.quick_items.all_functions=false end
            if reader.quick_items.page_display==nil then reader.quick_items.page_display=false end
        end
        reader.quick_layout_version=4
        changed=true
    end

    if version<5 then
        local former_home_default=true
        local former_enabled={home=true,toc=true,progress=true,font=true,frontlight=true,sync=true}
        for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
            if (reader.quick_items[key]==true)~=(former_enabled[key]==true) then
                former_home_default=false
                break
            end
        end
        if former_home_default then
            reader.quick_items={}
            for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
                reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true
            end
            reader.quick_order=U.copy(READER_QUICK_ITEM_ORDER)
        end
        reader.quick_layout_version=5
        changed=true
    end

    if version<6 then
        -- Every reader page now has a fixed Home control. Remove the old Home
        -- tile so the configurable six-cell area remains useful.
        if reader.quick_items.home~=nil then reader.quick_items.home=nil; changed=true end
        local clean_order={}
        for _,key in ipairs(reader.quick_order or {}) do
            if key~="home" then clean_order[#clean_order+1]=key end
        end
        reader.quick_order=clean_order
        reader.quick_layout_version=6
        changed=true
    end

    if version<7 then
        -- The footer already opens the complete reading control center. Use the
        -- duplicated sixth tile for the frequently used comment font control.
        local replacement={}
        local seen_comment=false
        for _,key in ipairs(reader.quick_order or {}) do
            if key=="all_functions" then
                if not seen_comment then replacement[#replacement+1]="comment_font"; seen_comment=true end
            elseif key~="comment_font" then
                replacement[#replacement+1]=key
            elseif not seen_comment then
                replacement[#replacement+1]=key; seen_comment=true
            end
        end
        if not seen_comment then replacement[#replacement+1]="comment_font" end
        reader.quick_order=replacement
        if reader.quick_items.all_functions==true or reader.quick_items.comment_font==nil then
            reader.quick_items.comment_font=true
        end
        reader.quick_items.all_functions=nil
        reader.quick_layout_version=7
        changed=true
    end

    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        if reader.quick_items[key]==nil then
            reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true
            changed=true
        end
    end
    local seen,order={},{}
    for _,key in ipairs(reader.quick_order) do
        if READER_QUICK_ITEM_DEFAULT[key]~=nil and not seen[key] then
            seen[key]=true
            order[#order+1]=key
        end
    end
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        if not seen[key] then seen[key]=true; order[#order+1]=key end
    end
    if table.concat(order,"|")~=table.concat(reader.quick_order,"|") then reader.quick_order=order; changed=true end

    if not Device:hasFrontlight() and reader.quick_items.frontlight==true then
        reader.quick_items.frontlight=false
        if reader.quick_items.page_display~=true then reader.quick_items.page_display=true end
        changed=true
    end

    local enabled_count=0
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        if reader.quick_items[key]==true then enabled_count=enabled_count+1 end
    end
    if enabled_count>6 then
        local kept=0
        for _,key in ipairs(reader.quick_order) do
            if reader.quick_items[key]==true then
                kept=kept+1
                if kept>6 then reader.quick_items[key]=false; changed=true end
            end
        end
    elseif enabled_count<4 then
        for _,key in ipairs({"toc","progress","font","frontlight","sync","comment_font","page_display"}) do
            if (key~="frontlight" or Device:hasFrontlight()) and reader.quick_items[key]~=true then
                reader.quick_items[key]=true
                enabled_count=enabled_count+1
                changed=true
                if enabled_count>=4 then break end
            end
        end
    end

    local recent_seen,recent={},{}
    for _,key in ipairs(reader.recent_actions) do
        key=tostring(key or "")
        if key~="" and not recent_seen[key] then
            recent_seen[key]=true
            recent[#recent+1]=key
            if #recent>=6 then break end
        end
    end
    if table.concat(recent,"|")~=table.concat(reader.recent_actions,"|") then
        reader.recent_actions=recent
        changed=true
    end

    preferences.reader_ui=reader
    if changed then self.store:save_preferences(preferences) end
    return reader,preferences
end

function Plugin:_reader_panel_active()
    local reader=self:_reader_preferences()
    if reader.enabled==false then return false end
    if self:_home_enabled() then return true end
    return reader.plugin_mode_enabled==true
end

function Plugin:_save_reader_preferences(reader,preferences)
    preferences=preferences or self.store:preferences()
    preferences.reader_ui=reader
    self.store:save_preferences(preferences)
end

function Plugin:_toggle_reader_quick_item(key)
    local reader,preferences=self:_reader_preferences()
    local current=reader.quick_items[key]==true
    local count=0
    for _,name in ipairs(READER_QUICK_ITEM_ORDER) do if reader.quick_items[name]==true then count=count+1 end end
    if not current and count>=6 then self:toast("阅读面板最多显示六项",2); return false end
    reader.quick_items[key]=not current
    count=count+(current and -1 or 1)
    if count<4 then reader.quick_items[key]=true; self:toast("阅读面板至少保留四项",2); return false end
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:_move_reader_quick_item(key,delta)
    local reader,preferences=self:_reader_preferences()
    local order=reader.quick_order or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    reader.quick_order=order
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:reader_quick_panel_order_menu()
    local reader=self:_reader_preferences()
    local rows={}
    for index,key in ipairs(reader.quick_order or READER_QUICK_ITEM_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={text=READER_QUICK_LABELS[item_key] or item_key,post_text=tostring(item_index),sub_item_table_func=function()
            local current=self:_reader_preferences().quick_order or READER_QUICK_ITEM_ORDER
            local current_index
            for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
            current_index=current_index or item_index
            return {
                {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_move_reader_quick_item(item_key,-1) end},
                {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_move_reader_quick_item(item_key,1) end},
            }
        end}
    end
    return rows
end

function Plugin:reader_quick_panel_items_menu()
    local rows={}
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        local item_key=key
        rows[#rows+1]={text=READER_QUICK_LABELS[item_key] or item_key,checked_func=function()
            return self:_reader_preferences().quick_items[item_key]==true
        end,keep_menu_open=true,callback=function() self:_toggle_reader_quick_item(item_key) end}
    end
    rows[#rows+1]={text="调整顺序",sub_item_table_func=function() return self:reader_quick_panel_order_menu() end}
    rows[#rows+1]={text="恢复推荐布局",callback=function()
        local reader,preferences=self:_reader_preferences()
        reader.quick_items={}
        for _,key in ipairs(READER_QUICK_ITEM_ORDER) do reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true end
        reader.quick_order=U.copy(READER_QUICK_ITEM_ORDER)
        if type(Device.hasFrontlight)~="function" or not Device:hasFrontlight() then
            reader.quick_items.frontlight=false
            reader.quick_items.page_display=true
        end
        reader.quick_layout_version=7
        self:_save_reader_preferences(reader,preferences)
        self:toast("阅读面板已恢复推荐布局")
    end}
    return rows
end

function Plugin:reader_quick_panel_settings_menu()
    return {
        {text="启用觅阅阅读面板",checked_func=function() return self:_reader_preferences().enabled~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.enabled=reader.enabled==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="插件模式下显示阅读面板",post_text="默认关闭，避免影响其他 UI",checked_func=function() return self:_reader_preferences().plugin_mode_enabled==true end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.plugin_mode_enabled=reader.plugin_mode_enabled~=true; self:_save_reader_preferences(reader,preferences)
            self:toast("重开书籍后生效",2)
        end},
        {text="显示书名",checked_func=function() return self:_reader_preferences().show_title~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.show_title=reader.show_title==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="显示阅读状态",checked_func=function() return self:_reader_preferences().show_status~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.show_status=reader.show_status==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="显示最近使用",checked_func=function() return self:_reader_preferences().show_recent~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.show_recent=reader.show_recent==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="快捷项目与顺序",post_text="最多六项",sub_item_table_func=function() return self:reader_quick_panel_items_menu() end},
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
    repair_while_reading="阅读中修复提醒",mode_switch="运行模式切换说明",
}

function Plugin:notice_settings_menu()
    local order={"reader_download","low_battery","low_storage","full_refresh","lockscreen","library_scan","repair_while_reading","mode_switch"}
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

function Plugin:show_home_layout_dialog()
    local dialog
    local home=self:_home_preferences()
    local current=home.layout_style=="compact" and "紧凑布局" or "标准布局"
    local function choose(style)
        if dialog then UIManager:close(dialog) end
        self:_set_home_layout(style)
    end
    dialog=ButtonDialog:new{
        title="页面布局 · 当前："..current,
        title_align="center",
        buttons={
            {{text=(home.layout_style~="compact" and "✓ " or "").."标准布局",callback=function() choose("desk") end}},
            {{text=(home.layout_style=="compact" and "✓ " or "").."紧凑布局",callback=function() choose("compact") end}},
            {{text="关闭",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
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

function Plugin:_show_standalone_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
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
    local MenuClass=options.native_input==true and RawMenu or Menu
    menu=MenuClass:new{title=tostring(title or "觅阅"),item_table=rows,is_borderless=true,title_bar_fm_style=true}
    menu._miuread_transient=true
    -- TitleBar captures a dynamic self:onClose() call when it is created.
    -- Replacing Menu:onClose on this concrete instance is sufficient and avoids
    -- mutating already-built child button fields that differ across KOReader
    -- versions.
    close_standalone=function(suppress_restore)
        if not menu or menu._miuread_closing then return true end
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

function Plugin:_reader_wifi_settings(back_callback)
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    return self:_reader_open_native_page("Wi-Fi",function()
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,nil,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            local ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr)
            if ok then return true end
        end
        return false
    end,back_callback or function() self:show_reader_control_center("device") end)
end

function Plugin:_home_status_line()
    local parts={os.date("%H:%M")}
    local ok_network,NetworkMgr=pcall(require,"ui/network/manager")
    if ok_network and NetworkMgr and type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then parts[#parts+1]=value==true and "Wi-Fi" or "离线" end
    end
    local device=HomeData.device_state()
    if tonumber(device.battery) then
        parts[#parts+1]=tostring(math.floor(tonumber(device.battery)+.5)).."%"
    end
    return table.concat(parts,"  ")
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
            local percent=self:_download_percent(state)
            local generating={underlines=true,thoughts=true,footnotes=true,images=true,package=true}
            return (generating[tostring(state.stage or "")] and "生成中 " or "下载中 ")..tostring(percent).."%"
        end
        if state.status=="failed" then return "失败" end
        if state.status=="interrupted" or state.status=="pending_install" or state.status=="annotation_pending" then return "待修复" end
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
    self._home_interaction_generation=(tonumber(self._home_interaction_generation) or 0)+1
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

function Plugin:_home_book_time(book)
    local value=tonumber(book and (book.lastReadTime or book.readUpdateTime or book.cloudUpdatedAt or book.last_read_at or book.opened_at or book.updateTime or book.downloadedAt or book.modified_at) or 0) or 0
    if value>100000000000 then value=math.floor(value/1000) end
    return value
end

function Plugin:_home_recent_book(miuread_rows,local_rows,account_rows)
    local best
    local lists={miuread_rows or {},local_rows or {},account_rows or {}}
    for _,list in ipairs(lists) do
        for _,book in ipairs(list) do
            if not (book.local_folder==true or book.kind=="folder") then
                local progress=tonumber(book.progress) or 0
                if progress>0 and progress<100 and (not best or self:_home_book_time(book)>self:_home_book_time(best)) then best=book end
            end
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
    local day=os.date("%Y-%m-%d",stamp)
    if day==os.date("%Y-%m-%d",now) then return "今天 "..os.date("%H:%M",stamp) end
    if day==os.date("%Y-%m-%d",now-24*60*60) then return "昨天 "..os.date("%H:%M",stamp) end
    if os.date("%Y",stamp)==os.date("%Y",now) then return os.date("%m月%d日",stamp) end
    return os.date("%Y年%m月%d日",stamp)
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

function Plugin:_home_open_book(book)
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
    return self:_home_open_miuread(book)
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
            if not (book.local_folder==true or book.kind=="folder") and progress>0 and key~="" and not seen[key] then
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
    for _,section in ipairs({"generated","account","local","mp"}) do
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
            on_select=function(book) self:_home_open_book(book) end,
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
            callback=function() self:_home_open_book(row) end,
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
    local dialog
    local function choose(title,choices,key,labels)
        local chooser
        local rows={}
        for _,value in ipairs(choices) do
            local selected=state[key]==value
            rows[#rows+1]={{text=(selected and "● " or "")..labels[value],callback=function()
                UIManager:close(chooser)
                state[key]=value
                self:_home_close_full_shelf()
                UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
            end}}
        end
        rows[#rows+1]={{text="返回",callback=function() UIManager:close(chooser) end}}
        chooser=ButtonDialog:new{title=title,title_align="center",buttons=rows}
        UIManager:show(chooser)
    end
    dialog=ButtonDialog:new{title="筛选与排序",title_align="center",buttons={
        {{text="来源："..source_labels[state.source],callback=function()
            UIManager:close(dialog); choose("选择来源",{"all","account","generated","local","mp"},"source",source_labels)
        end}},
        {{text="状态："..status_labels[state.status],callback=function()
            UIManager:close(dialog); choose("选择阅读状态",{"all","reading","unread","finished","downloaded","failed"},"status",status_labels)
        end}},
        {{text="排序："..sort_labels[state.sort],callback=function()
            UIManager:close(dialog); choose("选择排序",{"recent","added","title","author"},"sort",sort_labels)
        end}},
        {{text="恢复默认",callback=function()
            UIManager:close(dialog); self._home_all_books_options={source="all",status="all",sort="recent"}
            self:_home_close_full_shelf(); UIManager:scheduleIn(.05,function() self:show_home_all_books() end)
        end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
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
    if network_too~=false then network_started=self:_home_schedule_network_metadata(book,true)==true end
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

function Plugin:_home_delete_local_book(book)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在") return false end
    UIManager:show(ConfirmBox:new{
        text="删除本地文件《"..tostring(book.title or "书籍").."》？\n\n文件删除后无法通过觅阅恢复。阅读进度侧边文件不会主动删除。",
        ok_text="删除文件",cancel_text="取消",
        ok_callback=function()
            local ok,err=os.remove(path)
            if not ok then self:info("删除失败：\n"..tostring(err or "无法删除文件")); return end
            local cache=self:_home_local_cache()
            local kept={}
            for _,row in ipairs(cache.books or {}) do if tostring(row.file or "")~=path then kept[#kept+1]=row end end
            cache.books=kept
            self.store:set("home_local_index",cache)
            self:_show_miuread_home_now(false,true,true,"content")
            self:toast("本地文件已删除")
        end,
    })
    return true
end

function Plugin:_home_repair_book(book)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then self:info("这本书没有可用的修复记录") return false end
    local stored=self.store:book(id)
    local record=self:_preferred_record(id)
    if not stored or not record then self:info("这本书尚未生成，暂时不需要修复") return false end
    local context={
        book={book_id=id,title=stored.title or book.title},
        record=record,
        variant=record.variant,
        path=record.file,
        title=stored.title or book.title,
    }
    return self:_run_book_repair(context,nil,true)
end

function Plugin:_show_home_refresh_popup(anchor)
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="below",
        title="刷新",
        subtitle="更新主页、书架、阅读进度和下载状态",
        actions={
            {icon="↻",label="智能刷新",detail="只更新发生变化的内容",callback=function() self:_home_manual_refresh() end},
            {icon="⌕",label="完整刷新",detail="重新扫描来源并补全缺失信息",callback=function() self:_home_complete_refresh() end},
            {icon="▤",label="清除屏幕残影",detail="只执行一次墨水屏完整刷新",callback=function() self:_home_full_refresh() end},
        },
    }
end

function Plugin:_show_home_download_popup(anchor)
    local status=self:_download_menu_text()
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="below",
        title="下载管理",
        subtitle=status,
        actions={
            {icon="⇩",label="查看下载任务",detail="进度、排队、暂停与失败重试",callback=function() self:show_downloads() end},
            {icon="⚙",label="下载与存储设置",detail="下载策略、目录与提醒",callback=function() self:_show_standalone_menu("下载与存储",self:download_settings_menu()) end},
            {icon="⌫",label="清理下载残留",detail="不删除书籍、批注和阅读进度",callback=function() self:show_download_cleanup_dialog() end},
        },
    }
end

function Plugin:_show_home_sync_popup(anchor)
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="below",
        title="阅读同步",
        subtitle="当前状态："..self:progress_sync_label(),
        actions={
            {icon="i",label="查看同步状态",detail="最近同步结果和待处理项目",callback=function() self:show_sync_status(false) end},
            {icon="⇅",label="立即同步",detail="立即同步阅读进度与时间",callback=function() self:manual_sync() end},
            {icon="◉",label="进度同步开关",detail="控制阅读位置同步",callback=function() self:toggle_progress_sync() end},
            {icon="◷",label="时间同步开关",detail="控制阅读时长同步",callback=function() self:toggle_time_sync() end},
            {icon="⚙",label="完整同步设置",detail="冲突处理、自动同步与提示",callback=function() self:_show_standalone_menu("阅读同步",self:sync_menu()) end},
        },
    }
end

function Plugin:_show_home_settings_popup(anchor)
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="below",
        title="觅阅设置",
        subtitle="主页、阅读、下载和账号设置",
        actions={
            {icon="▦",label="首页与书架",detail="布局、快捷入口和书架来源",callback=function() self:_show_standalone_menu("首页与书架",self:display_settings_menu()) end},
            {icon="A",label="阅读界面",detail="阅读快捷栏和显示方式",callback=function() self:_show_standalone_menu("阅读界面",self:reader_quick_panel_settings_menu()) end},
            {icon="⇩",label="下载与存储",detail="下载策略、目录和清理",callback=function() self:_show_standalone_menu("下载与存储",self:download_settings_menu()) end},
            {icon="⇅",label="账号与同步",detail="登录状态和同步设置",callback=function() self:_show_standalone_menu("账号与同步",self:account_sync_settings_menu()) end},
            {icon="⚙",label="全部设置",detail="打开完整觅阅设置",callback=function() self:_show_standalone_menu("觅阅设置",self:settings_menu()) end},
        },
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

function Plugin:_show_home_delete_book_popup(book)
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
        preferred_direction="above",
        width_ratio=.66,
        title="删除书籍 · "..tostring(book.title or "书籍"),
        subtitle=subtitle,
        actions=actions,
        footer_action={label="取消",callback=function() end},
    }
    return true
end

function Plugin:_home_hold_book(book,anchor)
    if not book then return end
    if book.local_folder==true or book.kind=="folder" then
        local actions={
            {icon=book.local_parent and "back" or "folder",
                label=book.local_parent and "返回上一级" or "打开文件夹",
                detail=book.local_parent and tostring(book.status_text or "上一级") or "在主页中显示这一层",
                callback=function() self:_home_open_book(book) end},
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
            actions=actions,
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
                {icon="▶",label="打开公众号",detail="查看文章列表",callback=function() self:mp_account(target) end},
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
                {icon="▶",label="打开书籍",detail="继续阅读",callback=function() self:_home_open_local(book) end},
                {icon="i",label="查看详情",detail="文件、进度和图书信息",callback=function() self:_home_local_book_details(book) end},
                {icon="↻",label="更新书籍信息",detail="重新提取并尝试网络补全",callback=function() self:_home_refresh_one_book_metadata(book,true) end},
                {icon="▤",label="在文件管理中查看",detail="打开 KOReader 文件浏览器",callback=function() self:_home_close_to_native(true) end},
                {icon="−",label="从觅阅书架隐藏",detail="保留本地文件",callback=function() self:_home_hide_local_book(book) end},
                {icon="!",label="删除本地文件",detail="删除后无法通过觅阅恢复",danger=true,callback=function() self:_home_delete_local_book(book) end},
            },
        }
        return
    end

    local target=U.copy(book)
    self:_home_attach_local_record(target)
    local record=id~="" and self:_preferred_record(id) or nil
    local available=record and record.file and U.file_exists(record.file)
    ActionSheet.show{
        anchor=anchor,
        preferred_direction="above",
        width_ratio=.66,
        title=tostring(target.title or "书籍"),
        subtitle=U.trim(tostring(target.author or ""))~="" and tostring(target.author)
            or (available and "已下载" or "尚未下载"),
        actions={
            {icon=available and "▶" or "⇩",label=available and "打开书籍" or "下载书籍",
                detail=available and "继续阅读" or "加入下载任务",callback=function()
                    if available then self:_home_open_miuread(target) else self:choose_download(target,nil,false) end
                end},
            {icon="i",label="查看详情",detail="书籍简介和出版信息",callback=function() self:book_details(target) end},
            {icon="↻",label="更新书籍信息",detail="微信读书详情与网络补全",callback=function() self:_home_refresh_one_book_metadata(target,true) end},
            {icon="✚",label="修复这本书",detail="检查正文、目录和生成记录",callback=function() self:_home_repair_book(target) end},
            {icon="⇩",label="重新生成／下载",detail="重新选择下载版本",callback=function() self:choose_download(target,nil,false) end},
            {icon="⌫",label="删除书籍",detail=available and "选择删除当前或全部版本" or "查看本地下载记录",danger=true,callback=function()
                self:_show_home_delete_book_popup(target)
            end},
        },
        footer_action={label="更多书籍操作  ›",callback=function() self:book_menu(target) end},
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
    local definitions={
        refresh={icon="↻",icon_key="refresh",label="刷新",callback=function(anchor) self:_show_home_refresh_popup(anchor) end,hold_callback=function(anchor) self:_show_home_refresh_popup(anchor) end},
        search={icon="⌕",icon_key="search",label="搜索",callback=function() self:show_home_search_dialog() end},
        downloads={icon="⇩",icon_key="download",label="下载管理",badge=download_badge,callback=function(anchor) self:_show_home_download_popup(anchor) end,hold_callback=function(anchor) self:_show_home_download_popup(anchor) end},
        sync={icon="⇅",icon_key="sync",label="阅读同步",callback=function(anchor) self:_show_home_sync_popup(anchor) end,hold_callback=function(anchor) self:_show_home_sync_popup(anchor) end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",callback=function(anchor) self:_show_home_settings_popup(anchor) end,hold_callback=function(anchor) self:_show_home_settings_popup(anchor) end},
        all_books={icon="▦",label="全部书籍",callback=function() self:show_home_all_books() end},
        history={icon="◷",label="阅读历史",callback=function() self:show_home_reading_history() end},
        file_manager={icon="▤",label="文件管理",callback=function() self:_home_close_to_native(true) end},
        screenshot={icon="▣",label="截图",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
    }
    if Device:hasFrontlight() then
        definitions.frontlight={icon="☼",icon_key="frontlight",label="前光",callback=function() self:_home_frontlight() end,hold_callback=function() self:_home_frontlight() end}
    end
    local entries={}
    local used={}
    for _,key in ipairs(home.action_order or HOME_ACTION_ITEM_ORDER) do
        if home.action_items[key]==true and definitions[key] and not used[key] then
            used[key]=true; entries[#entries+1]=definitions[key]
            if #entries>=6 then break end
        end
    end
    -- Keep six useful positions on devices without frontlight.
    for _,key in ipairs({"history","all_books","file_manager","screenshot"}) do
        if #entries>=6 then break end
        if definitions[key] and not used[key] then used[key]=true; entries[#entries+1]=definitions[key] end
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
    elseif state.status=="interrupted" or state.status=="pending_install" or state.status=="annotation_pending" then
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
    if self.thought_index_async then self.thought_index_async:cancel(reason or "reader opening") end
    if self._thought_index_pause_path then U.atomic_write(self._thought_index_pause_path,"1",true) end
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
    local mode=tostring(home.local_library_mode or "direct")
    if force~=true and mode~="auto" then return false end
    if self:_home_background_blocked() or self:_active_reader_ui() then return false end
    local roots=self:_home_local_roots(true)
    if #roots==0 or not self.home_async or self.home_async:busy() or not self.home_async:available() then return false end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    local generation=self._home_scan_generation
    self._home_refreshing=true
    local root_payload=U.copy(roots)
    local recursive=mode~="direct"
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


local HOME_NETWORK_METADATA_TTL=30*24*60*60

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

function Plugin:_home_save_network_metadata(book,patch)
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    cache.rows[key]={checked_at=os.time(),patch=type(patch)=="table" and patch or {}}
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

function Plugin:_home_schedule_network_metadata(book,force)
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        return false
    end
    if type(book)~="table" or not HomeView.is_shown() then return false end
    local home=self:_home_preferences()
    if home.network_metadata==false then return false end
    if (book.source=="local" or book.local_file==true) and home.local_library_mode=="direct" then return false end
    local key=self:_home_network_metadata_key(book)
    if key=="" then return false end
    local cache=self:_home_network_metadata_cache()
    local cached=cache.rows[key]
    local age=os.time()-(tonumber(type(cached)=="table" and cached.checked_at or 0) or 0)
    if force~=true and type(cached)=="table" and age>=0 and age<HOME_NETWORK_METADATA_TTL then
        if type(cached.patch)=="table" and self:_home_merge_network_patch(book,cached.patch) then
            self:_home_schedule_render_refresh("content")
        end
        return false
    end
    if not self:is_online() or not self.home_metadata_async or self.home_metadata_async:busy()
        or not self.home_metadata_async:available() then return false end
    local candidate=U.copy(book)
    local id=tostring(candidate.bookId or candidate.book_id or "")
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
            logger.warn("[MiuRead][Home] network metadata unavailable",tostring(result and result.error or "unknown"))
            self:_home_save_network_metadata(candidate,{})
            return
        end
        local patch=type(result.value)=="table" and result.value or {}
        self:_home_save_network_metadata(candidate,patch)
        if self._home_hero and self:_home_network_metadata_key(self._home_hero)==key then
            local changed=self:_home_merge_network_patch(self._home_hero,patch)
            if changed and HomeView.is_shown() then self:_home_schedule_render_refresh("content") end
        end
    end,35)
    if not started then logger.warn("[MiuRead][Home] network metadata worker not started",tostring(err)) end
    return started==true
end

function Plugin:_home_schedule_local_metadata(books)
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.metadata=true
        return false
    end
    if not HomeView.is_shown() then return end
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue,seen={},{}
    local direct_mode=self:_home_preferences().local_library_mode=="direct"
    for _,book in ipairs(books or {}) do
        local filepath=tostring(book and book.file or "")
        local is_local=book and (book.source=="local" or book.local_file==true)
        if filepath~="" and not (direct_mode and is_local)
            and not seen[filepath] and LocalMetadata.needs_refresh(book,true) then
            seen[filepath]=true
            queue[#queue+1]={
                file=filepath,book=book,
                local_book=book.source=="local" or book.local_file==true,
                needs_description=U.trim(tostring(book.description or book.intro or book.summary or ""))=="",
            }
            if #queue>=4 then break end
        end
    end
    if #queue==0 then return end
    local index,changed_any=1,false
    local function finish()
        if changed_any and generation==self._home_metadata_generation and HomeView.is_shown() then
            self:_home_schedule_render_refresh("content")
        end
    end
    local function next_book()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        local item=queue[index]
        if not item then finish(); return end
        local metadata,err=LocalMetadata.read(item.file,self:_home_local_metadata_dir(),{
            -- MiuRead books already carry remote metadata.  Prefer the cheap
            -- embedded/BIM path on the home screen instead of opening the full
            -- document, which can block gestures and make the screen flash.
            -- Never open/render a full document from the home screen. Heavy
            -- metadata extraction remains available from the explicit book
            -- refresh action, while the shelf uses cheap embedded/BIM data.
            open_document=false,
            use_bim=true,
        })
        if metadata then
            local visible_changed=item.book and LocalMetadata.merge(item.book,metadata) or false
            if not item.local_book then metadata.metadata_complete=true end
            local changed=item.local_book
                and self:_home_update_local_cache(item.file,metadata)
                or self:_home_update_miuread_metadata(item.file,metadata)
            if changed or visible_changed then changed_any=true end
        else
            logger.warn("[MiuRead][Home] metadata unavailable",tostring(item.file),tostring(err))
        end
        index=index+1
        if queue[index] then UIManager:scheduleIn(.18,next_book) else finish() end
    end
    UIManager:scheduleIn(.65,next_book)
end

function Plugin:_home_schedule_remote_covers(books)
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.covers=true
        return false
    end
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
            if #queue>=10 then break end
        end
    end
    if #queue==0 or not self.home_cover_async then return end
    local index,changed_count=1,0
    local changed_sections={}
    local hero_changed=false
    local function mark_changed(book_id)
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
        if changed_count<=0 then return end
        for section in pairs(changed_sections) do self:_home_bump_section_revision(section) end
        local active=self._home_active_section or "account"
        if hero_changed then
            -- The recent-reading card belongs to the static body. Rebuild the
            -- content once after the whole cover batch instead of once per book.
            self:_home_schedule_render_refresh("content")
        elseif changed_sections[active] then
            self:_home_apply_section(active)
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
    end
    local function next_cover()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self.home_cover_async:busy() then UIManager:scheduleIn(.3,next_cover); return end
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
                if item.book then item.book.cover_path=result.value end
                if changed then
                    changed_count=changed_count+1
                    mark_changed(item.bookId)
                end
            elseif result and result.error then
                logger.warn("[MiuRead][Home] cover download failed",tostring(item.bookId),U.first_line(result.error,120))
            end
            index=index+1
            if queue[index] then UIManager:scheduleIn(.08,next_cover) else finish() end
        end,background and 35 or 14)
        if not started then
            if self._home_cover_inflight[item.bookId]==generation then self._home_cover_inflight[item.bookId]=nil end
            UIManager:scheduleIn(.35,next_cover)
        end
    end
    logger.info("[MiuRead][HomeCoverBatch] queued","count=",tostring(#queue))
    UIManager:scheduleIn(.12,next_cover)
end

function Plugin:_home_open_miuread(book)
    self:_home_stop_background("opening book")
    local id=tostring(book and (book.bookId or book.book_id) or "")
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
    if self:_home_preferences().local_library_mode=="direct" then return false end
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue={}
    for _,book in ipairs(rows or {}) do
        if not (book.local_folder==true or book.kind=="folder")
            and book.file and LocalMetadata.needs_refresh(book,true) then
            queue[#queue+1]=book
            if #queue>=8 then break end
        end
    end
    if #queue==0 then return end
    local index,changed_any=1,false
    local function finish()
        if changed_any and generation==self._home_metadata_generation
            and view and not view._miu_closed and type(view.updateItems)=="function" then
            pcall(view.updateItems,view,nil,true)
        end
    end
    local function next_book()
        if generation~=self._home_metadata_generation or self:_active_reader_ui() then return end
        local book=queue[index]
        if not book then finish(); return end
        local metadata,err=LocalMetadata.read(book.file,self:_home_local_metadata_dir(),{open_document=false,use_bim=true})
        if metadata then
            local visible_changed=LocalMetadata.merge(book,metadata)
            book.status_text=self:_home_status_text(book,true)
            local cache_changed=self:_home_update_local_cache(book.file,metadata)
            changed_any=changed_any or visible_changed or cache_changed
        else
            logger.warn("[MiuRead][Home] local shelf metadata unavailable",tostring(book.file),tostring(err))
        end
        index=index+1
        if queue[index] then UIManager:scheduleIn(.18,next_book) else finish() end
    end
    UIManager:scheduleIn(.12,next_book)
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

function Plugin:show_home_local_library(rows)
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    local roots=self:_home_local_roots(true)
    if #roots==0 then
        self:info("还没有设置本地书库目录。\n\n可在“首页与书架 → 本地书籍”中添加。")
        return false
    end
    if mode~="direct" then
        rows=type(rows)=="table" and rows or select(1,self:_home_local_rows())
        if #rows==0 then
            self:info(mode=="manual" and "本地书库尚未扫描。\n\n请在设置中点击“扫描本地书库”。"
                or "本地书库暂时没有可显示的书籍。")
            return false
        end
        return self:_home_show_full_shelf("本地书籍",rows)
    end
    if #roots==1 then return self:show_local_browser(roots[1].path,roots[1],{},false) end
    local folders={}
    for _,root in ipairs(roots) do folders[#folders+1]=self:_home_local_folder_entry(root.path,root.name,root.path) end
    local picker
    picker=LocalBrowserView.show{
        title="本地书籍",folders=folders,books={},
        on_open_folder=function(folder)
            local selected
            for _,root in ipairs(roots) do if root.path==folder.folder_path then selected=root; break end end
            self:show_local_browser(folder.folder_path,selected or {path=folder.folder_path,name=folder.title},{},false,picker)
        end,
        on_back=function(view) if view and not view._miu_closed then UIManager:close(view) end end,
        on_close=function(closed_view)
            if self._home_directory_request_owner==closed_view then
                self:_cancel_home_directory_request("local root picker closed")
            end
        end,
        on_refresh=function() self:_home_scan_local(true) end,
    }
    return picker
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
    NATIVE_MENU_GUARD.backdrop=nil
    NATIVE_MENU_GUARD.original_close=nil
    NativeMenuBackdrop.close()
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
    local backdrop=NativeMenuBackdrop.current()
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget and widget~=fm and widget~=reader and widget~=HomeView.current()
            and widget~=backdrop and widget.toast~=true then
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
    NATIVE_MENU_GUARD.backdrop=nil

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
    NativeMenuBackdrop.close()
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
    UIManager:scheduleIn(1,function() self:_refresh_home_view(nil,"header") end)
    return ok==true
end

function Plugin:_home_wifi_settings()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local function open_picker()
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,nil,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            pcall(NetworkMgr.turnOnWifi,NetworkMgr)
        end
        self:_show_native_koreader_menu()
        return true
    end
    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    if on and type(NetworkMgr.toggleWifiOff)=="function" then
        local ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr,function() open_picker() end,true)
        if ok then return true end
    end
    return open_picker()
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

function Plugin:show_home_quick_panel(more_expanded)
    -- Use cached device state so the gesture opens the panel immediately.
    -- Wi-Fi actions still query the live state when the user taps them.
    local state=HomeData.quick_device_state()
    local wifi_on=nil
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then wifi_on=value==true end
    end
    local wifi_detail
    if wifi_on==nil then wifi_detail="状态未知"
    elseif wifi_on~=true then wifi_detail="已关闭"
    elseif state.online==true then wifi_detail="已连接"
    else wifi_detail="未连接" end

    local download_detail=""
    if self:_has_download_status() or #self.store:download_queue()>0 then
        download_detail=self:_download_menu_text():gsub("^下载管理%s*[·：]?%s*","")
    end
    local definitions={
        wifi={
            icon="Wi-Fi",
            icon_path=ROOT.."/resources/"..(wifi_on==false and "wifi-off.svg" or (state.online==true and "wifi-connected.svg" or "wifi-disconnected.svg")),
            label="Wi-Fi",detail=wifi_detail,callback=function() self:_home_wifi_toggle() end
        },
        rotate={icon="↻",icon_key="rotate",label="旋转",detail="",callback=function() self:_home_rotate() end},
        screenshot={icon="▣",icon_key="screenshot",label="截图",detail="延时截取",callback=function(anchor) ScreenshotMode.start(self,anchor) end},
        koreader_settings={icon="⚙",icon_key="ko-reader",label="KOReader",detail="设置",callback=function() self:_show_native_koreader_menu() end},
        return_koreader={icon="←",icon_key="return",label="返回",detail="KOReader",callback=function() self:_home_close_to_native(true) end},
        quit={icon="⏻",icon_key="power",label="退出",detail="KOReader",callback=function() self:_quit_koreader() end},
        sync={icon="⇅",icon_key="sync",label="阅读同步",detail=self:progress_sync_label(),callback=function() self:_show_standalone_menu("阅读同步",self:sync_menu()) end},
        miuread_settings={icon="⚙",icon_key="settings",label="觅阅设置",detail="",callback=function() self:_show_standalone_menu("觅阅设置",self:settings_menu()) end},
        downloads={icon="⇩",icon_key="download",label="下载管理",detail=download_detail,callback=function() self:show_downloads() end},
        restart={icon="↺",icon_key="restart",label="重启",detail="KOReader",callback=function() self:_restart_koreader() end},
        full_refresh={icon="▤",icon_key="full-refresh",label="全屏刷新",detail="清除残影",callback=function() self:_home_full_refresh() end},
    }
    if Device:hasFrontlight() then
        definitions.frontlight={icon="☼",icon_key="frontlight",label="前光",detail="",callback=function() self:_home_frontlight() end}
    end
    if Device:canSuspend() then
        definitions.sleep={icon="◐",icon_key="sleep",label="休眠",detail="",callback=function() self:_home_sleep() end}
    end

    local home,preferences=self:_home_preferences()
    local buttons={}
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true and definitions[key] then buttons[#buttons+1]=definitions[key] end
        if #buttons>=8 then break end
    end

    local enabled_panel_keys={}
    for _,key in ipairs(home.panel_order or HOME_PANEL_ITEM_ORDER) do
        if home.panel_items[key]==true and definitions[key] then enabled_panel_keys[key]=true end
    end
    local more_candidates={
        {key="scan_all",icon="⌕",label="扫描书籍",detail="全部来源",callback=function() self:_home_complete_refresh() end},
        {key="metadata_all",icon="i",label="更新元数据",detail="全部书籍",callback=function()
            self:_home_reset_local_metadata(); self:_home_complete_refresh(true)
        end},
        {key="covers_all",icon="▧",label="重建封面",detail="全部书籍",callback=function() self:_clear_cover_cache() end},
        {key="repair_books",icon="✚",label="修复书籍",detail="批量检查",callback=function() self:scan_downloaded_books_for_repair() end},
        {key="repair_comments",icon="☷",label="修复评论",detail="重建索引",callback=function() self:clear_invalid_comment_indexes() end},
        {key="rebuild_shelf",icon="▦",label="重建书架",detail="索引与状态",callback=function()
            self.store:reload(); self.store:prune_missing_files(); self:_show_miuread_home_now(false,true,true,"full")
        end},
        {key="cache",icon="⌫",label="清理缓存",detail="安全清理",callback=function() self:show_download_cleanup_dialog() end},
        {key="diagnostics",icon="!",label="诊断修复",detail="日志与记录",callback=function()
            self:_show_standalone_menu("诊断与修复",self:book_repair_settings_menu())
        end},
        {key="restart",icon="↺",label="重启",detail="KOReader",callback=function() self:_restart_koreader() end},
    }
    local more_buttons={}
    for _,entry in ipairs(more_candidates) do
        -- Defaults avoid exact duplicates. Users may still place the same
        -- command in both areas through customization if they explicitly want it.
        if not enabled_panel_keys[entry.key] then more_buttons[#more_buttons+1]=entry end
    end


    local battery=tonumber(state.battery) and (tostring(math.floor(state.battery+.5)).."%") or "未知"
    local notice=self:_home_download_notice()
    local status_text
    if notice then
        status_text=tostring(notice.title or "")
        if notice.detail and notice.detail~="" then status_text=status_text.." · "..tostring(notice.detail) end
    elseif self:progress_sync_label()=="上传失败" then
        status_text="阅读同步需要处理"
    end
    local panel,err=HomeQuickPanel.show{
        title=os.date("%H:%M").."　快捷控制　电量 "..battery,
        subtitle="Wi-Fi "..wifi_detail,
        status_text=status_text,
        buttons=buttons,
        more_buttons=more_buttons,
        more_expanded=more_expanded==true,
        on_toggle_more=function(expanded)
            UIManager:scheduleIn(.04,function() self:show_home_quick_panel(expanded==true) end)
        end,
    }
    if not panel then
        logger.warn("[MiuRead][QuickPanel] unavailable",tostring(err or "unknown"))
        self:info("快捷控制暂时无法打开")
    end
end

function Plugin:_begin_koreader_exit(reason)
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

function Plugin:_quit_koreader()
    local active=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local queued=#self.store:download_queue()>0
    local detail=""
    if active and queued then
        detail="\n\n当前任务会中断，重新启动后可继续；排队任务会保留。"
    elseif active then
        detail="\n\n当前任务会中断，重新启动后可继续。"
    elseif queued then
        detail="\n\n当前有一个排队任务，重新启动后仍会保留。"
    end
    UIManager:show(ConfirmBox:new{
        text="退出 KOReader？"..detail,
        ok_text="退出",
        cancel_text="取消",
        ok_callback=function()
            self:_begin_koreader_exit("quit")
            pcall(function() self:onFlushSettings() end)
            if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
            -- Use KOReader's normal Exit event so FileManager/ReaderUI can tear
            -- down the entire widget stack. Calling UIManager:quit() directly
            -- can leave a fullscreen replacement home as the last visible UI.
            UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
        end,
    })
    return true
end

function Plugin:show_home_menu()
    -- The status area and the header menu button share one action list.
    return self:show_home_quick_panel()
end

function Plugin:home_preview_menu()
    return {
        {text="打开觅阅菜单",callback=function() self:show_home_menu() end},
        {text="切换到插件模式",callback=function() self:_set_home_mode(false) end},
        {text="KOReader 文件管理器",callback=function() self:_home_close_to_native() end},
    }
end

function Plugin:_mark_reader_busy(seconds)
    local path=tostring(self._reader_busy_path or "")
    if path=="" then return false end
    local target=os.time()+math.max(1,tonumber(seconds) or 4)
    if tonumber(self._reader_busy_until or 0)>=target-1 then return true end
    self._reader_busy_until=target
    return U.atomic_write(path,tostring(target),true)==true
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
        end,back_callback or function() self:show_reader_control_center("reading") end)
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

function Plugin:_show_reader_typeset_menu(back_callback)
    local ui=self.ui
    if not (ui and type(ui.handleEvent)=="function") then
        self:info("当前文档暂时无法打开 KOReader 高级排版")
        return false
    end
    self:_mark_reader_busy(6)
    return self:_reader_open_native_page("KOReader 高级排版",function()
        ui:handleEvent(Event:new("ShowConfigMenu"))
        return true
    end,back_callback or function() self:_show_reader_font_panel() end)
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
        self:_show_standalone_menu("正文字体",items,{native_input=true,reader_context=true,on_home=function() return self:return_to_miuread_home("reader surface") end,on_close=back_callback})
        return true
    end
    for _,method in ipairs({"onShowFontMenu","onShowFontFaceMenu"}) do
        if type(font[method])=="function" then
            return self:_reader_open_native_page("正文字体",function()
                local ok=pcall(font[method],font)
                return ok
            end,back_callback)
        end
    end
    self:info("当前 KOReader 版本暂时无法单独打开字体列表")
    return false
end
function Plugin:_show_reader_spacing_panel(back_callback)
    local return_to_spacing=function() self:_show_reader_spacing_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="行距与页边距",
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
                {title="行距预设",rows={
                    {label="紧凑",value="100%",checked=current==100,keep_open=true,callback=function() self:_reader_set_line_spacing(100) end},
                    {label="标准",value="120%",checked=current==120,keep_open=true,callback=function() self:_reader_set_line_spacing(120) end},
                    {label="舒展",value="140%",checked=current==140,keep_open=true,callback=function() self:_reader_set_line_spacing(140) end},
                }},
                {title="页边距",rows={
                    {label="页边距与复杂版式",value="KOReader 高级排版",value_bold=true,callback=function() self:_show_reader_typeset_menu(return_to_spacing) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_weight_panel(back_callback)
    local return_to_weight=function() self:_show_reader_weight_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="字体粗细与对齐",
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
                {title="粗细预设",rows={
                    {label="较细",value="-0.5",checked=math.abs(current+.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(-.5) end},
                    {label="默认",value="0",checked=math.abs(current)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(0) end},
                    {label="较粗",value="0.5",checked=math.abs(current-.5)<.01,keep_open=true,callback=function() self:_reader_set_font_weight(.5) end},
                }},
                {title="对齐与深入设置",rows={
                    {label="段落对齐、字距与高级选项",value="KOReader 高级排版",value_bold=true,callback=function() self:_show_reader_typeset_menu(return_to_weight) end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_thought_font_size_label()
    local level=tostring((self.store:preferences().thoughts or {}).font or "standard")
    local labels={small="小",standard="标准",large="大",xlarge="特大"}
    return labels[level] or labels.standard
end

function Plugin:_set_thought_font_size(level)
    local allowed={small=true,standard=true,large=true,xlarge=true}
    level=allowed[tostring(level or "")] and tostring(level) or "standard"
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.font=level
    self.store:save_preferences(p)
    if ThoughtNativePopup and type(ThoughtNativePopup.refresh_font)=="function" then
        pcall(ThoughtNativePopup.refresh_font,self:_thought_font_size(level),self:_thought_font_name(p.thoughts))
    end
    self:toast("评论字号已设为："..self:_thought_font_size_label(),2)
    return true
end

function Plugin:_toggle_thought_follow_body_font()
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
    self.store:save_preferences(p)
    return true
end

function Plugin:_show_reader_comment_settings(back_callback)
    local return_to_comments=function() self:_show_reader_comment_settings(back_callback) end
    ReaderSettingsDialog.show{
        title="评论显示",
        subtitle=function()
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
                {label="评论字体跟随正文",value=follow and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:_toggle_thought_follow_body_font() end},
                {label="固定字体",value=self:_thought_font_face_label(prefs),enabled=not follow,callback=function()
                    self:_show_standalone_menu("评论字体",self:thought_font_face_menu(),{native_input=true,reader_context=true,on_home=function() return self:return_to_miuread_home("reader surface") end,on_close=return_to_comments})
                end},
                {label="小",value=level=="small" and "已选择" or "",checked=level=="small",keep_open=true,callback=function() self:_set_thought_font_size("small") end},
                {label="标准",value=level=="standard" and "已选择" or "",checked=level=="standard",keep_open=true,callback=function() self:_set_thought_font_size("standard") end},
                {label="大",value=level=="large" and "已选择" or "",checked=level=="large",keep_open=true,callback=function() self:_set_thought_font_size("large") end},
                {label="特大",value=level=="xlarge" and "已选择" or "",checked=level=="xlarge",keep_open=true,callback=function() self:_set_thought_font_size("xlarge") end},
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
    local current=self:_current_book_record()
    local title=current and current.book and current.book.title or nil
    if not title or title=="" then
        local path=self:_current_document_path()
        title=path and path:match("([^/]+)$") or "正在阅读"
    end
    local percent=self:_reader_progress_percent()
    local progress=percent and (tostring(math.floor(percent+.5)).."%") or "位置未知"
    local status=progress.." · "..tostring(self:progress_sync_label())
    return tostring(title),status,progress,percent
end

function Plugin:_reader_record_recent_action(key)
    key=tostring(key or "")
    if key=="" or key=="home" or key=="toc" or key=="progress" or key=="font" or key=="sync" or key=="comment_font" then return false end
    local reader,preferences=self:_reader_preferences()
    local recent={key}
    for _,name in ipairs(reader.recent_actions or {}) do
        name=tostring(name or "")
        if name~="" and name~=key then recent[#recent+1]=name end
        if #recent>=6 then break end
    end
    reader.recent_actions=recent
    self:_save_reader_preferences(reader,preferences)
    return true
end

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

function Plugin:_reader_show_bookmarks(back_callback)
    local bookmark=self.ui and self.ui.bookmark or nil
    if not bookmark then self:info("当前 KOReader 版本暂时无法直接打开书签"); return false end
    return self:_reader_open_native_page("书签与标注",function()
        for _,method in ipairs({"onShowBookmark","onShowBookmarks","showBookmarks"}) do
            if type(bookmark[method])=="function" then
                local ok=pcall(bookmark[method],bookmark)
                if ok then return true end
            end
        end
        return false
    end,back_callback or function() self:show_reader_control_center("tools") end)
end
function Plugin:_reader_show_search(back_callback)
    local search=self.ui and self.ui.search or nil
    if not search then self:info("当前 KOReader 版本暂时无法直接打开全文搜索"); return false end
    return self:_reader_open_native_page("全文搜索",function()
        for _,method in ipairs({"onShowSearchDialog","onShowSearch","showSearchDialog"}) do
            if type(search[method])=="function" then
                local ok=pcall(search[method],search)
                if ok then return true end
            end
        end
        return false
    end,back_callback or function() self:show_reader_control_center("tools") end)
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
    end,back_callback or function() self:show_reader_control_center("reading") end)
end
function Plugin:_show_reader_font_panel(back_callback)
    local return_to_font=function() self:_show_reader_font_panel(back_callback) end
    ReaderSettingsDialog.show{
        title="字体与排版",
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
                {title="快速排版",rows={
                    {label="正文字体",value=self:_reader_font_label(),callback=function() self:_show_reader_font_face_menu(return_to_font) end},
                    {label="行距与页边距",value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%",callback=function() self:_show_reader_spacing_panel(return_to_font) end},
                    {label="字体粗细与对齐",value=self:_reader_font_weight_label(),callback=function() self:_show_reader_weight_panel(return_to_font) end},
                    {label="评论显示",value=self:_thought_font_size_label(),callback=function()
                        self:_show_reader_comment_settings(return_to_font)
                    end},
                }},
                {title="高级",rows={
                    {label="KOReader 高级排版",value="页边距、字距与复杂版式",value_bold=true,callback=function() self:_show_reader_typeset_menu(return_to_font) end},
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
                {title="同步状态",rows={
                    {label="当前状态",value=self:progress_sync_label(),value_bold=true,keep_open=true,callback=function() self:show_sync_status(false) end},
                    {label="自动同步阅读进度",value=sync.progress_enabled~=false and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:toggle_progress_sync() end},
                    {label="自动同步阅读时间",value=sync.time_enabled==true and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:toggle_time_sync() end},
                    {label="同步成功提醒",value=self:_sync_success_notice_enabled() and "已开启" or "已关闭",keep_open=true,callback=function() self:toggle_sync_success_notice() end},
                }},
                {title="立即操作",rows={
                    {icon="⇧",label="上传当前阅读进度",value="执行",value_bold=true,keep_open=true,callback=function() self:upload_local_progress(true) end},
                    {icon="⇩",label="读取云端阅读进度",value="执行",value_bold=true,keep_open=true,callback=function() self:manual_sync() end},
                    {icon="◉",label="同步诊断",value="进入",callback=function()
                        self:_show_standalone_menu("同步诊断",self:sync_diagnostics_menu(),{native_input=true,reader_context=true,on_home=function() return self:return_to_miuread_home("reader surface") end,on_close=return_to_sync})
                    end},
                }},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_current_book_panel(back_callback)
    self:_show_standalone_menu("当前书籍",self:current_book_menu(),{native_input=true,reader_context=true,on_home=function() return self:return_to_miuread_home("reader surface") end,on_close=back_callback})
    return true
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
    end,back_callback or function() self:show_reader_control_center("device") end)
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
        on_back=back_callback or function() self:show_reader_control_center("display") end,
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

function Plugin:_reader_control_item(key,label,icon,callback,options)
    options=options or {}
    return {
        label=label,
        icon=icon,
        value=options.value,
        value_bold=options.value_bold,
        arrow=options.arrow,
        enabled=options.enabled~=false,
        callback=function()
            self:_reader_record_recent_action(key)
            return callback()
        end,
    }
end

function Plugin:_reader_control_categories()
    local function back_to(category) return function() self:show_reader_control_center(category) end end
    local reading={
        {title="阅读导航",items={
            self:_reader_control_item("toc","目录","☰",function() return self:_show_reader_toc(back_to("reading")) end),
            self:_reader_control_item("progress","阅读进度","◴",function() return self:_show_reader_progress_control(back_to("reading")) end),
            self:_reader_control_item("position","页面跳转","→",function() return self:_show_reader_position_jump(back_to("reading")) end),
            self:_reader_control_item("back_location","返回上一位置","↶",function() return self:_reader_go_back_location() end,{arrow=false}),
            self:_reader_control_item("bookmark","书签","▯",function() return self:_reader_show_bookmarks(back_to("reading")) end),
            self:_reader_control_item("history","阅读历史","◷",function() return self:_reader_show_history(back_to("reading")) end),
        }},
        {title="书籍",items={
            self:_reader_control_item("current_book","当前书籍","□",function() return self:_show_reader_current_book_panel(back_to("reading")) end),
            self:_reader_control_item("home",self:_home_enabled() and "返回觅阅主页" or "打开觅阅书架","⌂",function()
                if self:_home_enabled() then return self:return_to_miuread_home() end
                return self:show_shelf(false,false,"account")
            end),
        }},
    }
    local layout={
        {title="快速排版",items={
            self:_reader_control_item("font","字体与字号","Aa",function() return self:_show_reader_font_panel(back_to("layout")) end),
            self:_reader_control_item("spacing","行距与页边距","≡",function() return self:_show_reader_spacing_panel(back_to("layout")) end,{value=tostring(math.floor(self:_reader_line_spacing_value()+.5)).."%"}),
            self:_reader_control_item("weight","字体粗细与对齐","T",function() return self:_show_reader_weight_panel(back_to("layout")) end,{value=self:_reader_font_weight_label()}),
            self:_reader_control_item("comments","评论显示","✎",function() return self:_show_reader_comment_settings(back_to("layout")) end),
        }},
        {title="显示与高级",items={
            self:_reader_control_item("page_display","页面显示","▤",function() return self:_show_reader_page_display_panel(back_to("layout")) end),
            self:_reader_control_item("typeset","KOReader 高级排版","⋯",function() return self:_show_reader_typeset_menu(back_to("layout")) end),
        }},
    }
    local display_items={
        self:_reader_control_item("page_display","页面显示","▤",function() return self:_show_reader_page_display_panel(back_to("display")) end),
        self:_reader_control_item("refresh_rate","刷新频率","↻",function() return self:_reader_cycle_refresh_rate() end,{value=self:_reader_refresh_rate_label(),arrow=false}),
        self:_reader_control_item("night","夜间模式","☾",function() return self:_home_toggle_night() end,{value=self:_reader_night_label(),arrow=false}),
        self:_reader_control_item("rotation","屏幕方向","↻",function() return self:_home_rotate() end,{value=self:_reader_rotation_label(),arrow=false}),
        self:_reader_control_item("full_refresh","全屏刷新","◉",function() return self:_home_full_refresh() end,{arrow=false}),
    }
    if Device:hasFrontlight() then
        table.insert(display_items,2,self:_reader_control_item("frontlight","前光与色温","☼",function() return self:_show_reader_frontlight_panel(back_to("display")) end,{value=tostring(math.floor((self:_reader_frontlight_value() or 0)+.5))}))
    end
    local display={{title="页面与屏幕",items=display_items}}
    local tools={
        {title="阅读工具",items={
            self:_reader_control_item("search","全文搜索","⌕",function() return self:_reader_show_search(back_to("tools")) end),
            self:_reader_control_item("bookmark","书签与标注","▯",function() return self:_reader_show_bookmarks(back_to("tools")) end),
            self:_reader_control_item("history","跳转历史","◷",function() return self:_reader_show_history(back_to("tools")) end),
            self:_reader_control_item("comments","评论显示","✎",function() return self:_show_reader_comment_settings(back_to("tools")) end),
        }},
        {title="觅阅工具",items={
            self:_reader_control_item("sync","阅读同步","⇅",function() return self:_show_reader_sync_panel(back_to("tools")) end),
            self:_reader_control_item("current_book","当前书籍","□",function() return self:_show_reader_current_book_panel(back_to("tools")) end),
            self:_reader_control_item("downloads","下载管理","⇩",function() return self:show_downloads(back_to("tools")) end),
        }},
    }
    local device_items={
        self:_reader_control_item("wifi","Wi-Fi","wifi",function() return self:_reader_wifi_settings(back_to("device")) end),
        self:_reader_control_item("rotation","屏幕方向","↻",function() return self:_home_rotate() end,{value=self:_reader_rotation_label(),arrow=false}),
        self:_reader_control_item("full_refresh","全屏刷新","◉",function() return self:_home_full_refresh() end,{arrow=false}),
    }
    if Device:hasFrontlight() then
        device_items[#device_items+1]=self:_reader_control_item("frontlight","前光","☼",function() return self:_show_reader_frontlight_panel(back_to("device")) end,{value=tostring(math.floor((self:_reader_frontlight_value() or 0)+.5))})
    end
    if Device:canSuspend() then
        device_items[#device_items+1]=self:_reader_control_item("sleep","休眠","◐",function() return self:_home_sleep() end,{arrow=false})
    end
    local device={
        {title="设备",items=device_items},
        {title="系统与高级",items={
            self:_reader_control_item("koreader_menu","KOReader 高级菜单","☰",function() return self:_show_koreader_reader_menu(back_to("device")) end),
            self:_reader_control_item("home",self:_home_enabled() and "返回觅阅主页" or "觅阅书架","⌂",function()
                if self:_home_enabled() then return self:return_to_miuread_home() end
                return self:show_shelf(false,false,"account")
            end),
        }},
    }
    return {
        {key="reading",label="阅读",sections=reading},
        {key="layout",label="排版",sections=layout},
        {key="display",label="显示",sections=display},
        {key="tools",label="工具",sections=tools},
        {key="device",label="设备",sections=device},
    }
end

function Plugin:show_reader_control_center(initial_category)
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    local center,err=ReaderControlCenter.show{
        title="全部阅读功能",
        initial_category=initial_category or "reading",
        categories=self:_reader_control_categories(),
        on_back=function() self:show_reader_quick_panel() end,
        on_home=function() return self:return_to_miuread_home("reader surface") end,
    }
    if not center then
        logger.warn("[MiuRead][ReaderControlCenter] unavailable",tostring(err or "unknown"))
        return false
    end
    return true
end

function Plugin:show_reader_more_panel()
    return self:show_reader_control_center("reading")
end

function Plugin:_reader_panel_definitions(progress)
    local home_label=self:_home_enabled() and "返回主页" or "觅阅书架"
    return {
        toc={key="toc",icon="☰",label="目录",detail="章节导航",callback=function() self:_show_reader_toc() end},
        progress={key="progress",icon="◴",label="阅读进度",detail=progress,callback=function() self:_show_reader_progress_control() end},
        font={key="font",icon="Aa",label="字体排版",detail="字号 "..self:_reader_font_size_label(),callback=function() self:_show_reader_font_panel() end},
        frontlight={key="frontlight",icon="☼",label="前光",detail=Device:hasFrontlight() and "亮度与色温" or "设备不支持",enabled=Device:hasFrontlight(),callback=function() self:_show_reader_frontlight_panel() end},
        sync={key="sync",icon="⇅",label="阅读同步",detail=self:progress_sync_label(),callback=function() self:_show_reader_sync_panel() end},
        comment_font={key="comment_font",icon="A✎",label="评论字号",detail=self:_thought_font_size_label(),callback=function()
            self:_show_reader_comment_settings(function() self:show_reader_quick_panel() end)
        end},
        page_display={key="page_display",icon="▤",label="页面显示",detail="状态栏与刷新",callback=function() self:_show_reader_page_display_panel() end},
        home={key="home",icon="⌂",label=home_label,detail=self:_home_enabled() and "退出阅读" or "打开书架",callback=function()
            if self:_home_enabled() then self:return_to_miuread_home() else self:show_shelf(false,false,"account") end
        end},
        typeset={key="typeset",icon="⋯",label="高级排版",detail="KOReader",callback=function() self:_show_reader_typeset_menu(function() self:show_reader_quick_panel() end) end},
        current_book={key="current_book",icon="□",label="当前书籍",detail=self:_current_book_record() and "详情与修复" or "文件未识别",callback=function() self:_show_reader_current_book_panel(function() self:show_reader_quick_panel() end) end},
        downloads={key="downloads",icon="⇩",label="下载管理",detail=self:_download_status_label(),callback=function() self:show_downloads(function() self:show_reader_quick_panel() end) end},
        full_refresh={key="full_refresh",icon="↻",label="全屏刷新",detail="清除残影",callback=function() self:_home_full_refresh() end},
        koreader_menu={key="koreader_menu",icon="☰",label="KOReader 高级菜单",detail="兼容入口",callback=function() self:_show_koreader_reader_menu(function() self:show_reader_quick_panel() end) end},
        sleep={key="sleep",icon="◐",label="休眠",detail="设备休眠",enabled=Device:canSuspend(),callback=function() self:_home_sleep() end},
    }
end

function Plugin:show_reader_quick_panel()
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    local title,status,progress,percent=self:_reader_toolbar_title()
    local reader=self:_reader_preferences()
    local definitions=self:_reader_panel_definitions(progress)
    local buttons={}
    for _,key in ipairs(reader.quick_order or READER_QUICK_ITEM_ORDER) do
        local source=definitions[key]
        if reader.quick_items[key]==true and source then
            local item_key=key
            local item={}
            for name,value in pairs(source) do item[name]=value end
            local callback=source.callback
            item.callback=function()
                self:_reader_record_recent_action(item_key)
                return callback()
            end
            buttons[#buttons+1]=item
        end
        if #buttons>=6 then break end
    end
    local panel,err=ReaderToolbar.show{
        title=reader.show_title~=false and title or "阅读快捷面板",
        subtitle=reader.show_status~=false and status or "",
        progress_percent=percent,
        columns=3,
        buttons=buttons,
        recent_title="最近使用",
        recent_buttons=self:_reader_recent_buttons(),
        footer_action={label="全部阅读功能  ›",callback=function() self:show_reader_control_center("reading") end},
        on_home=function() return self:return_to_miuread_home("reader surface") end,
        on_swipe_down=function()
            -- 首次下滑打开觅阅面板后，再次从顶部下滑直接进入 KOReader 原生菜单
            return self:_show_koreader_reader_menu(function() self:show_reader_quick_panel() end)
        end,
    }
    if not panel then
        logger.warn("[MiuRead][ReaderToolbar] unavailable",tostring(err or "unknown"))
        return false
    end
    logger.info("[MiuRead][ReaderToolbar] opened")
    return true
end

function Plugin:_close_miuread_transients()
    HomeQuickPanel.close()
    ReaderToolbar.close()
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
            local activation=native_menu.activation_menu
                or (G_reader_settings and G_reader_settings:readSetting("activate_menu")) or "swipe_tap"
            if activation~="swipe" then return plugin:show_reader_quick_panel() end
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
        if self.download_task then self.download_task:resume("page_transition") end
        logger.info("[MiuRead][Transition] complete",tostring(reason or "surface ready"),
            "generation=",tostring(generation))
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
    if snapshot.lifecycle~="closed" or not snapshot.filemanager then return false end
    READER_CLOSE.state="home_restoring"
    self:_ensure_reader_transition_guard("stable reader close")
    self:_close_miuread_transients()
    self:_set_foreground("home_pending")

    local shown=false
    if HomeView.is_shown() then
        HomeView.unpark(true)
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
    self:_resume_pending_post_reader_work("home restored after stable close",.45)
    self:_finish_page_transition(.8,"home restored after stable close")
    READER_CLOSE.state="completed"
    logger.info("[MiuRead][ReaderClose] home restored",
        "generation=",tostring(generation),"reason=",tostring(reason or READER_CLOSE.reason or "close"))
    self:_clear_reader_return(generation,"home restored")
    return true
end

function Plugin:_schedule_reader_close_settle(path,session_generation,reason)
    local generation=self:_begin_reader_return(reason or "document closed",path,false,session_generation)
    READER_CLOSE.close_event_received=true
    if READER_CLOSE.state~="native_surface_waiting" then READER_CLOSE.state="document_closed" end
    return self:_schedule_reader_return_finish(generation,.10,reason or "document closed")
end

function Plugin:_show_miuread_home_now(force_scan,from_refresh,quiet,refresh_kind)
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
    -- The visual home is removed while ReaderUI owns the screen, but the
    -- reader-origin token must survive so an explicit return can rebuild it.
    if not self:_active_reader_ui() then
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
    end
    persist_home_session()

    if force_scan==true then self:_home_reset_local_metadata() end
    local miuread_rows=self:_home_miuread_rows()
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

    local home=self:_home_preferences()
    local hero=self:_home_recent_book(miuread_rows,local_rows,account_rows)
    if hero then
        hero=U.copy(hero)
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
        hero.on_tap=function() self:_home_open_book(hero) end
    end

    local sections={
        account={title="微信书架",rows=account_rows,empty="这里还没有微信书架内容"},
        generated={title="已下载",rows=miuread_rows,empty="这里还没有已下载书籍"},
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

    HOME_SESSION.lockscreen_recent_enabled=home.lockscreen_recent~=false
    HOME_SESSION.screensaver_file=hero and hero.cover_path or nil
    local view,err=HomeView.show({
        title="觅阅",
        status_line=self:_home_status_line(),
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
        download_notice=self:_home_download_notice(),
        alerts=self:_home_alerts(),
        lockscreen_enabled=home.lockscreen_recent~=false,
        screensaver_file=hero and hero.cover_path or nil,
        on_quick_panel=function() self:show_home_quick_panel() end,
        on_account=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end,
        on_menu=function() self:show_home_menu() end,
        on_back=function() return self:_home_handle_back() end,
        on_empty_account=function() self:_home_open_section(active) end,
        on_open_book=function(book) self:_home_open_book(book) end,
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
    self:_set_foreground("home")
    self._home_refresh_pending=false
    if active=="local" then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and self._home_active_section=="local" then self:_home_ensure_local_inline_loaded() end
        end)
    end
    if self._thought_index_pause_path then os.remove(self._thought_index_pause_path) end

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
    self:_home_schedule_local_metadata(metadata_targets)
    self:_home_schedule_remote_covers(cover_targets)
    local hero_needs_network = hero and (
        U.trim(tostring(hero.description or hero.intro or hero.summary or ""))==""
        or U.trim(tostring(hero.category or ""))==""
        or U.trim(tostring(hero.publisher or ""))==""
        or U.trim(tostring(hero.published_date or ""))==""
        or U.trim(tostring(hero.isbn or ""))==""
    )
    if hero_needs_network and home.network_metadata~=false then
        -- Network metadata is a low-priority opt-in job. Give the home screen
        -- time to become idle before issuing any external request.
        UIManager:scheduleIn(20,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_schedule_network_metadata(hero,false) end
        end)
    end

    if not from_refresh then
        self:_home_scan_local(force_scan==true)
        -- Remote shelves are shown from cache at startup. A network refresh is
        -- performed only from the explicit refresh action.
    end
    if home.background_thought_index==true and not force_scan then UIManager:scheduleIn(20,function()
        if HomeView.is_shown() and not self._home_refreshing then self:_start_thought_index_maintenance() end
    end) end
    return true
end

function Plugin:show_miuread_home(force_scan,from_refresh)
    local lifecycle=self:_reader_lifecycle_state()
    if lifecycle~="closed" then return self:return_to_miuread_home() end
    return self:_show_miuread_home_now(force_scan,from_refresh)
end

function Plugin:_ensure_filemanager_base(file,opts)
    opts=type(opts)=="table" and opts or {}
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
    local shown,err=xpcall(function() FileManager:showFiles(dir,selected) end,debug.traceback)
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
        HomeView.unpark(true)
        HomeView.raise(true)
        UIManager:setDirty(HomeView.current(),"ui")
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
        persist_home_session()
        self:_set_foreground("home")
        self:_close_reader_recovery_surface()
        self:_release_reader_transition_guard("home already visible")
        self:_resume_pending_post_reader_work("home revealed",.45)
        self:_finish_page_transition(.8,"home revealed")
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
        self:_resume_pending_post_reader_work("home restored",.45)
        self:_finish_page_transition(.8,"home rebuilt")
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
function Plugin:reverify_book_and_open(book_id,preferred_path)
    book_id=tostring(book_id or "")
    local record
    if preferred_path then local _,matched=self.store:identify_file(preferred_path,false); record=matched end
    record=record or self:_preferred_record(book_id) or self.access:first_record(book_id,nil,false)
    local path=preferred_path or (record and record.file)
    if not path then self:info("本地书籍记录不存在，请重新生成本书。"); return end
    local resolved=self.access:resolve_path(book_id,path)
    if resolved and U.file_exists(resolved) then self:_open_file_direct(resolved)
    else self:info("本地 EPUB 不存在，请重新生成本书。") end
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
    local items={}
    local records={{kind="clean",label="纯净版"},{kind="notes",label="划线与想法版"},
        {kind="range_clean",label="章节版 · 纯净版"},{kind="range_notes",label="章节版 · 划线与想法版"},
        {kind="preview_clean",label="试读版 · 纯净版"},{kind="preview_notes",label="试读版 · 划线与想法版"}}
    for _,entry in ipairs(records) do
        local record=self:_variant_exists(b.bookId,entry.kind)
        if record then
            items[#items+1]={text="打开"..entry.label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text="生成／更新书籍",callback=function() self:choose_download(b,nil,false) end}
    items[#items+1]={text="按章节下载",callback=function() self:chapters(b) end}
    if self:_has_range_variant(b.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(b) end}
    end
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理本书文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    items[#items+1]={text="书籍详情",callback=function() self:book_details(b) end}
    self:list(b.title,items)
end

function Plugin:book_details(b)
    self:online("details",function() local x=self.api:book(b.bookId); local z=normalize(x); self:info(z.title.."\n"..z.author.."\n\n"..tostring(x.intro or x.description or "")) end)
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
        self:info("剩余存储空间不足，无法安全开始下载。\n\n请先在“下载与存储”中清理本地文件。")
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
    local dialog
    local function launch(background,defer_until_reader_closed)
        if defer_until_reader_closed==true then
            if dialog then UIManager:close(dialog) end
            self:_queue_download(b,opt,open_after,{defer_until_reader_closed=true,reason="退出阅读后下载"})
            return
        end
        if self._download_launch_pending then
            self:toast("下载操作正在准备，请勿重复点击",2)
            return
        end
        self._download_launch_pending=true
        if dialog then UIManager:close(dialog) end
        self:status_toast("觅阅",tostring(b and b.title or "未命名")..
            (background and "正在准备后台下载" or "正在准备下载"),2)
        UIManager:scheduleIn(.20,function()
            self._download_launch_pending=false
            self:download(b,opt,open_after,nil,background)
        end)
    end
    local function begin_after_preflight(background)
        local active_reader=self:_active_reader_ui()~=nil
        if not active_reader then launch(background); return end
        local preferences=self.store:preferences()
        local policy=tostring(preferences.download_reader_policy or "ask")
        if policy=="allow" or preferences.download_reader_warning==false or not self:_notice_enabled("reader_download") then
            launch(background)
            return
        end
        if policy=="after_reading" then
            launch(true,true)
            return
        end
        if dialog then UIManager:close(dialog) end
        dialog=ButtonDialog:new{title="阅读时下载会增加耗电，并可能导致翻页、评论或菜单响应变慢。",title_align="center",buttons={
            {{text="继续后台下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true) end}},
            {{text="退出阅读后下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true,true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
    end
    local function start(background)
        if dialog then UIManager:close(dialog); dialog=nil end
        self:_download_preflight(function() begin_after_preflight(background) end)
    end
    dialog=ButtonDialog:new{title="下载方式",title_align="center",buttons={
        {{text="后台下载",callback=function() start(true) end}},
        {{text="留在当前页面下载",callback=function() start(false) end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:choose_download(b,limit,open_after,uid)
    local dialog
    local function choose_version(annotations)
        UIManager:close(dialog)
        self:choose_download_mode(b,{annotations=annotations,limit=limit,chapter_uid=uid},open_after)
    end
    dialog=ButtonDialog:new{
        title="下载《"..tostring(b.title or "未命名").."》",title_align="center",
        buttons={
            {{text="纯净版",callback=function() choose_version(false) end}},
            {{text="划线与想法版",callback=function() choose_version(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
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
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if runtime.dialog then runtime.dialog:set_state(state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    local home_percent=self:_download_percent(state)
    local home_mark=math.floor(home_percent/10)*10
    local home_stage=tostring(state and state.stage or "")
    if runtime.home_progress_mark~=home_mark or runtime.home_progress_stage~=home_stage then
        runtime.home_progress_mark=home_mark
        runtime.home_progress_stage=home_stage
        self:_notify_home_data_changed("section")
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
    self:_close_download_dialog()
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
                or (network_failed and "network" or (content_pending and "content_pending"
                or (validation_failed and "validation" or nil)))),
            wait_seconds=rate_limited and wait_seconds or nil,
        },true)
        self:_update_open_shelf_download_status(b.bookId,
            auth_required and "等待重新登录" or (rate_limited and "请求受限 · 稍后继续"
                or (network_failed and "等待网络 · 可继续" or "生成未完成")))
        self:_notify_home_data_changed("content")
        local first
        if auth_required then
            first="微信读书登录已失效。下载断点已经保留，请重新扫码登录后继续。"
        elseif rate_limited then
            first="微信读书暂时限制了请求频率。插件已停止继续请求，正文和断点均已保留，请稍后继续下载。"
        elseif network_failed then
            first="网络连接暂时中断。已完成章节和下载断点均已保留，网络恢复后可继续下载。"
        elseif content_pending then
            first="生成未完成，原文件和下载进度已保留。请稍后使用“生成／更新书籍”重试。"
        elseif validation_failed then
            first="生成的书籍校验未通过，原文件和下载进度已保留。请重试；若仍失败，请反馈日志。"
        else
            first=U.first_line(err)
        end
        if was_background then
            local toast_title=auth_required and "下载登录验证失败" or (rate_limited and "请求受限"
                or (network_failed and "等待网络" or "觅阅"))
            local toast_text=auth_required and "后台下载已暂停，重新扫码后自动继续"
                or (rate_limited and "已停止继续请求，下载断点已保留"
                or (network_failed and "下载断点已保留，网络恢复后可继续"
                or (content_pending and "生成未完成，原文件和进度已保留"
                or (tostring(b.title or "未命名").."下载未完成，进度已保留"))))
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
    if state.status=="annotation_pending" then return "后台下载 · 生成未完成" end
    if state.status=="completed" then return "后台下载 · 已完成" end
    if state.status=="failed" and state.auth_required==true then return "后台下载 · 等待重新登录" end
    if state.status=="failed" and state.error_kind=="network" then return "后台下载 · 等待网络，可继续" end
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
function Plugin:_close_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not runtime.dialog then return end
    local dialog=runtime.dialog
    runtime.dialog=nil
    pcall(function() dialog:close() end)
end
function Plugin:_send_download_to_background()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then return end
    runtime.background=true
    self:_close_download_dialog()
    self.download_task:set_backgrounded(true)
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:status_toast("觅阅",tostring(runtime.book.title or "未命名").."已转入后台下载",3)
end
function Plugin:_show_active_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then self:show_download_status(); return end
    if runtime.dialog then return end
    runtime.background=false
    self.download_task:set_backgrounded(false)
    local dialog
    dialog=DownloadProgress:new{
        title="正在下载《"..tostring(runtime.book.title or "未命名").."》",
        on_cancel=function() if self.download_task then self.download_task:cancel() end end,
        on_background=function() self:_send_download_to_background() end,
    }
    runtime.dialog=dialog
    dialog:show()
    if runtime.last_state then dialog:set_state(runtime.last_state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
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
    self.access:unlock_book(book.bookId,"all")

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
    elseif state.status=="annotation_pending" then lines[#lines+1]="生成未完成，请稍后重新生成"
    elseif state.status=="pending_install" then
        if state.annotation_pending==true then lines[#lines+1]="新版本已下载完成"
        elseif state.annotation_fallback==true then lines[#lines+1]="新版本已下载完成"
        else lines[#lines+1]="新版本已下载完成" end
    elseif state.status=="failed" and state.auth_required==true then lines[#lines+1]="等待重新登录"
    elseif state.status=="failed" and state.error_kind=="rate_limit" then lines[#lines+1]="请求频率受限，稍后可继续"
    elseif state.status=="failed" and state.error_kind=="network" then lines[#lines+1]="网络中断，断点已保留"
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
    local current=tostring(self:_current_document_path() or "")
    self.store:reload()
    local pending=self.store:prune_pending_installs()
    if #pending==0 then return false end
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
        return true
    end
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
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    opt=U.copy(opt or {})
    local requested_id=tostring(b and (b.bookId or b.book_id) or "")
    if from_queue~=true and requested_id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==requested_id then
                self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
                return false
            end
        end
    end
    if self.download_task and self.download_task:busy() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    local stored=self.store:download_state()
    if stored.status=="active" and self:_recover_download_state() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，完成后再开始下载。"); return end
    if b and b.bookId and tostring(b.bookId)~="" then
        self.store:save_book(b.bookId,{book_id=tostring(b.bookId),title=b.title,author=b.author,
            content_type=b.content_type,updated_at=os.time()})
    end
    local prefs=self.store:preferences()
    opt.images=prefs.images
    opt.active_document_path=self:_current_document_path()
    local runtime={book=U.copy(b),options=U.copy(opt),last_state={stage="prepare",current=0,total=1,percent=0,chapter=b.title or ""},background=start_in_background==true,dialog=nil,started_at=os.time(),open_after=open_after==true,done=done,notified_milestones={}}
    self._download_runtime=runtime
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:_notify_home_data_changed("content")
    local ok,err=self.download_task:start(b,opt,
        function(state) self:_on_download_progress(runtime,state) end,
        function(result) self:_finish_download_runtime(runtime,result) end)
    if not ok then
        self._download_runtime=nil
        self.store:clear_download_state()
        self:_notify_home_data_changed("content")
        if from_queue then self:_queue_download(b,opt,open_after) end
        self:info("无法启动下载任务：\n"..tostring(err))
        return false
    end
    runtime.task=self.download_task:descriptor()
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    if runtime.background then
        self.download_task:set_backgrounded(true)
        self:_update_open_shelf_download_status(b.bookId,"生成中 0%")
        if self.store:preferences().download_notice_enabled~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名").."已转入后台下载",3)
        end
    else
        self:_show_active_download_dialog()
    end
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
    self:online("range-extend",function()
        local _,rows=self.downloader:catalog(b.bookId)
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
    end)
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
    local record=self:_current_book_record()
    if not record or not record.book then self:info("当前不是觅阅生成的书籍。") return end
    local b={bookId=record.book.book_id,title=record.book.title,author=record.book.author,cover=record.book.cover}
    local wanted=math.max(1,tonumber(count) or 1)
    self:online("current-chapter-download",function()
        local _,rows=self.downloader:catalog(b.bookId)
        rows=rows or {}
        local first=self:_current_catalog_index(record,rows)
        if not first or not rows[first] then self:info("暂时无法确定当前章节，请使用“选择章节范围”。") return end
        local last=math.min(#rows,first+wanted-1)
        self:_choose_range_version(b,rows,first,last,false)
    end)
end

function Plugin:_chapter_state_text(book_id,chapter)
    local uid=tostring(chapter.chapterUid or chapter.uid or "")
    local states={}
    for _,entry in ipairs({{"clean","纯净版"},{"notes","划线与想法版"}}) do
        local record=self.store:chapter_variant(book_id,uid,entry[1])
        if record and record.file and U.file_exists(record.file) then states[#states+1]=entry[2] end
    end
    return #states>0 and table.concat(states," · ") or tostring(chapter.wordCount or "")
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
    self:online("chapters",function()
        local _,rows=self.downloader:catalog(b.bookId)
        rows=rows or {}
        local items={
            {text="下载单章",callback=function()
                self:_chapter_list_menu(b,rows,"选择单章 · "..tostring(b.title or "未命名"),function(_,chapter) self:chapter_menu(b,chapter) end)
            end},
            {text="下载章节范围",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first)
                    self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
                end)
            end},
            {text="从指定章节开始",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first) self:_range_count_menu(b,rows,first) end)
            end},
        }
        self:list("章节下载 · "..tostring(b.title or "未命名"),items,"没有可用章节")
    end)
end
function Plugin:chapter_menu(b,ch)
    local uid=tostring(ch.chapterUid or ch.uid or "")
    local clean=self.store:chapter_variant(b.bookId,uid,"clean")
    local notes=self.store:chapter_variant(b.bookId,uid,"notes")
    if not (clean and clean.file and U.file_exists(clean.file)) then clean=nil end
    if not (notes and notes.file and U.file_exists(notes.file)) then notes=nil end
    local items={}
    for _,entry in ipairs({{record=clean,label="纯净版"},{record=notes,label="划线与想法版"}}) do
        local record=entry.record
        if record then
            local label=DownloadResult.variant_label(entry.label,record)
            items[#items+1]={text="阅读"..label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text=(clean or notes) and "更新本章" or "下载本章",callback=function() self:choose_download(b,nil,true,uid) end}
    if clean or notes then items[#items+1]={text="删除本章文件",callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or uid) end} end
    self:list(ch.title or uid,items)
end

function Plugin:_open_file_direct(path)
    path=normalized_reader_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return false end
    sync_home_session()
    local now=os.time()
    local opening=tostring(HOME_SESSION.opening_file or "")
    local opening_age=now-(tonumber(HOME_SESSION.opening_at) or 0)
    if opening~="" and opening_age>=0 and opening_age<12 then
        if opening==path then
            logger.info("[MiuRead][Reader] duplicate open ignored",opening)
            self:status_toast("正在打开书籍","请稍候",2)
            return true
        end
        logger.info("[MiuRead][Reader] replacing pending open target",opening,"with",path)
    end
    HOME_SESSION.opening_file=path
    HOME_SESSION.opening_at=now
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
    if not path then self:info(_("No cached file")); return end
    local book=self.store:identify_file(path,false)
    local book_id=book and tostring(book.book_id or book.bookId or "") or ""
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
        or name:match("^download%-progress%-.+%.json$")
        or name:match("^download%-result%-.+%.json$")
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
    local dialog
    dialog=ButtonDialog:new{title="清理下载与缓存",title_align="center",buttons={
        {{text="清理下载断点与临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
        {{text="清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:show_downloads(back_callback)
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
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除这本书",post_text="同时删除本机想法、评论与记录",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end
function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
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
    self.store:save_preferences(p)
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
            self.sync:test_upload(function(ok,result)
                if ok then self:status_toast("阅读时间测试","30 秒已成功上传",4)
                else self:info("阅读时间测试失败\n\n"..tostring(result or "未知错误")) end
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

function Plugin:sync_menu()
    return {
        {text="同步状态",callback=function() self:show_sync_status(false) end},
        {text="自动同步阅读进度",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="自动同步阅读时间",checked_func=function() return self.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="同步成功提醒",checked_func=function() return self:_sync_success_notice_enabled() end,keep_menu_open=true,callback=function() self:toggle_sync_success_notice() end},
        {text="立即上传当前进度",callback=function() self:upload_local_progress(true) end},
        {text="重新读取云端进度",callback=function() self:manual_sync() end},
        {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
    }
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
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled; self.store:save_preferences(p)
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
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled; self.store:save_preferences(p)
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
            self:info("Wi-Fi 尚未恢复。\n\n本地阅读时间和位置已保留，联网后会重新确认并补传。")
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
    local target=math.floor((tonumber(position.progress) or 0)+.5)
    self.sync:begin_progress_sync("主动上传本机阅读进度")
    self:_save_progress_state(id,"uploading","正在上传本机阅读进度",target,nil)
    if manual then self:status_toast("阅读进度同步","正在上传 "..target.."%……",3) end
    local started=self.sync:upload_progress(function(ok,result,submitted)
        if not ok then
            self:_save_progress_state(id,"upload_failed","阅读进度上传失败",target,nil)
            self.sync:end_progress_sync("阅读进度上传失败")
            if manual then self:info("阅读进度上传失败\n\n"..tostring(result or "未知错误")) end
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
    elseif s.state=="paused" then time_text="暂时失败，稍后重新计时"
    elseif type(s.last_error)=="string" and (tonumber(s.consecutive_failures) or 0)>=2 then time_text="暂时失败，稍后重试"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end
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
function Plugin:on_read_report_failure(err)
    if Http.is_auth_error(err) then
        self:_mark_auth_problem("read_report",err,false)
        self:status_toast("阅读同步","登录验证暂时失败，本次时间不补传；稍后重新计时",5)
        return
    end
    self:status_toast("阅读同步","连续同步失败，本次时间不补传；稍后重试",5)
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
    local lines={"发现书籍数据需要修复。"}
    for _,issue in ipairs((report and report.issues) or {}) do
        lines[#lines+1]=""
        lines[#lines+1]=tostring(issue.detail or issue.title or "书籍数据异常")
    end
    lines[#lines+1]=""
    lines[#lines+1]="修复只处理本地数据，不会重新下载整本书。"
    return table.concat(lines,"\n")
end

function Plugin:_run_book_repair(context,report,force)
    context=context or self:_repair_context()
    if not context or not context.book then self:info("当前没有可修复的觅阅书籍"); return false end
    if self.repair_async and self.repair_async:busy() then self:toast("已有修复任务正在进行"); return false end
    local title=tostring((context.book or {}).title or context.title or "当前书籍")
    self:toast("正在修复《"..title.."》",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("book-repair",function()
        return repair:repair(context,report,force==true)
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            local message=tostring(result and result.error or "修复任务未完成")
            self:_record_repair_history({title=title,book_id=(context.book or {}).book_id},"失败")
            self:info("修复失败：\n"..message)
            return
        end
        local value=result.value
        self:_record_repair_history(value,value.ok and "已完成" or "部分失败")
        self:_save_repair_state(value.book_id,{
            signature=value.signature,
            status=value.ok and "fixed" or "failed",
            checked_at=os.time(),
        })
        if value.ok then
            self:info("修复完成，可以继续阅读。")
        else
            self:info("部分内容没有修复成功，请在“修复记录”中查看后重试。")
        end
    end,180)
    if not started then self:info("无法开始修复：\n"..tostring(err or "未知原因")); return false end
    return true
end

function Plugin:_show_book_repair_prompt(context,report)
    if self._repair_prompt_open then return end
    self._repair_prompt_open=true
    local book_id=tostring(report and report.book_id or ((context.book or {}).book_id or ""))
    local signature=tostring(report and report.signature or self.book_repair:signature(context))
    UIManager:show(ConfirmBox:new{
        text=self:_repair_message(report),
        ok_text="一键修复",
        cancel_text="暂不处理",
        ok_callback=function()
            self._repair_prompt_open=false
            self:_run_book_repair(context,report,false)
        end,
        cancel_callback=function()
            self._repair_prompt_open=false
            self:_save_repair_state(book_id,{signature=signature,status="ignored",checked_at=os.time()})
        end,
    })
end

function Plugin:_schedule_current_book_repair_check(current,urgent)
    local prefs=self:_repair_preferences()
    if prefs.auto_check==false then return false end
    local context=self:_repair_context(current)
    if not context or not context.book then return false end
    local book_id=tostring((context.book or {}).book_id or (context.book or {}).bookId or "")
    if book_id=="" then return false end
    local signature=self.book_repair:signature(context)
    local previous=self:_repair_state()[book_id]
    if urgent~=true and type(previous)=="table" and tostring(previous.signature or "")==signature
        and (previous.status=="ok" or previous.status=="fixed" or previous.status=="ignored") then
        return false
    end
    if self.repair_async and self.repair_async:busy() then return false end
    local repair=self.book_repair
    local delay=urgent==true and .05 or 1.4
    UIManager:scheduleIn(delay,function()
        local active=self:_current_document_path()
        if tostring(active or "")~=tostring(context.path or "") then return end
        if self.repair_async:busy() then return end
        local started=self.repair_async:run("book-repair-check",function()
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
        end,90)
        if not started then logger.dbg("[MiuRead][Repair] check deferred") end
    end)
    return true
end

function Plugin:repair_current_book(confirmed)
    local context=self:_repair_context()
    if not context then self:info("请先打开一本觅阅书籍"); return end
    if confirmed~=true and self:_active_reader_ui() and self:_notice_enabled("repair_while_reading") then
        local dialog
        dialog=ButtonDialog:new{title="修复会重新检查当前书籍，期间评论、菜单或翻页可能暂时变慢。",title_align="center",buttons={
            {{text="继续修复",callback=function() UIManager:close(dialog); self:repair_current_book(true) end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("repair_while_reading",false); self:repair_current_book(true) end}},
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
    if self.repair_async:busy() then self:toast("已有检查或修复任务正在进行"); return end
    self:toast("正在检查已下载书籍",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("scan-book-repair",function()
        return repair:scan_downloaded()
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
        end
        local scan=result.value
        if tonumber(scan.affected or 0)==0 then
            self:info("检查完成，没有发现需要修复的已下载书籍。")
            return
        end
        UIManager:show(ConfirmBox:new{
            text="发现 "..tostring(scan.affected).." 本书需要修复。\n\n是否一键修复？",
            ok_text="全部修复",
            cancel_text="暂不处理",
            ok_callback=function()
                if self.repair_async:busy() then self:toast("已有修复任务正在进行"); return end
                local ok_start,error_start=self.repair_async:run("repair-downloaded-books",function()
                    return repair:repair_scan(scan)
                end,function(fixed)
                    if not fixed or fixed.ok~=true or type(fixed.value)~="table" then
                        self:info("批量修复失败：\n"..tostring(fixed and fixed.error or "未知原因")); return
                    end
                    local value=fixed.value
                    self:_record_repair_history({title="批量修复",book_id=""},value.ok and "已完成" or "部分失败")
                    self:info(value.ok and "修复完成。" or "部分书籍修复失败，请稍后重试。")
                end,300)
                if not ok_start then self:info("无法开始批量修复：\n"..tostring(error_start or "未知原因")) end
            end,
        })
    end,180)
    if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
end

function Plugin:clear_invalid_comment_indexes()
    if self.repair_async:busy() then self:toast("已有检查或修复任务正在进行"); return end
    local repair=self.book_repair
    local started,err=self.repair_async:run("clear-invalid-comment-indexes",function()
        return repair:clear_invalid_downloaded_indexes()
    end,function(result)
        if result and result.ok==true then
            Thoughts.clear_memory_cache()
            self:info("已清理失效的评论索引。需要时会自动重新建立。")
        else
            self:info("清理失败：\n"..tostring(result and result.error or "未知原因"))
        end
    end,120)
    if not started then self:info("无法开始清理：\n"..tostring(err or "未知原因")) end
end

function Plugin:show_repair_history()
    local history=self.store:get("book_repair_history",{})
    local items={}
    for _,row in ipairs(type(history)=="table" and history or {}) do
        items[#items+1]={
            text=tostring(row.title or "书籍"),
            post_text=os.date("%m-%d %H:%M",tonumber(row.at) or os.time()).." · "..tostring(row.status or ""),
            enabled=false,
        }
    end
    if #items==0 then items[1]={text="还没有修复记录",enabled=false} end
    self:list("修复记录",items)
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
        {text="自动检查书籍问题",checked_func=function()
            return (self.store:preferences().repair or {}).auto_check~=false
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.repair=p.repair or {}
            p.repair.auto_check=p.repair.auto_check==false
            self.store:save_preferences(p)
        end},
        {text="修复当前书籍",callback=function() self:repair_current_book() end},
        {text="扫描已下载书籍",callback=function() self:scan_downloaded_books_for_repair() end},
        {text="重新扫描本地书籍与封面",callback=function() self:show_miuread_home(true) end},
        {text="清理失效评论索引",callback=function() self:clear_invalid_comment_indexes() end},
        {text="修复记录",callback=function() self:show_repair_history() end},
        {text="重置检查结果",callback=function()
            self.store:set("book_repair_state",{})
            self:toast("已重置书籍检查结果")
        end},
    }
end

function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end




function Plugin:_thought_display_label()
    return "轻量列表 · 点击翻页"
end

function Plugin:_toggle_home_network_metadata()
    local home,preferences=self:_home_preferences()
    home.network_metadata=home.network_metadata==false
    self:_save_home_preferences(home,preferences)
    if home.network_metadata and self._home_hero then self:_home_schedule_network_metadata(self._home_hero,true) end
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

function Plugin:local_library_settings_menu()
    local home=self:_home_preferences()
    local mode=tostring(home.local_library_mode or "direct")
    local items={
        {text="本地书库模式",post_text=self:_local_library_mode_label(mode),sub_item_table_func=function() return self:local_library_mode_menu() end},
    }
    for _,root in ipairs(self:_home_local_roots(false)) do
        local path=root.path
        items[#items+1]={
            text=tostring(root.name or LocalLibrary.basename(path)),post_text=root.enabled~=false and "已启用" or "已停用",
            sub_item_table_func=function() return self:local_root_settings_menu(path) end,
        }
    end
    if #self:_home_local_roots(false)==0 then items[#items+1]={text="尚未添加本地书库目录",enabled=false} end
    items[#items+1]={text="添加本地书库目录",post_text="选择文件夹",callback=function() self:add_local_root_dialog() end}

    if mode=="direct" then
        items[#items+1]={text="进入文件夹时检查当前层",checked_func=function()
            return self:_home_preferences().local_check_on_open~=false
        end,keep_menu_open=true,callback=function()
            local current,preferences=self:_home_preferences(); current.local_check_on_open=current.local_check_on_open==false
            self:_save_home_preferences(current,preferences)
        end}
        items[#items+1]={text="刷新根目录",post_text="只读取当前层",callback=function() self:_home_scan_local(true) end}
        items[#items+1]={text="清除目录浏览缓存",callback=function()
            self.store:set("home_local_tree_index",{version=1,dirs={}})
            if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            self:toast("目录缓存已清除",2)
        end}
    else
        local cache=self:_home_local_cache()
        local scanned=tonumber(cache.scanned_at or 0) or 0
        items[#items+1]={text="扫描本地书库",post_text=scanned>0 and ("上次："..os.date("%m-%d %H:%M",scanned)) or "尚未扫描",callback=function()
            if self:_home_scan_local(true) then self:toast("正在后台更新本地书库",2)
            else self:toast("当前暂时无法开始扫描",2) end
        end}
        items[#items+1]={text="清除本地书库索引",callback=function()
            self.store:set("home_local_index",{books={},scanned_at=0,roots={}})
            if HomeView.is_shown() then self:_notify_home_data_changed("content") end
            self:toast("本地书库索引已清除",2)
        end}
    end
    return items
end

function Plugin:display_settings_menu()
    local home=self:_home_preferences()
    local size_labels={compact="紧凑",standard="标准",large="大号"}
    return {
        {text="页面布局",post_text=(home.layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return self:home_layout_settings_menu() end},
        {text="显示大小",post_text=size_labels[home.display_size] or "标准",sub_item_table_func=function() return self:home_display_size_menu() end},
        {text="首页书架来源",post_text="选择显示项目",sub_item_table_func=function() return self:home_source_settings_menu() end},
        {text="本地书籍",post_text=self:_local_library_mode_label(home.local_library_mode),sub_item_table_func=function() return self:local_library_settings_menu() end},
        {text="主页快捷工具",post_text="最多六项",sub_item_table_func=function() return self:home_action_settings_menu() end},
        {text="下滑工具栏",post_text="设备与 KOReader",sub_item_table_func=function() return self:home_panel_settings_menu() end},
        {text="网络补全图书信息",post_text="微信读书详情、Google Books、Open Library",checked_func=function() return self:_home_preferences().network_metadata~=false end,keep_menu_open=true,callback=function() self:_toggle_home_network_metadata() end},
        {text="主页锁屏显示最近阅读封面",checked_func=function() return self:_home_preferences().lockscreen_recent~=false end,keep_menu_open=true,callback=function() self:_toggle_home_lockscreen() end},
        {text=home.local_library_mode=="direct" and "刷新本地根目录" or "刷新本地书库与封面",callback=function()
            if home.local_library_mode=="direct" then self:_home_scan_local(true)
            else self:_confirm_library_scan(function() self:show_miuread_home(true) end) end
        end},
        {text="显示书架封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
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
        self:info("无法修改低内存模式：\n"..tostring(result_or_error))
        return
    end
    local result=result_or_error or {}
    if enabled then
        self:info("低内存模式已开启。\n\n完整退出并重新启动 KOReader 后生效。PDF、漫画和快速跳页可能稍慢。")
    elseif result.external_change then
        self:info("低内存模式已关闭。\n\n检测到缓存设置已被其他配置修改，因此没有覆盖当前值。完整重启 KOReader 后生效。")
    else
        self:info("低内存模式已关闭，原有缓存设置已恢复。\n\n完整退出并重新启动 KOReader 后生效。")
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
        text="恢复开启低内存模式前的缓存设置？\n\n恢复后需要完整重启 KOReader。卸载觅阅前建议先执行恢复。"
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
        text="低内存模式适合下载大书时容易闪退或卡死的设备。\n\n开启后会减少 KOReader 页面缓存，PDF、漫画和快速跳页可能稍慢。需要完整重启 KOReader 后生效。",
        ok_text="开启",
        ok_callback=function() self:_set_memory_mode(true) end,
    })
end

function Plugin:download_settings_menu()
    local memory_status=self.memory_mode:status()
    local policy=tostring(self.store:preferences().download_reader_policy or "ask")
    local policy_label=policy=="allow" and "允许后台下载" or (policy=="after_reading" and "退出阅读后下载" or "每次询问")
    local items={
        {text="阅读时下载策略",post_text=policy_label,sub_item_table_func=function() return self:download_reader_policy_menu() end},
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提醒",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
        {text="低内存模式",post_text=self:_memory_mode_label(),checked_func=function() return (self.store:preferences().memory_mode or {}).enabled==true end,callback=function() self:toggle_memory_mode() end},
    }
    if memory_status.enabled or memory_status.residual then
        items[#items+1]={text="恢复缓存设置",callback=function() self:restore_memory_mode() end}
    end
    items[#items+1]={text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end}
    items[#items+1]={text="下载管理与清理",callback=function() self:show_downloads() end}
    return items
end
function Plugin:mp_settings_menu()
    return {
        {text="下载文章图片",checked_func=function() return self.store:preferences().mp_images==true end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_global_cache_menu() end},
    }
end
function Plugin:account_sync_settings_menu()
    local rows={
        {text="账号状态",post_text=self:_account_status_label(),callback=function() self:show_account_status() end},
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=function() self.auth_flow:start() end},
    }
    if self:logged_in() then rows[#rows+1]={text="退出登录",callback=function() self:confirm_logout() end} end
    for _,row in ipairs(self:sync_menu()) do rows[#rows+1]=row end
    return rows
end

function Plugin:more_settings_menu()
    return {
        {text="提醒与确认",sub_item_table_func=function() return self:notice_settings_menu() end},
        {text="书籍检查与修复",sub_item_table_func=function() return self:book_repair_settings_menu() end},
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
    return {
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
        {text="首页与书架",post_text="布局、来源与快捷面板",sub_item_table_func=function() return self:display_settings_menu() end},
        {text="阅读界面",post_text="快捷面板与阅读状态",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end},
        {text="评论与标注",post_text=self:_thought_display_label(),sub_item_table_func=function() return self:thought_font_settings_menu() end},
        {text="账号与同步",post_text=self:progress_sync_label(),sub_item_table_func=function() return self:account_sync_settings_menu() end},
        {text="下载与存储",post_text=self:_download_settings_summary(),sub_item_table_func=function() return self:download_settings_menu() end},
        {text="公众号阅读",sub_item_table_func=function() return self:mp_settings_menu() end},
        {text="更多设置",sub_item_table_func=function() return self:more_settings_menu() end},
    }
end

function Plugin:thought_font_settings_menu()
    local prefs=self.store:preferences().thoughts or {}
    return {
        {text="评论字体跟随正文",checked_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font==true
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
            self.store:save_preferences(p)
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
function Plugin:thought_font_face_menu()
    local rows={
        {text="KOReader 默认字体（最快）",radio=true,menu_item_id="__default__",checked_func=function()
            return U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))==""
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=""; p.thoughts.follow_body_font=false
            self.store:save_preferences(p); self:toast("评论字体已设为 KOReader 默认字体")
        end},
    }
    local ok,faces=pcall(function()
        local cre=require("document/credocument"):engineInit()
        return cre and cre.getFontFaces and cre.getFontFaces() or {}
    end)
    if not ok or type(faces)~="table" then
        rows[#rows+1]={text="无法读取设备字体列表",enabled=false}
        return rows
    end
    local unique,list={},{}
    for _,face in ipairs(faces) do
        face=U.trim(tostring(face or ""))
        if face~="" and not unique[face] then unique[face]=true; list[#list+1]=face end
    end
    table.sort(list,function(a,b) return a:lower()<b:lower() end)
    for _,face in ipairs(list) do
        local selected=face
        rows[#rows+1]={text=selected,radio=true,menu_item_id=selected,checked_func=function()
            return tostring((self.store:preferences().thoughts or {}).font_face or "")==selected
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=selected; p.thoughts.follow_body_font=false
            self.store:save_preferences(p); self:toast("评论字体已设为："..selected)
        end}
    end
    rows.max_per_page=7
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
    local p=self.store:preferences(); p.update=U.merge(p.update or {},update or {}); self.store:save_preferences(p)
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
        self:online("install",function()
            local path=self.updater:download(manifest)
            local ok,err=self.updater:install(path,manifest)
            if ok then self:_after_update_installed(manifest)
            else self:info("更新失败：\n"..tostring(err)) end
        end)
    end})
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
    self._auto_update_check_running=true
    update.last_attempt_at=now
    self:_save_update_preferences(update)
    UIManager:scheduleIn(.05,self:safe("auto-update",function()
        local ok,manifest,err=pcall(self.updater.check,self.updater)
        self._auto_update_check_running=false
        if not ok then err=manifest; manifest=nil end
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
    end))
    return true
end
function Plugin:check_update(automatic)
    if automatic then return self:maybe_auto_check_update(true) end
    self:online("update",function()
        self:status_toast("更新","正在检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本……",3)
        local ok,manifest,err=pcall(self.updater.check,self.updater)
        if not ok then err=manifest; manifest=nil end
        local _,update=self:_update_preferences()
        update.last_attempt_at=os.time()
        if manifest then update.last_success_at=os.time() end
        self:_save_update_preferences(update)
        if not manifest then self:info("检查更新失败：\n"..tostring(err)); return end
        self:_present_update(manifest,false)
    end)
end
function Plugin:show_about()
    local memory_note=""
    local memory_status=self.memory_mode:status()
    if memory_status.enabled then
        memory_note="\n\n低内存模式当前已开启。卸载觅阅前，请在“下载与存储”中恢复缓存设置。"
    elseif memory_status.residual then
        memory_note="\n\n检测到外部或遗留的低内存设置，可在“下载与存储”中检查并恢复。"
    end
    self:info(Config.NAME.." "..self.version
        .."\n\n为 KOReader 提供微信读书书架、书籍下载、阅读同步与本地书籍管理。"
        .."\n\n支持阅读进度、划线、想法、评论及阅读记录等功能。"
        .."\n\n许可证：AGPL-3.0-only。"
        ..memory_note
        .."\n\n非官方社区项目，与微信读书及 KOReader 无官方隶属或合作关系。")
end
function Plugin:onExit()
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
    self:_show_reader_typeset_menu()
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
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end
function Plugin:_start_thought_index_maintenance()
    local home=self:_home_preferences()
    if home.background_thought_index~=true then return false end
    if self:_home_background_blocked() then
        self._home_resume_pending_work=self._home_resume_pending_work or {}
        self._home_resume_pending_work.thoughts=true
        return false
    end
    if not self.thought_index_async or not self.ui or self.ui.document then return false end
    if self:_home_enabled() and not HomeView.is_shown() then return false end
    local now=os.time()
    if THOUGHT_MAINTENANCE.running==true or now-(tonumber(THOUGHT_MAINTENANCE.last_at) or 0)<120 then return false end
    if self.download_task and self.download_task:busy() then
        UIManager:scheduleIn(10,function() self:_start_thought_index_maintenance() end)
        return false
    end
    if self.thought_index_async:busy() or not self.thought_index_async:available() then return false end
    local data_dir=self.store.data_dir
    local pause_path=self._thought_index_pause_path
    os.remove(pause_path)
    THOUGHT_MAINTENANCE.running=true
    THOUGHT_MAINTENANCE.last_at=now
    local started,err=self.thought_index_async:run("thought-index-maintenance",function()
        local ok,ffi=pcall(require,"ffi")
        if ok and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,15) end)
        end
        return Thoughts.build_missing_indexes(data_dir,pause_path,100000)
    end,function(result)
        THOUGHT_MAINTENANCE.running=false
        THOUGHT_MAINTENANCE.last_at=os.time()
        if not result or result.ok~=true or type(result.value)~="table" then
            logger.warn("[MiuRead][Thoughts] background index maintenance failed",
                tostring(result and result.error or "unknown"))
            return
        end
        local value=result.value
        logger.info("[MiuRead][Thoughts] background index maintenance",
            "checked=",tostring(value.checked or 0),"built=",tostring(value.built or 0),
            "failed=",tostring(value.failed or 0),"paused=",tostring(value.paused==true))
    end,900)
    if not started then
        THOUGHT_MAINTENANCE.running=false
        logger.dbg("[MiuRead][Thoughts] index maintenance deferred",tostring(err))
    end
    return started==true
end

function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    -- Scale once and keep proportional gaps. The former fixed 26 px ceiling
    -- collapsed every choice to the same size on high-DPI Kindle screens.
    local standard=math.max(15,Device.screen:scaleBySize(15))
    local sizes={
        small=math.max(12,math.floor(standard*.78+.5)),
        standard=standard,
        large=math.floor(standard*1.24+.5),
        xlarge=math.floor(standard*1.50+.5),
    }
    sizes.large=math.max(sizes.standard+3,sizes.large)
    sizes.xlarge=math.max(sizes.large+3,sizes.xlarge)
    return sizes[tostring(level or "standard")] or sizes.standard
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
    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end

    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end

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
    self:_mark_reader_busy(2)
    UIManager:scheduleIn(1.2,function() collectgarbage("step",48) end)
end

function Plugin:_close_active_thought_popup(reason)
    local popup=self._thought_popup
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    self._thought_popup=nil
    self._thought_popup_busy=false
    self:_clear_thought_popup_marker()
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
    local started=os.clock()
    local popup,notice
    local ok,unexpected=xpcall(function()
        self:_write_thought_popup_marker("lookup",info)
        local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        if not group then notice=tostring(err or "没有想法内容"); return end
        local prefs=self.store:preferences().thoughts or {}
        local function on_close() self:_finish_thought_popup(generation) end
        self:_write_thought_popup_marker("build",info,{mode="native_rounded_layered"})
        local source,comments,count,native_cache_hit=Thoughts.native_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        if tostring(source or "")=="" and #(comments or {})==0 then notice="没有想法内容"; return end
        popup=ThoughtNativePopup.show{
            source_text=source,
            comments=comments,
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
        logger.info("[MiuRead][ThoughtPopup] opened",
            "mode=","native_rounded_layered",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(count or 0),
            "source=",token and token.index_hit and "compact_index" or "chapter_cache",
            "cache=",token and token.cache_hit and "hit" or "miss",
            "native_cache=",native_cache_hit and "hit" or "miss",
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
        if not popup then error("评论窗口未能加入界面") end
        self._thought_popup=popup
        self:_write_thought_popup_marker("visible",info,{elapsed_ms=math.floor((os.clock()-started)*1000+.5)})
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
    local info=Thoughts.parse_href(href); if not info then return false end
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

function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    return self:_show_thought_href(href)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="miuread_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end

function Plugin:on_sync_record_ready(current)
    self:_teardown_thought_tap()
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        local record=current.record or {}
        local variant=tostring(current.variant or record.variant or "")
        if record.annotation_requested==true or variant:find("notes",1,true) then
            self:_setup_thought_tap()
        end
        UIManager:scheduleIn(1.0,function()
            local active=self.sync and self.sync.current
            if self.ui and self.ui.document and active and tostring(active.book.book_id)==book_id then
                self.store:mark_last_read(book_id,path)
            end
        end)
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
function Plugin:onReaderReady()
    HOME_SESSION.home_restore_generation=(tonumber(HOME_SESSION.home_restore_generation) or 0)+1
    HOME_SESSION.home_restore_active=false
    self:_cancel_reader_close_settle("reader ready")
    if READER_CLOSE.state~="idle" then
        self:_clear_reader_return(READER_CLOSE.generation,"reader ready cancelled stale return")
        self:_finish_page_transition(1.0,"reader ready")
    else
        HOME_SESSION.return_requested=false
        HOME_SESSION.return_session_generation=0
        HOME_SESSION.return_request_file=nil
    end
    HOME_SESSION.reader_session_generation=(tonumber(HOME_SESSION.reader_session_generation) or 0)+1
    HOME_SESSION.reader_session_active=true
    HOME_SESSION.reader_session_file=normalized_reader_file(self:_current_document_path())
    self._reader_session_generation=HOME_SESSION.reader_session_generation
    local ready_session=self._reader_session_generation
    self._home_reader_transition=false
    self:_close_reader_recovery_surface()
    self:_close_home_for_reader("reader ready")
    self:_ensure_reader_transition_guard("reader ready")
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    -- Give EPUB opening and the first visible page priority over a background
    -- book generation task. The worker resumes automatically after this window.
    self:_mark_reader_busy(8)
    logger.info("[MiuRead][Sync] reader ready","session=",tostring(self._reader_session_generation or 0))
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
        local record,variant
        if path then
            local _book
            _book,record,variant=self.store:identify_file(path,false)
        end
        if record and (record.annotation_requested==true or tostring(variant or record.variant or ""):find("notes",1,true)) then
            self:_setup_thought_tap()
            logger.info("[MiuRead][ThoughtPopup] local tap ready before cloud sync")
        end
    end)
    if self._thought_index_pause_path then U.atomic_write(self._thought_index_pause_path,"1",true) end
    self:_teardown_thought_tap()
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
        self._reader_sync_ready_task=nil
        if self.ui and self.ui.document
            and tonumber(HOME_SESSION.reader_session_generation or 0)==ready_session
            and not reader_close_active() then self.sync:on_reader_ready() end
    end
    self._reader_sync_ready_task=task
    -- Let KOReader paint the first page and restore input before identity and
    -- cloud-progress work begins. Local comment taps are already installed by
    -- the next-tick block above, so this does not delay reading interaction.
    UIManager:scheduleIn(.35,task)
end
function Plugin:onSetDimensions()
    self:_close_miuread_transients()
    if reader_close_active() then
        logger.info("[MiuRead][Navigation] dimensions deferred during reader close",
            tostring(READER_CLOSE.state))
        return true
    end
    self:_cancel_reader_close_settle("dimensions changed")
    if READER_CLOSE.state=="completed" or READER_CLOSE.state=="failed" then
        self:_clear_reader_return(READER_CLOSE.generation,"dimensions changed after close")
    end
    if self.ui and self.ui.document then
        self:_set_foreground("reader")
        self._reader_dimension_generation=(tonumber(self._reader_dimension_generation) or 0)+1
        local generation=self._reader_dimension_generation
        if self._reader_dimension_task then
            UIManager:unschedule(self._reader_dimension_task)
            self._reader_dimension_task=nil
        end
        local last_w,last_h,stable,attempts=nil,nil,0,0
        local task
        task=function()
            if self._reader_dimension_task~=task or generation~=self._reader_dimension_generation then return end
            attempts=attempts+1
            local sw,sh=Device.screen:getWidth(),Device.screen:getHeight()
            local rotation=Device.screen.getRotationMode and Device.screen:getRotationMode() or nil
            if sw==last_w and sh==last_h then stable=stable+1 else last_w,last_h,stable=sw,sh,0 end
            if stable>=1 or attempts>=8 then
                self._reader_dimension_task=nil
                if self.ui and self.ui.document and HOME_SESSION.suspended~=true then
                    local changed=sw~=self._reader_dimension_width or sh~=self._reader_dimension_height
                        or rotation~=self._reader_dimension_rotation
                    self._reader_dimension_width,self._reader_dimension_height=sw,sh
                    self._reader_dimension_rotation=rotation
                    if changed then
                        self:_install_reader_menu_bridge()
                        self:_install_reader_quick_panel_zone()
                        UIManager:setDirty("all","full")
                    end
                end
                return
            end
            UIManager:scheduleIn(.08,task)
        end
        self._reader_dimension_task=task
        UIManager:scheduleIn(.06,task)
    end
end
function Plugin:onScreenResize() return self:onSetDimensions() end
function Plugin:onRotation() return self:onSetDimensions() end
function Plugin:onPageUpdate(page)
    self:_mark_reader_busy(3)
    self.sync:on_page(page)
end
function Plugin:onAnnotationsModified()
    self._reader_checkpoint_dirty=true
    -- KOReader emits this for new, edited and deleted highlights/notes. Save
    -- once after a short quiet period so a later crash cannot discard a whole
    -- reading session, without writing on every pen movement.
    self:_schedule_reader_checkpoint("annotations_modified",2.0)
end
function Plugin:onSuspend()
    self._miuread_suspended=true
    HOME_SESSION.suspended=true
    HOME_SESSION.foreground_before_suspend=HOME_SESSION.foreground
    HOME_SESSION.navigation_before_suspend=self:_navigation_state()
    self:_set_foreground("suspended")
    StatusToast.set_blocked(true)
    StatusToast.close()
    self:_close_miuread_transients()
    self:_cancel_reader_close_settle("suspend")
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
    self:_mark_reader_busy(10)
    self._suspended_at=os.time()
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

    local reader_active=self.ui and self.ui.document
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
        -- refresh, scans, covers, metadata and index maintenance remain behind
        -- the interaction barrier until the page has been released and idle.
        self:_home_begin_resume(slept)
        UIManager:scheduleIn(1.0,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then
                self:_resume_pending_post_reader_work("resume home",.35)
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
        self.sync:clear_verified("resume_recheck")
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
function Plugin:_resume_pending_post_reader_work(reason,delay)
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if phase=="" or self._post_reader_work_task then return false end
    if self:_active_reader_ui() or ReaderTransitionGuard.is_shown() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        return false
    end
    return self:_schedule_post_reader_work(reason or "surface ready",delay or .35)
end

function Plugin:_run_post_reader_work(generation)
    if generation~=(tonumber(HOME_SESSION.post_reader_work_generation) or 0) then return false end
    self._post_reader_work_task=nil
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if phase=="" then
        HOME_SESSION.post_reader_work_deferred_phase=nil
        return true
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
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not HomeView.is_shown() and not (ok_fm and FileManager and FileManager.instance) then
        logger.info("[MiuRead][Download] post-reader work waiting for stable surface",phase)
        local task
        task=function()
            if self._post_reader_work_task~=task then return end
            self._post_reader_work_task=nil
            self:_run_post_reader_work(generation)
        end
        self._post_reader_work_task=task
        UIManager:scheduleIn(.8,task)
        return false
    end
    if phase=="install" then
        HOME_SESSION.post_reader_work_deferred_phase=nil
        local ok,err=pcall(self._install_pending_downloads,self,true)
        if not ok then logger.warn("[MiuRead][Download] pending install failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase="queue"
        local task
        task=function()
            if self._post_reader_work_task~=task then return end
            self._post_reader_work_task=nil
            self:_run_post_reader_work(generation)
        end
        self._post_reader_work_task=task
        UIManager:scheduleIn(.5,task)
        return true
    end
    if phase=="queue" then
        HOME_SESSION.post_reader_work_deferred_phase=nil
        local ok,err=pcall(self._start_next_queued_download,self)
        if not ok then logger.warn("[MiuRead][Download] queued start failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase=nil
        return true
    end
    HOME_SESSION.post_reader_work_deferred_phase=nil
    HOME_SESSION.post_reader_work_phase=nil
    return true
end

function Plugin:_schedule_post_reader_work(reason,delay)
    if not HOME_SESSION.post_reader_work_phase then
        HOME_SESSION.post_reader_work_phase="install"
    end
    HOME_SESSION.post_reader_work_deferred_phase=nil
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
    UIManager:scheduleIn(math.max(0,tonumber(delay) or .8),task)
    logger.info("[MiuRead][Download] post-reader work scheduled",tostring(reason or "close"),tostring(HOME_SESSION.post_reader_work_phase))
    return true
end

function Plugin:onCloseDocument()
    self:_begin_page_transition("closing_reader")
    self:_ensure_reader_transition_guard("close document")
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint("close_document",true)
    end
    self:_mark_reader_busy(6)
    self:_close_active_thought_popup("document closed")
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    if READER_CLOSE.state=="idle" then self._home_reader_transition=false end
    local closing_path=tostring(self:_current_document_path() or "")
    local opening_path=tostring(HOME_SESSION.opening_file or "")
    -- During switchDocument the old ReaderUI closes while the target book is
    -- still opening. Keep that target guard until the new ReaderReady event.
    if opening_path=="" or opening_path==closing_path then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end
    self:_cancel_network_waits()
    if self.repair_async and self.repair_async.job and self.repair_async.job.label=="book-repair-check" then
        self.repair_async:cancel("document closed")
    end
    self._repair_prompt_open=false
    if self._thought_index_pause_path then os.remove(self._thought_index_pause_path) end
    if self._reader_active_path then os.remove(self._reader_active_path) end
    -- Keep the worker paused just long enough for the bookshelf to become
    -- responsive, then release the marker. Uploading the final reading tail is
    -- already delegated to the lightweight service and never awaited here.
    if self._reader_busy_path then
        local busy_path=self._reader_busy_path
        UIManager:scheduleIn(4,function() os.remove(busy_path) end)
    end
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    self:_teardown_thought_tap(); self._progress_prompted_book_id=nil; self._progress_check_running=false; self.sync:on_close()
    -- Keep post-close work pending until a non-reading surface is available.
    -- Opening another book quickly no longer drops installation or queue work.
    self:_schedule_post_reader_work("document closed",1.4)
    sync_home_session()
    HOME_SESSION.reader_session_active=false
    local session_generation=tonumber(HOME_SESSION.reader_session_generation) or 0
    local explicit_return=READER_CLOSE.state~="idle"
        and (self._miuread_return_requested==true or HOME_SESSION.return_requested==true)
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
            -- CloseDocument may be an internal switch or rebuild. Start the
            -- same lifecycle watcher; ReaderReady cancels it if a document
            -- comes back before a stable native surface is observed.
            self:_schedule_reader_close_settle(closing_path,session_generation,"document closed")
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
end
function Plugin:onFlushSettings()
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    self:_flush_reader_checkpoint("flush_settings",true)
    self:_flush_cover_index()
    self.store:flush()
end
return Plugin
