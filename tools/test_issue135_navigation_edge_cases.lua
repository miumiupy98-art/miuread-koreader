-- Regression tests for navigation-only headings, partial downloads, verified
-- chapter-local anchors, and nested catalog records. No live API is called.
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
local ROOT=TOOL_DIR.."/../miuread.koplugin/"
package.path=ROOT.."?.lua;"..package.path
local Toc=require("miuread.toc")
local function count(s,needle)
    local _,n=s:gsub(needle,"");return n
end
local tmp=arg[1] or "/tmp/miuread-issue135-anchor-test.xhtml"
local f=assert(io.open(tmp,"wb"))
f:write('<section><p title=\' id="ghost"\'>属性内容不应冒充真实ID</p><h2 id="real-anchor">段落</h2><h2 id="other">其他</h2></section>')
f:close()

local chapters={
    {uid="11",title="第一章",toc_level=2,body_path=tmp,toc_anchors={
        {title="找到的锚点",id="real-anchor"},
        {title="不存在的锚点",id="missing-anchor"},
        {title="只有偏移",offset=120},
        {title="不安全路径",href="https://external.example/#abc"},
        {title="不安全字符",id='x" onclick="alert(1)'},
        {title="伪造的ID",id="ghost"},
    }},
    {uid="12",title="第二章",toc_level=2,body="<p>正文</p>"},
}
local metadata={
    {uid="",title="第一篇",toc_level=1,structural_heading=true},
    {uid="11",title="第一章",toc_level=2},
    {uid="12",title="第二章",toc_level=2},
    {uid="",title="孤立的第三篇",toc_level=1,structural_heading=true},
    {uid="99",title="被部分下载排除的正文",toc_level=2},
}
local nav,ncx,depth=Toc.build(chapters,nil,metadata)
assert(depth==3,"anchor should become the third level")
assert(nav:find('第一篇</a><ol>',1,true),"navigation-only parent missing")
assert(nav:find('text/chapter-0001.xhtml#real-anchor',1,true),"existing anchor omitted")
assert(not nav:find('missing-anchor',1,true),"nonexistent anchor must be skipped")
assert(not nav:find('只有偏移',1,true),"offset is not a verified XHTML anchor")
assert(not nav:find('不安全',1,true),"unsafe href must be skipped")
assert(not nav:find('伪造的ID',1,true),"quoted attribute content is not a real ID")
assert(not nav:find('孤立的第三篇',1,true),"empty parent must be omitted")
assert(count(nav,"<li>")==4,"expected heading, two chapters and verified anchor")
assert(count(ncx,"<navPoint ")==4,"NCX and nav node counts disagree")
assert(ncx:find('playOrder="4"',1,true),"NCX playOrder sequence missing")

local no_uid={{uid="11",title="X",toc_level=2,body="<p>X</p>"}}
local partial_catalog={
    {uid="",title="无正文父标题",toc_level=1,structural_heading=true},
    {uid="11",title="X",toc_level=2},
    {uid="20",title="未选章节",toc_level=2},
}
local nav2,ncx2,depth2=Toc.build(no_uid,nil,partial_catalog)
assert(depth2==2)
assert(count(nav2,"<li>")==2 and count(ncx2,"<navPoint ")==2)
assert(not nav2:find("未选章节",1,true))

-- Exercise the real catalog flattening path with mocked dependencies, including
-- a no-UID heading and nested (non-flat) chapter records.
local modules={
    "miuread.protocol", "miuread.config", "miuread.codec", "miuread.annotation_coord",
    "miuread.footnotes", "miuread.resource_refs", "miuread.internal_links",
    "miuread.thoughts", "miuread.epub", "miuread.http", "miuread.download_plan",
    "miuread.download_database", "miuread.epub_installer", "miuread.book_integrity",
    "miuread.source_position", "miuread.util", "logger",
}
for _,name in ipairs(modules) do
    package.loaded[name]=nil
    package.preload[name]=function()
        if name=="logger" then return {warn=function() end,info=function() end} end
        if name=="miuread.util" then return {id_name=tostring} end
        return {}
    end
end
local Downloader=require("miuread.downloader")
local source={{title="无正文父标题",level=1,children={
    {chapterUid=11,title="第一章",level=2,anchors={{title="找到的锚点",id="real-anchor"}}},
    {chapterUid=12,title="第二章",level=2},
}}}
local reader={
    catalog=function() return {format="epub",updated=source} end,
    _is_cover_chapter=function() return false end,
    _is_unavailable_chapter=function() return false end,
    _is_structure_chapter=function(ch) return ch.childCount==1 end,
}
local downloader=Downloader:new(reader,nil,nil,nil,nil)
local info,selected=downloader:catalog("book")
assert(#selected==2 and tostring(selected[1].chapterUid)=="11")
assert(selected[1]._miuread_toc_level==2,"nested catalog lost level")
assert(#info._miuread_toc_entries==3,"navigation-only parent was dropped")
local metadata2=info._miuread_toc_entries
local nav3=Toc.build(chapters,nil,metadata2)
assert(nav3:find('无正文父标题</a><ol>',1,true),"nested title not retained")
os.remove(tmp)
print("Issue #135 navigation-only parents / real anchors / nested catalog passed")
