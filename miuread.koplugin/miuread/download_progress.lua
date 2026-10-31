local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureBridge = require("miuread.gesture_bridge")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("miuread.util")

local Screen = Device.screen

local DownloadProgress = InputContainer:extend{
    name = "miuread_download_progress",
    title = "MiuRead",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    _miuread_download_progress = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    on_cancel = nil,
    on_pause = nil,
    on_background = nil,
    on_close = nil,
    cancel_text = "取消下载",
    pause_text = "暂停下载",
    background_text = "后台下载",
}

local function widget_is_shown(widget)
    if not widget then return false end
    local ok, shown = pcall(UIManager.isWidgetShown, UIManager, widget)
    return ok and shown == true
end

function DownloadProgress:handleEvent(event)
    return GestureBridge.handle(InputContainer, self, event)
end

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function DownloadProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false
    self.closed = false
    self._close_reason = nil
    self._close_notified = false

    local frame_width = math.floor(Screen:getWidth() * 0.82)
    local frame_height = math.floor(Screen:getHeight() * 0.60)
    local content_width = frame_width - Size.padding.large * 2
    local content_height = frame_height - Size.padding.large * 2
    local group = VerticalGroup:new{align="center"}

    self.title_widget = TextBoxWidget:new{
        text = self.title or "MiuRead",
        face = Font:getFace("ffont", 22),
        bold = true,
        width = content_width,
        height = math.floor(content_height * 0.15),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.title_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.progress = ProgressWidget:new{
        width = content_width,
        height = Screen:scaleBySize(20),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
        padding = Size.padding.small,
        margin = Size.margin.tiny,
    }
    group[#group + 1] = self.progress
    group[#group + 1] = VerticalSpan:new{width = Size.padding.small}

    self.percent_widget = TextBoxWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 19),
        width = content_width,
        height = math.floor(content_height * 0.07),
        height_adjust = false,
        alignment = "center",
    }
    group[#group + 1] = self.percent_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.status_widget = TextBoxWidget:new{
        text = "准备下载……",
        face = Font:getFace("cfont", 18),
        width = content_width,
        height = math.floor(content_height * 0.48),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.status_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    local buttons={{
        {
            text = tostring(self.cancel_text or "取消下载"),
            callback = function()
                if self.cancelled then return end
                local accepted=true
                if self.on_cancel then
                    local ok,result=pcall(self.on_cancel)
                    if not ok then logger.warn("[MiuRead][DownloadUI] cancel callback failed",tostring(result))
                    elseif result==false then accepted=false end
                end
                if not accepted then return end
                self.cancelled=true
                self.status_widget:setText("正在取消……")
                self:_redraw()
            end,
        },
    }}
    if self.hide_pause~=true then
        buttons[1][#buttons[1]+1]={
            text=tostring(self.pause_text or "暂停下载"),
            callback=function()
                if self.cancelled then return end
                if self.on_pause then
                    local ok,result=pcall(self.on_pause)
                    if not ok then logger.warn("[MiuRead][DownloadUI] pause callback failed",tostring(result))
                    elseif result==false then return end
                end
                self:close("paused")
            end,
        }
    end
    if self.hide_background~=true then
        buttons[1][#buttons[1]+1]={
            text=tostring(self.background_text or "后台下载"),
            callback=function()
                if self.cancelled then return end
                if self.on_background then self.on_background() end
            end,
        }
    end
    self.buttons = ButtonTable:new{
        width = content_width,
        show_parent = self,
        zero_sep = true,
        buttons=buttons,
    }
    group[#group + 1] = self.buttons

    local fixed_area = CenterContainer:new{
        dimen = Geom:new{x=0, y=0, w=content_width, h=content_height},
        group,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        fixed_area,
    }
    local center=CenterContainer:new{dimen=self.dimen,self.frame}
    if self.comment_opaque==true then
        self[1]=OverlapGroup:new{dimen=self.dimen,allow_mirroring=false,
            LineWidget:new{background=Blitbuffer.COLOR_WHITE,
                dimen=Geom:new{w=Screen:getWidth(),h=Screen:getHeight()}},
            center,
        }
    else
        self[1]=center
    end
end

local function clean_status(value, limit)
    local text = tostring(value or ""):gsub("[%c]+", " "):gsub("%s+", " ")
    text = U.trim(text)
    limit = tonumber(limit) or 160
    if #text > limit then text = text:sub(1, limit) .. "…" end
    return text
end

function DownloadProgress:is_shown()
    return widget_is_shown(self)
end

function DownloadProgress:_redraw()
    -- A background download can keep publishing progress after this surface was
    -- retired by a page transition or another modal. Never dirty a detached
    -- widget: on e-ink that can leave the old white frame as a "ghost" box.
    if self.closed or not self:is_shown() then return false end
    local target = self.comment_opaque and self.dimen
        or (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function()
        return "fast", target
    end)
    return true
end

local function format_bytes(value)
    local n=math.max(0,tonumber(value) or 0)
    if n>=1024*1024*1024 then return string.format("%.1f GB",n/(1024*1024*1024)) end
    if n>=1024*1024 then return string.format("%.1f MB",n/(1024*1024)) end
    if n>=1024 then return string.format("%.0f KB",n/1024) end
    return tostring(math.floor(n+0.5)).." B"
end

local function format_eta(value)
    local seconds=math.max(0,math.floor(tonumber(value) or 0))
    if seconds<=0 then return "" end
    if seconds<60 then return tostring(seconds).." 秒" end
    local minutes=math.floor(seconds/60)
    local rest=seconds%60
    if minutes<60 then return tostring(minutes).." 分"..(rest>0 and (" "..tostring(rest).." 秒") or "") end
    return tostring(math.floor(minutes/60)).." 小时 "..tostring(minutes%60).." 分"
end

function DownloadProgress:set_state(state)
    state = state or {}
    if state.kind=="comments" then
        local current=math.max(0,tonumber(state.current) or 0)
        local total=math.max(0,tonumber(state.total) or 0)
        local percent=total>0 and clamp(current/total,0,1) or 0
        local rows={"已处理章节 "..tostring(current).." / "..tostring(total),
            "本地评论 "..tostring(state.comments or 0).." 条",
            "复用缓存 "..tostring(state.skipped or 0).." 章 · 失败 "..tostring(state.failed or 0).." 章"}
        if state.chapter and state.chapter~="" and current<total then
            rows[#rows+1]=clean_status(state.chapter,100)
        end
        if state.message and state.message~="" then rows[#rows+1]=clean_status(state.message,110) end
        local percent_text=tostring(math.floor(percent*100+0.5)).."%"
        local status_text=table.concat(rows,"\n")
        local signature=percent_text.."\n"..status_text
        if signature==self._last_signature then return end
        self._last_signature=signature
        self.progress:setPercentage(percent)
        self.percent_widget:setText(percent_text)
        self.status_widget:setText(status_text)
        self:_redraw()
        return
    end
    if state.kind=="extension" then
        local bytes=tonumber(state.downloaded_bytes) or 0
        local total=tonumber(state.total_bytes) or 0
        local percent=tonumber(state.percent)
        if not percent then percent=total>0 and bytes/total or 0 elseif percent>1 then percent=percent/100 end
        percent=clamp(percent,0,1)
        local labels={
            queued="准备下载",prepare="准备下载",download="正在下载",downloading="正在下载",
            waiting_network="等待 Wi-Fi",paused_user="下载已暂停",paused_power="设备休眠，下载已暂停",
            interrupted="下载已中断",downloaded="下载完成",verifying="正在校验",
            extracting="正在解压",installing="正在安装",done="安装完成",error="任务未完成",cancelled="下载已停止",
        }
        local rows={labels[state.stage] or labels[state.state] or tostring(state.stage or state.state or "处理中")}
        if total>0 then rows[#rows+1]=format_bytes(bytes).." / "..format_bytes(total) else rows[#rows+1]=format_bytes(bytes) end
        local speed=tonumber(state.speed_bps) or 0
        if speed>0 and (state.stage=="download" or state.state=="downloading") then rows[#rows+1]="速度 "..format_bytes(speed).."/s" end
        local eta=format_eta(state.eta_seconds)
        if eta~="" and (state.stage=="download" or state.state=="downloading") then rows[#rows+1]="预计剩余 "..eta end
        if state.source and tostring(state.source)~="" then rows[#rows+1]="下载源："..clean_status(state.source,80) end
        if state.message and tostring(state.message)~="" then rows[#rows+1]=clean_status(state.message,150) end
        local percent_text=tostring(math.floor(percent*100+0.5)).."%"
        local status_text=table.concat(rows,"\n")
        local signature=percent_text.."\n"..status_text
        if signature==self._last_signature then return end
        self._last_signature=signature
        self.progress:setPercentage(percent)
        self.percent_widget:setText(percent_text)
        self.status_widget:setText(status_text)
        self:_redraw()
        return
    end
    local current = tonumber(state.current) or 0
    local total = tonumber(state.total) or 0
    local percent = tonumber(state.percent)
    if not percent then
        percent = total > 0 and (current / total) or 0
    elseif percent > 1 then
        percent = percent / 100
    end
    percent = clamp(percent, 0, 1)

    local labels = {
        prepare = "准备下载",
        catalog = "读取目录",
        resume = "恢复下载断点",
        content = "获取章节正文",
        underlines = "获取划线",
        thoughts = "获取想法",
        footnotes = "处理脚注",
        images = "处理图片",
        coordinate = "补全并验证 Web 定位",
        package = "验证并生成 EPUB",
        rate_limit = "等待请求恢复",
        restart = "从断点自动恢复",
        hibernated = "已安全休眠，稍后自动继续",
        done = "下载完成",
        error = "下载失败",
        cancelled = "下载已取消",
    }
    local rows = {}
    rows[#rows + 1] = labels[state.stage] or tostring(state.stage or "处理中")
    if total > 0 then rows[#rows + 1] = "章节 " .. tostring(current) .. " / " .. tostring(total) end
    if state.chapter and state.chapter ~= "" then rows[#rows + 1] = clean_status(state.chapter, 120) end
    if state.batch_total and tonumber(state.batch_total) and tonumber(state.batch_total) > 0 then
        rows[#rows + 1] = "想法批次 " .. tostring(state.batch or 0) .. " / " .. tostring(state.batch_total)
    end
    if state.underlines ~= nil or state.thoughts ~= nil then
        rows[#rows + 1] = "累计划线 " .. tostring(state.underlines or 0)
            .. "　想法组 " .. tostring(state.thoughts or 0)
    end
    if state.message and state.message ~= "" then rows[#rows + 1] = clean_status(state.message, 180) end
    local percent_text = tostring(math.floor(percent * 100 + 0.5)) .. "%"
    local status_text = table.concat(rows, "\n")
    local signature = percent_text .. "\n" .. status_text
    if signature == self._last_signature then return end
    self._last_signature = signature
    self.progress:setPercentage(percent)
    self.percent_widget:setText(percent_text)
    self.status_widget:setText(status_text)
    self:_redraw()
end

function DownloadProgress:onShow()
    self.closed = false
    UIManager:setDirty(self, function()
        return "ui", self.comment_opaque and self.dimen
            or (self.frame and self.frame.dimen) or self.dimen
    end)
end

function DownloadProgress:onCloseWidget()
    if self._close_notified then return end
    self._close_notified = true
    self.closed = true
    local region = self.comment_opaque and self.dimen
        or (self.frame and self.frame.dimen and self.frame.dimen:copy() or nil)
    -- Force the newly exposed surface to repaint the exact frame area. This is
    -- intentionally stronger than the progress widget's normal fast refresh.
    if region then
        UIManager:setDirty(nil, function() return "ui", region end)
    end
    local callback = self.on_close
    self.on_close = nil
    if callback then
        local ok, err = pcall(callback, self, self._close_reason or "external")
        if not ok then logger.warn("[MiuRead][DownloadUI] close callback failed", tostring(err)) end
    end
end

function DownloadProgress:show()
    if self:is_shown() then return true end
    self.closed = false
    self._close_notified = false
    self._close_reason = nil
    UIManager:show(self, "ui")
    return self:is_shown()
end

function DownloadProgress:close(reason)
    self._close_reason = tostring(reason or "explicit")
    if not self:is_shown() then
        self.closed = true
        return false
    end
    UIManager:close(self, "ui")
    return true
end

-- Remove any detached/orphaned progress surface before a new one is shown.
-- Runtime state is deliberately not stored here; the download task owns that.
function DownloadProgress.close_orphans(except)
    local closed = 0
    local seen = {}
    local stack = UIManager._window_stack or {}
    for index = #stack, 1, -1 do
        local window = stack[index]
        local widget = window and window.widget or nil
        if widget and widget ~= except and not seen[widget]
            and widget._miuread_download_progress == true and widget_is_shown(widget) then
            seen[widget] = true
            widget._close_reason = "orphan_replaced"
            local ok, err = pcall(UIManager.close, UIManager, widget, "ui")
            if ok then
                closed = closed + 1
            else
                logger.warn("[MiuRead][DownloadUI] orphan close failed", tostring(err))
            end
        end
    end
    return closed
end

return DownloadProgress
