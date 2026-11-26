package.path="./miuread.koplugin/?.lua;"..package.path
local received={}
local constructor=function(_,opts)
    received[#received+1]=opts
    return opts
end
local info=setmetatable({},{__index={new=constructor}})
package.loaded["ui/widget/infomessage"]=info
package.loaded["ui/bidi"]={filepath=function(file) return "["..file.."]" end}
package.loaded["apps/filemanager/filemanagerutil"]={abbreviate=function(file) return file:match("[^/]+$") end}
package.loaded["ffi/util"]={
    template=function(pattern,value) return (pattern:gsub("%%1",function() return value end)) end,
    realpath=function(file) return file:gsub("^/alias/", "/books/") end,
}
package.loaded.gettext=function(value)
    assert(value=="Opening file '%1'.")
    return "正在打开文件 %1。"
end
local Notice=require("miuread.reader_open_notice")
local pending
local reader={}
function reader:showReaderCoroutine(path,provider,seamless)
    assert(provider=="epub")
    if path=="/books/broken.epub" then error("Open failed") end
    local name=path:match("[^/]+$")
    info:new{text="正在打开文件 ["..name.."]。",timeout=0,invisible=seamless}
    info:new{text="原有的错误提示"}
    return "scheduled"
end
function reader:showReader(path,provider,seamless)
    return self:showReaderCoroutine(path,provider,seamless)
end
function reader:switchDocument(path,seamless)
    return self:showReader(path,"epub",seamless)
end
Notice.install(reader,function() return pending end)
local patched=reader.showReaderCoroutine
Notice.install(reader,function() error("must be installed once") end)
assert(reader.showReaderCoroutine==patched)

pending="/alias/current.epub"
assert(reader:showReader("/books/current.epub","epub",false)=="scheduled")
assert(received[1].text=="正在打开书…" and received[1].timeout==0 and received[1].invisible==false)
assert(received[2].text=="原有的错误提示")

pending="/books/next.epub"
assert(reader:switchDocument("/books/next.epub",false)=="scheduled")
assert(received[3].text=="正在打开书…" and received[4].text=="原有的错误提示")
reader:showReader("/local/another.epub","epub",true)
assert(received[5].text=="正在打开文件 [another.epub]。" and received[5].invisible==true)
assert(rawget(info,"new")==nil and info.new==constructor)

pending="/books/broken.epub"
local ok,err=pcall(reader.switchDocument,reader,pending)
assert(not ok and tostring(err):find("Open failed",1,true))
assert(rawget(info,"new")==nil and info.new==constructor)
print("Opening and chapter switching preserve native dialogs, repaint options and errors")
