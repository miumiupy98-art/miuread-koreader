-- Compact, non-modal, chapter-granularity progress for public comments.
-- Unlike the EPUB DownloadProgress, this paints ONLY its small bottom frame.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Ui = require("miuread.ui_components")
local logger = require("logger")

local Screen = Device.screen

local TapBox = InputContainer:extend{dimen=nil,callback=nil}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w=1,h=1}
    self.ges_events={TapSelect={GestureRange:new{ges="tap",range=self.dimen}}}
end
function TapBox:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function TapBox:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    if self[1] then self[1]:paintTo(bb,x,y) end
end
function TapBox:onTapSelect()
    if self.callback then self.callback() end
    return true
end
function TapBox:handleEvent(event) return InputContainer.handleEvent(self,event) end

local Compact = InputContainer:extend{
    name="miuread_comment_progress",
    _miuread_comment_progress=true,
    -- Never register as a modal surface or block ReaderUI outside the buttons.
    covers_fullscreen=false,
    stop_events_propagation=false,
    on_background=nil,on_pause=nil,on_cancel=nil,on_close=nil,
    closed=false,
}

function Compact:handleEvent(event) return InputContainer.handleEvent(self,event) end

local function number(v)
    return math.max(0,math.floor(tonumber(v) or 0))
end

-- A flat touch target: keep the full hit area without drawing three boxes.
function Compact:_button(icon,label,width,height,callback)
    local icon_size=math.min(Screen:scaleBySize(17),math.floor(height*.60))
    local content=HorizontalGroup:new{align="center",
        Ui.icon(icon,icon_size,icon_size,icon_size),
        HorizontalSpan:new{width=Screen:scaleBySize(4)},
        TextWidget:new{ text=label, face=Font:getFace("x_smallinfofont"),
            max_width=math.max(15,width-icon_size-Screen:scaleBySize(9)),
            truncate_with_ellipsis=true },
    }
    -- No individual FrameContainer/border: CenterContainer only paints its content.
    return TapBox:new{dimen=Geom:new{w=width,h=height},callback=callback,
        CenterContainer:new{dimen=Geom:new{w=width,h=height},content}}
end

function Compact:_build()
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local outer_w=math.min(math.floor(sw*.88),Screen:scaleBySize(500))
    outer_w=math.max(math.min(sw-12,outer_w),math.min(300,sw-12))
    local pad=Screen:scaleBySize(8)
    local frame_border=math.max(1,Screen:scaleBySize(1))
    local content_w=outer_w-2*(pad+frame_border)
    local line_h=Screen:scaleBySize(22)
    local button_h=Screen:scaleBySize(30) -- retain generous touch area
    local bar_h=math.max(2,math.min(4,Screen:scaleBySize(3)))
    local gap=Screen:scaleBySize(3)
    local title_w=math.floor(content_w*.55)
    local count_w=content_w-title_w
    self.title_label=TextWidget:new{
        text=(self.paused and "评论获取已暂停" or "正在获取评论"),
        face=Font:getFace("x_smallinfofont"),bold=true,
        max_width=title_w,truncate_with_ellipsis=true,
    }
    self.count_label=TextWidget:new{
        text="0/0章", face=Font:getFace("x_smallinfofont"),
        max_width=count_w,truncate_with_ellipsis=true,
    }
    self.detail_label=TextWidget:new{
        text="准备获取评论",face=Font:getFace("x_smallinfofont"),
        max_width=content_w,truncate_with_ellipsis=true,
    }
    self.progress=ProgressWidget:new{
        width=content_w,height=bar_h,percentage=0,
        fillcolor=Blitbuffer.COLOR_BLACK,padding=0,margin=0,
    }
    local bw=math.floor((content_w-gap*2)/3)
    local bw3=content_w-2*bw-2*gap
    local buttons=HorizontalGroup:new{align="center",
        self:_button("minimize","后台",bw,button_h,function()
            if self.on_background then self.on_background() end
        end),
        HorizontalSpan:new{width=gap},
        self:_button(self.paused and "play" or "pause",self.paused and "继续" or "暂停",bw,button_h,function()
            if self.on_pause then self.on_pause(self.paused~=true) end
        end),
        HorizontalSpan:new{width=gap},
        self:_button("close","取消",bw3,button_h,function()
            if self.on_cancel then self.on_cancel() end
        end),
    }
    local lines=VerticalGroup:new{align="center",
        HorizontalGroup:new{align="center",
            HorizontalGroup:new{align="center",
                Ui.icon("comment",Screen:scaleBySize(17),line_h,Screen:scaleBySize(16)),
                HorizontalSpan:new{width=Screen:scaleBySize(4)},
                Ui.align(self.title_label,title_w-Screen:scaleBySize(21),line_h,"left","center"),
            },
            Ui.align(self.count_label,count_w,line_h,"right","center"),
        },
        VerticalSpan:new{width=gap},
        self.progress,
        VerticalSpan:new{width=gap},
        self.detail_label,
        VerticalSpan:new{width=gap},
        buttons,
    }
    -- One thin outline around the complete progress surface, not separate
    -- boxes around the buttons or a fullscreen overlay over the reader.
    self.frame=FrameContainer:new{
        background=Blitbuffer.COLOR_WHITE,
        color=Blitbuffer.COLOR_BLACK,
        bordersize=frame_border,
        radius=Screen:scaleBySize(6),padding=pad,margin=0,lines,
    }
    local size=self.frame:getSize()
    local x=math.floor((sw-size.w)/2)
    local y=math.max(0,sh-size.h-math.max(Screen:scaleBySize(20),math.floor(sh*.025)))
    self.popup_dimen=Geom:new{x=x,y=y,w=size.w,h=size.h}
    self.frame.overlap_offset={x,y}
    self[1]=OverlapGroup:new{
        dimen=Screen:getSize(),allow_mirroring=false,self.frame,
    }
    -- Only the small frame is opaque. No full-screen white LineWidget.
end

function Compact:init()
    self.closed=false
    self.paused=self.paused==true
    self:_build()
end

function Compact:is_shown()
    local ok,shown=pcall(UIManager.isWidgetShown,UIManager,self)
    return ok and shown==true
end

function Compact:_redraw()
    if self.closed or not self:is_shown() then return false end
    UIManager:setDirty(self,"ui",self.popup_dimen)
    return true
end

function Compact:set_state(state)
    state=state or {}
    local paused=state.paused==true
    if paused~=self.paused then
        self.paused=paused
        local old_region=self.popup_dimen and self.popup_dimen:copy() or nil
        self:_build()
        -- A resized paused/running layout may expose old ink: invalidate both rectangles.
        if old_region and self:is_shown() then
            local x=math.min(old_region.x,self.popup_dimen.x)
            local y=math.min(old_region.y,self.popup_dimen.y)
            local right=math.max(old_region.x+old_region.w,self.popup_dimen.x+self.popup_dimen.w)
            local bottom=math.max(old_region.y+old_region.h,self.popup_dimen.y+self.popup_dimen.h)
            UIManager:setDirty("all","ui",Geom:new{x=x,y=y,w=right-x,h=bottom-y})
        end
    end
    local current=number(state.current)
    local total=number(state.total)
    local fraction=total>0 and math.min(1,current/total) or 0
    local single=total==1
    local label=single and "当前章节" or (tostring(current).."/"..tostring(total).."章")
    local detail=tostring(state.message or "")
    if paused then detail="已暂停 · "..detail end
    if single and current==0 and detail=="" then detail="正在获取评论" end
    if not single then detail=detail.." · 已保存 "..tostring(number(state.comments)).." 条" end
    local signature=(paused and "paused" or "running")..":"..label..":"..detail
    if signature==self._last_signature then return end
    self._last_signature=signature
    self.progress:setPercentage(fraction)
    self.count_label:setText(label)
    self.detail_label:setText(detail)
    self:_redraw()
end

function Compact:onShow()
    self.closed=false
    UIManager:setDirty(self,"ui",self.popup_dimen)
end

function Compact:onCloseWidget()
    self.closed=true
    local region=self.popup_dimen and self.popup_dimen:copy() or nil
    local callback=self.on_close
    self.on_close=nil
    if callback then
        local ok,err=pcall(callback,self,self._close_reason or "external")
        if not ok then logger.warn("[MiuRead][Comments] progress close callback",tostring(err)) end
    end
    -- Repaint the ReaderUI AFTER removal from the window stack (no white box).
    if region then UIManager:nextTick(function() UIManager:setDirty("all","ui",region) end) end
end

function Compact:show()
    if self:is_shown() then return true end
    self.closed=false
    UIManager:show(self,"ui")
    return self:is_shown()
end

function Compact:close(reason)
    self._close_reason=tostring(reason or "explicit")
    if not self:is_shown() then self.closed=true;return false end
    UIManager:close(self,"ui",self.popup_dimen)
    return true
end

return Compact
