package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.http"]={}
package.loaded["miuread.json"]={}
local Rights=require("miuread.download_entitlements")
local now=os.time()
local response={expired=0,expiredTime=now+600,remainTime=600,isPaying=1,payingRemainTime=300}
local status=Rights.account_status(response,now)
status.owner="A"
assert(status.member_until==now+600 and status.paid_until==now+300)
assert(Rights.account_status({expired=1,expiredTime=now,remainTime=0},now).member_until==0)
assert(not Rights.account_status({expiredTime=now+600},now))
local owned={kind="owned"}
local paid={kind="paid",checked_at=now,expires_at=now+300}
local trial={kind="member",checked_at=now,expires_at=now+600}
local loan={kind="loan",checked_at=now,expires_at=now+100}
local record={entitlement_owner="A",chapter_map={
    {uid="1",entitlement=owned},{uid="2",entitlement=paid},{uid="3",entitlement=trial},
}}
assert(Rights.active_for(record,owned,status,"A",now+1000)==true)
assert(Rights.active_for(record,paid,status,"A",now+300)==false)
assert(Rights.active_for(record,trial,status,"A",now+300)==true)
assert(Rights.active_for(record,loan,status,"A",now+100)==false)
assert(Rights.active_for(record,owned,status,"B",now)==nil)
assert(Rights.active_for(record,nil,status,"A",now)==nil)
assert(Rights.by_uid(record,"2")==paid)
local extended={owner="A",observed_at=now+380,member_until=now+1000,paid_until=now+1000}
assert(Rights.active_for(record,paid,extended,"A",now+381)==true)
assert(Rights.active_for(record,paid,extended,"A",now+350)==false)
assert(Rights.active_for(record,loan,extended,"A",now+381)==false)
local revoked={owner="A",observed_at=now+50,member_until=0,paid_until=0}
assert(Rights.active_for(record,paid,revoked,"A",now+55)==false)

local document={}
function document:getPageXPointer(page)
    return ({"/body/DocFragment[1]/body/p", "/body/DocFragment[2]/body/p",
        "/body/DocFragment[2]/body/p[2]", "/body/DocFragment[3]/body/p"})[page]
end
local rows=Rights.page_grants(record,document,2)
assert(#rows==1 and rows[1].uid=="2")
local available,until_at=Rights.window_end(record,rows,status,"A",now+290)
assert(available and until_at==now+300)
local span=Rights.clip_span({page=2,start_time=now+290,duration=30,source_start=now+290},until_at)
assert(span.duration==10 and span.source_start==now+290)
assert(not Rights.clip_span({page=2,start_time=now+300,duration=20},until_at))
assert(not Rights.window_end(record,Rights.page_grants(record,document,9),status,"A",now))
assert(not Rights.reminder_due("never",now) and not Rights.reminder_due(now+259200,now))
assert(Rights.reminder_due(now,now))

local calls,denied=0,false
local http={}
function http:download_to_file(url,path)
    calls=calls+1
    assert(url:find("offline=1",1,true) and not url:find("preview=1",1,true))
    if denied then error("HTTP 402",0) end
    return path,{}
end
local native=require("miuread.eink_client").new(http,{auth=function() return {account={vid="1234"}} end})
local chapter,book={chapterUid=2,price=1},{bookId="101",payType=1048576}
function native:_chapter_request_scope() return {book=book},chapter,"txt","0" end
function native:_durable_download_access() return chapter.paid==1 end
function native:request(_,path) assert(path=="/pay/memberCardSummary"); return response end
function native:authorized(fn) return fn({vid="1234"}) end
function native:options() return {} end
assert(not pcall(native.download,native,book,chapter,"local.txt",{}) and calls==0)
local _,_,_,info=native:download(book,chapter,"local.txt",{record_download_entitlement=true})
assert(calls==1 and info.download_grant.kind=="paid" and not info.online_expires)
denied=true
local ok,err=pcall(native.download,native,book,chapter,"local.txt",{record_download_entitlement=true})
assert(not ok and tostring(err):find("[MiuReadChapterLocked]",1,true) and calls==2)
denied=false
chapter.paid=1
_,_,_,info=native:download(book,chapter,"local.txt",{record_download_entitlement=true})
assert(info.download_grant.kind=="owned" and calls==3)
chapter.paid=nil
book.shortTimeRead={active=1,expireTime=now+100}
_,_,_,info=native:download(book,chapter,"local.txt",{record_download_entitlement=true})
assert(info.download_grant.kind=="loan" and info.download_grant.expires_at==now+100 and calls==4)
print("E-Ink offline entitlement, authoritative refusal, account renewal, mixed chapters and expiry clipping passed")
