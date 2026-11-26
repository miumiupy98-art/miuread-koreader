-- Run the actual plugin entry points with a simulated chapter worker.
local function slice(path,first,last,env)
    local file=assert(io.open(path,"rb"))
    local source=file:read("*a")
    file:close()
    local a=assert(source:find(first,1,true))
    local b=assert(source:find(last,a+1,true))
    setfenv(assert(loadstring(source:sub(a,b-1))),setmetatable(env,{__index=_G}))()
end

local path="miuread.koplugin/main.lua"
local plugin={}
local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for k,v in pairs(value) do result[k]=copy(v) end
    return result
end
local env={
    Plugin=plugin,b4_content_only_options=copy,
    U={copy=copy,first_line=tostring,file_exists=function() return true end},
    reader_close_active=function() return false end,
    logger={warn=function() end},Http={is_auth_error=function() return false end},
    DownloadResult={failure_kind=function() return nil end},
    StatusToast={show=function(opts)
        assert(opts.timeout==0 and opts.title=="阅读")
        return {_close=function(widget) widget.closed=true end,opts=opts}
    end},
    require=function(name)
        assert(name=="miuread.download_coordinate_retry")
        return {key=function() end,remove=function() end}
    end,
}
slice(path,"function Plugin:_wait_for_online_chapter_slot(","function Plugin:_range_variant(",env)
slice(path,"function Plugin:_close_online_loading(","function Plugin:_on_download_progress(",env)
slice(path,"function Plugin:_restore_download_after_chapter(","function Plugin:_finish_download_runtime(",env)
local old={status="failed",title="Prior offline job"}
local function host()
    local h=setmetatable({notices={},writes={},queue=0,dialogs=0}, {__index=plugin})
    local state=copy(old)
    local worker={running=false}
    function worker:start(_,options,_,finish)
        self.options=options
        self.finish=finish
        self.running=true
        return true
    end
    function worker:descriptor() return {pid=10} end
    function worker:busy() return self.running end
    function worker:set_backgrounded(value) self.backgrounded=value end
    h.download_task=worker
    h.store={
        auth=function() return {login_session_id="session"} end,
        preferences=function() return {images=true} end,
        download_state=function() return state end,
        download_queue=function() return {} end,
        save_book=function() end,
        save_download_state=function(_,value) state=value end,
        clear_download_state=function() state={} end,
    }
    function h:require_login() return true end
    function h:logged_in() return true end
    function h:is_online() return true end
    function h:_network_radio_hint() return true end
    function h:_current_document_path() end
    function h:_download_resources_ready() return true end
    function h:_interactive_network_context() return {"original view"} end
    function h:_interactive_network_context_valid(ctx) return self.context_valid~=false and ctx[1]=="original view" end
    function h:_write_download_state(status) self.writes[#self.writes+1]=status end
    function h:_active_download_payload() return {} end
    function h:_notify_home_data_changed() self.dirty=true end
    function h:_show_active_download_dialog() self.dialogs=self.dialogs+1 end
    function h:_queue_download() self.queue=self.queue+1;return true end
    function h:status_toast(title,detail) self.notices[#self.notices+1]={title,detail} end
    function h:_merge_download_result(reply) return reply.value end
    function h:_friendly_remote_error(err) return err end
    function h:open_file(file) self.opened=file end
    function h:_switch_single_chapter_file(file,_,uid) self.opened=file;self.next_uid=uid end
    function h:_start_next_queued_download() end
    function h:_clear_chapter_advance_wait() self.cleared=true end
    return h
end
local book={bookId="id",title="Book"}
local h=host()
assert(h:download(book,{chapter_uid="7",read_online=true},true))
assert(h.download_task.options.prefetch and not h.download_task.options.prefetch_hidden and h.download_task.options.read_online)
assert(h.writes[1]=="prefetch" and #h.writes==1 and h.dialogs==0 and not h.dirty)
local first=h._download_runtime.online_loading
assert(first.opts.text=="正在加载正文…")
h:_update_online_loading(h._download_runtime,{stage="content",activity="image_archive_download"})
local images=h._download_runtime.online_loading
assert(first.closed and images.opts.text=="正在加载插图…")
h:_update_online_loading(h._download_runtime,{stage="content",activity="image_archive_download"})
assert(h._download_runtime.online_loading==images)
h:_finish_online_read(h._download_runtime,{ok=true,value={file="/cache/7-online.epub"}})
assert(images.closed and h.opened=="/cache/7-online.epub" and h.store:download_state().title==old.title)

h=host()
assert(h:download(book,{chapter_uid="8",chapter_continuous_open=true},true))
h:_finish_online_read(h._download_runtime,{ok=true,value={file="/cache/8-online.epub"}})
assert(h.next_uid=="8" and h.cleared and h.dialogs==0)

h=host()
assert(h:download(book,{chapter_uid="7",read_online=true},true))
h.context_valid=false
h:_finish_online_read(h._download_runtime,{ok=true,value={file="/cache/7-online.epub"}})
assert(not h.opened)
h.context_valid=true
h:_finish_online_read(h._download_runtime,{ok=false,error="Network failed"})
assert(h.notices[1][1]=="正文加载失败" and h.store:download_state().status=="failed")

h=host()
h.download_task.running=true
assert(not h:download(book,{chapter_uid="7",read_online=true},true))
assert(h.queue==0 and h.dialogs==0)
h.download_task.running=false
assert(h:download(book,{chapter_uid="7"},false))
assert(not h.download_task.options.prefetch and h.dialogs==1 and h.writes[1]=="active")

local scheduled
env.UIManager={scheduleIn=function(_,_,task) scheduled=task end}
env.monotonic_wall_time=function() return 1 end
h=host()
h.background_scheduler={active={key="home_cover_render"}}
h._download_resources_ready=function(self)
    if self.background_scheduler.active then return false,"background_busy" end
    return true
end
assert(h:download(book,{chapter_uid="7",read_online=true},true))
assert(scheduled and h._online_chapter_slot and not h.download_task.running)
scheduled()
assert(not h.download_task.running)
h.background_scheduler.active=nil
scheduled()
assert(h.download_task.running and not h._online_chapter_slot and h.queue==0)

-- Short taps turn comment pages; only an explicit long-press action opens replies.
local popup={}
slice("miuread.koplugin/miuread/thought_native_popup.lua","function NativePopup:onTapPage(",
    "function NativePopup:onSwipePage(",{NativePopup=popup})
local panel=setmetatable({popup_dimen={x=0,w=100},comments_dimen={x=0,w=100},
    on_replies_callback=function() end}, {__index=popup})
function panel:_change_page(delta) self.delta=delta;return true end
function panel:_handle_action() error("body tap accidentally opened replies") end
function panel:_comment_at_position() return {review_id="selected"} end
function panel:_show_action_menu(comment) self.selected=comment.review_id;return true end
local pos={x=75,notIntersectWith=function() return false end}
assert(panel:onTapPage(nil,{pos=pos}) and panel.delta==1)
pos.x=25
assert(panel:onTapPage(nil,{pos=pos}) and panel.delta==-1)
assert(panel:onHoldComment(nil,{pos=pos}) and panel.selected=="selected")
print("Online chapter loading, offline download UI, saved download state and comment gestures passed")

local cache_file="/cache/7-online.epub"
local repair_state={online_image_repair={book_id="id",uid="7",path=cache_file}}
local repair_record={file=cache_file,task_id="chapter-task",image_repair={login="session",version="4",items={{key="1"}}}}
local install_count,refresh_count=0,0
local repair_env={Plugin=plugin,HOME_SESSION=repair_state,U={copy=copy,file_exists=function() return true end,
    remove_tree=function() end,file_size=function() return 4096 end},
    EpubInstaller={install=function() install_count=install_count+1; return true end},
    require=function(name)
        if name=="miuread.online_cache" then return {matches=function() return true end,
            finished_at=function() return 100 end,mark_finished=function(_,_,_,_,when) assert(when==100) end} end
        if name=="miuread.api_transport" then return {preference=function() return "eink" end} end
        if name=="miuread.diagnostic_log" then return {record=function() end} end
        error(name)
    end,
}
slice(path,"function Plugin:_repair_closed_online_chapter(","function Plugin:_post_reader_work_needed(",repair_env)
local repair_host=host()
repair_host.store.temp_dir="/temp"
repair_host.interactive_network_async={busy=function() return false end}
repair_host._active_reader_ui=function(self) return self.reopened end
repair_host.store.chapter_variant=function() return copy(repair_record) end
repair_host.store.save_chapter_variant=function(_,_,_,_,record)
    refresh_count=refresh_count+1
    repair_record=record
end
repair_host._run_interactive_network=function(self,_,_,_,callback) self.image_callback=callback; return true end
local reply={ok=true,value={result={images={assets=2,required_missing=0},used={["1"]=1},remaining=0}}}
repair_host.reopened=true
assert(not repair_host:_repair_closed_online_chapter() and not repair_host.image_callback)
repair_host.reopened=false
assert(repair_host:_repair_closed_online_chapter())
repair_host.reopened=true
repair_host.image_callback(reply)
assert(install_count==0 and refresh_count==0)
repair_host.reopened=false
assert(repair_host:_repair_closed_online_chapter())
repair_host.image_callback(reply)
assert(install_count==1 and refresh_count==1 and repair_record.image_repair==nil)
assert(repair_record.image_summary.required_missing==0 and not repair_state.online_image_repair)

-- The online directory is built from the full E-Ink catalog, even when the
-- locally open EPUB contains only one of its chapters.
local current="/internal/book/1-online.epub"
local snapshot,display={}
local toc={store={}}
setmetatable(toc,{__index=plugin})
function toc.store:auth() return {login_session_id="session"} end
function toc.store:chapter_variant() end
function toc.store:hidden_prefetch_record() end
function toc:_current_document_path() return self.file or current end
function toc:_mark_reader_busy() end
function toc:_chapter_navigation_context() end
function toc:_chapter_uid_value(row) return tostring(row.uid or row.chapterUid or "") end
function toc:download(book,opts,open)
    assert(book.bookId=="one" and opts.chapter_continuous_open and open)
    self.target=opts.chapter_uid
    return true
end
local rows={{uid="1",title="First"},{uid="2",title="Second"},{uid="3",title="Third"}}
local outline={{title="Part one"},{uid="1",title="First",toc_level=2},
    {uid="2",title="Second",toc_level=2},{uid="3",title="Third",toc_level=2}}
function toc:_request_catalog(book,label,callback,opts)
    assert(book.bookId=="one" and label=="online-reader-toc" and opts.eink_only)
    self.fetches=(self.fetches or 0)+1
    return callback(rows,nil,nil,outline)
end
local toc_env={
    Plugin=plugin,HOME_SESSION=snapshot,reader_close_active=function() return false end,
    normalized_reader_file=function(path) return path end,
    U={trim=function(value) return value end},
    require=function(name)
        assert(name=="miuread.online_cache")
        return {reusable=function(record) return record~=nil end}
    end,
    ReaderTocDialog={show=function(opts) display=opts.items;return true end},
}
slice(path,"function Plugin:_remember_online_toc(","function Plugin:_show_reader_toc(",toc_env)
local view={path=current,book_id="one",book_record={},book={bookId="one"},current_uid="1"}
assert(toc:_show_online_reader_toc(view))
assert(#display==4 and not display[1].callback and display[2].current and display[3].depth==2)
assert(display[4].callback() and toc.target=="3")
assert(toc:_show_online_reader_toc(view) and toc.fetches==1)
toc.file="/different/document.epub"
assert(not display[3].callback() and toc.target=="3")
print("Full online table of contents, current chapter, arbitrary E-Ink jump and stale callback fence passed")
