local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local TransientGuard = require("miuread.transient_guard")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_panel
local update_text

local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = options.radius or 0,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    hold_callback = nil,
    _hold_handled = false,
}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
    if self.hold_callback then
        self.ges_events.HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}}
        self.ges_events.HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}}
    end
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil) end
    return true
end
function TapBox:onHoldSelect()
    self._hold_handled = false
    if self.hold_callback then
        self._hold_handled = true
        self.hold_callback(self.dimen and self.dimen:copy() or nil)
    end
    return true
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    return false
end

local function tappable(width, height, child, callback, hold_callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local ControlSlider = InputContainer:extend{
    dimen=nil, bar_w=1, value_w=1, value_gap=0,
    min=0, max=100, value=0, on_change=nil, owner=nil, enabled=true,
    slide_dimen=nil, value_text=nil, last_refresh=0,
}
function ControlSlider:init()
    self.dimen=self.dimen or Geom:new{w=1,h=1}
    self.min=tonumber(self.min) or 0
    self.max=tonumber(self.max) or self.min+1
    if self.max<=self.min then self.max=self.min+1 end
    self.value=math.max(self.min,math.min(self.max,tonumber(self.value) or self.min))
    self.slide_dimen=Geom:new{x=0,y=0,w=math.max(1,self.bar_w),h=self.dimen.h}
    self.ges_events={
        TapSlide={GestureRange:new{ges="tap",range=self.slide_dimen}},
        PanSlide={GestureRange:new{ges="pan",range=self.slide_dimen}},
    }
    self.value_text=TextWidget:new{
        text=tostring(math.floor(self.value+.5)),
        face=face("smallinfofont",9.4,12.8,8.2),bold=true,
        fgcolor=Blitbuffer.COLOR_BLACK,
    }
end
function ControlSlider:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function ControlSlider:_armed()
    return self.enabled~=false and self.owner and type(self.owner._controls_armed)=="function" and self.owner:_controls_armed()
end
function ControlSlider:_ratio()
    return math.max(0,math.min(1,(self.value-self.min)/math.max(1,self.max-self.min)))
end
function ControlSlider:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    self.slide_dimen.x,self.slide_dimen.y=x,y
    local track_h=math.max(UiScale.line("medium"),UiScale.dp(4,3,6))
    local marker=UiScale.dp(12,10,16)
    local bar_y=y+math.floor((self.dimen.h-track_h)/2)
    local ratio=self:_ratio()
    local fill_w=math.max(track_h,math.floor(self.bar_w*ratio))
    local marker_x=x+math.floor((self.bar_w-marker)*ratio)
    local active=self.enabled~=false
    local fill_color=active and Blitbuffer.COLOR_BLACK or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY)
    local marker_color=active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    bb:paintRect(x,bar_y,self.bar_w,track_h,Blitbuffer.COLOR_GRAY)
    bb:paintRect(x,bar_y,math.min(self.bar_w,fill_w),track_h,fill_color)
    bb:paintRect(marker_x,y+math.floor((self.dimen.h-marker)/2),marker,marker,marker_color)
    local size=self.value_text:getSize()
    self.value_text:paintTo(bb,x+self.bar_w+self.value_gap+math.floor((self.value_w-size.w)/2),y+math.floor((self.dimen.h-size.h)/2))
end
function ControlSlider:_set_from_position(ges,force)
    if not self:_armed() then return true end
    local pos=ges and ges.pos
    if not pos then return false end
    local ratio=math.max(0,math.min(1,(pos.x-self.dimen.x)/math.max(1,self.bar_w)))
    local target=math.floor(self.min+ratio*(self.max-self.min)+.5)
    local actual=target
    if self.on_change then
        local ok,result=pcall(self.on_change,target,force and "commit" or "drag")
        if not ok then logger.warn("[MiuRead][QuickPanel] frontlight slider failed",tostring(result)); return true end
        if result==false then return true end
        if tonumber(result) then actual=tonumber(result) end
    end
    self.value=math.max(self.min,math.min(self.max,actual))
    self.value_text:setText(tostring(math.floor(self.value+.5)))
    local interval=Screen.low_pan_rate and .10 or .04
    if force or os.clock()-(tonumber(self.last_refresh) or 0)>=interval then
        self.last_refresh=os.clock()
        UIManager:setDirty(self.owner,function() return "ui",self.dimen end)
    end
    return true
end
function ControlSlider:onTapSlide(_,ges) return self:_set_from_position(ges,true) end
function ControlSlider:onPanSlide(_,ges)
    if not self:_armed() then return true end
    local direction=tostring(ges and ges.direction or "")
    local horizontal=direction=="east" or direction=="west"
    local relative=ges and ges.relative
    if not horizontal and relative then
        local dx=math.abs(tonumber(relative.x) or 0)
        local dy=math.abs(tonumber(relative.y) or 0)
        horizontal=dx>=UiScale.dp(8,6,12) and dx>dy*1.25
    end
    if not horizontal then return true end
    return self:_set_from_position(ges,false)
end

local function panel_button(entry, width, height, close_callback, compact, owner, index)
    local label = tostring(entry.label or entry.text or "")
    local detail = tostring(entry.detail or "")
    local icon = tostring(entry.icon_key or entry.icon or "")
    local enabled = entry.enabled ~= false
    local has_detail = detail ~= ""
    local dense = compact and width < UiScale.dp(104, 90, 136)
    local pad = UiScale.dp(dense and 2 or (compact and 3 or 4), 2, dense and 4 or 6)
    local inner_w = math.max(1, width - pad * 2)
    local gap_h = UiScale.dp(dense and 2 or 3, 2, dense and 4 or 5)
    local icon_slot_h = UiScale.dp(dense and 31 or (compact and 34 or 38), dense and 28 or (compact and 30 or 34), dense and 40 or (compact and 44 or 50))
    local label_slot_h = UiScale.dp(dense and 30 or (compact and 31 or 34), dense and 27 or (compact and 27 or 30), dense and 38 or (compact and 40 or 44))
    -- Reserve the same third line in every cell. Without this, Wi-Fi (which
    -- has an SSID detail) becomes taller and its icon is vertically shifted.
    local detail_slot_h = UiScale.dp(dense and 19 or (compact and 20 or 22), dense and 17 or (compact and 18 or 20), dense and 24 or (compact and 26 or 29))
    local icon_size = UiScale.dp(dense and 24 or (compact and 27 or 30), dense and 22 or (compact and 24 or 27), dense and 31 or (compact and 35 or 39))

    local label_box=Ui.textbox(label, inner_w, label_slot_h,
        face("smallinfofont", dense and 10.5 or (compact and 11.6 or 12.3), dense and 13.6 or (compact and 14.8 or 16.0), dense and 9.2 or (compact and 10.1 or 10.7)), {
            bold = true, alignment = "center", halign = "center",
            height_overflow_show_ellipsis = true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    local detail_box=Ui.textbox(has_detail and detail or " ", inner_w, detail_slot_h,
        face("smallinfofont", dense and 8.5 or (compact and 9.2 or 9.8), dense and 11.1 or (compact and 12.0 or 12.8), dense and 7.4 or (compact and 8.0 or 8.5)), {
            alignment = "center", halign = "center",
            height_overflow_show_ellipsis = true,
            fgcolor = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        })
    if owner and index then
        owner._button_refs[index]={label=label_box and label_box[1],detail=detail_box and detail_box[1]}
    end
    local content = VerticalGroup:new{
        align = "center",
        Ui.icon(icon, inner_w, icon_slot_h, icon_size, {
            icon_key = icon,
            icon_path = entry.icon_path,
            face = UiScale.iconFace("cfont", dense and 19.5 or (compact and 22 or 25), dense and 26 or (compact and 29 or 33), dense and 16.5 or (compact and 18 or 20)),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            fallback_text = "•",
        }),
        VerticalSpan:new{height = gap_h},
        label_box,
        detail_box,
    }

    local surface = fixed_frame(width, height, {
        bordersize = 0,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, CenterContainer:new{dimen = Geom:new{w = inner_w, h = math.max(1, height - pad * 2)}, content})

    local function run_action(action, anchor)
        if owner and type(owner._controls_armed)=="function" and not owner:_controls_armed() then return end
        if not enabled or type(action) ~= "function" then return end
        if entry.keep_open == true then
            UIManager:nextTick(function()
                local ok, err = pcall(action, anchor)
                if not ok then logger.warn("[MiuRead][QuickPanel] action failed", tostring(err)) end
            end)
            return
        end
        if close_callback then
            close_callback(function() return action(anchor) end)
        end
    end

    return tappable(width, height, surface,
        function(anchor) run_action(entry.callback, anchor) end,
        type(entry.hold_callback) == "function"
            and function(anchor) run_action(entry.hold_callback, anchor) end
            or nil)
end

local QuickPanelWidget = InputContainer:extend{
    name = "miuread_quick_panel",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    panel_h = 0,
    _closed = false,
    pending_action = nil,
    _controls_ready = false,
    _frontlight_enabled = true,
    _night_enabled = false,
}

function QuickPanelWidget:handleEvent(event)
    if event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local gesture = ges and ges.ges
        local pointer_action = gesture == "tap" or gesture == "hold" or gesture == "hold_release"
            or gesture == "double_tap" or gesture == "two_finger_tap"
        if not pointer_action and not (ges and ges.direction == "north")
            and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self, event)
end

function QuickPanelWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function QuickPanelWidget:_controls_armed()
    return self._controls_ready==true and self._closed~=true
end

function QuickPanelWidget:_guarded(action)
    return function(anchor)
        if not self:_controls_armed() then return true end
        if type(action)=="function" then return action(anchor) end
        return true
    end
end

function QuickPanelWidget:_refresh_frontlight_state()
    local frontlight=type(self.opts.frontlight)=="table" and self.opts.frontlight or nil
    if not frontlight then return end
    if type(frontlight.get_enabled)=="function" then
        local ok,value=pcall(frontlight.get_enabled)
        if ok then self._frontlight_enabled=value==true end
    end
    if type(frontlight.get_night)=="function" then
        local ok,value=pcall(frontlight.get_night)
        if ok then self._night_enabled=value==true end
    end
    update_text(self._text_refs.frontlight_toggle,self._frontlight_enabled and "关闭前光" or "开启前光")
    update_text(self._text_refs.night_toggle,self._night_enabled and "夜间：开" or "夜间：关")
    if self._sliders and self._sliders.brightness then
        local slider=self._sliders.brightness
        slider.enabled=self._frontlight_enabled
        if frontlight.brightness and type(frontlight.brightness.get_value)=="function" then
            local ok,value=pcall(frontlight.brightness.get_value)
            if ok and tonumber(value) then slider.value=math.max(slider.min,math.min(slider.max,tonumber(value))); slider.value_text:setText(tostring(math.floor(slider.value+.5))) end
        end
    end
    if self._sliders and self._sliders.warmth then
        local slider=self._sliders.warmth
        slider.enabled=self._frontlight_enabled
        if frontlight.warmth and type(frontlight.warmth.get_value)=="function" then
            local ok,value=pcall(frontlight.warmth.get_value)
            if ok and tonumber(value) then slider.value=math.max(slider.min,math.min(slider.max,tonumber(value))); slider.value_text:setText(tostring(math.floor(slider.value+.5))) end
        end
    end
    if self.panel_dimen then UIManager:setDirty(self,function() return "ui",self.panel_dimen end) end
end

function QuickPanelWidget:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    return true
end

function QuickPanelWidget:_build()
    self._button_refs={}
    self._text_refs={}
    self._sliders={}
    local scale = UiScale.metrics()
    local sw, sh = scale.sw, scale.sh
    local margin = math.max(UiScale.dp(11, 9, 18), math.floor(scale.short * .018))
    local gap = UiScale.dp(6, 5, 10)
    local button_gap = UiScale.dp(4, 3, 6)
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local line = UiScale.line("thin")

    -- The pull-down shortcut strip uses the actual visible count (up to eight).
    -- Hidden/unsupported controls therefore never leave dead space on the right.
    local visible_button_count = math.min(8, #buttons)
    local columns = math.max(1, visible_button_count)
    local rows = visible_button_count > 0 and 1 or 0
    local frontlight=type(self.opts.frontlight)=="table" and self.opts.frontlight or nil
    local warmth=frontlight and type(frontlight.warmth)=="table" and frontlight.warmth or nil
    if frontlight then
        if type(frontlight.get_enabled)=="function" then
            local ok,value=pcall(frontlight.get_enabled); if ok then self._frontlight_enabled=value==true end
        end
        if type(frontlight.get_night)=="function" then
            local ok,value=pcall(frontlight.get_night); if ok then self._night_enabled=value==true end
        end
    end
    local frontlight_h=frontlight and UiScale.dp(warmth and 142 or 94,warmth and 126 or 84,warmth and 182 or 122) or 0

    local title_h = UiScale.dp(52, 47, 70)
    local button_h = UiScale.dp(98, 90, 128)
    local footer_h = (self.opts.on_customize or self.opts.on_tools) and UiScale.dp(48, 43, 64) or 0
    local status_h = (self.opts.status_text and self.opts.status_text ~= "") and UiScale.dp(34, 30, 46) or 0

    self.panel_h = margin * 2 + title_h + line + gap * 2
    if rows > 0 then
        self.panel_h = self.panel_h + rows * button_h + math.max(0, rows - 1) * gap + gap
    end
    if status_h > 0 then self.panel_h = self.panel_h + status_h + gap end
    if frontlight_h > 0 then self.panel_h = self.panel_h + line + gap + frontlight_h + gap end
    if footer_h > 0 then self.panel_h = self.panel_h + line + gap + footer_h end
    self.panel_h = math.min(sh - margin, self.panel_h)

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }

    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(children, 0, 0, fixed_frame(sw, self.panel_h, {background = Blitbuffer.COLOR_WHITE}))

    local close_w = UiScale.dp(92, 80, 120)
    local battery_w = UiScale.dp(98, 84, 126)
    local time_w = math.max(1, sw - margin * 2 - close_w - battery_w - gap * 2)

    local time_box=Ui.text(tostring(self.opts.time_text or os.date("%H:%M")), time_w, title_h,
        face("cfont", 20.5, 28.5), {bold = true, halign = "left"})
    local battery_text_w=math.max(1,battery_w-UiScale.dp(28,24,38))
    local battery_box=Ui.text(tostring(self.opts.battery_text or "未知"),battery_text_w,title_h,
        face("smallinfofont",11.8,16),{bold=true})
    self._text_refs.time=time_box and time_box[1]
    self._text_refs.battery=battery_box and battery_box[1]
    local title_row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = time_w, h = title_h},time_box},
        HorizontalSpan:new{width = gap},
        CenterContainer:new{
            dimen=Geom:new{w=battery_w,h=title_h},
            HorizontalGroup:new{
                align="center",
                Ui.icon("battery",UiScale.dp(25,22,33),title_h,UiScale.dp(19,17,25),{icon_key="battery"}),
                HorizontalSpan:new{width=UiScale.dp(3,2,5)},
                battery_box,
            },
        },
        HorizontalSpan:new{width = gap},
        tappable(close_w, title_h,
            fixed_frame(close_w, title_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                Ui.text("收起 ↑", close_w, title_h, face("smallinfofont", 11.8, 16), {bold = true})),
            self:_guarded(function() self:_close() end)),
    }
    self:_add(children, margin, margin, title_row)

    local y = margin + title_h + gap
    self:_add(children, margin, y, LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = sw - margin * 2, h = line},
    })
    y = y + line + gap

    if rows > 0 then
        local button_w = math.floor((sw - margin * 2 - button_gap * (columns - 1)) / columns)
        for index, entry in ipairs(buttons) do
            if index > 8 then break end
            local row = math.floor((index - 1) / columns)
            local col = (index - 1) % columns
            self:_add(children, margin + col * (button_w + button_gap), y + row * (button_h + gap),
                panel_button(entry, button_w, button_h, function(action) self:_close(action) end, true, self, index))
        end
        y = y + rows * button_h + math.max(0, rows - 1) * gap + gap
    end

    if frontlight_h > 0 and y + line + gap + frontlight_h <= self.panel_h then
        self:_add(children,margin,y,LineWidget:new{
            background=Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
            dimen=Geom:new{w=sw-margin*2,h=line},
        })
        y=y+line+gap
        local content_w=sw-margin*2
        local header_h=UiScale.dp(36,32,47)
        local button_w=UiScale.dp(116,100,150)
        local header_gap=UiScale.dp(7,5,10)
        local title_w=math.max(1,content_w-button_w*2-header_gap*2)
        local toggle_text=Ui.text(self._frontlight_enabled and "关闭前光" or "开启前光",button_w-UiScale.dp(6,4,8),header_h,face("smallinfofont",9.6,13.2),{bold=true})
        local night_text=Ui.text(self._night_enabled and "夜间：开" or "夜间：关",button_w-UiScale.dp(6,4,8),header_h,face("smallinfofont",9.6,13.2),{bold=true})
        self._text_refs.frontlight_toggle=toggle_text and toggle_text[1]
        self._text_refs.night_toggle=night_text and night_text[1]
        local toggle=tappable(button_w,header_h,
            fixed_frame(button_w,header_h,{bordersize=UiScale.line("thin"),radius=UiScale.radius(6,5,9),background=Blitbuffer.COLOR_WHITE},toggle_text),
            function(anchor)
                if not self:_controls_armed() then return true end
                if type(frontlight.on_toggle)=="function" then pcall(frontlight.on_toggle,anchor) end
                self:_refresh_frontlight_state()
                -- Some KOReader power drivers ramp the frontlight asynchronously.
                -- Re-read once more after the native toggle has settled.
                UIManager:scheduleIn(.35,function() if not self._closed then self:_refresh_frontlight_state() end end)
                return true
            end)
        local night=tappable(button_w,header_h,
            fixed_frame(button_w,header_h,{bordersize=UiScale.line("thin"),radius=UiScale.radius(6,5,9),background=Blitbuffer.COLOR_WHITE},night_text),
            function(anchor)
                if not self:_controls_armed() then return true end
                if type(frontlight.on_night)=="function" then pcall(frontlight.on_night,anchor) end
                UIManager:scheduleIn(.24,function() if not self._closed then self:_refresh_frontlight_state() end end)
                return true
            end)
        self:_add(children,margin,y,HorizontalGroup:new{
            align="center",
            LeftContainer:new{dimen=Geom:new{w=title_w,h=header_h},Ui.text("前光",title_w,header_h,face("cfont",13.4,18.2),{bold=true,halign="left"})},
            HorizontalSpan:new{width=header_gap},toggle,HorizontalSpan:new{width=header_gap},night,
        })
        y=y+header_h+UiScale.dp(5,4,7)

        local function add_slider(setting,label)
            setting=type(setting)=="table" and setting or nil
            if not setting then return end
            local row_h=UiScale.dp(42,37,54)
            local label_w=UiScale.dp(72,62,94)
            local value_w=UiScale.dp(48,42,62)
            local value_gap=UiScale.dp(5,4,8)
            local bar_w=math.max(1,content_w-label_w-value_w-value_gap)
            local slider=ControlSlider:new{
                dimen=Geom:new{w=bar_w+value_gap+value_w,h=row_h},bar_w=bar_w,value_w=value_w,value_gap=value_gap,
                min=setting.min,max=setting.max,value=setting.value,on_change=setting.on_set,owner=self,enabled=self._frontlight_enabled,
            }
            self._sliders[label=="亮度" and "brightness" or "warmth"]=slider
            self:_add(children,margin,y,HorizontalGroup:new{
                align="center",
                LeftContainer:new{dimen=Geom:new{w=label_w,h=row_h},Ui.text(label,label_w,row_h,face("smallinfofont",10.2,14),{bold=true,halign="left"})},
                slider,
            })
            y=y+row_h+UiScale.dp(3,2,5)
        end
        add_slider(frontlight.brightness,"亮度")
        if warmth then add_slider(warmth,"色温") end
        y=math.max(y,margin+title_h+line+gap*2+rows*button_h+gap+frontlight_h)
    end

    -- Keep the frontlight controls immediately below the horizontal
    -- shortcuts. Any transient status message follows the controls instead
    -- of splitting that relationship.
    if status_h > 0 and y + status_h <= self.panel_h then
        local status_box=Ui.textbox(tostring(self.opts.status_text or ""),
            sw - margin * 2, status_h,
            face("smallinfofont", 10.8, 15), {
                bold = true, alignment = "left", halign = "left",
                height_overflow_show_ellipsis = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
        self._text_refs.status=status_box and status_box[1]
        self:_add(children, margin, y, status_box)
        y = y + status_h + gap
    end

    if footer_h > 0 and y + line + gap + footer_h <= self.panel_h then
        self:_add(children, margin, y, LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = sw - margin * 2, h = line},
        })
        y = y + line + gap

        local available_w = sw - margin * 2
        local has_customize = type(self.opts.on_customize) == "function"
        local has_tools = type(self.opts.on_tools) == "function"
        local count = (has_customize and 1 or 0) + (has_tools and 1 or 0)
        local footer_gap = count > 1 and UiScale.dp(18, 14, 26) or 0
        local item_w = count > 0 and math.floor((available_w - footer_gap * math.max(0, count - 1)) / count) or available_w
        local x = margin

        if has_customize then
            local customize = tappable(item_w, footer_h,
                fixed_frame(item_w, footer_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                    Ui.text("自定义", item_w, footer_h, face("cfont", 13.2, 18), {bold = true})),
                function(anchor)
                    if not self:_controls_armed() then return true end
                    self:_close(function() self.opts.on_customize(anchor) end)
                end)
            self:_add(children, x, y, customize)
            x = x + item_w + footer_gap
        end
        if has_tools then
            local tools = tappable(item_w, footer_h,
                fixed_frame(item_w, footer_h, {bordersize = 0, background = Blitbuffer.COLOR_WHITE},
                    Ui.text("工具与维护  ›", item_w, footer_h, face("cfont", 13.2, 18), {bold = true})),
                function(anchor)
                    if not self:_controls_armed() then return true end
                    self:_close(function() self.opts.on_tools(anchor) end)
                end)
            self:_add(children, x, y, tools)
        end
    end

    self:_add(children, 0, self.panel_h - UiScale.line("thick"), LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{w = sw, h = UiScale.line("thick")},
    })
    self[1] = children
end

local function panel_signature(opts)
    opts=type(opts)=="table" and opts or {}
    local parts={tostring(Screen:getWidth()),tostring(Screen:getHeight()),
        tostring(UiScale.getDisplayMode and UiScale.getDisplayMode() or "standard"),
        tostring(UiScale.getFontName and UiScale.getFontName() or ""),
        tostring(type(opts.on_customize)=="function"),tostring(type(opts.on_tools)=="function"),
        tostring((opts.status_text and opts.status_text~="") and 1 or 0),
        tostring(type(opts.frontlight)=="table"),
        tostring(type(opts.frontlight)=="table" and type(opts.frontlight.warmth)=="table")}
    for _,entry in ipairs(type(opts.buttons)=="table" and opts.buttons or {}) do
        parts[#parts+1]=tostring(entry.icon_key or entry.icon or "")..":"..tostring(entry.label or "")
    end
    return table.concat(parts,"|")
end

update_text=function(ref,value)
    if ref and type(ref.setText)=="function" then ref:setText(tostring(value or "")) end
end

function QuickPanelWidget:updateFromOptions(opts)
    opts=type(opts)=="table" and opts or {}
    if panel_signature(opts)~=self._signature then return false end
    self.opts=opts
    self._closed=false
    self.pending_action=nil
    self._controls_ready=false
    UIManager:nextTick(function() if not self._closed and live_panel==self then self._controls_ready=true end end)
    update_text(self._text_refs.time,opts.time_text or os.date("%H:%M"))
    update_text(self._text_refs.battery,opts.battery_text or "未知")
    update_text(self._text_refs.status,opts.status_text or "")
    for index,entry in ipairs(type(opts.buttons)=="table" and opts.buttons or {}) do
        local refs=self._button_refs[index] or {}
        update_text(refs.label,entry.label or entry.text or "")
        update_text(refs.detail,(entry.detail and entry.detail~="") and entry.detail or " ")
    end
    return true
end

function QuickPanelWidget:init()
    self._signature=panel_signature(self.opts)
    self._controls_ready=false
    self:_build()
end

function QuickPanelWidget:onTapDismiss(_, ges)
    if not (ges and ges.pos) then return false end
    if ges.pos.y > self.panel_h then
        self:_close()
        return true
    end
    return false
end

function QuickPanelWidget:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then
        self:_close()
        return true
    end
    return false
end

function QuickPanelWidget:onBack()
    self:_close()
    return true
end
function QuickPanelWidget:onScreenResize()
    self._rotation_close = true
    self:_close(nil, true)
    return true
end
function QuickPanelWidget:onRotation()
    self._rotation_close = true
    self:_close(nil, true)
    return true
end

function QuickPanelWidget:onShow()
    -- Arm controls only after the event loop has returned from the south-swipe
    -- that opened this panel. This isolates the opening gesture without relying
    -- on a guessed millisecond delay.
    self._controls_ready=false
    UIManager:nextTick(function()
        if not self._closed and live_panel==self then self._controls_ready=true end
    end)
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
end

function QuickPanelWidget:onCloseWidget()
    local region = self.panel_dimen and self.panel_dimen:copy() or nil
    local action = self.pending_action
    self.pending_action = nil
    self._closed = true
    if live_panel == self then live_panel = nil end
    if not self._rotation_close and region then
        UIManager:setDirty(nil, function() return "ui", region end)
    end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][QuickPanel] action failed", tostring(err)) end
        end)
    end
end

local QuickPanel = {}
function QuickPanel.close()
    if live_panel and not live_panel._closed then live_panel:_close(nil, true) end
    live_panel = nil
end

function QuickPanel.refreshFrontlight()
    if live_panel and not live_panel._closed and type(live_panel._refresh_frontlight_state)=="function" then
        live_panel:_refresh_frontlight_state()
        return true
    end
    return false
end
function QuickPanel.invalidate()
    QuickPanel.close()
    return true
end
function QuickPanel.show(opts)
    TransientGuard.close_all()
    local started=os.clock()
    QuickPanel.close()
    opts=opts or {}
    local ok,panel=pcall(QuickPanelWidget.new,QuickPanelWidget,{opts=opts})
    if not ok or not panel then
        logger.warn("[MiuRead][QuickPanel] build failed",tostring(panel))
        return nil,tostring(panel)
    end
    local built=os.clock()
    panel._closed=false
    live_panel=panel
    local shown,show_err=pcall(UIManager.show,UIManager,panel,"ui",panel.panel_dimen)
    if not shown then
        live_panel=nil
        logger.warn("[MiuRead][QuickPanel] show failed",tostring(show_err or "unknown"))
        return nil,tostring(show_err or "show failed")
    end
    logger.info("[MiuRead][QuickPanel] build timing",
        "reused=", "false",
        "build_ms=",tostring(math.floor((built-started)*1000+.5)),
        "submit_ms=",tostring(math.floor((os.clock()-built)*1000+.5)))
    return panel
end
return QuickPanel
