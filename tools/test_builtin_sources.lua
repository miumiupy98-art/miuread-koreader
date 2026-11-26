package.path="./miuread.koplugin/?.lua;"..package.path
local root=assert(arg[1])
package.loaded["datastorage"]={getDataDir=function() return root end}
package.loaded["miuread.util"]={
    trim=function(value) return (tostring(value or ""):gsub("^%s+",""):gsub("%s+$","")) end,
    safe_name=function(value) return value end, utf8_truncate=function(value) return value end,
    mkdir=TEST_MKDIR,file_exists=function(path)
        local file=io.open(path,"rb")
        if file then file:close(); return true end
        return false
    end,
    file_size=function(path)
        local file=io.open(path,"rb")
        if file then local size=file:seek("end"); file:close(); return size end
    end,
}
local Groups=require("miuread.shelf_groups")
local cloud={archive={{archiveId=8,name="Reading",bookIds={"A"}},{archiveId=9,name="Later",bookIds={}}},
    books={{bookId="A"}}}
local calls=0
local account={shelf=function() return cloud end}
function account:write_shelf_group(action,id,name,book)
    calls=calls+1
    if action=="move" then
        assert(id==9 and book=="A")
        cloud.archive[1].bookIds={}
        cloud.archive[2].bookIds={"A"}
        error("response lost")
    elseif action=="rename" then
        assert(id==9 and name=="New name" and book==nil)
        cloud.archive[2].name=name
    elseif action=="delete" then
        assert(id==8 and book==nil)
        table.remove(cloud.archive,1)
    end
end
assert(not pcall(Groups.change,account,{action="delete",group=8}) and calls==0)
assert(Groups.change(account,{action="move",group=9,book="A"}) and calls==1)
assert(Groups.change(account,{action="move",group=9,book="A"}) and calls==1)
assert(Groups.change(account,{action="rename",group=9,name="New name"}) and calls==2)
assert(Groups.change(account,{action="delete",group=8}) and calls==3)

local Fonts=require("miuread.weread_font_download")
assert(#Fonts.catalog==29)
local payload="OTTO"..string.rep("x",28)
local entries={{index=1,path="nest/other.otf",mode="file",size=#payload},
    {index=2,path="nest/face.otf",mode="file",size=#payload}}
local reader={open=function() return true end,close=function() end}
function reader:iterate()
    local i=0
    return function() i=i+1; return entries[i] end
end
function reader:extractToMemory(i) assert(i==2); return payload end
package.loaded["ffi/archiver"]={Reader={new=function() return reader end}}
assert(Fonts.read_archive("fixture.zip",{file="face.otf"})==payload)
assert(not pcall(Fonts.read_archive,"fixture.zip",{file="unknown.otf"}))

package.loaded["miuread.protocol"]={query=function(fields)
    if fields.action=="login" then assert(fields.password=="fixture-only") end
    return "encoded"
end}
local responses={
    login={response={id="42",remix_userkey="fake-key"}},
    search={success=1,books={{id=23,hash="abc",title="Fixture book",extension="pdf"}}},
    file={success=1,file={allowDownload=true,downloadLink="https://book.test/file",extension="pdf"}},
}
package.loaded["miuread.json"]={decode=function(value) return assert(responses[value]) end}
local Library=require("miuread.zlibrary_source")
local seen={}
local http={}
function http:request(opt)
    assert(opt.auth==false and opt.redirects==0)
    if opt.url=="https://account.test/rpc.php" then
        assert(opt.method=="POST" and opt.body=="encoded" and not opt.headers.Cookie)
        return "login",200
    elseif opt.url=="https://account.test/eapi/book/search" then
        assert(opt.headers.Cookie=="remix_userid=42; remix_userkey=fake-key")
        return "search",200
    elseif opt.url=="https://account.test/eapi/book/23/abc/file" then
        assert(opt.headers.Cookie=="remix_userid=42; remix_userkey=fake-key")
        return "file",200
    elseif opt.url=="https://book.test/file" then
        assert(not opt.headers.Cookie)
        return "",302,{location="https://cdn.test/book.pdf"}
    elseif opt.url=="https://cdn.test/book.pdf" then
        assert(not opt.headers.Cookie)
        local file=assert(io.open(opt.sink_path,"wb"))
        file:write("%PDF-1.7\n")
        file:close()
        return "",200,{["content-length"]="9"}
    end
    error("unexpected HTTP request")
end
assert(not Library.origin("https://account.test@example.test"))
local session=Library.login(http,"https://account.test","reader@example.test","fixture-only")
local result=Library.search(http,session,"Fixture",1)
assert(#result.books==1 and not result.more)
local saved=Library.download(http,session,result.books[1])
assert(saved:find("/books/Z-Library/",1,true) and saved:match("%.pdf$"))
assert(Library.download(http,session,result.books[1])==saved)
print("Verified cloud group actions, official font catalog and archive selection, and built-in login/search/download with origin isolation")
