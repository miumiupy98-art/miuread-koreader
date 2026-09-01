--[[--
书摘卡片编辑器：实时预览、本地保存与局域网扫码取图。

编辑器布局（色块网格 + ✕ 关闭 + 按图高自动收缩 + 两栏自适应）：
  * 打开即渲染实时预览（renderBB -> BlitBuffer -> ImageWidget，绕开文件缓存，
    配色切换宽高不变时不会命中旧图）；
  * 配色/静影背景为色块网格（4 列方阵，选中加粗黑边），模板为 ✓ 前缀按钮；
  * 切换样式/配色即时刷新预览（同步渲染 + 延迟更新条），无「渲染中」弹窗；
  * 弹窗按预览图高度自动收缩，避免大面积空白；长条卡片左右两栏，矮宽卡片上下分栏；
  * ✕ 叠在框右上角 / 点框外 / 返回键 关闭；
  * 保存 PNG（阅读器默认目录）/ 手机扫码保存（局域网）/ 复制文字。

扫码前先关闭编辑器，再单独显示二维码，避免方框叠加。
渲染由 book_excerpt_card 负责；局域网传输由 book_excerpt_transfer 负责。
--]]--

local BlitBuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RawQRMessage = require("ui/widget/qrmessage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font = require("ui/font")
local Size = require("ui/size")

local GestureBridge = require("miuread.gesture_bridge")
local Card = require("miuread.book_excerpt_card")
local Transfer = require("miuread.book_excerpt_transfer")
local U = require("miuread.util")
local logger = require("logger")
local util = require("util")
local ffiutil = require("ffi/util")
local DataStorage = require("datastorage")

local Screen = Device.screen
local label_face = Font:getFace("cfont", 10)

local function gesture_aware_class(base, attrs)
    local class = base:extend(attrs or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local QRMessage = gesture_aware_class(RawQRMessage, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})

-- 可点占位容器：dimen 即命中区，[1] 为展示内容，回调由 onTapSelect 触发。
local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    enabled = true,
}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {
        GestureRange:new{ges = "tap", range = self.dimen},
        GestureRange:new{ges = "touch", range = self.dimen},
    }}
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.enabled ~= false and self.callback then self.callback() end
    return true
end

local M = {}
local active_dialog
local qr_dialog
local preview_path
local closing = false
local ui_generation = 0

local SETTING_TEMPLATE = "miuread_book_excerpt_template"
local SETTING_COLOR = "miuread_book_excerpt_color"
local SETTING_BACKGROUND = "miuread_book_excerpt_background"

local function settings_read(key, default)
    if _G.G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, key)
        if ok and value ~= nil then return value end
    end
    return default
end

local function settings_write(key, value)
    if _G.G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
        pcall(G_reader_settings.saveSetting, G_reader_settings, key, value)
    end
end

local function clamp_index(value, list, default)
    local n = math.floor(tonumber(value) or default or 1)
    if n < 1 then n = 1 end
    if n > #list then n = #list end
    return n
end

local function current_selection()
    return {
        template_idx = clamp_index(settings_read(SETTING_TEMPLATE, 1), Card.TEMPLATES, 1),
        color_idx = clamp_index(settings_read(SETTING_COLOR, 1), Card.COLORS, 1),
        background_idx = clamp_index(settings_read(SETTING_BACKGROUND, 1), Card.BACKGROUND_IMAGES, 1),
    }
end

local function copy_selection(value)
    value = type(value) == "table" and value or current_selection()
    return {
        template_idx = clamp_index(value.template_idx, Card.TEMPLATES, 1),
        color_idx = clamp_index(value.color_idx, Card.COLORS, 1),
        background_idx = clamp_index(value.background_idx, Card.BACKGROUND_IMAGES, 1),
    }
end

local function clean_text(value)
    return U.trim(tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function close_widget(widget)
    if widget then pcall(UIManager.close, UIManager, widget) end
end

local function toast(host, text, seconds)
    if host and type(host.toast) == "function" then
        pcall(host.toast, host, text, seconds or 2.5)
    elseif host and type(host.info) == "function" then
        pcall(host.info, host, text)
    end
end

local function info(host, text)
    if host and type(host.info) == "function" then
        pcall(host.info, host, text)
    else
        toast(host, text, 3)
    end
end

local function temp_dir(context)
    local dir = context and context.temp_dir
    if type(dir) ~= "string" or dir == "" then
        dir = ffiutil.joinPath(DataStorage:getFullDataDir(), "miuread/tmp")
    end
    util.makePath(dir)
    return dir
end

local function render_options(context, selection, preview)
    local font_face = clean_text(context.font_face)
    if font_face == "" then font_face = nil end
    return {
        text = clean_text(context.text),
        book_title = clean_text(context.book_title),
        book_author = clean_text(context.book_author),
        book_id = tostring(context.book_id or "book"),
        font_face = font_face,
        template_idx = selection.template_idx,
        color_idx = selection.color_idx,
        background_idx = selection.background_idx,
        out_dir = preview and temp_dir(context) or nil,
        filename = preview and ("book_excerpt_preview_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".png") or nil,
        qr_url = nil,
    }
end

local function remove_preview(path)
    path = path or preview_path
    if path then pcall(os.remove, path) end
    if path == preview_path then preview_path = nil end
end

local function render_card(host, context, selection, preview)
    if clean_text(context.text) == "" then return nil, nil, "没有可生成书摘的文字" end
    local old_preview = preview and preview_path or nil
    local ok, path, dimen = pcall(Card.render, render_options(context, selection, preview))
    if not ok then
        logger.warn("[MiuRead][BookExcerpt] render crashed", tostring(path))
        return nil, nil, U.first_line(path, 160)
    end
    if not path then return nil, nil, tostring(dimen or "生成失败") end
    if preview then
        preview_path = path
        if old_preview and old_preview ~= path then remove_preview(old_preview) end
    end
    if type(dimen) == "table" and dimen.truncated == true then
        toast(host, "摘录内容较长，当前模板只能显示部分内容", 3)
    end
    return path, dimen
end

-- 由已渲染 BlitBuffer 直接构造预览图（复用首次渲染，避免二次渲染）
local function make_preview_image(bb, dimen, avail_w, avail_h)
    if not bb or not dimen or dimen.w <= 0 or dimen.h <= 0 then
        if bb then bb:free() end
        return nil
    end
    local scale = math.min(avail_w / dimen.w, avail_h / dimen.h)
    local img_w = math.max(1, math.floor(dimen.w * scale))
    local img_h = math.max(1, math.floor(dimen.h * scale))
    return ImageWidget:new{
        image = bb,
        image_disposable = true, -- ImageWidget free 时释放 bb
        width = img_w,
        height = img_h,
    }, img_h
end

local Editor = InputContainer:extend{
    name = "miuread_book_excerpt_editor",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = false, -- 非全屏居中框：reader 画在后面，点框外关闭
    stop_events_propagation = true,
    align = "center",           -- InputContainer:paintTo 据此居中 [1]=frame
    vertical_align = "center",
    host = nil,
    context = nil,
    selection = nil,
    closed = false,
    pending_action = nil,
    preview_image = nil,
    -- 布局产物（_build 赋值，_refresh_preview / _rebuild 复用）
    frame = nil,
    close_btn = nil,
    close_w = 0,
    close_h = 0,
    preview_container = nil,
    controls = nil,
    template_strip = nil,
    color_strip = nil,
    export_buttons = nil,
    pv_avail_w = 0,
    pv_avail_h = 0,
    main = nil,
    controls_center = nil,
    right_col = nil,
    frame_content = nil,
    ctrl_width = 0,
    ctrl_w = 0,
    two_col = false,
}
function Editor:handleEvent(event) return GestureBridge.handle(InputContainer, self, event) end

function Editor:_close(action)
    if action and not self.pending_action then self.pending_action = action end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Editor:_current_template()
    return Card.TEMPLATES[self.selection.template_idx]
end

function Editor:_is_stillness()
    local t = self:_current_template()
    return t and t.id == "stillness" or false
end

-- 渲染卡片到 BlitBuffer 并按可用宽高缩放为 ImageWidget
function Editor:_new_preview(avail_w, avail_h)
    local bb, dimen = Card.renderBB(render_options(self.context, self.selection, false))
    if not bb or not dimen or dimen.w <= 0 or dimen.h <= 0 then
        if bb then bb:free() end
        logger.warn("[MiuRead][BookExcerpt] preview render failed")
        return nil
    end
    local scale = math.min(avail_w / dimen.w, avail_h / dimen.h)
    local img_w = math.max(1, math.floor(dimen.w * scale))
    local img_h = math.max(1, math.floor(dimen.h * scale))
    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = img_w,
        height = img_h,
    }, img_h
end

-- 据图片高度收缩弹窗：更新 preview_container/controls_center 尺寸并清掉
-- VG/HG 缓存的 _size，使帧随内容收缩、InputContainer 重心居中。
function Editor:_apply_auto_shrink(image_h)
    if not image_h or not self.preview_container then return end
    local new_h = image_h
    if self.controls_center then -- 双栏：控件居中于整列高，列随 new_h 收缩
        local ctrl_natural = self.controls and self.controls:getSize().h or 0
        if ctrl_natural > new_h then new_h = ctrl_natural end
        self.controls_center.dimen = Geom:new{w = self.ctrl_width, h = new_h}
        if self.right_col then self.right_col:resetLayout() end
    end
    self.preview_container.dimen = Geom:new{w = self.pv_avail_w, h = new_h}
    if self.main then self.main:resetLayout() end
    if self.frame_content then self.frame_content:resetLayout() end
end

-- 应用预览图到容器：clear() 会释放旧子控件（含 ImageWidget 及其 bb），
-- 故不再单独 free，避免 bb 双重释放。换入新图后触发全屏重绘。
function Editor:_apply_preview_img(img)
    if not img or not self.preview_container then return end
    self.preview_container:clear()
    self.preview_container[1] = img
    self.preview_image = img
    -- 收缩后旧帧暴露区须重绘 reader 才不残留；editor 不 cover_fullscreen，reader 在重绘栈内
    UIManager:setDirty("all", "full")
end

function Editor:_do_render_preview()
    local img, image_h = self:_new_preview(self.pv_avail_w, self.pv_avail_h)
    self:_apply_auto_shrink(image_h)
    self:_apply_preview_img(img)
end

-- after_render：渲染完回调——把色块/模板条的 setDirty 推迟到渲染之后，与预览同帧 paint。
function Editor:_refresh_preview(after_render)
    self:_do_render_preview()
    if after_render then after_render() end
end

function Editor:_on_select_template(i)
    self.selection.template_idx = clamp_index(i, Card.TEMPLATES, 1)
    self:_refresh_preview(function()
        settings_write(SETTING_TEMPLATE, self.selection.template_idx)
        self:_update_template_strip()
        self:_update_color_strip()
    end)
end

function Editor:_on_select_color(i)
    local persist_key, persist_value
    if self:_is_stillness() then
        self.selection.background_idx = clamp_index(i, Card.BACKGROUND_IMAGES, 1)
        persist_key, persist_value = SETTING_BACKGROUND, self.selection.background_idx
        -- 背景图只使用随插件打包的资产；缺失时渲染回退纯色（见 render.lua）
        if not Card.backgroundImagePath(self.selection.background_idx) then
            logger.warn("[MiuRead][BookExcerpt] background image asset missing:", self.selection.background_idx)
        end
    else
        self.selection.color_idx = clamp_index(i, Card.COLORS, 1)
        persist_key, persist_value = SETTING_COLOR, self.selection.color_idx
    end
    self:_refresh_preview(function()
        settings_write(persist_key, persist_value)
        self:_update_color_strip()
    end)
end

-- 单个配色/背景图色块 cell：无字色块规避 Button 黑字在深色背景不可读的问题。
-- 纯色块必须有占位子 widget，否则空 FrameContainer 在 getSize 时 index nil 崩溃。
function Editor:_make_swatch_cell(i, cell, selected)
    local b = selected and 3 or 0
    local inner = math.max(1, cell - 2 * b)
    local content, bg, name
    if self:_is_stillness() then
        local p = Card.backgroundImagePath(i)
        if p then content = ImageWidget:new{file = p, width = inner, height = inner} end
        local bi = Card.BACKGROUND_IMAGES[i]
        name = bi and bi.name or ""
    end
    if not content then
        local c = Card.COLORS[i] or {bg = "FAFAFA"}
        bg = Card.Draw.hexToColor(c.bg)
        content = WidgetContainer:new{dimen = Geom:new{w = inner, h = inner}}
        name = c.name or ""
    end
    local box = FrameContainer:new{
        background = bg, -- 缩略图时为 nil（不填底，透明）
        bordersize = b,
        color = BlitBuffer.COLOR_BLACK,
        padding = 0, margin = 0, radius = 0,
        content,
    }
    -- 色块 + 下方名称小字（VG align=center 横向居中）
    local label = TextWidget:new{text = name, face = label_face}
    local body = VerticalGroup:new{
        align = "center",
        box,
        VerticalSpan:new{width = Screen:scaleBySize(2)},
        label,
    }
    local cw = TapBox:new{
        dimen = Geom:new{w = cell, h = body:getSize().h},
        callback = function() self:_on_select_color(i) end,
    }
    cw[1] = body
    return cw
end

-- 配色/背景图行：4 列方阵（cell 由列宽推导并封顶 max_cell，n=10 时 3 行×4，末行 4,4,2）
function Editor:_make_color_strip(width)
    local still = self:_is_stillness()
    local items = still and Card.BACKGROUND_IMAGES or Card.COLORS
    local sel_idx = still and self.selection.background_idx or self.selection.color_idx
    local n = #items
    local cols = 4
    local rows = math.ceil(n / cols)
    local span = Screen:scaleBySize(4)
    local cell = math.floor((width - (cols - 1) * span) / cols)
    local max_cell = Screen:scaleBySize(42)
    if cell > max_cell then cell = max_cell end
    local vg = VerticalGroup:new{width = width, align = "center"}
    local idx = 0
    for r = 1, rows do
        local hg = HorizontalGroup:new{align = "center"}
        -- 仅放置实际存在的色块；末行不足时由 VerticalGroup align=center 居中
        local placed = 0
        for c = 1, cols do
            idx = idx + 1
            if idx <= n then
                placed = placed + 1
                if placed > 1 then
                    hg[#hg + 1] = HorizontalSpan:new{width = span}
                end
                hg[#hg + 1] = self:_make_swatch_cell(idx, cell, idx == sel_idx)
            end
        end
        vg[#vg + 1] = hg
        if r < rows then
            vg[#vg + 1] = VerticalSpan:new{width = span}
        end
    end
    return vg
end

-- 模板芯片：选中项 "✓ " 前缀。两栏布局控件列窄→分两行(每行2)，单栏宽→单行(每行6)
function Editor:_make_template_strip(width, two_col)
    local btns = {}
    for i, t in ipairs(Card.TEMPLATES) do
        btns[#btns + 1] = {
            id = "btn_tpl_" .. i,
            text = (i == self.selection.template_idx and "✓ " or "") .. t.name,
            callback = function() self:_on_select_template(i) end,
        }
    end
    local cols = two_col and 2 or 6
    local rows = {}
    for i = 1, #btns, cols do
        local row = {}
        for j = 0, cols - 1 do
            if btns[i + j] then row[#row + 1] = btns[i + j] end
        end
        rows[#rows + 1] = row
    end
    return ButtonTable:new{width = width, buttons = rows}
end

-- 重建色块行（模板切换致 items 变化；选择变化也统一重建，简单且正确）
function Editor:_update_color_strip()
    if not self.controls or not self.ctrl_w then return end
    self.color_strip = self:_make_color_strip(self.ctrl_w)
    -- controls 结构：[1]template_strip [2]vspan [3]color_strip [4]vspan [5]export_buttons
    self.controls[3] = self.color_strip
    if self.dimen then
        UIManager:setDirty(self, "full", self.dimen)
    else
        UIManager:setDirty(self, "full")
    end
end

-- 模板行就地更新选中标记（setText 不重建，避免行高抖动）
function Editor:_update_template_strip()
    if not self.template_strip then return end
    for i, t in ipairs(Card.TEMPLATES) do
        local b = self.template_strip:getButtonById("btn_tpl_" .. i)
        if b and b.setText then
            b:setText((i == self.selection.template_idx and "✓ " or "") .. t.name, b.width)
        end
    end
    if self.dimen then
        UIManager:setDirty(self, "full", self.dimen)
    else
        UIManager:setDirty(self, "full")
    end
end

function Editor:_save_png()
    -- 正式保存：默认目录 + 时间戳文件名（render_card preview=false 走 Card 默认输出）
    local path, _, err = render_card(self.host, self.context, self.selection, false)
    if not path then
        info(self.host, "书摘卡片生成失败：\n" .. tostring(err or "unknown"))
        return
    end
    toast(self.host, "书摘卡片已保存到阅读器\n" .. tostring(path), 4)
end

function Editor:_qr_transfer()
    -- 先关编辑器再开二维码，避免方框叠加；编辑器 onCloseWidget 跑 pending_action 复活二维码
    local host, context, selection = self.host, self.context, copy_selection(self.selection)
    self:_close(function() M._show_qr_transfer(host, context, selection) end)
end

function Editor:_copy_text()
    if Device and Device.input and Device.input.setClipboardText then
        pcall(Device.input.setClipboardText, Device.input, clean_text(self.context.text))
        toast(self.host, "选中文字已复制到剪贴板", 2.5)
    end
end

-- 导出按钮（纵向单列，各占满列宽）
function Editor:_make_export_buttons(width)
    return ButtonTable:new{
        width = width,
        buttons = {
            {{text = "保存 PNG", callback = function() self:_save_png() end}},
            {{text = "手机扫码保存", callback = function() self:_qr_transfer() end}},
            {{text = "复制文字", callback = function() self:_copy_text() end}},
        },
    }
end

-- 控件列：模板行 + 配色行 + 导出按钮（纵向堆叠）
function Editor:_build_controls(width, two_col)
    local gap = Screen:scaleBySize(8)
    self.ctrl_w = width
    self.template_strip = self:_make_template_strip(width, two_col)
    self.color_strip = self:_make_color_strip(width)
    self.export_buttons = self:_make_export_buttons(width)
    return VerticalGroup:new{
        width = width, align = "center",
        self.template_strip,
        VerticalSpan:new{width = gap},
        self.color_strip,
        VerticalSpan:new{width = gap},
        self.export_buttons,
    }
end

-- 初始渲染 + 自适应布局 + 构建（同步，不再弹「渲染中」提示）
function Editor:_build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(10)
    local border = Size.border.window
    self._border = border
    self._margin = margin
    local gap = Screen:scaleBySize(8)
    local dialog_w = math.floor(sw * 0.92)
    local dialog_h = math.floor(sh * 0.90)
    local content_w = dialog_w - 2 * (border + margin)
    local content_h = dialog_h - 2 * (border + margin)

    -- 首帧渲染（renderBB -> BlitBuffer，复用进首张预览图，避免二次渲染）
    local bb, dimen = Card.renderBB(render_options(self.context, self.selection, false))
    if not bb or not dimen or dimen.w <= 0 or dimen.h <= 0 then
        if bb then bb:free() end
        logger.warn("[MiuRead][BookExcerpt] preview render failed")
        dimen = {w = 1, h = 2} -- 占位 dimen 强制走单栏，避免除零
    end
    local w_c, h_c = dimen.w, dimen.h

    -- 右上角关闭按钮：不进内容布局，由 Editor:paintTo 叠在 frame 右上角
    local close_body = FrameContainer:new{
        bordersize = 0,
        padding = Screen:scaleBySize(2),
        margin = 0,
        radius = 0,
        background = BlitBuffer.COLOR_WHITE,
        TextWidget:new{text = "✕", face = Font:getFace("cfont", 18)},
    }
    local close_sz = close_body:getSize()
    self.close_w = close_sz.w
    self.close_h = close_sz.h
    -- dimen 宽度包含 _margin，使 tap 区域延伸到 frame 右边缘
    self.close_btn = InputContainer:new{
        dimen = Geom:new{w = self.close_w + self._margin, h = self.close_h},
        [1] = close_body,
    }

    local two_col = h_c > w_c -- 长条卡片→左右两栏；矮宽卡片→上下分栏
    self.two_col = two_col
    local open_img_h -- 首帧图片高度：构建后据其收缩弹窗
    if two_col then
        -- 预览列只取卡片所需宽度，剩余全给控件列
        local scale = content_h / h_c
        local pv_w = math.floor(w_c * scale)
        local min_ctrl = math.floor(content_w * 0.30)
        if pv_w > content_w - min_ctrl then
            pv_w = content_w - min_ctrl
        end
        self.pv_avail_w = pv_w
        self.pv_avail_h = content_h
        self.ctrl_width = content_w - pv_w - gap
        self.controls = self:_build_controls(self.ctrl_width, true)
        -- 控件列：控件居中于整列高（✕ 由 Editor 叠在 frame 右上角，不占列高）
        self.controls_center = CenterContainer:new{
            dimen = Geom:new{w = self.ctrl_width, h = content_h},
            self.controls,
        }
        self.right_col = VerticalGroup:new{align = "center", self.controls_center}
        local first_img
        first_img, open_img_h = make_preview_image(bb, dimen, pv_w, content_h)
        self.preview_container = CenterContainer:new{
            dimen = Geom:new{w = pv_w, h = content_h},
        }
        self.preview_container[1] = first_img or WidgetContainer:new{
            dimen = Geom:new{w = 1, h = 1},
        }
        self.preview_image = first_img
        self.main = HorizontalGroup:new{
            align = "center",
            self.preview_container,
            HorizontalSpan:new{width = gap},
            self.right_col,
        }
    else
        -- 上下分栏：先建控件量高，再算预览可用高
        self.controls = self:_build_controls(content_w, false)
        local ctrl_h = self.controls:getSize().h
        local pv_h_avail = content_h - ctrl_h - gap
        if pv_h_avail < Screen:scaleBySize(200) then
            pv_h_avail = Screen:scaleBySize(200)
        end
        self.pv_avail_w = content_w
        self.pv_avail_h = pv_h_avail
        local first_img
        first_img, open_img_h = make_preview_image(bb, dimen, content_w, pv_h_avail)
        self.preview_container = CenterContainer:new{
            dimen = Geom:new{w = content_w, h = pv_h_avail},
        }
        self.preview_container[1] = first_img or WidgetContainer:new{
            dimen = Geom:new{w = 1, h = 1},
        }
        self.preview_image = first_img
        self.main = VerticalGroup:new{
            align = "center",
            self.preview_container,
            VerticalSpan:new{width = gap},
            self.controls,
        }
    end
    self:_apply_auto_shrink(open_img_h)
    self.frame_content = VerticalGroup:new{self.main}
    self.frame = FrameContainer:new{
        background = BlitBuffer.COLOR_WHITE,
        color = BlitBuffer.COLOR_DARK_GRAY,
        radius = Size.radius.window,
        bordersize = border,
        padding = margin,
        margin = 0,
        self.frame_content,
    }
    self[1] = self.frame
    self[2] = self.close_btn
    self.dimen = Geom:new{w = sw, h = sh} -- 全屏占位（点框外关闭）；frame 由 align/vertical_align 居中
    self.ges_events = {
        TapClose = {
            GestureRange:new{ges = "tap", range = self.dimen},
            GestureRange:new{ges = "touch", range = self.dimen},
        },
    }
    UIManager:setDirty("all", "full")
end

-- 屏幕旋转/尺寸变化后整体重建布局
function Editor:_rebuild()
    if self.preview_image and self.preview_image.free then
        pcall(self.preview_image.free, self.preview_image)
    end
    self.preview_image = nil
    self:_build()
    if self.dimen then
        UIManager:setDirty(self, "full", self.dimen)
    else
        UIManager:setDirty(self, "full")
    end
end

function Editor:init()
    self.selection = copy_selection(self.selection)
    self:_build()
end

-- base 居中绘制 frame 后，把 ✕ 叠到 frame 右上角
function Editor:paintTo(pbb, x, y)
    InputContainer.paintTo(self, pbb, x, y)
    if self.close_btn and self.frame and self.frame.dimen then
        local fd = self.frame.dimen
        local pad = Screen:scaleBySize(2)
        local cx = fd.x + fd.w - self._margin - self.close_w
        local cy = fd.y + pad
        self.close_btn.dimen.x = cx
        self.close_btn.dimen.y = cy
        self.close_btn:paintTo(pbb, cx, cy)
    end
end

function Editor:onTapClose(arg, ges)
    if not ges or not ges.pos or not self.frame or not self.frame.dimen then return end
    local should_close = not ges.pos:intersectWith(self.frame.dimen)
        or (self.close_btn and self.close_btn.dimen and self.close_btn.dimen:contains(ges.pos))
    if should_close then
        -- touch 事件只消费不关闭，等 tap 事件到达时再关闭，
        -- 避免 Editor 提前移除导致 tap 泄漏到 reader 触发手势
        if ges.ges == "tap" then
            self:_close()
        end
        return true
    end
end

function Editor:onBack()
    self:_close()
    return true
end

function Editor:onClose()
    self:_close()
    return true
end

function Editor:onShow()
    -- "all"+"full"：启动即重绘 reader 并全屏闪，清掉静影头图区残留的 reader 拋影
    UIManager:setDirty("all", "full")
end

function Editor:onCloseWidget()
    if active_dialog == self then active_dialog = nil end
    if self.preview_image and self.preview_image.free then
        pcall(self.preview_image.free, self.preview_image)
    end
    self.preview_image = nil
    -- 释放静影头图缓存（改动前可能不存在该 API，pcall 兜底）
    pcall(Card.clearStillnessHeadCache)
    UIManager:setDirty(nil, "flashui")
    local action = self.pending_action
    self.pending_action = nil
    if action then UIManager:nextTick(action) end
    return true
end

function Editor:onScreenResize()
    self:_rebuild()
    return true
end

function Editor:onRotation()
    self:_rebuild()
    return true
end

local function reopen(host, context, selection, generation)
    local expected = generation or ui_generation
    UIManager:scheduleIn(.04, function()
        if closing or expected ~= ui_generation then return end
        M.show(host, context, selection)
    end)
end

local function show_qr(url, host, context, selection, generation)
    local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * .72)
    local dialog
    dialog = QRMessage:new{
        text = url,
        width = size,
        height = size,
        scale_factor = .92,
        dismiss_callback = function()
            if qr_dialog == dialog then qr_dialog = nil end
            Transfer.stop("qr page closed")
            if not closing then reopen(host, context, selection, generation) end
        end,
    }
    qr_dialog = dialog
    UIManager:show(dialog)
end

function M._show_qr_transfer(host, context, selection)
    if closing then return false end
    local generation = ui_generation
    local path, _, err = render_card(host, context, selection, true)
    if not path then
        info(host, "书摘卡片生成失败：\n" .. tostring(err or "unknown"))
        reopen(host, context, selection, generation)
        return false
    end
    Transfer.stop("new qr transfer")
    local url, details = Transfer.start{
        file_path = path,
        title = context.book_title,
        on_download = function()
            toast(host, "手机已获取书摘图片", 2.5)
        end,
    }
    if not url then
        info(host, tostring(details or "无法开启手机扫码保存"))
        reopen(host, context, selection, generation)
        return false
    end
    -- Single-surface rule: the editor is already closed; QR is the only main
    -- overlay. Dismissing it stops the temporary LAN server and restores editor.
    show_qr(url, host, context, selection, generation)
    toast(host, "手机与阅读器需连接同一局域网；扫码后可在手机保存原图", 4)
    return true
end

function M.close(reason)
    if closing then return true end
    ui_generation = ui_generation + 1
    closing = true
    local q = qr_dialog
    qr_dialog = nil
    close_widget(q)
    Transfer.stop(reason or "dialog closed")
    local d = active_dialog
    active_dialog = nil
    close_widget(d)
    remove_preview()
    closing = false
    return true
end

function M.show(host, context, selection)
    context = context or {}
    context.text = clean_text(context.text)
    if context.text == "" then
        info(host, "没有可生成书摘的文字")
        return false
    end

    -- Do not stack editor on top of QR/old editor. Every transition first closes
    -- the previous surface; the next one is created only afterwards.
    if qr_dialog then
        local q = qr_dialog
        qr_dialog = nil
        closing = true
        close_widget(q)
        Transfer.stop("open card editor")
        closing = false
    end
    if active_dialog then
        local old = active_dialog
        active_dialog = nil
        closing = true
        close_widget(old)
        closing = false
    end

    local dialog = Editor:new{
        host = host,
        context = context,
        selection = copy_selection(selection or current_selection()),
    }
    active_dialog = dialog
    UIManager:show(dialog)
    return true
end

return M
