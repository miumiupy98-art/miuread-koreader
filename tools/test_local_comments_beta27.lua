-- Standalone, network-free regression for beta.27's local EPUB binding,
-- quote mapping, and reply parser/cache. Uses only mocked KOReader dependencies.
local folder=tostring(arg and arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path=folder.."/../miuread.koplugin/?.lua;"..package.path
local function serialize(v)
    if type(v)=="string" then return string.format("%q",v) end
    if type(v)~="table" then return tostring(v) end
    local keys={}
    for key in pairs(v) do keys[#keys+1]=key end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    local entries={}
    for _,key in ipairs(keys) do
        entries[#entries+1]="["..serialize(key).."]="..serialize(v[key])
    end
    return "{"..table.concat(entries,",").."}"
end
package.preload["miuread.json"]=function()
    return {encode=serialize,decode=function(s) return assert(loadstring("return "..s))() end}
end
package.preload["miuread.util"]=function()
    return {atomic_write=function(path,body)
        local f=assert(io.open(path,"wb"));assert(f:write(body));f:close();return true
    end}
end
package.preload["libs/libkoreader-lfs"]=function()
    return {attributes=function(path)
        local f=io.open(path,"rb")
        if not f then return nil end
        local size=f:seek("end")
        f:close()
        return {size=size,modification=1234,mode="file"}
    end}
end
local root="/tmp/miuread-beta27-mock-"..tostring(os.time()).."-"..tostring(math.random(10000))
os.execute("mkdir -p "..root)
local file=root.."/book.epub"
local f=assert(io.open(file,"wb"));f:write(string.rep("abcdefghijklmnop",2000));f:close()
local B=require("miuread.local_book_binding")
local store={data_dir=root}
local registry=B:new(store)
assert(B.fingerprint(file))
assert(registry:bind(file,{bookId="b1",title="书一",author="A"},{{chapterUid="1",title="第一章 初遇"},
    {chapterUid="2",title="第二章 风雨"}}))
assert(registry:bind(file,{bookId="b2",title="合集第二本"},{{chapterUid="5",title="Chapter 1 Start"}}))
assert(registry:assign(file,1,"b1","1",false))
assert(registry:assign(file,1,"b2","5",true))
local M=require("miuread.local_chapter_map")
local rows={{title="第一章 初遇",xpointer="xp100"},
    {title="第二章 风雨",xpointer="xp200"},{title="其他",xpointer="xp300"}}
assert(M.title_key("第一章 初遇")==M.title_key("第1章 初遇"))
assert(M.title_key("Chapter 1 Start")=="start")
local entry=registry:for_path(file)
local targets=M.targets(entry,rows,1)
assert(#targets==2 and targets[1].manual and targets[2].manual)
assert(#M.targets(entry,rows,2)==1)
local refreshed=B:new(store)
assert(#M.targets(refreshed:for_path(file),rows,1)==2)
local locations={{range="a-b",document_fingerprint="doc|quote",xpointer_start="xp100"}}
assert(refreshed:save_locations(file,"b1","1",locations,1))
assert(B:new(store):locations(file,"b1","1",1)["a-b"].xpointer_start=="xp100")
assert(B:new(store):locations(file,"b2","5",1)["a-b"]==nil)
assert(B:new(store):locations(file,"b1","1",2)["a-b"]==nil)
assert(refreshed:clear_assignment(file,1))
assert(#M.targets(refreshed:for_path(file),rows,1)==1)
assert(refreshed:unbind(file,"b1"))
assert(#M.targets(refreshed:for_path(file),rows,2)==0)
-- Mock a bounded findAllText that returns one exact hit for the right chapter.
local search_count=0
local ui={toc={toc=rows,getTocIndexByPage=function(_,_) return 1 end},
    rolling={xpointer="xp130"},document={
        findAllText=function(_,quote)
            search_count=search_count+1
            if quote=="这个片段足够长，位于当前章节正文"
                or quote=="这是另一个不重复的原文片段可以匹配" then
                return {{start="xp120",["end"]="xp125"}}
            end
            return {}
        end,
        compareXPointers=function(_,a,b)
            local ia,ib=tonumber(tostring(a):match("%d+")),tonumber(tostring(b):match("%d+"))
            if ia<ib then return 1 elseif ia>ib then return -1 end
            return 0
        end,
        clearSelection=function() end,
    }}
assert(M.current_index(ui)==1)
local vote=M.vote_for_current(ui,rows,1,{b2={catalog={{chapterUid="5",title="Unrelated"},
    {chapterUid="6",title="Matched"}}}},function(id,uid)
        if uid=="6" then return {{texts={{abstract="这个片段足够长，位于当前章节正文"},
            {abstract="这是另一个不重复的原文片段可以匹配"}}}} end
        return {}
    end)
assert(vote and vote.chapterUid=="6" and vote.score==2)
assert(search_count==2)
local Reply=require("miuread.review_replies")
local parsed=assert(Reply.normalize({comments={{user={name="A"},content="hello",likesCount=3},
    {author={nick="B"},text="world",likes=2}},commentsCount=5},"rev1"))
assert(#parsed.items==2 and parsed.total==5 and parsed.truncated)
assert(parsed.items[1].author=="A" and parsed.items[1].likes==3)
assert(Reply.save(store,parsed))
assert(#Reply.load(store,"rev1").items==2)
assert(Reply.normalize({review={},commentsCount=0},"rev2").total==0)
assert(Reply.normalize({review={content="原想法"},likesCount=2},"rev-empty").total==0)
assert(Reply.normalize({data={comments={{author="读者丙",content="很好"}},commentsCount=1}},
    "rev-nested").items[1].author=="读者丙")
assert(Reply.normalize({errCode=-2003,errMsg="bad"},"rev3")==nil)
print("test_local_comments_beta27: PASS (bind/multi-book/manual/map/quote/replies/cache)")
os.remove(file);os.remove(root.."/local_book_bindings.json");os.remove(root.."/review_replies_cache.json")
os.execute("rmdir "..root)
