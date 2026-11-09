-- Run with KOReader's LuaJIT or a Lua 5.3+ runner (e.g. texlua).
-- Uses the real EPUB writer while replacing only the KOReader-only dependencies.
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
local ROOT=TOOL_DIR.."/../miuread.koplugin/"
package.path=ROOT.."?.lua;"..package.path

package.preload["bit"]=package.preload["bit"] or function()
    local ok,bit=pcall(require,"bit32")
    if ok then return bit end
    error("bit/bit32 support unavailable")
end
package.preload["miuread.util"]=function()
    return {
        xml=function(s) return (tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")) end,
        id_name=function(s) return tostring(s or ""):gsub("[^%w%._%-]","_") end,
        mkdir=function(s) os.execute("mkdir -p "..string.format("%q",s)) end,
    }
end
package.preload["miuread.json"]=function() return {encode=function() return "{}" end} end

local Toc=require("miuread.toc")
local Epub=require("miuread.epub")
local escape=require("miuread.util").xml
local function same(actual,expected,message)
    assert(actual==expected,(message or "mismatch").."\nExpected: "..tostring(expected).."\nActual: "..tostring(actual))
end
local function count(text,pattern)
    local _,n=text:gsub(pattern,"")
    return n
end

local rich={
    {uid="10",title="第一卷",toc_level=1,body="<p>卷首</p>"},
    {uid="11",title="第一章",toc_level=2,body="<p>章</p>"},
    {uid="12",title="第一节",toc_level=3,body="<p>节</p>"},
    {uid="13",title="第二章 & <测试>",toc_level=2,body="<p>第二章</p>"},
    {uid="14",title="第二卷",toc_level=1,body="<p>第二卷</p>"},
    {uid="15",title="第三章",toc_level=2,body="<p>第三章</p>"},
}
local nav,ncx,depth=Toc.build(rich,escape)
same(depth,3,"three levels")
same(count(nav,"<li>"),6,"number of XHTML navigation items")
same(count(nav,"<ol>"),3,"nested XHTML lists")
same(count(ncx,"<navPoint "),6,"NCX node count")
assert(nav:find("第二章 &amp; &lt;测试&gt;",1,true),"escaped title")
assert(ncx:find("第二章 &amp; &lt;测试&gt;",1,true),"NCX escaped title")
assert(nav:find('<a href="text/chapter-0001.xhtml">第一卷</a><ol>',1,true),"volume contains chapters")
assert(nav:find('<a href="text/chapter-0002.xhtml">第一章</a><ol>',1,true),"chapter contains sections")
assert(nav:find('</ol></li><li><a href="text/chapter-0004.xhtml">',1,true),"sibling chapter nesting")

local flat={
    {uid="a",title="甲"},
    {uid="b",title="乙"},
    {uid="c",title="丙"},
}
local flat_nav,flat_ncx,flat_depth=Toc.build(flat,escape)
same(flat_depth,1,"flat fallback depth")
same(count(flat_nav,"<ol>"),0,"no invented hierarchy")
same(count(flat_ncx,"<navPoint "),3,"flat NCX")

local subset={
    {uid="d",title="第二节",toc_level=3},
    {uid="e",title="第三节",toc_level=3},
    {uid="f",title="新章",toc_level=2},
    {uid="g",title="子节",toc_level=3},
}
local part_nav,_,part_depth=Toc.build(subset,escape)
same(part_depth,2,"partial chapter range relative hierarchy")
assert(part_nav:find('<a href="text/chapter-0003.xhtml">新章</a><ol>',1,true),"subset chapter has child")

local linked={
    {uid="parent",title="part"},
    {uid="child",title="chapter",toc_parent_uid="parent"},
    {uid="sibling",title="chapter 2",toc_parent_uid="parent"},
    {uid="out",title="out of order",toc_parent_uid="child"},
}
local linked_nav,_,linked_depth=Toc.build(linked,escape)
same(linked_depth,2,"explicit parent UID hierarchy")
assert(linked_nav:find('</ol></li><li><a href="text/chapter-0004.xhtml">',1,true),
    "closed subtree cannot reorder out-of-order references")

local tmp=arg[1] or "/tmp/miuread-issue135-test.epub"
Epub.build(tmp,{bookId="135",title="目录测试",author="MiuRead"},rich,nil,nil,nil,{})
local f=assert(io.open(tmp,"rb"))
local header=f:read(4);f:close()
same(header,"PK\003\004","ZIP EPUB signature")
print("Issue #135 TOC/Lua EPUB generation tests passed; output="..tmp)
