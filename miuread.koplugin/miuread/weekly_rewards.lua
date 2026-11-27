-- The reference plugin uses this App endpoint for weekly reading rewards.
local M={}
local PATH="/weekly/exchange"
local PLATFORM="weread_wx-2001-iap-2001-iphone"

local function integer(value)
    local number=tonumber(value)
    if number and number>=0 and number<math.huge and number%1==0 then return number end
end

local function parse(value)
    local model={tiers={},reading_seconds=integer(value.readingTime),reading_days=integer(value.readingDay)}
    local found=false
    for _,key in ipairs({"readtimeAwards","readdayAwards","readgoalAwards"}) do
        local rows=value[key]
        if type(rows)=="table" then
            found=true
            for _,row in ipairs(rows) do
                local id=integer(row.awardLevelId)
                local status=integer(row.awardStatus)
                if id and id>0 and status and status<=2 then
                    local tier={id=id,status=status,chosen=integer(row.awardChooseType),
                        title=tostring(row.awardLevelDesc or ""), detail=tostring(row.awardChoicesDesc or ""),
                        status_text=tostring(row.awardStatusDesc or ""),choices={}}
                    for _,item in ipairs(type(row.awardChoices)=="table" and row.awardChoices or {}) do
                        local kind,quantity=integer(item.choiceType),integer(item.awardNum)
                        if (kind==1 or kind==2) and quantity and quantity>0 then
                            tier.choices[#tier.choices+1]={kind=kind,quantity=quantity,
                                enabled=item.canChoice~=false and integer(item.canChoice)~=0}
                        end
                    end
                    model.tiers[#model.tiers+1]=tier
                end
            end
        end
    end
    if not found then error("奖励列表暂未取得",0) end
    return model
end

local function find_tier(model,id)
    for _,tier in ipairs(model.tiers) do
        if tier.id==id then return tier end
    end
end

function M.query(client)
    return parse(client:request("POST",PATH,{awardLevelId=0,awardChoiceType=0,isExchangeAward=0,pf=PLATFORM},"rewards"))
end

function M.balance(client)
    local value=client:request("POST","/pay/balance",{pf=PLATFORM},"rewards",
        {timeout={3,5},no_auth_recovery=true})
    return tonumber(value.balance)
end

function M.presentation(model,balance,week)
    local rows,claimable,claimed={},0,0
    for _,tier in ipairs(model.tiers) do
        local row={id=tier.id,title=tier.title~="" and tier.title or "阅读奖励",detail=tier.detail,choices={}}
        if tier.status==2 then
            claimed=claimed+1
            row.claimed=true
            row.status=tier.chosen==1 and "已领取 · 体验卡" or (tier.chosen==2 and "已领取 · 书币" or "已领取")
        elseif tier.status==1 then
            for _,choice in ipairs(tier.choices) do
                if choice.enabled then
                    local label=choice.kind==1 and (choice.quantity.." 天体验卡") or (choice.quantity.." 书币")
                    row.choices[#row.choices+1]={kind=choice.kind,quantity=choice.quantity,label=label}
                end
            end
            if #row.choices>0 then claimable=claimable+1 else row.status="暂不可领" end
        else
            row.status=tier.status_text~="" and tier.status_text or "未达成"
        end
        rows[#rows+1]=row
    end
    local summary={}
    if week and week~="" then summary[#summary+1]="本周 "..week end
    if model.reading_seconds then
        local minutes=math.floor(model.reading_seconds/60)
        local hrs=math.floor(minutes/60)
        local time=hrs>0 and (hrs.." 小时 "..(minutes%60).." 分") or (minutes.." 分钟")
        summary[#summary+1]="已读 "..time
    end
    if model.reading_days then summary[#summary+1]=model.reading_days.." 天" end
    local headline=claimable>0 and ("还有 "..claimable.." 档可领取") or "本周暂无可领取奖励"
    if #rows>0 and claimed==#rows then headline="本周奖励已全部领取" end
    return {rows=rows,headline=headline,summary=table.concat(summary," · "),
        balance_text=type(balance)=="number" and string.format("%.2f 书币",balance) or ""}
end

function M.claim(client,id,kind,quantity)
    local model=M.query(client)
    local tier=find_tier(model,id)
    if not tier or tier.status~=1 then return {state="changed",model=model} end
    local selected
    for _,choice in ipairs(tier.choices) do
        if choice.enabled and choice.kind==kind and choice.quantity==quantity then selected=choice;break end
    end
    if not selected then return {state="changed",model=model} end
    -- The account and credentials are checked again at dispatch. Only the
    -- readback may retry, since a lost write response can follow a real claim.
    pcall(client.request,client,"POST",PATH,{
        awardLevelId=id,awardChoiceType=kind,isExchangeAward=1,pf=PLATFORM,
    },"rewards",{single_dispatch=true})
    local readable,current=pcall(M.query,client)
    local verified=readable and find_tier(current,id)
    if verified and verified.status==2 and verified.chosen==kind then
        return {state="received",model=current}
    end
    return {state="unconfirmed",model=readable and current or nil}
end

return M
