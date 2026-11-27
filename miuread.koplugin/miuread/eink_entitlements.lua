local bit=require("bit")
local Protocol=require("miuread.protocol")
local M={}
local MEMBER=4096
local COUPON=8192
local PAID_MEMBER=1048576
local FREE=32
local LIMITED_FREE=64

local function enabled(value)
    return value==true or tonumber(value)==1
end

local function nonnegative(value)
    local n=tonumber(value)
    return n and n>=0 and n%1==0 and n or nil
end

function M.summary(member,now)
    local remaining=nonnegative(member.remainTime)
    local expires=nonnegative(member.expiredTime)
    local paid_remaining=nonnegative(member.payingRemainTime)
    local expired=enabled(member.expired) or (expires and expires>0 and expires<=now)
    local paying=enabled(member.isPaying) or enabled(member.paying)
    return {
        remaining=remaining, expires=expires, expired=expired,
        paid_remaining=paid_remaining, paying=paying,
        permanent=enabled(member.permanent),
        trial_remaining=remaining and (paying and paid_remaining and math.max(0,remaining-paid_remaining)
            or (not paying and remaining) or nil),
        coupons=nonnegative(member.remainCoupon),
    }
end

function M.purchase_url(vid)
    if not tostring(vid or ""):match("^%d+$") then return nil end
    -- VidEncrpyt.encrypt in the APK uses the same numeric encoding as reader links.
    return "https://weread.qq.com/web/redirect?type=memCard&memCardExpand=1&eink=1&vid="
        ..Protocol.obfuscate(vid)
end

function M.locked_options(client,id,uid)
    local book=client:book(id,true)
    local member=M.summary(client:membership_summary(),os.time())
    local pay_type=tonumber(book.payType) or 0
    local catalog=client:catalog(id)
    local chapter
    for _,item in ipairs(catalog.updated) do
        if tostring(item.chapterUid)==uid then chapter=item;break end
    end
    local result={title=chapter and chapter.title,coupons=member.coupons,member=member}
    if not chapter then return result end
    result.already_paid=enabled(chapter.paid) or enabled(book.paid)
    local tips=client:request("GET","/reader/tips",{bookId=id,from="reader"},"online_access")
    if tips.bookId and tips.bookId~="" and tostring(tips.bookId)~=id then
        error("微信读书返回的权益信息与当前书籍不一致",0)
    end
    local paid_only=bit.band(pay_type,PAID_MEMBER)~=0 or tonumber(tips.payingType)==1
    local has_member=member.permanent or (not member.expired and (member.remaining or 0)>0)
    local active_benefit=has_member and (paid_only and (member.permanent
        or (member.paying and (member.paid_remaining or 0)>0))
        or (not paid_only and (bit.band(pay_type,MEMBER)~=0 or enabled(tips.canFreeRead))))
    if not has_member and not paid_only and bit.band(pay_type,FREE+LIMITED_FREE)==0
        and (bit.band(pay_type,MEMBER)~=0 or enabled(tips.canFreeRead)) then
        local offer=client:request("GET","/act/recvinfinite",{cmd="query",action="get",from="reader"},"account")
        result.trial_days=nonnegative(offer.day)
        if result.trial_days==0 then result.trial_days=nil end
    end
    result.can_use_coupon=not result.trial_days and not result.already_paid and not active_benefit
        and tonumber(chapter.price)~=0 and not enabled(chapter.free)
        and bit.band(pay_type,COUPON)~=0 and (member.coupons or 0)>0
    if not result.trial_days and not result.can_use_coupon and not active_benefit and enabled(tips.readAfterPay)
        and not member.permanent then
        if has_member then
            result.can_buy_member=not member.paying
        else
            local ok,features=pcall(client.request,client,"GET","/feature",{synckey=0},"account")
            local raw
            if ok and type(features.feature)=="table" then raw=features.feature.membership_show_buy end
            -- The APK's BooleanFeatureWrapper sets the default to true.
            result.can_buy_member=raw==nil or enabled(raw) or raw=="true"
        end
    end
    return result
end

function M.apply(client,id,uid,action)
    if not id:match("^[%w_-]+$") or not uid:match("^%d+$") then error("当前书籍或章节无效",0) end
    local state=M.locked_options(client,id,uid)
    if state.already_paid then return {reopen=true,member=state.member} end
    local mutation={single_dispatch=true}
    if action=="coupon" and state.can_use_coupon then
        client:request("GET","/coupon/buyChapter",{bookId=id,chapterIds=uid},"account",mutation)
    elseif action=="trial" and state.trial_days then
        client:request("GET","/act/recvinfinite",{cmd="recv",action="get",from=""},"account",mutation)
    else
        error("微信读书当前未确认此操作可用，请重新查看本章权益",0)
    end
    -- Entitlement is confirmed by opening the original chapter again.
    -- A readback timeout must not cause the claim or coupon request to be repeated.
    local checked,summary=pcall(client.membership_summary,client)
    return {reopen=true,member=checked and M.summary(summary,os.time()) or nil}
end

return M
