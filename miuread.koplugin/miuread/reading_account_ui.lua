local UIManager=require("ui/uimanager")
local U=require("miuread.util")
local Rewards=require("miuread.weekly_rewards")
local M={}

local function readonly(text,value,detail)
    return {text=text,post_text=value,detail=detail,enabled=false,readonly_label=true}
end

function M.member_benefits(plugin,back)
    return plugin:_fetch_eink_display("member-benefits","会员权益明细",function(api)
        local client=api:_native({})
        local member=client:membership_summary()
        local value=client:request("GET","/pay/memberCardDetails",{
            pf="android",getPredicted=(tonumber(member.expiredTime) or 0)>0 and 0 or 1,
        },"account")
        if type(value.data)~="table" then error("会员权益明细暂未取得",0) end
        local names={}
        for _,benefit in ipairs(value.data) do
            if type(benefit)=="table" and type(benefit.name)=="string" and benefit.name~="" then
                names[#names+1]=benefit.name
            end
        end
        if #value.data>0 and #names==0 then error("会员权益明细暂未取得",0) end
        return names
    end,{},function(names)
        local items={}
        for _,name in ipairs(names) do items[#items+1]=readonly(name) end
        if #items==0 then items[1]=readonly("暂无可显示的会员权益") end
        plugin:_show_miuread_menu("会员权益明细",items,{on_back=back})
    end)
end

function M.rewards(plugin,view,week,row,choice)
    local claim=choice~=nil
    local function unavailable(message)
        view:set_rewards{error=message}
    end
    if not plugin:logged_in() then
        unavailable("请先在「账户」扫码登录微信读书")
        return false
    end
    local function failed(error)
        if claim then
            unavailable("领取结果待确认，请重新获取本周奖励")
        else
            unavailable(plugin:_friendly_remote_error(error,"本周奖励"))
        end
    end
    local started,reason=plugin:_fetch_eink_display(claim and "weekly-reward-claim" or "weekly-rewards",
        "本周奖励",function(api)
            local client=api:_native({})
            local result=claim and Rewards.claim(client,row.id,choice.kind,choice.quantity)
                or {model=Rewards.query(client)}
            if result.model then
                local ok,balance=pcall(Rewards.balance,client)
                if ok then result.balance=balance end
            end
            return result
        end,{},function(result)
            if result.state=="unconfirmed" or not result.model then
                unavailable("领取结果待确认，请重新获取本周奖励")
                return
            end
            local data=Rewards.presentation(result.model,result.balance,week)
            if result.state=="changed" then data.notice="奖励状态已更新，请重新选择" end
            view:set_rewards(data)
        end,claim,failed,{silent=true,on_cancel=function() failed("奖励请求已中断") end})
    if not started then
        unavailable(reason=="offline" and "网络不可用，联网后重新获取" or "暂时无法获取本周奖励，请重试")
    end
    return started
end

local function show_entry(title,text)
    local TextViewer=require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{modal=true,title=title,text=text})
end

local function notebook(plugin,book,back)
    return plugin:_fetch_eink_display("cloud-notebook:"..book.id,"云端笔记",function(api)
        local AnnotationSync=require("miuread.annotation_sync")
        local marks_ok,marks=pcall(AnnotationSync.cloud_bookmarks,api,book.id)
        local thoughts_ok,thoughts=pcall(AnnotationSync.cloud_thoughts,api,book.id)
        if not marks_ok and not thoughts_ok then error(marks,0) end
        return {marks=marks_ok and marks or nil,thoughts=thoughts_ok and thoughts or nil}
    end,{},function(result)
        local items={}
        for _,row in ipairs(result.thoughts or {}) do
            local text=row.content~="" and row.content or row.quote
            items[#items+1]={text=U.utf8_truncate(text,36,"…"),post_text="想法",detail=row.chapter,
                keep_menu_open=true,callback=function()
                    local quote=row.quote~="" and row.content~="" and ("原文\n"..row.quote.."\n\n") or ""
                    show_entry("想法",quote..text)
                end}
        end
        for _,row in ipairs(result.marks or {}) do
            local label=row.kind==1 and "划线" or "书签"
            local text=row.content~="" and row.content or (row.chapter~="" and row.chapter or label)
            items[#items+1]={text=U.utf8_truncate(text,36,"…"),post_text=label,detail=row.chapter,
                keep_menu_open=true,callback=function() show_entry(label,text) end}
        end
        if not result.thoughts then items[#items+1]=readonly("想法暂未取得") end
        if not result.marks then items[#items+1]=readonly("书签和划线暂未取得") end
        if #items==0 then items[1]=readonly("暂无云端笔记") end
        plugin:_show_miuread_menu(book.title,items,{on_back=back})
    end)
end

function M.notebooks(plugin,back,cursor,previous)
    return plugin:_fetch_eink_display("cloud-notebooks","云端笔记","notebooks",{20,cursor or 0},function(value)
        local items={}
        local function reopen() M.notebooks(plugin,back,cursor,previous) end
        local next_cursor
        for _,row in ipairs(value.books or {}) do
            local data=type(row.book)=="table" and row.book or row
            local id=row.bookId or data.bookId
            local sort=tonumber(row.sort)
            if sort and (not next_cursor or sort<next_cursor) then next_cursor=sort end
            if id then
                local book={id=tostring(id),title=tostring(data.title or row.title or id)}
                items[#items+1]={text=book.title,detail=tostring(data.author or ""),
                    callback=function() notebook(plugin,book,reopen) end}
            end
        end
        if #items==0 then items[1]=readonly("暂无云端笔记") end
        if value.hasMore==true or tonumber(value.hasMore)==1 then
            if next_cursor and next_cursor>0 and (not cursor or next_cursor<cursor) then
                items[#items+1]={text="加载下一批",callback=function() M.notebooks(plugin,back,next_cursor,reopen) end}
            else items[#items+1]=readonly("暂未取得下一批笔记") end
        end
        plugin:_show_miuread_menu("云端笔记",items,{on_back=previous or back})
    end)
end

function M.progress_views(api,id)
    local ShelfProgress=require("miuread.shelf_progress")
    local options={retries=0,timeout={3,5},no_auth_recovery=true}
    local rows={}
    local web=api.web_backend
    -- These observers never apply a position locally and never submit a write.
    for _,source in ipairs({
        {label="E-Ink",client=api,method=api.progress},
        {label="Web",client=web,method=web.web_progress},
        {label="Agent",client=web,method=web._gateway_progress},
    }) do
        local ok,value=pcall(source.method,source.client,id,options)
        rows[#rows+1]={label=source.label,position=ok and ShelfProgress.parse(value,id) or nil}
    end
    return rows
end

return M
