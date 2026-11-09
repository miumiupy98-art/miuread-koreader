local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
local ROOT=TOOL_DIR.."/../miuread.koplugin/"
package.path=ROOT.."?.lua;"..package.path

-- Only the catalog and append_entry paths are exercised: do not load a full
-- KOReader process or connect to WeRead.
local modules={
    "miuread.protocol", "miuread.config", "miuread.codec", "miuread.annotation_coord",
    "miuread.footnotes", "miuread.resource_refs", "miuread.internal_links",
    "miuread.thoughts", "miuread.epub", "miuread.http", "miuread.download_plan",
    "miuread.download_database", "miuread.epub_installer", "miuread.book_integrity",
    "miuread.source_position", "miuread.util", "logger"
}
for _,name in ipairs(modules) do
    package.preload[name]=function()
        if name=="logger" then return {warn=function() end,info=function() end} end
        if name=="miuread.util" then return {id_name=tostring} end
        return {}
    end
end

local Downloader=require("miuread.downloader")
local source={
    {chapterUid=10,chapterIdx=10,title="上卷",wordCount=0,level=1},
    {chapterUid=11,chapterIdx=11,title="第一章",wordCount=55,level=2},
    {chapterUid=12,chapterIdx=12,title="第一节",wordCount=66,level=3},
    {chapterUid=13,chapterIdx=13,title="第二章",wordCount=77,level=2},
}
local reader={
    catalog=function() return {format="epub",updated=source} end,
    _is_cover_chapter=function() return false end,
    _is_unavailable_chapter=function() return false end,
}
local downloader=Downloader:new(reader,nil,nil,nil,nil)
local _,all=downloader:catalog("book")
assert(#all==4 and all[1]._miuread_toc_level==1)
assert(all[3]._miuread_toc_level==3)

local append
for i=1,128 do
    local name,value=debug.getupvalue(Downloader._book_once,i)
    if not name then break end
    if name=="append_entry" then append=value;break end
end
assert(type(append)=="function","expected append_entry local in Downloader:_book_once")

local resulting_chapters,assets,css_list,css_seen={}, {}, {}, {}
for i,chapter in ipairs(all) do
    append(resulting_chapters,assets,css_list,css_seen,{
        uid=tostring(chapter.chapterUid),title=chapter.title,index=chapter.chapterIdx,
        word_count=chapter.wordCount,structural=i==1,
    },"<p>已缓存正文</p>","",{},i,chapter)
end
assert(#resulting_chapters==4)
assert(resulting_chapters[3].toc_level==3 and resulting_chapters[3].uid=="12")
assert(resulting_chapters[1].structural==true and resulting_chapters[1].toc_level==1)

-- Confirm resuming from a cached XHTML does not remove fresh TOC metadata.
local Toc=require("miuread.toc")
local nav,ncx,depth=Toc.build(resulting_chapters)
assert(depth==3 and nav:find("<ol>",1,true) and ncx:find('id="n3"',1,true))
print("Issue #135 catalog -> resume checkpoint -> EPUB TOC metadata pipeline passed")
