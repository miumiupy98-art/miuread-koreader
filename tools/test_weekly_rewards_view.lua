package.path="./miuread.koplugin/?.lua;"..package.path
local widgets={}
function widgets:extend(value) return setmetatable(value,{__index=self}) end
function widgets:new(value)
    local object=self:extend(value)
    if object.init then object:init() end
    return object
end
function widgets:copy() return self:new{x=self.x,y=self.y,w=self.w,h=self.h} end
function widgets:combine() return self end
for _,name in ipairs({"ui/widget/container/centercontainer","ui/geometry","ui/gesturerange","ui/widget/horizontalgroup",
    "ui/widget/horizontalspan","ui/widget/container/inputcontainer","ui/widget/linewidget","ui/widget/overlapgroup",
    "ui/widget/verticalgroup","ui/widget/verticalspan","ui/widget/widget","ui/widget/container/widgetcontainer"}) do
    package.loaded[name]=widgets
end
package.loaded["ffi/blitbuffer"]={COLOR_WHITE=15,COLOR_BLACK=0,COLOR_GRAY=8,COLOR_LIGHT_GRAY=12,COLOR_DARK_GRAY=4}
package.loaded.device={screen={getWidth=function() return 758 end,getHeight=function() return 1024 end},
    hasKeys=function() return false end}
local shown,closed=0,0
package.loaded["ui/uimanager"]={
    show=function() shown=shown+1 end,
    close=function(_,view) closed=closed+1;view:onCloseWidget() end,
    setDirty=function() end,
}
package.loaded["miuread.dialog_transition"]={after_close=function() end}
package.loaded["miuread.transient_guard"]={close_all=function() end}
package.loaded["miuread.home_data"]={}
package.loaded["miuread.reader_skin"]={
    dp=function(value) return value end,face=function() return {} end,line=function() return 1 end,
    radius=function(value) return value end,expand_region=function(region) return region end,
    frame=function(w,h,options,content) return {w=w,h=h,options=options,content} end,
    divider=function(w,_,h) return {w=w,h=h} end,
}
local function text(value,w,h,_,opts)
    return {text=value,w=w,h=h,opts=opts}
end
package.loaded["miuread.ui_components"]={text=text,textbox=text,icon=function(value) return {text=value} end}

local loads,claims,confirms=0,0,0
local data={headline="还有 1 档可领取",summary="已读 5 分钟",balance_text="10.00 书币",rows={{
    id=4,title="读 5 分钟",detail="可得体验卡或书币",choices={
        {label="1 天体验卡",kind=1,quantity=1},{label="1 书币",kind=2,quantity=1},
    },
}}}
local answer
local view=assert(require("miuread.reading_stats_dialog").show("weread",{weekly={loading=true}},{
    on_load_rewards=function() loads=loads+1 end,
    on_confirm_reward=function(row,choice,callback)
        assert(row.id==4 and choice.kind==2)
        confirms=confirms+1;answer=callback
    end,
    on_claim_reward=function(dialog,row,choice)
        assert(dialog.reward_busy and row.id==4 and choice.kind==2)
        claims=claims+1
    end,
}))
local function find(widget,label,tap)
    if type(widget)~="table" then return end
    tap=widget.callback and widget or tap
    if widget.text==label then return tap or widget end
    for _,child in ipairs(widget) do
        local found=find(child,label,tap)
        if found then return found end
    end
end
assert(view.dimen.w==758 and view.dimen.h==1024 and view.selected_key=="weekly")
local root=view[1]
local first_tab
for i,child in ipairs(root) do
    if find(child,"周") then assert(first_tab and first_tab<i);break end
    if find(child,"奖励") then first_tab=i end
end
find(root,"奖励").callback()
assert(view.selected_key=="rewards" and loads==1 and shown==1 and closed==0)
assert(find(view[1],"正在获取本周奖励…"))
view:set_rewards(data)
assert(find(view[1],"10.00 书币") and find(view[1],"1 天体验卡").callback)
find(view[1],"1 书币").callback()
assert(confirms==1 and claims==0 and closed==0)
answer()
assert(claims==1 and not find(view[1],"1 书币").callback)
view:set_rewards{error="网络不可用"}
find(view[1],"重新获取").callback()
assert(loads==2 and view.selected_key=="rewards" and shown==1)
view:set_rewards(data)
find(view[1],"周").callback()
find(view[1],"奖励").callback()
assert(loads==2 and closed==0 and find(view[1],"1 书币").callback)
print("Full-screen statistics reward tab, direct row actions, confirmation, retry and same-view navigation passed")
