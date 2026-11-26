-- Load only the reader actions with the same highlights/boxes contract as KOReader.
local plugin={}
local selected,public,changes,shown
local U={trim=function(text) return (text:gsub("^%s+",""):gsub("%s+$","")) end,
    first_line=tostring}
local env=setmetatable({Plugin=plugin,U=U,
    Device={screen={getWidth=function() return 600 end}},
    Thoughts={href=function(_,_,range) return range end},
    LocalAnnotationDatabase={annotation_id=function(_,item) return item.pos0 end},
    UIManager={scheduleIn=function(_,_,callback) callback() end},
},{__index=_G})
local f=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=f:read("*a")
f:close()
local function load(start,finish)
    local first=assert(source:find("function Plugin:"..start.."(",1,true))
    local last=assert(source:find("function Plugin:"..finish.."(",first,true))
    setfenv(assert(loadstring(source:sub(first,last-1))),env)()
end
load("_reader_annotation_index","_book_excerpt_context")
load("_reader_delete_annotation_note","_reader_confirm_annotation_action")
load("_reader_own_thoughts_at","_refresh_current_comment_overlay")
function plugin:_reader_annotation_type(item) return item.note and "thought" or "highlight" end
function plugin:_reader_annotation_changed(reason) changes=reason return true end
function plugin:_thoughts_enabled() return true end
function plugin:_reader_gesture_guard_active() return false end
function plugin:_reader_edge_guard_state() return false end
function plugin:_show_paragraph_thoughts(info) shown=info; return true end
function plugin:_reader_session_is_weread() return true end
function plugin:_personal_thought_rows()
    local note={local_id="x",review_id="r1",range="12-18",chapter_uid="1",content="Mine"}
    return {note},{note}
end
function plugin:info() end

local own={drawer="underscore",note="Mine",pos0="x",datetime="now"}
local other={drawer="underscore",pos0="y"}
local boxes={
    {index=1,rect={x=20,y=20,w=100,h=10}},
    {index=1,rect={x=20,y=20,w=110,h=10}},
    {index=2,rect={x=20,y=50,w=100,h=10}},
}
plugin.ui={
    annotation={annotations={own,other}},highlight={},
    view={highlight={visible_boxes=boxes},screenToPageTransform=function(_,pos) return pos end},
}
plugin._comment_overlay={enabled=true,hitTest=function(_,pos)
    local bounds=pos.y<40 and {left=20,right=120,top=20,text_bottom=30}
        or {left=20,right=120,top=50,text_bottom=60}
    return {book_id="book",chapter_uid="1",range=pos.y<40 and "10-25" or "40-60"},bounds
end}
assert(#plugin:_reader_own_thoughts_at({x=60,y=24})==1)
assert(plugin:_on_comment_overlay_tap({pos={x=60,y=32}}) and #shown.own==1)
assert(shown.own[1].review_id=="r1" and shown.range=="10-25" and not shown.own_only)
shown=nil
assert(plugin:_on_comment_overlay_tap({pos={x=60,y=54}}) and shown.range=="40-60" and #shown.own==0)
plugin._comment_overlay.hitTest=function() return nil end
function plugin:_current_thought_favorite_scope() return {book_id="book",chapter_uid="1"} end
assert(plugin:_on_comment_overlay_tap({pos={x=60,y=24}}) and shown.own_only and #shown.own==1)
plugin.ui.highlight.select_mode=true
assert(not plugin:_on_comment_overlay_tap({pos={x=60,y=24}}))

plugin.ui.bookmark={deleteItemNote=function(_,item) assert(item==own) end}
assert(not plugin:_reader_delete_annotation_note(own) and not changes)
plugin.ui.bookmark.deleteItemNote=function(_,item) item.note=nil end
local stale={note="Mine",drawer="underscore",pos0="x",datetime="now"}
assert(not plugin:_reader_delete_annotation_note(stale) and own.note=="Mine")
assert(plugin:_reader_delete_annotation_note(own))
assert(own.drawer and not own.note and changes=="annotation_delete_note")
plugin.ui.bookmark.removeItem=function() end
assert(not plugin:_reader_delete_annotation_item(own))
plugin.ui.bookmark.removeItem=function(_,item,index)
    assert(item==own and index==1)
    table.remove(plugin.ui.annotation.annotations,index)
end
assert(plugin:_reader_delete_annotation_item(own))
assert(#plugin.ui.annotation.annotations==1 and plugin.ui.annotation.annotations[1]==other)
package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["miuread.download_database"]={account_key=function(store) return store.account end}
package.loaded["miuread.json"]={encode=function(rows) return rows end,decode=function(rows) return rows end}
local files={}
package.loaded["miuread.util"]={
    read_file=function(path) return files[path] end,
    atomic_write=function(path,value) files[path]=value; return true end,
}
local Personal=require("miuread.personal_thoughts")
local store={account="alpha",book_cache_path=function(_,book) return book end,book_dir=function() end}
local remote={review_id="r1",chapter_uid="1",range="12-18",content="Phone",status="synced",updated_at=12}
assert(Personal.save(store,"book",{remote},20))
local snapshot=Personal.load(store,"book")
assert(snapshot.rows[1].content=="Phone")
store.account="beta"
assert(not Personal.load(store,"book"))
store.account="alpha"
local local_copy={kind="thought",present=true,remote_id="r1",local_id="x",sync_state="synced",
    note="Old",synced_note="Old",last_attempt_at=15}
local visible=Personal.combine({local_copy},snapshot)
assert(#visible==1 and visible[1].content=="Phone")
local_copy.chapter_uid,local_copy.range_key,local_copy.book_version="1","12-18",20
local incomplete={review_id="r1",chapter_uid="",range="",book_version=21,content="Updated"}
local preserved=Personal.combine({local_copy},{rows={incomplete}})[1]
assert(preserved.content=="Updated" and preserved.chapter_uid=="1" and preserved.range=="12-18"
    and preserved.book_version==20)
incomplete.chapter_uid,incomplete.range,incomplete.book_version="2","3-4",nil
local moved=Personal.combine({local_copy},{rows={incomplete}})[1]
assert(moved.chapter_uid=="2" and moved.range=="3-4" and moved.book_version==nil)
local merged=Personal.popup_rows(visible,{{review_id="r1",content="duplicate"},
    {review_id="r2",content="first public"},{review_id="r3",content="second public"}})
assert(#merged==3 and merged[1].own and merged[2].review_id=="r2" and merged[3].review_id=="r3")
assert(#Personal.combine({local_copy},{rows={},checked_at=14,present_ids={}})==1)
assert(#Personal.combine({local_copy},{rows={},checked_at=21})==1)
assert(#Personal.combine({local_copy},{rows={},checked_at=21,present_ids={r1=true}})==1)
assert(#Personal.combine({local_copy},{rows={},checked_at=21,present_ids={}})==0)
assert(Personal.save(store,"book",{},30,{}))
assert(not Personal.save(store,"book",{remote},29,{r1=true}))
local deleted_snapshot=Personal.load(store,"book")
assert(deleted_snapshot.checked_at==30 and deleted_snapshot.removed_ids.r1)
local public_left=Personal.popup_rows({},{{review_id="r1",content="stale public"},
    {review_id="other",content="other reader"}},deleted_snapshot.removed_ids)
assert(#public_left==1 and public_left[1].review_id=="other")
local_copy.sync_state="local_only"
local_copy.note="Kindle draft"
visible=Personal.combine({local_copy},snapshot)
assert(visible[1].content=="Kindle draft" and visible[1].status=="conflict")
local_copy.present=false
assert(#Personal.combine({local_copy},snapshot)==0)
-- The local mirror follows the KOReader sidecar only after the sidecar saves.
local row={present=true,kind="thought",sync_state="synced",remote_id="r1",source_path="book.epub",
    chapter_uid="1",range_key="12-18",last_attempt_at=15,note="Old"}
local item={drawer="underscore",note="Old"}
local saved,stored,held=0,0,0
local fail_disk=false
local function replay(thoughts,checked_at,present)
    return plugin:_apply_personal_thought_snapshot("book",thoughts,checked_at,present)
end
env.normalized_reader_file=function(path) return path end
env.UIManager.setDirty=function() end
env.LocalAnnotationDatabase.thoughts=function() return {row} end
env.LocalAnnotationDatabase.apply_phone_thought=function(_,_,target,content)
    assert(saved>stored and item.note==content and target==row)
    stored=stored+1
    return true
end
env.LocalAnnotationDatabase.annotation_id=function() return "highlight-only" end
env.LocalAnnotationDatabase.hold_local=function(_,_,id) assert(id=="highlight-only"); held=held+1 end
load("_apply_personal_thought_snapshot","_accept_personal_thought_snapshot")
function plugin:_current_document_path() return "book.epub" end
function plugin:_annotation_find_reader_item() return item end
function plugin:_capture_local_annotation_snapshot() return true end
function plugin:_flush_reader_checkpoint()
    if fail_disk then return false end
    saved=saved+1
    return true
end
replay({},16,{r1=true})
assert(item.note=="Old" and stored==0)
replay({remote},15,{r1=true})
assert(item.note=="Old" and stored==0)
fail_disk=true
replay({remote},16,{r1=true})
assert(item.note=="Old" and stored==0)
fail_disk=false
replay({remote},17,{r1=true})
assert(item.note=="Phone" and stored==1)
row.note="Phone"
item.note="local draft"
replay({},18,{})
assert(item.note=="local draft" and stored==1)
item.note=row.note
replay({},19,{})
assert(item.drawer and not item.note and stored==2 and held==1)
print("Personal-first popup, old- and incomplete-snapshot fences, saved phone changes, and draft protection passed")
