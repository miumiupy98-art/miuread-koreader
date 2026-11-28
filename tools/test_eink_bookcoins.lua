package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["miuread.protocol"]={}
local Coins=require("miuread.eink_bookcoins")
local id="1234"
local writes={}
local book={title="测试书",payType=1,price=10}
local chapter={chapterUid=8,title="测试章",price=3}
local balance={balance=20,giftBalance=0}
local renew_membership=false
local result_kind="success"
local client={}
function client:book(book_id,details)
    assert(book_id==id and details)
    return book
end
function client:membership_summary()
    return {expired=0,expiredTime=renew_membership and (os.time()+3600) or 0}
end
function client:catalog(book_id,refresh)
    assert(book_id==id and refresh==true)
    return {updated={chapter}}
end
function client:request(method,path,fields,stage,opt)
    assert(method=="POST" and stage=="account")
    assert(fields.pf=="wechat_wx-2001-android-100-weread" and fields.release==1 and fields.zoneid=="1")
    if path=="/pay/balance" then return balance end
    assert(path=="/pay/buyBook" or path=="/pay/buyChapters")
    assert(opt.single_dispatch and opt.include_service_error_code)
    writes[#writes+1]={path=path,fields=fields}
    if result_kind=="insufficient" then error("error_code=-2112",0) end
    if result_kind=="unclear" then error("network timeout",0) end
    if path=="/pay/buyBook" then book.paid=1 else chapter.paid=1 end
    return {}
end

local offer=Coins.quote(client,id,"8")
assert(offer.state=="ready" and offer.scope=="book" and offer.price==1000)
assert(Coins.submit(client,offer).state=="owned")
assert(#writes==1 and writes[1].fields.price==10 and writes[1].path=="/pay/buyBook")
assert(Coins.submit(client,offer).state=="owned" and #writes==1)

book.paid=nil
book.payType=1+2097152
balance={balance=20,giftBalance=15}
assert(Coins.quote(client,id,"8").state=="insufficient")
assert(Coins.submit(client,offer).state=="insufficient" and #writes==1)
balance.giftBalance=nil
assert(Coins.quote(client,id,"8").state=="unavailable")

book.payType=2
book.mcardDiscount=20
renew_membership=true
balance={balance=9,giftBalance=0}
assert(Coins.quote(client,id,"").state=="chapter_required")
offer=Coins.quote(client,id,"8")
assert(offer.scope=="chapter" and offer.price==240)
chapter.price=4
assert(Coins.submit(client,offer).state=="changed" and #writes==1)
chapter.price=3
result_kind="insufficient"
assert(Coins.submit(client,offer).state=="insufficient" and #writes==2)
local fields=writes[2].fields
assert(writes[2].path=="/pay/buyChapters" and fields.chapterIds=="8" and fields.totalprice==2.4)
assert(fields.isautopay=="0" and fields.isMCard==1)
result_kind="unclear"
assert(Coins.submit(client,offer).state=="pending" and #writes==3)
assert(Coins.verify(client,offer).state=="pending" and #writes==3)
chapter.paid=true
assert(Coins.verify(client,offer).state=="owned" and #writes==3)
print("Bookcoin quotes, stored balance, discount changes, manual chapters and uncertain purchase readback passed")
