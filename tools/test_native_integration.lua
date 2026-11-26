-- Production E-Ink modules with an in-memory account and HTTP fixtures.
package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["miuread.digests"]={sha256=function(value) return "fixture:"..#value end}
package.loaded["miuread.diagnostic_log"]={now=os.clock,record=function() end}
package.loaded["miuread.http"]={
    auth_error_code=function(value) return tostring(value):match("error_code=(%-?%d+)") end,
    is_auth_error=function(value) return tostring(value):find("HTTP 401",1,true)~=nil end,
    is_rate_limit_error=function() return false end,rate_limit_details=function() return nil end,
}
local encoded
local null={}
package.loaded["miuread.json"]={encode=function(body)
        encoded=body
        local item=body.books and body.books[1] or body
        return item.hours and '{"hours":{}}' or '{"fixture":1}'
    end,
    is_null=function(value) return value==null end}
local U=require("miuread.util")
local Shelf=require("miuread.shelf_client")
local Native=require("miuread.eink_client")
local Coordinates=require("miuread.eink_coordinates")
local ReadtimeProtocol=require("miuread.readtime_protocol")
ReadtimeProtocol.time_zone=function() return "+00:00" end

local current={auth_revision=0}
local identity_counter=0
local store={
    auth=function() return U.copy(current) end,
    preferences=function() return {api_transport="web"} end,
    read_persisted=function(_,key) assert(key=="auth"); return U.copy(current) end,
    generate_login_session_id=function() identity_counter=identity_counter+1; return "session-"..identity_counter end,
    save_auth=function(_,value,options)
        if options.expected_revision~=current.auth_revision then return false,"revision mismatch" end
        local revision=current.auth_revision
        current=U.copy(value)
        current.auth_revision=revision+1
        return true
    end,
}
local calls,remote,post_count={},nil,0
local flow_vid,request_kind,shelf_failure="test-account","read",false
local book_format="epub"
local durations=false
local response_error
local quote="synthetic anchor sentence"
local search={result={{chapterUid=7,keywordStart=113,absStart=110,absEnd=170,
    abstract="😀 <em>"..quote.."</em>."}},totalCount=1,hasMore=false}
local http={
    get_json=function(_,url,opt)
        calls[#calls+1]=url
        assert(opt.auth==false and not (opt.headers and opt.headers.Cookie))
        if url:find("/wxticket",1,true) then return {signature="fixture",timeStamp=1} end
        if url:find("/sdk/qrconnect",1,true) then return {errcode=0,uuid="fixture-id"} end
        if url:find("/connect/l/qrconnect",1,true) then return {wx_errcode=405,wx_code="fixture-code"} end
        if url:find("/shelf/sync",1,true) then
            if shelf_failure then error("HTTP 503",0) end
            assert(opt.headers.vid==flow_vid and url:find("lectureSynckey=0",1,true))
            return {books={}}
        end
        if url:find("/book/getProgress",1,true) then return remote end
        if url:find("/book/info",1,true) then return {bookId="sample",title="Fixture",format=book_format,version=4} end
        if url:find("/book/search",1,true) then
            if not url:find("keyword=fixture",1,true) then return search end
            assert(url:find("fragmentSize=100",1,true) and url:find("count=10",1,true))
            if url:find("maxIdx=0",1,true) then
                return {bookId="sample",result={{chapterUid=7,chapterIdx=2,searchIdx=1,abstract="<em>fixture</em> text"}},
                    totalCount=2,hasMore=true}
            end
            assert(url:find("maxIdx=1",1,true))
            return {bookId="sample",result={{chapterUid=8,chapterIdx=3,searchIdx=1,abstract="fixture"}},
                totalCount=2,hasMore=true}
        end
        if url:find("/config",1,true) then return {token="configuration"} end
        if url:find("/feature",1,true) then return {feature={guest_token="fixture"}} end
        if url:find("/pay/memberCardSummary",1,true) then return {remainTime=86400,expiredTime=2000000000} end
        if url:find("/book/bookmarklist",1,true) then return {data={}} end
        if url:find("/book/bestbookmarks",1,true) then
            assert(url:find("^https://i%.weread%.qq%.com/book/bestbookmarks%?"))
            assert(url:find("count=500",1,true) and url:find("synckey=0",1,true) and url:find("maxIdx=0",1,true))
            return {bookId="sample",totalCount=3,
                chapters={{chapterUid=7,chapterIdx=2,title="Sample chapter"}},
                data={{chapterUid=8,chapterIdx=3,range="11-15",markText="Second",totalCount=4},
                    {chapterUid=7,range="6-10",markText="First",totalCount=6}},
                updated={{chapterUid=7,range="6-10",markText="Updated first",totalCount=7}}}
        end
        if url:find("/review/single",1,true) then
            assert(url:find("^https://i%.weread%.qq%.com/review/single%?"))
            assert(url:find("commentsCount=20",1,true) and url:find("commentsDirection=1",1,true))
            local second=url:find("commentsMaxIdx=1",1,true)
            assert(url:find(second and "synckey=9" or "bookReviewCount=1",1,true))
            return {review={review={reviewId="review-a",bookId="sample",chapterUid=7}},
                comments={{commentId=second and "c2" or "c1",content="reply fixture",
                    author={name="fixture author"},replyUser={name="fixture recipient"}}},
                commentsCount=2,synckey=9}
        end
        error("unexpected fixture GET")
    end,
    post_json=function(_,url,body,opt)
        if url:find("/pay/balance",1,true) then
            assert(body.pf=="android" and body.zoneid=="1" and opt.headers.vid==flow_vid)
            return {balance=12.5,giftBalance=3}
        end
        assert(url=="https://i.weread.qq.com/login" and opt.headers.accessToken==nil)
        assert(body.code=="fixture-code" or body.refreshToken=="fixture-refresh")
        return {vid=flow_vid,accessToken=body.code and "fixture-access" or "fixture-renewed",
            refreshToken="fixture-refresh",name="Fixture"}
    end,
    json=function(_,options)
        if request_kind=="read" then
            assert(options.url=="https://i.weread.qq.com/book/read" and options.retries==0)
            assert(encoded.chapterOffset==113)
            if durations then
                assert(encoded.readingTime==19 and #encoded.hours==2 and encoded.risk==3)
                assert(encoded.hours[1].readingTime==9 and encoded.hours[2].readingTime==10)
            else
                assert(options.body:find('"hours":[]',1,true) and encoded.readingTime==0 and #encoded.hours==0)
            end
            if not options.before_dispatch() then error("cancelled before dispatch") end
            post_count=post_count+1
            if response_error then error(response_error) end
            return {succ=1}
        end
        if request_kind=="resend" or request_kind=="time-only" then
            assert(options.url=="https://i.weread.qq.com/book/batchUploadProgress" and options.retries==0)
            assert(encoded.timestamp%1000==0 and #encoded.books==1)
            local book=encoded.books[1]
            assert(book.isResendReadingInfo==1 and book.voiceType==nil)
            if request_kind=="time-only" then
                assert(not book.chapterOffset and #book.hours==2 and book.readingTime==19)
            else
                assert(book.chapterOffset==113 and book.readingTime==(durations and 19 or 0))
            end
            assert(options.before_dispatch())
            post_count=post_count+1
            return {succ=1}
        end
        if request_kind=="pdf" then
            assert(options.url=="https://i.weread.qq.com/book/read" and encoded.chapterUid==2 and encoded.chapterIdx==2)
            assert(encoded.chapterOffset==0 and encoded.progress==20 and encoded.currentProgress==20)
            assert(options.before_dispatch())
            post_count=post_count+1
            return {succ=1}
        end
        assert(options.url=="https://i.weread.qq.com/review/add" and options.retries==0)
        assert(options.body:find('"atUserVids":[]',1,true))
        return {succ=1}
    end,
}

local login=Shelf.new(http,store,true)
local uid=login:uid()
assert(login:qr_url(uid):find("fixture-id",1,true))
local signed=login:finish(login:poll(uid))
assert(signed.account.vid==flow_vid and signed.cookies==nil and signed.api_key==nil and signed.native_shelf.installId)
assert(login:validate_commit(signed))
assert(store:save_auth(signed,{expected_revision=0}))
assert(not login:validate_commit(signed))
assert(Shelf.refresh(http,store).accessToken=="fixture-renewed")
local install_id=current.native_shelf.installId
assert(install_id==signed.native_shelf.installId)
local unfinished=Shelf.new(http,store,true)
shelf_failure=true
assert(not pcall(unfinished.finish,unfinished,{wx_code="fixture-code"}) and current.login_session_id=="session-1")
shelf_failure=false

local Api=require("miuread.api")
local api=Api:new(http,store)
api.web_backend.shelf=function() error("Web fallback was invoked") end
assert(type(api:shelf().books)=="table")
shelf_failure=true
local ok,err=pcall(api.shelf,api)
assert(not ok and tostring(err):find("HTTP 503",1,true))
shelf_failure=false
assert(not pcall(api.add_review,api,{}))
local native=Native.new(http,store)
assert(native:account_overview().balance==12.5)
assert(type(native:bookmark_list("sample").data)=="table")
api.web_backend.book_search=function() error("Web book search unexpectedly invoked") end
local book_hits=api:book_search("sample","fixture")
assert(book_hits.rows[1].chapter_uid=="7" and book_hits.rows[1].text=="fixture text" and book_hits.cursor==1)
assert(not api:book_search("sample","fixture",book_hits.cursor).cursor)
api.web_backend.best_bookmarks=function() error("Web best bookmarks unexpectedly invoked") end
local marks=api:best_bookmarks("sample")
assert(#marks.rows==2 and marks.total==3 and marks.partial)
assert(marks.rows[1].chapter_uid=="7" and marks.rows[1].chapter_title=="Sample chapter"
    and marks.rows[1].text=="Updated first" and marks.rows[1].count==7)
assert(not require("miuread.hot_marks").normalize({data={
    {bookId="other",chapterUid=7,range="6-10",markText="Wrong book"}}},"sample"))
local Replies=require("miuread.review_replies")
local reply_context={book_id="sample",chapter_uid="7"}
api.web_backend.review_comments=function() error("Web replies unexpectedly invoked") end
local reply_page=assert(Replies.normalize_native(api:review_comments("review-a"),"review-a",reply_context))
assert(reply_page.cursor.offset==1 and reply_page.cursor.synckey==9)
assert(reply_page.items[1].review_id=="c1" and reply_page.items[1].reply_to=="fixture recipient")
local second_page=assert(Replies.normalize_native(api:review_comments("review-a",reply_page.cursor),
    "review-a",reply_context,reply_page.cursor))
local replies=Replies.merge_native(reply_page,second_page)
assert(#replies.items==2 and replies.items[2].review_id=="c2" and not replies.cursor)
assert(not Replies.normalize_native({review={reviewId="wrong"},comments={}},"review-a",reply_context))
assert(Replies.normalize_native({reviewId="review-a",comments=null},"review-a",reply_context).total==0)
local first,last=Coordinates.lookup(native,"sample",7,quote)
assert(first==113 and last==113+#quote)
search.totalCount=2
assert(Coordinates.lookup(native,"sample",7,quote)==nil)
search.totalCount=1
search.result[1].keywordStart=140
assert(Coordinates.lookup(native,"sample",7,quote)==nil)
search.result[1].keywordStart=113


local short_calls=0
local short_native={request=function(_,verb,path,args)
    assert(verb=="GET" and path=="/book/search" and args.keyword=="123456789")
    short_calls=short_calls+1
    return {bookId="sample",totalCount=1,hasMore=false,result={
        {chapterUid=7,abstract="x<em>123456789</em>y",absStart=3,absEnd=14,keywordStart=4},
    }}
end}
local short_first,short_last=Coordinates.lookup(short_native,"sample",7,"123456789")
assert(short_first==4 and short_last==13)
assert(Coordinates.lookup(short_native,"sample",8,"123456789")==nil)
assert(Coordinates.lookup(short_native,"other",7,"123456789")==nil)
assert(Coordinates.lookup(short_native,"sample",7,"")==nil)
assert(Coordinates.lookup(short_native,"sample",7,"12\n456789")==nil)
assert(short_calls==3)
local duplicate_short={totalCount=1,hasMore=false,result={
    {chapterUid=7,abstract="123456789 123456789",absStart=3,absEnd=22,keywordStart=3},
}}
assert(Coordinates.locate(duplicate_short,7,"123456789")==nil)

local position=assert(Coordinates.position(native,{book={book_id="sample"}},{
    book_version=4,chapter_uid="7",chapter_index=2,anchor_text=quote,point_side="start",xpointer="xpointer-fixture",
},42))
position.captured_at=os.time()
remote={book={bookId="sample",chapterUid=8,chapterOffset=2,updateTime=position.captured_at+5,
    appId="another-device",progress=44}}
local conflict=native:write_position(position)
assert(not conflict.accepted and conflict.cloud_conflict and post_count==0)
remote.book.updateTime=position.captured_at-5
assert(not native:write_position(position,function() return false end).accepted and post_count==0)
assert(native:write_position(position).accepted and post_count==1)
remote.book.chapterUid,remote.book.chapterOffset=7,113
assert(native:write_position(position).already and post_count==1)
remote={book={bookId="sample",progress=40}}
assert(not native:write_position(position).accepted and post_count==1)
remote.book.chapterUid=-1
assert(native:write_position(position).accepted and post_count==2)
remote.book=null
assert(Native.progress_is_empty(native:progress("sample"),"sample"))
position.eink_resend=true
request_kind="resend"
assert(native:write_position(position).accepted and post_count==3)

book_format="pdf"
request_kind="pdf"
local Pdf=require("miuread.eink_pdf")
local pdf=assert(Pdf.capture({book={book_id="sample"},record={pdf_book_version=4}},3,10))
assert(Pdf.capture({book={book_id="sample"},record={pdf_book_version=4}},10,10).progress==100)
assert(not Pdf.capture({book={book_id="sample"},record={pdf_book_version=4}},11,10))
remote={book={chapterUid=1,chapterIdx=1,chapterOffset=0,bookVersion=4,
    updateTime=os.date("!%Y-%m-%dT%H:%M:%SZ",pdf.captured_at-5)}}
assert(native:pdf_progress("sample").chapter_idx==1)
assert(native:write_position(pdf).accepted and post_count==4)
remote.book.chapterUid,remote.book.chapterIdx=2,2
assert(native:write_position(pdf).already and post_count==4)
remote.book.otherType={}
assert(not pcall(native.pdf_progress,native,"sample"))
request_kind="review"
assert(native:add_review({bookId="sample",content="fixture",type=1}).succ==1)
assert(calls[1]:find("https://i.weread.qq.com/wxticket",1,true))

book_format="epub"
position.eink_resend=false
durations=true
local hour=math.floor((os.time()-3600)/3600)*3600
local seconds={
    {start_time=hour+3591,duration=15,time_zone="+00:00",book_version=4,risk=1},
    {start_time=hour+3606,duration=4,time_zone="+00:00",book_version=4,risk=2},
}
local now=position.captured_at
remote={
    book={bookId="sample",chapterUid=8,chapterOffset=2,updateTime=now-5,bookVersion=4},
    tts={bookId="sample",chapterUid=9,chapterOffset=22,updateTime=os.date("!%Y-%m-%dT%H:%M:%SZ",now+8),
        appId=current.native_shelf.deviceId,installId=current.native_shelf.installId,bookVersion=4},
}
assert(Native.progress_position(remote,"sample").chapter_uid=="9")
assert(not Native.other_progress_device(Native.progress_position(remote,"sample"),current.native_shelf))
request_kind="read"
local combined=native:write_position(position,function(with_time) assert(with_time); return true end,seconds)
assert(combined.accepted and combined.time_receipt.state=="confirmed" and post_count==5)
local no_write=native:write_position(position,function() return false end,seconds)
assert(not no_write.request_dispatched and no_write.time_receipt.state=="pending" and post_count==5)
response_error="timed out after sending"
local ambiguous=native:write_position(position,nil,seconds)
assert(not ambiguous.accepted and ambiguous.request_dispatched and ambiguous.time_receipt.state=="unknown" and post_count==6)
response_error=nil
request_kind="resend"
position.eink_resend=true
assert(native:write_position(position,nil,seconds).time_receipt.state=="confirmed" and post_count==7)
remote.tts.installId="another-install"
request_kind="time-only"
local other=native:write_position(position,nil,seconds)
assert(other.cloud_conflict and not other.request_dispatched and other.time_receipt.state=="confirmed" and post_count==8)


local shown,complete
local ui_class={extend=function()
    return {new=function(_,options) return options end}
end}
package.loaded["ui/widget/qrmessage"]=ui_class
package.loaded["ui/widget/buttondialog"]=ui_class
package.loaded["ui/widget/inputdialog"]=ui_class
package.loaded["miuread.gesture_bridge"]={}
package.loaded["device"]={screen={getWidth=function() return 758 end,getHeight=function() return 1024 end}}
package.loaded["ui/uimanager"]={
    scheduleIn=function(_,_,callback) callback() end,
    show=function(_,dialog) shown=dialog.text or shown end,close=function() end,
}
local Auth=require("miuread.auth")
local auth_flow=Auth.new_native(http,store,{
    is_online=function() return true end,
    online=function(_,_,callback) callback() end,
    on_auth_success=function(_,name) complete=name end,
})
flow_vid="another-synthetic-account"
auth_flow:start()
assert(complete=="Fixture" and shown=="https://open.weixin.qq.com/connect/confirm?uuid=fixture-id")
assert(current.account.vid==flow_vid and current.cookies==nil and current.login_session_id=="session-2")
print("Native first login, committed session renewal, no Web fallback, account data, verified UTF-16 position and single native write passed")

local readtime=require("miuread.eink_readtime")
assert(readtime.receipt(true,false,"HTTP 429, retry_after=60").state=="pending")
assert(readtime.receipt(true,false,"HTTP 499").state=="unknown")
assert(readtime.receipt(true,false,"timeout").state=="unknown")
assert(readtime.receipt(false,false,"failed before dispatch").state=="pending")
