local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local U = require("miuread.util")

local Screen = Device.screen

local DownloadProgress = InputContainer:extend{
    title = "MiuRead",
    on_cancel = nil,
}

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function DownloadProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false

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

    self.buttons = ButtonTable:new{
        width = content_width,
        show_parent = self,
        zero_sep = true,
        buttons = {{
            {
                text = "取消下载",
                callback = function()
                    if self.cancelled then return end
                    self.cancelled = true
                    self.status_widget:setText("正在取消……")
                    self:_redraw()
                    if self.on_cancel then self.on_cancel() end
                end,
            },
        }},
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
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.frame,
    }
end

local function clean_status(value, limit)
    local text = tostring(value or ""):gsub("[%c]+", " "):gsub("%s+", " ")
    text = U.trim(text)
    limit = tonumber(limit) or 160
    if #text > limit then text = text:sub(1, limit) .. "…" end
    return text
end

function DownloadProgress:_redraw()
    local target = (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function()
        return "fast", target
    end)
end

function DownloadProgress:set_state(state)
    state = state or {}
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
        package = "验证并生成 EPUB",
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

function DownloadProgress:show()
    UIManager:show(self, "ui")
end

function DownloadProgress:close()
    UIManager:close(self, "ui")
end

return DownloadProgress
