package.path="./miuread.koplugin/?.lua;"..package.path
local files,contents={},{}
package.loaded["libs/libkoreader-lfs"]={attributes=function(file) return files[file] end}
package.loaded["miuread.util"]={
    id_name=tostring,safe_name=tostring,
    read_file=function(file) return contents[file] end,
    atomic_write=function(file,content) contents[file]=content;return true end,
}
local os_remove=os.remove
os.remove=function(file)
    if not files[file] and not contents[file] then return nil end
    files[file],contents[file]=nil,nil
    return true
end
local Cache=require("miuread.online_cache")
local leased_file="/temp/limited/book/1-online.epub"
local login="session-a"
local leased={file=leased_file,online_server_only=true,online_login=login}
local limited_store={limited_online_dir="/temp/limited",
    auth=function() return {login_session_id=login} end,
    file_record_fast=function() return "book",leased end}
assert(not Cache.allowed_to_open(limited_store,leased_file))
assert(not Cache.reusable(leased))
Cache.allow_session(limited_store,leased)
assert(Cache.allowed_to_open(limited_store,leased_file))
login="session-b"
assert(not Cache.allowed_to_open(limited_store,leased_file))
login="session-a"
Cache.close_session(leased_file)
assert(not Cache.allowed_to_open(limited_store,leased_file))

local root="/settings/miuread/prefetch"
local library,prefetch={},{}
local store={prefetch_dir=root}
function store:prefetch_book_path(id) return root.."/"..id end
function store:library() return library end
function store:get(key) assert(key=="prefetch_cache");return prefetch end
function store:set(key,value)
    if key=="library" then library=value else assert(key=="prefetch_cache");prefetch=value end
end
local function add(id,uid,kind)
    local file=root.."/"..id.."/"..uid.."-"..kind..".epub"
    files[file]={mode="file",size=100,modification=120}
    local set
    if kind=="online" then
        library[id]=library[id] or {chapters={}}
        set=library[id].chapters
    else
        prefetch[id]=prefetch[id] or {}
        set=prefetch[id]
    end
    set[uid]=set[uid] or {}
    set[uid][kind]={file=file}
    return file
end
local read=add("book","1","online")
local active=add("book","2","online")
local unfinished=add("book","3","online")
local unread=add("book","4","clean")
local farther=add("book","5","clean")
local sidecar=read:gsub("%.epub$",".sdr").."/metadata.epub.lua"
files[sidecar]={mode="file",size=700,modification=150}
local started=1000000
local TTL=48*60*60
assert(Cache.mark_finished(store,"book","1",read,started))
assert(not Cache.mark_finished(store,"book","1",read,started+5))
assert(Cache.mark_finished(store,"book","2",active,started))
assert(not Cache.mark_finished(store,"elsewhere","1",read,started))
assert(Cache.inspect(store,{measure_only=true}).bytes==500)
assert(Cache.prune(store,{now=started+TTL-1})==0)
assert(Cache.prune(store,{now=started+TTL,protected={[active]=true}})==1)
assert(not files[read] and not contents[read..".miuread-eof"] and files[sidecar])
assert(files[active] and files[unfinished] and files[unread] and files[farther])
assert(Cache.prune(store,{now=started+TTL*10,protected={[active]=true}})==0)

-- A full offline copy supersedes unread and partially read cached chapters.
assert(Cache.prune(store,{now=started+1,protected={[active]=true},
    complete=function(id) return id=="book" end})==3)
assert(files[active] and files[sidecar] and not files[unfinished] and not files[unread] and not files[farther])
assert(Cache.prune(store,{manual=true,protected={[active]=true}})==0)
assert(Cache.prune(store,{manual=true})==1)
assert(files[sidecar] and Cache.inspect(store,{measure_only=true}).count==0)

-- EOF is intercepted before ReaderStatus can show a rating or mark a book.
local source=assert(io.open("miuread.koplugin/main.lua","rb"))
local text=source:read("*a")
source:close()
local first=assert(text:find("function Plugin:_install_online_eof_hook(",1,true))
local last=assert(text:find("function Plugin:_online_cache_protected(",first,true))
local Plugin={}
local env=setmetatable({Plugin=Plugin,normalized_reader_file=function(value) return value end},{__index=_G})
setfenv(assert(loadstring(text:sub(first,last-1))),env)()
local online=add("book","6","online")
local status={onEndOfBook=function() return "normal book completion" end}
local host=setmetatable({store=store,ui={status=status},file=online},{__index=Plugin})
function store:file_record_fast(path)
    assert(path==online)
    return {book_id="book"},{chapter_uid="6"}
end
function host:_current_document_path() return self.file end
function host:onEndOfBook() self.chapter_done=true;return true end
host:_install_online_eof_hook()
assert(status:onEndOfBook()==true and host.chapter_done and contents[online..".miuread-eof"])
host.file="/books/normal.epub"
assert(status:onEndOfBook()=="normal book completion")
os.remove=os_remove
print("Online EOF, 48-hour expiry, unread retention, whole-book cleanup and annotation preservation passed")

store.limited_online_dir="/tmp/miuread"
function store:limited_online_path(id,uid,format)
    return self.limited_online_dir.."/"..id.."/"..uid.."-online"..(format=="txt" and ".txt" or ".epub")
end
local limited=store:limited_online_path("book","7")
local limited_text=store:limited_online_path("book","8","txt")
local login="session"
function store:auth() return {login_session_id=login} end
function store:file_record_fast(path)
    if path==limited or path==limited_text then return {book_id="book"},{online_expires=100,online_login="session"} end
end
assert(Cache.is_online_file(store,limited) and Cache.matches(store,"book","7",limited))
assert(Cache.allowed_to_open(store,limited,99) and not Cache.allowed_to_open(store,limited,100))
assert(Cache.is_limited_file(store,limited_text) and Cache.matches(store,"book","8",limited_text))
assert(Cache.allowed_to_open(store,limited_text,99) and not Cache.allowed_to_open(store,limited_text,100))
login="new session"
assert(not Cache.allowed_to_open(store,limited,99))
assert(not Cache.allowed_to_open(store,limited_text,99))
assert(not Cache.reusable({online_expires=100,file=limited}))
print("Limited online storage is scoped to the authorized session and expiry")
