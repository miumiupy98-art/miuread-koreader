-- Convert the original review coordinates using only KOReader's position API.
package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.annotation_coord"]={}
package.loaded["miuread.thought_database"]={}
package.loaded["miuread.source_position"]={}
package.loaded.util={splitToArray=function(text)
    local parts={}
    for part in text:gmatch("[^-]+") do parts[#parts+1]=part end
    return parts
end}
package.loaded["miuread.eink_comment_source"]={rendered_bodies=function(html) return {html} end}
local Source=require("miuread.eink_progress_source")
local Locator=require("miuread.comment_locator")
local text="前言两个字中间两个字后来两个字结束后的内容"
local raw="<p>"..text.."</p>"
local rendered="<p>"..text.."</p>"
local source,layout=assert(Source.align(raw,rendered))
local fetched=0
local cache_version=17
require("miuread.eink_comment_source").personal_alignment=function(_,id,uid,path,version)
    assert(id=="id" and uid=="56" and path=="/test.epub" and version==17)
    fetched=fetched+1
    return {source=source,rendered=layout,version=cache_version}
end

-- The direct XPointer interface is mocked here. Deliberately supply no text-search
-- API to ensure repeated short selections can still be placed.
local glyphs={}
local title="章题"
for glyph in (title..text):gmatch("[^\128-\191][\128-\191]*") do glyphs[#glyphs+1]=glyph end
local document={file="/test.epub"}
function document:getPageCount() return math.ceil(#glyphs/5) end
function document:getPageXPointer(i) return tostring((i-1)*5) end
function document:getPageFromXPointer(xp) return math.floor(tonumber(xp)/5)+1 end
function document:isXPointerInDocument(xp) return tonumber(xp) and tonumber(xp)<=#glyphs end
function document:getNextVisibleChar(xp)
    local n=tonumber(xp)
    if n<#glyphs then return tostring(n+1) end
end
function document:getTextFromXPointers(a,b,draw)
    assert(draw==false)
    return table.concat(glyphs,"",tonumber(a)+1,tonumber(b))
end
local record={eink_content_mode="eink-offline",progress_source_book_version=17,
    chapter_map={{uid="56",title=title}}}
local ui={document=document}
-- The first occurrence starts at raw offset 5, the second at 10, the third 15.
local ranges={"5-8","10-13","15-18","3-5","0-3","900-905"}
local positions=Locator.eink_positions({},ui,"id","56",record,ranges)
assert(fetched==1)
assert(positions["5-8"].pos0=="4" and positions["5-8"].pos1=="7")
assert(positions["10-13"].pos0=="9" and positions["10-13"].pos1=="12")
assert(positions["15-18"].pos0=="14" and positions["15-18"].pos1=="17")
assert(positions["3-5"].pos0=="2" and positions["3-5"].pos1=="4")
assert(not positions["0-3"] and not positions["900-905"])
cache_version=nil
local existing,why=Locator.eink_positions({},ui,"id","56",record,{"10-13","15-18"},
    {quotes={["10-13"]="两个字",["15-18"]="另一句"}})
assert(existing["10-13"].pos0=="9" and not existing["15-18"] and why=="source_cache_missing")
local checked,err=Locator.eink_positions({},ui,"id","56",record,{"10-13","15-18"},
    {quotes={["10-13"]="两个字",["15-18"]="另一句"},verify_quote=true})
assert(checked["10-13"].pos0=="9" and not checked["15-18"] and err=="official_range_text_differs")
local public=Locator.eink_positions({},ui,"id","56",record,{"10-13","15-18"},{public=true})
assert(public["10-13"].pos0=="9" and public["15-18"].pos0=="14")
print("Original chapter coordinates select the intended repeated excerpt and skip the generated heading")

-- The actual reader action preserves a versionless detail through a chapter
-- switch and requests chapter source before retrying the same official range.
local plugin,H={},{}
local target_book,target_note="id",{review_id="old-review",chapter_uid="21",range="10-13",
    quote="两个字",book_version=8}
local fake_util=require("miuread.util")
local env=setmetatable({Plugin=plugin,HOME_SESSION=H,U=fake_util,
    reader_close_active=function() return false end,normalized_reader_file=function(p) return p end,
    DownloadDatabase={account_key=function() return "account" end},
    logger={info=function() end,warn=function() end},
},{__index=_G})
local f=assert(io.open("miuread.koplugin/main.lua","rb"))
local main=f:read("*a")
f:close()
local first=assert(main:find("function Plugin:_jump_to_cloud_thought(",1,true))
local last=assert(main:find("function Plugin:_show_personal_thought(",first,true))
setfenv(assert(loadstring(main:sub(first,last-1))),env)()
plugin.ui=ui
plugin.store={auth=function() return {login_session_id="session"} end}
local detail_calls,source_calls=0,0
local last_landing,message
function plugin:_current_document_path() return "/test.epub" end
function plugin:_annotation_current_book_id() return target_book end
function plugin:_current_book_record() return {book={title="Book"},record=record} end
function plugin:is_online() return true end
function plugin:info(text) message=text end
function plugin:_reader_goto_annotation(item) last_landing=item;return true end
function plugin:_schedule_personal_thought_overlay() end
function plugin:_open_online_toc_chapter(_,uid) assert(uid=="56");return true end
function plugin:_fetch_eink_display(_,_,_,args,callback)
    assert(args[1]==target_book and args[2]=="old-review")
    detail_calls=detail_calls+1
    callback({chapter_uid="56",range="15-18"})
    return true
end
function plugin:_run_interactive_network(_,_,_,callback)
    source_calls=source_calls+1
    cache_version=17
    callback({ok=true,value={request_ok=true}})
    return true
end
record.chapter_uid="21"
assert(plugin:_jump_to_cloud_thought(target_book,target_note) and detail_calls==1)
assert(H.personal_thought_jump and H.personal_thought_jump.note.book_version==nil)
assert(H.personal_thought_jump.note.chapter_uid=="56" and H.personal_thought_jump.note.range=="15-18")
record.chapter_uid="56"
local native=require("miuread.eink_comment_source")
local alignment=native.personal_alignment
native.personal_alignment=function(...)
    if not cache_version then return nil,"source_cache_missing" end
    return alignment(...)
end
assert(plugin:_jump_to_cloud_thought(target_book,H.personal_thought_jump.note,H.personal_thought_jump.refreshed))
assert(source_calls==1 and detail_calls==1 and last_landing.pos0=="14")
assert(plugin._selected_cloud_thought.note.book_version==17)
target_note.chapter_uid,target_note.quote="56","不同"
last_landing=nil
assert(not plugin:_jump_to_cloud_thought(target_book,target_note,true) and not last_landing and message)
print("Older review detail, versionless response, cross-chapter handoff, source recovery and guarded failure passed")

