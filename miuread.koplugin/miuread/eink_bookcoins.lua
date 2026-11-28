local bit=require("bit")
local Entitlements=require("miuread.eink_entitlements")
local M={}

-- BookHelper pay types and MidasPayConfig.PLATFORM from the E-Ink APK.
local BOOK,CHAPTERS,FREE,LIMITED_FREE,PAPER_TRIAL,ONLY_CHARGE=1,2,32,64,524288,2097152
local PLATFORM="wechat_wx-2001-android-100-weread"

local function yes(value)
    return value==true or tonumber(value)==1
end

local function cents(value)
    local n=tonumber(value)
    if n and n>=0 and n<100000000 then return math.floor(n*100+.5) end
end

local function get_chapter(client,id,uid)
    local catalog=client:catalog(id,true)
    for _,chapter in ipairs(catalog.updated or {}) do
        if tostring(chapter.chapterUid)==uid then return chapter end
    end
end

function M.verify(client,order)
    local book=client:book(order.id,true)
    if yes(book.paid) then return {state="owned"} end
    if order.scope=="chapter" then
        local chapter=get_chapter(client,order.id,order.uid)
        if chapter and yes(chapter.paid) then return {state="owned"} end
    end
    return {state="pending"}
end

function M.quote(client,id,uid)
    if type(id)~="string" or not id:match("^%d+$") then return {state="unsupported"} end
    local book=client:book(id,true)
    local pay_type=tonumber(book.payType) or 0
    if yes(book.paid) then return {state="owned"} end
    if (tonumber(book.soldout) or 0)~=0 or bit.band(pay_type,FREE+LIMITED_FREE+PAPER_TRIAL)~=0 then
        return {state="unsupported"}
    end
    local scope,title,raw_price="book",book.title,tonumber(book.price)
    if bit.band(pay_type,BOOK)==0 then
        if bit.band(pay_type,CHAPTERS)==0 then return {state="unsupported"} end
        if type(uid)~="string" or not uid:match("^%d+$") then return {state="chapter_required"} end
        local chapter=get_chapter(client,id,uid)
        if not chapter then return {state="unsupported"} end
        if yes(chapter.paid) then return {state="owned"} end
        if yes(chapter.free) then return {state="unsupported"} end
        scope,title,raw_price="chapter",chapter.title,tonumber(chapter.price)
    end
    local price=cents(raw_price)
    if not price or price==0 then return {state="unsupported"} end
    local info=Entitlements.summary(client:membership_summary(),os.time())
    local member=not info.expired and (info.expires or 0)>os.time()
    local discount=tonumber(book.mcardDiscount) or 0
    if member and discount>0 and discount<100 then
        price=cents(raw_price*(100-discount)/100)
    end
    if price<=0 then return {state="unsupported"} end
    local funds=client:request("POST","/pay/balance",
        {pf=PLATFORM,zoneid="1",release=1,onlyLimitFree=0,noSnapshot=0},"account")
    local available=cents(funds.balance)
    if bit.band(pay_type,ONLY_CHARGE)~=0 then
        local gift=cents(funds.giftBalance)
        available=available and gift and math.max(0,available-gift) or nil
    end
    if not available then return {state="unavailable"} end
    return {state=available>=price and "ready" or "insufficient",id=id,uid=scope=="chapter" and uid or nil,
        scope=scope,title=title,book_title=book.title,price=price,available=available,pay_type=pay_type,
        member=member and 1 or 0,cp_name=type(book.cpName)=="string" and book.cpName or ""}
end

function M.submit(client,order)
    local ok,current=pcall(M.quote,client,order.id,order.uid)
    if not ok then return {state="unavailable"} end
    if current.state~="ready" then return current end
    if current.price~=order.price or current.scope~=order.scope or current.pay_type~=order.pay_type
        or current.member~=order.member or current.cp_name~=order.cp_name then return {state="changed"} end
    local payload={bookId=current.id,pf=PLATFORM,zoneid="1",release=1,
        payType=current.pay_type,isMCard=current.member}
    local path
    if current.scope=="book" then
        path="/pay/buyBook"
        payload.price,payload.cpName=current.price/100,current.cp_name
    else
        path="/pay/buyChapters"
        payload.chapterIds,payload.totalprice,payload.isautopay=current.uid,current.price/100,"0"
    end
    local sent,result=pcall(client.request,client,"POST",path,payload,"account",
        {single_dispatch=true,include_service_error_code=true})
    if not sent then
        local code=tonumber(tostring(result):match("error_code=(%-?%d+)"))
            or tonumber(tostring(result):lower():match('"errcode"%s*:%s*(%-?%d+)'))
        if code==-2112 then return {state="insufficient"} end
        if code==-2281 or code==-2204 then return {state="changed"} end
    end
    local checked,observed=pcall(M.verify,client,order)
    return checked and observed or {state="pending"}
end

return M
