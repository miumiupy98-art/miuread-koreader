-- Generate a real EPUB with source-only headings and verified chapter anchors.
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
local ROOT=TOOL_DIR.."/../miuread.koplugin/"
package.path=ROOT.."?.lua;"..package.path
package.preload["bit"]=package.preload["bit"] or function() return assert(require("bit32")) end
package.preload["miuread.util"]=function()
    return {xml=function(s) return (tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")) end,
        id_name=function(s) return tostring(s or ""):gsub("[^%w%._%-]","_") end,
        mkdir=function(p) os.execute("mkdir -p "..string.format("%q",p)) end}
end
package.preload["miuread.json"]=function() return {encode=function() return "{}" end} end
local Epub=require("miuread.epub")
local output=assert(arg[1],"output EPUB required")
local chapters={
    {uid="c11",index=101,title="第一章",toc_level=2,body='<h2 id="intro">第一节</h2><p>intro</p>',
        toc_anchors={{title="第一节",id="intro"},{title="不存在",id="not-found"}}},
    {uid="c12",index=102,title="第二章",toc_level=2,body='<p>正文</p>'},
}
local catalog={
    {uid="",title="第一篇",toc_level=1,structural_heading=true},
    {uid="c11",title="第一章",toc_level=2},
    {uid="c12",title="第二章",toc_level=2},
}
Epub.build(output,{bookId="135",title="多级目录校验",author="Tester"},chapters,nil,{},nil,{},nil,catalog)
print("Issue #135 real EPUB integration build succeeded: "..output)
