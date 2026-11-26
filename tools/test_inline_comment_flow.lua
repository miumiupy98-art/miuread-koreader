-- In-text reading uses one cheap chapter discovery and one selected-range request.
package.path="./miuread.koplugin/?.lua;"..package.path
local files,encoded={},{}
package.loaded.logger={info=function() end,warn=function() end}
package.loaded["libs/libkoreader-lfs"]={attributes=function(path)
    if path=="/book.epub" then return {mode="file",size=1024,modification=1} end
end}
package.loaded.util={splitToArray=function(value)
    local parts={}
    for part in value:gmatch("[^-]+") do parts[#parts+1]=part end
    return parts
end}
package.loaded["miuread.http"]={is_auth_error=function() return false end,
    is_rate_limit_error=function() return false end,is_forbidden_error=function() return false end}
local U=require("miuread.util")
U.read_file=function(path) return files[path] end
U.atomic_write=function(path,body) files[path]=body;return true end
package.loaded["miuread.json"]={
    encode=function(value) encoded[#encoded+1]=U.copy(value);return tostring(#encoded) end,
    decode=function(data) return U.copy(assert(encoded[tonumber(data)])) end,
    is_null=function() return false end,
}
local saved_groups,located_groups
local saved_cursor
package.loaded["miuread.thought_database"]={
    range_cursor=function(_,id,uid,range,account)
        assert(id=="book" and uid=="7" and account=="42")
        return range=="5-15" and saved_cursor or nil
    end,
    save_range_page=function(_,id,uid,range,account,expected,page)
        assert(id=="book" and uid=="7" and range=="5-15" and account=="42" and expected==saved_cursor)
        saved_groups={page}
        saved_cursor=page.cursor
        return true
    end,
    load_checkpoint=function() return {underlines={{markRange="5-15",markText="可靠的正文片段"}}} end,
    load_locations=function() return {} end,
    save_locations=function(_,_,_,rows) located_groups=rows;return true end,
    match_review_ids=function(_,id,ids)
        assert(id=="book")
        local result={}
        for _,key in ipairs(ids) do if key=="selected" then result[key]=true end end
        return result
    end,
}
package.loaded["miuread.thoughts"]={}
package.loaded["miuread.annotation_coord"]={}
package.loaded["miuread.annotations.posmap"]={}
package.loaded["miuread.source_position"]={readCachedChapter=function() end}
local Sync=require("miuread.comment_sync")
local calls={marks=0,range=0}
local mode
local api={}
function api:underlines(id,uid)
    assert(id=="book" and uid=="7")
    calls.marks=calls.marks+1
    if mode=="failed" then error("fixture offline") end
    if mode=="wrong" then return {bookId="other",underlines={}} end
    return {bookId=id,chapterUid=7,underlines={{range="5-15"},{range="000"},{range="7-7"}}}
end
function api:readreviews(id,uid,batch)
    assert(id=="book" and uid=="7" and #batch==1 and batch[1].range=="5-15")
    calls.range=calls.range+1
    if calls.range>1 then
        assert(batch[1].count==5 and batch[1].synckey==nil and batch[1].maxIdx==8)
        if mode=="bad-cursor" then return {bookId=id,chapterUid=7,reviews={
            {range="5-15",hasMore=true,maxIdx=8,pageReviews={}}}} end
        return {bookId=id,chapterUid=7,reviews={
            {range="5-15",hasMore=false,pageReviews={{reviewId="second",content="续页想法"}}}}}
    end
    assert(batch[1].count==5 and batch[1].synckey==0 and batch[1].maxIdx==nil)
    return {bookId=id,chapterUid=7,reviews={
        {range="5-15",hasMore=true,maxIdx=8,pageReviews={
            {reviewId="selected",content="这是其他读者留下的想法",author={name="读者",vid="123"}},
            {reviewId="mine",content="这是我自己的想法",author={name="我",vid="42"}},
        }},
        {range="16-20",pageReviews={{reviewId="other-range",content="另一段的想法"}}},
    }}
end
local store={data_dir="/data"}
function store:book_cache_path(id) return "/data/books/"..id end
function store:book_dir(id) return self:book_cache_path(id) end
function store:auth() return {account={vid="42"}} end
local sync=Sync:new(api,store)
assert(sync:load_marks("book","7")==nil)
assert(#sync:fetch_marks("book","7").underlines==1 and calls.range==0)
mode="wrong"
assert(not sync:fetch_marks("book","7") and #sync:load_marks("book","7").underlines==1)
mode="failed"
assert(not sync:fetch_marks("book","7") and sync:load_marks("book","7").book_id=="book")
assert(not sync:fetch_range("book","7","7") and calls.range==0)
local range=assert(sync:fetch_range("book","7","5-15"))
assert(#range.texts==1 and range.texts[1].review_id=="selected" and calls.range==1)
assert(saved_groups[1].range=="5-15" and #saved_groups[1].texts==1 and saved_cursor==8)
assert(sync:range_has_more("book","7","5-15"))
assert(not sync:range_has_more("book","7","7"))
assert(sync:fetch_range("book","7","5-15").texts[1]==nil and calls.range==1)
mode="bad-cursor"
assert(not sync:fetch_range("book","7","5-15",true) and saved_cursor==8)
mode=nil
local more=assert(sync:fetch_range("book","7","5-15",true))
assert(more.known_end and more.texts[1].review_id=="second" and saved_cursor==0)
assert(not sync:range_has_more("book","7","5-15"))
assert(sync:fetch_range("book","7","5-15",true).known_end and calls.range==3)

local db=require("miuread.thought_database")
local cached_checkpoint={book_id="book",chapter_uid="7",job_id="interrupted-refresh",pending_ranges={"5-15"}}
db.load_checkpoint=function() return cached_checkpoint end
db.record_fetch=function(_,_,_,_,checkpoint,meta)
    assert(checkpoint.job_id=="interrupted-refresh")
    cached_checkpoint=checkpoint
    return {comments=1,groups=1}
end
require("miuread.thoughts").load=function() return {} end
require("miuread.thoughts").clear_memory_cache=function() end
local chapter=Sync:new(api,store,{
    from_cache=function(_,data) return U.copy(data) end,
    to_cache=function(_,data) return U.copy(data) end,
    merge=function(_,_,data) return data end,
    fetch_chapter=function(_,id,uid,progress,options)
        assert(options.force_refresh==false and options.previous.pending_ranges[1]=="5-15")
        return {book_id=id,chapter_uid=uid,underline_request_ok=true,complete=true,review_groups={},
            underlines={{range="5-15",markText="可靠的正文片段"}}}
    end,
})
function chapter:status()
    return {status="partial",has_cache=true,comments=1,groups=1}
end
assert(chapter:fetch("book","7",{force=true,job_id="interrupted-refresh"}).complete)

local doc={file="/book.epub",top=0,page=1}
function doc:getCurrentPos() return self.top end
function doc:getCurrentPage() return self.page end
function doc:getPosFromXPointer(value) return tonumber(value) end
function doc:isXPointerInDocument() return true end
function doc:compareXPointers(a,b)
    a,b=tonumber(a),tonumber(b)
    return a==b and 0 or (a<b and 1 or -1)
end
function doc:findAllText(quote)
    assert(quote=="可靠的正文片段")
    return {{start="5",["end"]="15"}}
end
function doc:getTextFromXPointers() return "可靠的正文片段" end
function doc:getScreenBoxesFromPositions()
    return {{x=20,y=30,w=40,h=15},{x=20,y=84,w=40,h=7}}
end
local verified=require("miuread.comment_locator")
local slices=0
local ui={document=doc,dimen={x=0,y=0,w=100,h=100},view={
    footer_visible=true,footer={getHeight=function() return 12 end},
}}
local marks=sync:load_marks("book","7").underlines
local groups,stats=verified.resolve(store,nil,ui,"book","7",{local_document=true,
    local_bounds={start="1",ending="20"},location_save=function(rows)
        located_groups=rows
        return true
    end},{{range="5-15",mark_only=true}},marks,function() slices=slices+1 end)
assert(stats.matched==1 and slices==1 and #located_groups==1 and groups[1].mark_only)

local screen={getHeight=function() return 100 end,getWidth=function() return 100 end,
    scaleBySize=function(_,value) return value end}
package.loaded.device={screen=screen}
package.loaded["ffi/blitbuffer"]={Color8=function(value) return value end}
local Overlay=require("miuread.comment_overlay")
local overlay=Overlay:new()
overlay.ui=ui
assert(overlay:setRecords(groups))
assert(not overlay:setRecords(groups))
local painted={}
local bb={paintRect=function(_,x,y)
    assert(x>=20 and y<88)
    painted[#painted+1]=y
end}
overlay:paintTo(bb)
assert(painted[1]==47 and overlay:hitTest{x=25,y=47}.range=="5-15")
assert(not overlay:hitTest{x=25,y=95})
doc.page=2
assert(not overlay:hitTest{x=25,y=47})
doc.page,doc.top=1,0
overlay:setEnabled(false)
assert(not overlay:hitTest{x=25,y=47})

local Replies=require("miuread.review_replies")
local now=os.time()
assert(Replies.save(store,{id="selected",items={},fetched_at=now},"42"))
assert(Replies.save(store,{id="other",items={},fetched_at=now},"42"))
local ids=Replies.legacy_ids_for_book(store,"book")
assert(ids.selected and not ids.other)
assert(Replies.save(store,{id="selected",items={{content="本书回复"}},fetched_at=now},"42","book"))
assert(Replies.load(store,"selected",true,"42","book").items[1].content=="本书回复")
assert(not Replies.load(store,"selected",true,"123","book"))
assert(Replies.prune_legacy(store,ids))
assert(not Replies.load(store,"selected",true,"42") and Replies.load(store,"other",true,"42"))
print("Inline comments: marks without range fetch, exact anchors, page-safe taps, scoped replies and legacy cleanup passed")

-- Offset-only marks use the native UTF-16 coordinate space, even when a
-- non-BMP character or an entity precedes the quoted text.
package.loaded["miuread.annotations.posmap"]=nil
package.loaded["miuread.source_position"]=nil
package.loaded["miuread.eink_comment_source"]=nil
package.loaded.util.splitToChars=function(text)
    local result={}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do result[#result+1]=char end
    return result
end
local Native=require("miuread.eink_comment_source")
local chapter_raw="<html><head><title>Example</title></head><body><p>😀 <em>Darcy &amp; Elizabeth</em> were here.</p></body></html>"
local source_prefix=assert(chapter_raw:find("Darcy",1,true))-1
local range_start=source_prefix-2 -- one four-byte UTF-8 character uses two UTF-16 units
local native_range=range_start.."-"..(range_start+#"Darcy &amp; Elizabeth")
assert(Native.quote(Native.make_map(chapter_raw,"html"),native_range)=="Darcy & Elizabeth")
assert(Native.quote(Native.make_map("😀Regular text","text"),"1-5")==nil)
assert(Native.quote(Native.make_map("😀Regular text","text"),"2-9")=="Regular")

local generated=arg[1] and (arg[1].."/native-comment.epub") or os.tmpname()
U.mkdir=function() return true end
local Epub=require("miuread.epub")
local Installer=require("miuread.epub_installer")
local function make_chapter(body)
    Epub.build(generated,{bookId="book",title="Fixture",author="Fixture"},
        {{uid="7",index=1,title="Fixture",body=body}},nil,{},nil,
        {book_id="book",variant="online",standalone=true,chapter_uid="7",
            chapters={{uid="7",index=1,title="Fixture"}}})
end
make_chapter('<h1 class="miu-chapter-title">Fixture</h1><p>😀 <em>Darcy &amp; Elizabeth</em> were here.</p>')
assert(Installer.read_chapter_text(generated,1):find("Darcy",1,true))
assert(Installer.read_chapter_text_by_uid(generated,"book","7"):find("Darcy",1,true))
assert(not Installer.read_chapter_text_by_uid(generated,"wrong","7"))
assert(not Installer.read_chapter_text_by_uid(generated,"book","8"))
local native_fetches=0
local source_reader={eink_comment_source=function(_,id,uid)
    assert(id=="book" and uid=="7")
    native_fetches=native_fetches+1
    return chapter_raw,"html"
end}
files["/data/books/book/comment-marks-7.json"]=nil
function api:underlines(id,uid)
    calls.marks=calls.marks+1
    return {bookId=id,chapterUid=uid,underlines={{range=native_range}}}
end
assert(sync:fetch_marks("book","7",{file=generated,reader=source_reader}))
assert(Native.exists(store,"book","7") and native_fetches==1)
local fetched_marks=calls.marks
assert(sync:fetch_marks("book","7",{file=generated,reader=source_reader}))
assert(native_fetches==1 and calls.marks==fetched_marks)
local native_map=assert(Native.for_document(store,"book","7",generated))
local quote=verified.quoteFor({range=native_range,mark_only=true},{},nil,nil,native_map)
assert(quote=="Darcy & Elizabeth")
make_chapter('<p>😀 <em>Darcy &amp; Elizabeth</em><span class="fn-ref"><a epub:type="noteref" role="doc-noteref" href="#wt_1" id="wtref_1">[1]</a></span> were here.</p>'
    ..'<div class="footnotes" role="doc-endnotes"><aside role="doc-footnote" id="wt_1" class="footnote weread-book-footnote"><p>Generated footnote 1</p></aside></div>')
assert(Native.for_document(store,"book","7",generated),"generated footnotes must not invalidate E-Ink comments")
make_chapter('<p>Another edition <em>Darcy &amp; Elizabeth</em> were here.</p>'
    ..'<aside role="doc-footnote" id="wt_1" class="footnote weread-book-footnote"><p>Generated footnote 1</p></aside>')
assert(not Native.for_document(store,"book","7",generated))
assert(not Native.ensure(source_reader,store,"book","7",generated))
os.remove(generated)
print("Native comment offsets preserve UTF-16 and are checked against the actual EPUB")
