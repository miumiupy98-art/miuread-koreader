-- Keep the E-Ink reading routes and article-cache behavior covered without network access.
package.path="./miuread.koplugin/?.lua;"..package.path
local files,dirs={},{}
package.loaded["libs/libkoreader-lfs"]={attributes=function(path,field)
    if field=="mode" then return dirs[path] and "directory" or files[path] and "file" end
end}
package.loaded.logger={info=function() end,warn=function() end}
package.loaded["miuread.http"]={is_auth_error=function() return false end,
    is_rate_limit_error=function() return false end,rate_limit_details=function() end}
package.loaded["miuread.diagnostic_log"]={now=os.clock,record=function() end}
local U=require("miuread.util")
local encoded={}
local json_null={}
package.loaded["miuread.json"]={
    encode=function(value) encoded[#encoded+1]=U.copy(value); return tostring(#encoded) end,
    decode=function(value) return U.copy(assert(encoded[tonumber(value)])) end,
    is_null=function(value) return value==json_null end,
}
U.mkdir=function(path) dirs[path]=true; return true end
U.atomic_write=function(path,body) files[path]=body; return true end
U.read_file=function(path) return files[path] end
U.file_exists=function(path) return files[path]~=nil end
U.remove_tree=function(path)
    for name in pairs(files) do if name:sub(1,#path+1)==path.."/" then files[name]=nil end end
    dirs[path]=nil
    return true
end
local rename=os.rename
os.rename=function(old,new)
    if not dirs[old] then return nil end
    local moved={}
    for name,data in pairs(files) do
        if name:sub(1,#old+1)==old.."/" then moved[new..name:sub(#old+1)]=data; files[name]=nil end
    end
    for name,data in pairs(moved) do files[name]=data end
    dirs[old]=nil; dirs[new]=true
    return true
end

local Api=require("miuread.api")
local MP=require("miuread.mp")
local auth={account={vid="42"},login_session_id="a",
    native_shelf={vid="42",accessToken="access",refreshToken="refresh",deviceId="device"}}
local store={mp_dir="/mp"}
function store:auth() return U.copy(auth) end
function store:read_persisted(key) assert(key=="auth"); return self:auth() end
function store:preferences() return {api_transport="web"} end
function store:mp_account_dir(id) return "/mp/"..id end
local http={}
local hits={}
local public_requests,images,paid_queries=0,0,0
local list_mode
local function route(url,options)
    assert(url:match("^https://i%.weread%.qq%.com/"))
    assert(options.auth==false and options.redirects==0 and options.headers.accessToken=="access")
    local path=url:match("^https://i%.weread%.qq%.com(/[^?]*)")
    hits[path]=(hits[path] or 0)+1
    return path
end
function http:get_json(url,options)
    local path=route(url,options)
    if path=="/config" then
        assert(url:find("synckey=0",1,true))
        return {accountsets={mpBookGranted=true}}
    elseif path=="/mp/list" then
        assert(url:find("showWx=1",1,true))
        if list_mode=="broken" then error("fixture offline") end
        if url:find("maxIdx=30",1,true) then
            return {listType=0,lists={{reviewId="paid",title="付费文章",idx=20,key="item-2"}},
                removedKeys={"remove-me"},continueFlag=false}
        elseif url:find("listType=1",1,true) then
            return {listType=1,lists=json_null,continueFlag=false}
        end
        assert(url:find("synckey=0",1,true))
        return {listType=0,lists={{reviewId="free",title="公众号文章",account="公众号名",idx=40,key="item-1"},
            {reviewId="gone",title="移除条目",idx=30,key="remove-me"}},continueFlag=true}
    elseif path=="/review/single" then
        local id=assert(url:match("reviewId=(%w+)"))
        local paid=id=="paid" or id=="blocked"
        local doc_url=id=="unsafe" and "https://mp.weixin.qq.com.invalid/a" or "https://mp.weixin.qq.com/a"
        return {reviewId=id,review={reviewId=id,type=16,mpInfo={doc_url=doc_url,payType=paid and 2 or 0}}}
    elseif path=="/book/podcasts" then
        for _,parameter in ipairs({"bookId=book-1","synckey=0","count=120","listType=2","reviewListType=0"}) do
            assert(url:find(parameter,1,true),url)
        end
        return {bookId="book-1",reviewsHasMore=true,reviews={
            {review={author={name="读者甲"},review={reviewId="r1",bookId="book-1",content="一本好书"}}},
            {reviewData={reviewId="r2",bookId="book-1",content="书评内容"}},
            {reviewId="r1",content="重复条目"},
        }}
    elseif path=="/book/info" then
        assert(url:find("myzy=1",1,true))
        return {bookId="book-1",title="图书",newRating=872,newRatingCount=200}
    end
    error("unexpected route "..path)
end
local allow_paid
function http:post_json(url,body,options)
    local path=route(url,options)
    if path=="/mp/getpaidinfo" then
        paid_queries=paid_queries+1
        assert(body.need_content==1 and body.urls[1]=="https://mp.weixin.qq.com/a")
        return {pay_appmsg_infos={{ispaid=allow_paid,content="<p>授权之后可读的文章段落。</p>"}}}
    elseif path=="/dict/query" then
        assert(body.word=="朱雀" or body.word=="无释义")
        if body.word=="无释义" then return {status=0} end
        return {status=1,message={spell_en="· pronunciation ·",result={
            {part="名词",mean="古代神话中的神鸟",means={{mean="四象之一"}}}}},
            baike="补充释义"}
    end
    error("unexpected route "..path)
end
function http:download(url,options)
    assert(options.auth==false and options.redirects==0 and not (options.headers or {}).accessToken)
    if url=="https://mp.weixin.qq.com/a" then
        public_requests=public_requests+1
        return [[<html><div id='js_content'><div>嵌套段落在文章内。</div><p>嵌套段落后仍可显示。
<img src="bad" data-src="//mmbiz.qpic.cn/example?x=1&amp;y=2"></p></div><p>文章外的推荐内容。</p></html>]]
    end
    assert(url=="https://mmbiz.qpic.cn/example?x=1&y=2",url)
    images=images+1
    return "\137PNG\r\n\26\nfixture"
end
local api=Api:new(http,store)
local mp=MP:new(nil,http,store,api)

local first=mp:native_feed(0,false)
assert(first.articles[1].reviewId=="free" and first.more and first.cursor==30)
local merged=mp:native_feed(0,true)
assert(#merged.articles==2 and merged.articles[2].reviewId=="paid" and not merged.more)
assert(hits["/config"]==1)
assert(#mp:native_feed(1,false).articles==0)
list_mode="broken"
assert(not pcall(mp.native_feed,mp,0,false))
assert(#mp:cached_articles(merged.bookId)==2)
list_mode=nil

local book=mp:native_feed_book(0)
local opened=mp:fetch_article(book,merged.articles[1],{images=true})
assert(opened.images_complete and opened.image_count==1)
local document=assert(files[opened.file])
assert(document:find("嵌套段落后仍可显示",1,true) and not document:find("文章外的推荐内容",1,true))
assert(document:find("images/0001.png",1,true) and mp:identify_path(opened.file))
assert(mp:fetch_article(book,merged.articles[1],{images=true}).file==opened.file)
assert(public_requests==1 and images==1)
assert(not pcall(api.mp_content,api,"unsafe"))
assert(public_requests==1)

allow_paid=false
assert(not pcall(mp.fetch_article,mp,book,merged.articles[2],{images=true}))
assert(not mp:article_record(book.bookId,merged.articles[2]) and paid_queries==1)
allow_paid=true
local paid=mp:fetch_article(book,merged.articles[2],{images=true})
assert(files[paid.file]:find("授权之后可读",1,true) and paid_queries==2 and public_requests==1)
auth.account.vid="43"
assert(mp:native_feed_book(0).bookId~=book.bookId and not mp:identify_path(paid.file))
assert(not mp:article_record(book.bookId,merged.articles[2]))
auth.account.vid="42"

local details=api:book("book-1",true)
assert(details.newRating==872 and details.newRatingCount==200)
local reviews=api:book_reviews("book-1")
assert(reviews.partial and #reviews.rows==2 and reviews.rows[1].author=="读者甲")
assert(reviews.rows[2].content=="书评内容")
local dict=api:dictionary(" 朱雀 ")
assert(dict.definition:find("四象之一",1,true) and dict.encyclopedia=="补充释义")
assert(api:dictionary("无释义").definition=="")
assert(not pcall(api.dictionary,api,"词\n组") and hits["/dict/query"]==2)
os.rename=rename
print("E-Ink article lists, offline HTML and images, paid access, cache isolation, reviews and dictionary passed")
