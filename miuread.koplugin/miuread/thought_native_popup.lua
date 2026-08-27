local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local ThoughtFaceFactory = require("miuread.thought_face_factory")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local TransientGuard = require("miuread.transient_guard")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local U = require("miuread.util")

local Size = require("ui/size")

local Screen = Device.screen
local MUTED_TEXT_COLOR = Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_DARK_GRAY
local INACTIVE_TEXT_COLOR = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_DARK_GRAY
local SEPARATOR_COLOR = Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_DARK_GRAY
local live_popup
local pooled_popup

local LAYOUT_CACHE_LIMIT = 3
local GHOSTING_REFRESH_INTERVAL = 6
local layout_cache = {}
local layout_cache_order = {}

local function layout_cache_touch(key)
    for index = #layout_cache_order, 1, -1 do
        if layout_cache_order[index] == key then
            table.remove(layout_cache_order, index)
            break
        end
    end
    layout_cache_order[#layout_cache_order + 1] = key
end

local function layout_cache_get(key)
    local cached = key and layout_cache[key] or nil
    if cached then layout_cache_touch(key) end
    return cached
end

local function layout_cache_put(key, value)
    if not key or key == "" or type(value) ~= "table" then return end
    layout_cache[key] = value
    layout_cache_touch(key)
    while #layout_cache_order > LAYOUT_CACHE_LIMIT do
        local expired = table.remove(layout_cache_order, 1)
        layout_cache[expired] = nil
    end
end

local function clear_layout_cache()
    layout_cache = {}
    layout_cache_order = {}
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize()
    return self[1]:getSize()
end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local Separator = Widget:extend{
    dimen = nil,
    dashed = false,
    inset = 0,
    top_padding = 0,
    line_size = 1,
    dash_width = 8,
    dash_gap = 6,
    color = SEPARATOR_COLOR,
}
function Separator:getSize()
    return self.dimen or Geom:new{w = 1, h = 1}
end
function Separator:paintTo(bb, x, y)
    local dimen = self:getSize()
    self.dimen.x, self.dimen.y = x, y
    local inset = math.max(0, math.floor(tonumber(self.inset) or 0))
    local line_size = math.max(1, math.floor(tonumber(self.line_size) or 1))
    local line_width = math.max(1, math.floor(dimen.w - inset * 2))
    local line_x = x + inset
    local line_y = y + math.max(0, math.floor(tonumber(self.top_padding) or 0))
    local color = self.color or SEPARATOR_COLOR
    if not self.dashed then
        bb:paintRect(line_x, line_y, line_width, line_size, color)
        return
    end

    local dash_width = math.max(1, math.floor(tonumber(self.dash_width) or 1))
    local dash_gap = math.max(1, math.floor(tonumber(self.dash_gap) or 1))
    local offset = 0
    while offset < line_width do
        local width = math.min(dash_width, line_width - offset)
        bb:paintRect(line_x + offset, line_y, width, line_size, color)
        offset = offset + dash_width + dash_gap
    end
end

local CloseButton = InputContainer:extend{dimen = nil, callback = nil}
function CloseButton:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapClose = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
end
function CloseButton:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end
function CloseButton:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function CloseButton:onTapClose()
    if self.callback then return self.callback() end
    return true
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function is_edge_blank_at(text, index, length)
    local byte = text:byte(index)
    if not byte then return false, 0 end
    if byte == 0x09 or byte == 0x0A or byte == 0x0B or byte == 0x0C
        or byte == 0x0D or byte == 0x20 then
        return true, 1
    end
    if byte == 0xC2 and index + 1 <= length and text:byte(index + 1) == 0xA0 then
        return true, 2
    end
    if byte == 0xE2 and index + 2 <= length and text:byte(index + 1) == 0x80 then
        local third = text:byte(index + 2)
        if third == 0x8B or third == 0x8C then return true, 3 end
    end
    if byte == 0xE3 and index + 2 <= length
        and text:byte(index + 1) == 0x80 and text:byte(index + 2) == 0x80 then
        return true, 3
    end
    if byte == 0xEF and index + 2 <= length
        and text:byte(index + 1) == 0xBB and text:byte(index + 2) == 0xBF then
        return true, 3
    end
    return false, 0
end

local function trim_edge_blanks(text)
    text = tostring(text or "")
    local length = #text
    if length == 0 then return text end
    local first = 1
    while first <= length do
        local blank, bytes = is_edge_blank_at(text, first, length)
        if not blank then break end
        first = first + bytes
    end
    local last = length
    while last >= first do
        local start = last
        while start > first do
            local byte = text:byte(start)
            if not byte or byte < 0x80 or byte >= 0xC0 then break end
            start = start - 1
        end
        local blank, bytes = is_edge_blank_at(text, start, length)
        if not blank or start + bytes - 1 ~= last then break end
        last = start - 1
    end
    if first > last then return "" end
    if first == 1 and last == length then return text end
    return text:sub(first, last)
end

local function clean_body(value)
    local text = U.clean_utf8 and U.clean_utf8(value) or tostring(value or "")
    text = tostring(text or "")
        :gsub("\239\191\189", "")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
        :gsub("[%z\1-\8\11\12\14-\31]", " ")
        :gsub("[ \t]+\n", "\n")
        :gsub("\n[ \t]+", "\n")
    return trim_edge_blanks(text)
end

local function clean_inline(value)
    return trim_edge_blanks(clean_body(value)
        :gsub("\194\160", " ")
        :gsub("\226\128[\139\140]", " ")
        :gsub("\227\128\128", " ")
        :gsub("[%c]+", " ")
        :gsub("%s+", " "))
end

local clean = clean_inline

local function display_units(value)
    value = clean(value)
    local units, index, length = 0, 1, #value
    while index <= length do
        local byte = value:byte(index)
        if not byte then break end
        if byte < 0x80 then
            if byte == 0x20 or byte == 0x09 then
                units = units + 0.35
            elseif byte >= 0x30 and byte <= 0x39 then
                units = units + 0.55
            else
                units = units + 0.60
            end
            index = index + 1
        elseif byte < 0xE0 then
            units = units + 1
            index = index + 2
        elseif byte < 0xF0 then
            units = units + 1
            index = index + 3
        else
            units = units + 1
            index = index + 4
        end
    end
    return math.max(1, units)
end

local function make_face(name, size, fallback)
    local requested = clean(name)
    if requested == "" then requested = nil end
    local ok, value = pcall(ThoughtFaceFactory.getFinalFace, ThoughtFaceFactory, requested, size, fallback or "cfont")
    if ok and value then return value end
    if requested then
        ok, value = pcall(function() return Font:getFace(requested, size) end)
        if ok and value then return value end
    end
    return Font:getFace(fallback or "cfont", size)
end

local NativePopup = InputContainer:extend{
    name = "miuread_thought_native_popup",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    -- This is a transparent full-screen input layer around a smaller popup.
    -- Marking it as opaque prevents ReaderUI from repainting areas exposed when
    -- a dynamically sized page becomes shorter.
    covers_fullscreen = false,
    stop_events_propagation = true,
    source_text = "",
    comments = nil,
    cache_key = nil,
    font_size = nil,
    font_name = nil,
    width_ratio = 0.92,
    height_ratio = 0.55,
    on_close_callback = nil,
    on_interact_callback = nil,
    on_error_callback = nil,
    closing = false,
    page_index = 1,
    pages = nil,
    page_changing = false,
    paint_failed = false,
    comments_dimen = nil,
    page_indicator_dimen = nil,
    content_refresh_dimen = nil,
    page_refresh_count = 0,
    _measurement_cache = nil,
}

function NativePopup:handleEvent(event)
    if not self.closing and event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and self.on_interact_callback and (ges.ges == "tap" or ges.ges == "swipe" or ges.ges == "hold") then
            pcall(self.on_interact_callback)
        end
    end
    return InputContainer.handleEvent(self, event)
end

function NativePopup:_fail(stage, err)
    if self.paint_failed or self.closing then return end
    self.paint_failed = true
    logger.err("[MiuRead][ThoughtPopup] native renderer failed", "stage=", tostring(stage or "unknown"), tostring(err or ""))
    UIManager:nextTick(function()
        if self.closing then return end
        local callback = self.on_error_callback
        self.on_error_callback = nil
        self:_close()
        if callback then pcall(callback, tostring(stage or "unknown"), tostring(err or "")) end
    end)
end

function NativePopup:paintTo(bb, x, y)
    local ok, err = xpcall(function()
        InputContainer.paintTo(self, bb, x, y)
    end, debug.traceback)
    if not ok then self:_fail("paint", err) end
end

function NativePopup:_close()
    if self.closing then return true end
    self:_close_action_dialog()
    self.closing = true
    UIManager:close(self)
    return true
end

function NativePopup:_text_box(text, face, width, opts)
    opts = opts or {}
    local box = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        width = math.max(1, width),
        alignment = opts.alignment or "left",
        justified = false,
        auto_para_direction = true,
        line_height = opts.line_height or 0.16,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
        height_adjust = true,
    }
    if opts.height then
        box.height = opts.height
        box.height_adjust = false
        box.height_overflow_show_ellipsis = opts.ellipsis ~= false
    end
    return box
end

function NativePopup:_content_identity()
    local parts = {tostring(self.cache_key or ""), clean(self.source_text)}
    if parts[1] == "" then
        for _, item in ipairs(type(self.comments) == "table" and self.comments or {}) do
            parts[#parts + 1] = table.concat({
                clean(item.author),
                tostring(tonumber(item.likes or 0) or 0),
                clean_body(item.content),
                tostring(item.review_id or ""),
            }, "\31")
        end
    end
    return table.concat(parts, "\30")
end

function NativePopup:_layout_cache_key(width, maximum_height, metrics)
    return table.concat({
        self:_content_identity(),
        tostring(Screen:getWidth()),
        tostring(Screen:getHeight()),
        tostring(width),
        tostring(maximum_height),
        tostring(metrics.body_size),
        tostring(metrics.meta_size),
        tostring(metrics.source_size),
        clean(self.font_name),
        ThoughtFaceFactory:signature(),
    }, "|")
end

function NativePopup:_measure_piece(piece, width, metrics)
    self._measurement_cache = self._measurement_cache or {}
    local key = table.concat({
        clean(piece.author),
        tostring(tonumber(piece.likes or 0) or 0),
        piece.continuation and "1" or "0",
        clean_body(piece.content),
        tostring(width),
        tostring(metrics.body_size),
        tostring(metrics.meta_size),
    }, "\31")
    local cached = self._measurement_cache[key]
    if cached then return cached end
    local widget, measured = self:_piece_widget(piece, width, metrics)
    measured = math.max(1, tonumber(measured) or 1)
    self._measurement_cache[key] = measured
    if widget and type(widget.free) == "function" then pcall(widget.free, widget) end
    return measured
end

function NativePopup:_layout_metrics(base_size)
    -- font_size already contains KOReader's device scaling. beta.8 keeps this
    -- final-size contract and asks ThoughtFaceFactory:getFinalFace() to avoid
    -- scaling the glyph face a second time.
    local body_size = math.max(12, math.floor((tonumber(base_size) or 15) + .5))
    local meta_size = math.max(10, math.floor(body_size * .72 + .5))
    local source_size = math.max(11, math.floor(body_size * .82 + .5))
    local separator_line_size = math.max(1, Screen:scaleBySize(1))
    local source_separator_top = math.max(6, math.floor(body_size * .40))
    local source_separator_bottom = math.max(8, math.floor(body_size * .52))
    local comment_separator_top = math.max(6, math.floor(body_size * .40))
    local comment_separator_bottom = comment_separator_top
    return {
        body_size = body_size,
        meta_size = meta_size,
        source_size = source_size,
        body_face = make_face(self.font_name, body_size, "cfont"),
        meta_face = make_face(self.font_name, meta_size, "smallinfofont"),
        source_face = make_face(self.font_name, source_size, "smallinfofont"),
        meta_body_gap = math.max(5, math.floor(body_size * .22)),
        body_line_height = 0.20,
        frame_guard = math.max(6, math.floor(body_size * .22)),
        separator_side_inset = math.max(10, math.floor(body_size * .65)),
        separator_line_size = separator_line_size,
        separator_dash_width = math.max(8, math.floor(body_size * .58)),
        separator_dash_gap = math.max(6, math.floor(body_size * .42)),
        source_separator_top = source_separator_top,
        source_separator_bottom = source_separator_bottom,
        source_separator_height = source_separator_top + separator_line_size + source_separator_bottom,
        comment_separator_top = comment_separator_top,
        comment_separator_bottom = comment_separator_bottom,
        comment_separator_height = comment_separator_top + separator_line_size + comment_separator_bottom,
    }
end

function NativePopup:_separator_widget(width, metrics, dashed, source_separator, extra_inset)
    local top_padding = source_separator and metrics.source_separator_top or metrics.comment_separator_top
    local bottom_padding = source_separator and metrics.source_separator_bottom or metrics.comment_separator_bottom
    local line_size = metrics.separator_line_size
    return Separator:new{
        dimen = Geom:new{
            w = math.max(1, width),
            h = math.max(1, top_padding + line_size + bottom_padding),
        },
        dashed = dashed == true,
        inset = math.max(0, (tonumber(extra_inset) or 0) + metrics.separator_side_inset),
        top_padding = top_padding,
        line_size = line_size,
        dash_width = metrics.separator_dash_width,
        dash_gap = metrics.separator_dash_gap,
        color = SEPARATOR_COLOR,
    }
end

local function needs_comment_separator(previous_piece, current_piece)
    if not previous_piece or not current_piece then return false end
    local previous_index = tonumber(previous_piece.comment_index)
    local current_index = tonumber(current_piece.comment_index)
    if previous_index and current_index then return previous_index ~= current_index end
    return not current_piece.continuation
end

function NativePopup:_piece_widget(piece, width, metrics)
    local group = VerticalGroup:new{align = "left"}
    local author = clean(piece.author)
    if author == "" then author = "微信读书用户" end
    local likes = tonumber(piece.likes or 0) or 0
    local meta
    if piece.continuation then
        meta = author .. " · 续"
    elseif likes > 0 then
        meta = author .. " · 赞 " .. tostring(likes)
    else
        meta = author
    end
    local content = clean_body(piece.content)
    if content == "" then content = " " end

    -- Let KOReader measure the author row with the same face it will paint.
    -- A forced height clipped or completely hid author names on later pages on
    -- some Kindle font metrics. Keep the row muted so the comment body remains
    -- the primary reading focus.
    group[#group + 1] = self:_text_box(meta, metrics.meta_face, width, {
        line_height = 0.10,
        fgcolor = MUTED_TEXT_COLOR,
    })
    group[#group + 1] = VerticalSpan:new{height = metrics.meta_body_gap}
    group[#group + 1] = self:_text_box(content, metrics.body_face, width, {
        line_height = metrics.body_line_height,
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    return group, math.max(1, group:getSize().h)
end

function NativePopup:_fit_prefix(item, content, maximum_height, width, metrics, continuation)
    local length = math.max(1, U.utf8_len(content))
    local low, high, best, best_height = 1, length, 0, nil
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local prefix = U.utf8_sub(content, 1, middle)
        local measured = self:_measure_piece({
            author = item.author,
            likes = item.likes,
            content = prefix,
            continuation = continuation,
            comment_index = item.comment_index,
        }, width, metrics)
        if measured <= maximum_height then
            best, best_height = middle, measured
            low = middle + 1
        else
            high = middle - 1
        end
    end
    if best < 1 then
        best = 1
        local measured = self:_measure_piece({
            author = item.author,
            likes = item.likes,
            content = U.utf8_sub(content, 1, 1),
            continuation = continuation,
            comment_index = item.comment_index,
        }, width, metrics)
        best_height = measured
    end
    local prefix = U.utf8_sub(content, 1, best)
    local remainder = U.utf8_sub(content, best + 1, length)
    return prefix, remainder, math.max(1, best_height or maximum_height)
end

function NativePopup:_paginate_next_page(width, maximum_height, metrics)
    local comments = type(self.comments) == "table" and self.comments or {}
    local state = self._pagination_state
    if type(state) ~= "table" then
        state = {comment_index = 1, item = nil, remaining_content = nil, continuation = false, done = false}
        self._pagination_state = state
    end
    if state.done then return nil, nil, true end
    if #comments == 0 then
        state.done = true
        return {}, 0, true
    end

    self._measurement_cache = {}
    local page, used = {}, 0
    local function add(piece, height)
        local gap = #page > 0 and needs_comment_separator(page[#page], piece)
            and metrics.comment_separator_height or 0
        page[#page + 1] = piece
        used = used + gap + height
    end
    local function clear_item(advance)
        if advance then state.comment_index = (tonumber(state.comment_index) or 1) + 1 end
        state.item = nil
        state.remaining_content = nil
        state.continuation = false
    end

    while true do
        if not state.item then
            local index = tonumber(state.comment_index) or 1
            local raw = comments[index]
            if not raw then
                state.done = true
                break
            end
            local item = {
                author = clean(raw.author),
                likes = tonumber(raw.likes or 0) or 0,
                content = clean_body(raw.content),
                comment_index = index,
            }
            if item.author == "" then item.author = "微信读书用户" end
            if item.content == "" then
                clear_item(true)
            else
                state.item = item
                state.remaining_content = item.content
                state.continuation = false
            end
        end

        local item = state.item
        if item then
            local remaining_content = tostring(state.remaining_content or "")
            if remaining_content == "" then
                clear_item(true)
            else
                local probe_piece = {
                    author = item.author,
                    likes = item.likes,
                    content = remaining_content,
                    continuation = state.continuation == true,
                    comment_index = item.comment_index,
                }
                local gap = #page > 0 and needs_comment_separator(page[#page], probe_piece)
                    and metrics.comment_separator_height or 0
                local available = math.max(1, maximum_height - used - gap)
                local whole_height = self:_measure_piece(probe_piece, width, metrics)

                if whole_height <= available then
                    add(probe_piece, whole_height)
                    clear_item(true)
                else
                    local prefix, remainder, piece_height = self:_fit_prefix(
                        item, remaining_content, available, width, metrics,
                        state.continuation == true
                    )
                    if prefix ~= "" and piece_height <= available then
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = prefix,
                            continuation = state.continuation == true,
                            comment_index = item.comment_index,
                        }, piece_height)
                        state.remaining_content = remainder
                        state.continuation = true
                        if remainder == "" then clear_item(true) end
                        break
                    elseif #page > 0 then
                        -- Leave the unconsumed comment for the next page rather
                        -- than measuring later comments that cannot be shown yet.
                        break
                    else
                        local forced_prefix, forced_remainder, forced_height = self:_fit_prefix(
                            item, remaining_content, maximum_height, width, metrics,
                            state.continuation == true
                        )
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = forced_prefix,
                            continuation = state.continuation == true,
                            comment_index = item.comment_index,
                        }, math.min(maximum_height, forced_height))
                        state.remaining_content = forced_remainder
                        state.continuation = true
                        if forced_remainder == "" then clear_item(true) end
                        break
                    end
                end
            end
        end

        if used >= maximum_height then break end
        if state.done then break end
    end

    if not state.item and (tonumber(state.comment_index) or 1) > #comments then
        state.done = true
    end
    self._measurement_cache = nil
    if #page == 0 and state.done then return nil, nil, true end
    return page, used, state.done == true
end

function NativePopup:_ensure_lazy_page(target)
    target = math.max(1, tonumber(target) or 1)
    local layout = self._pagination_layout
    if type(layout) ~= "table" then return false end
    self.pages = self.pages or {}
    self.page_heights = self.page_heights or {}

    while #self.pages < target and not self._pagination_complete do
        local page, height, done = self:_paginate_next_page(
            layout.width, layout.maximum_height, layout.metrics
        )
        if page then
            self.pages[#self.pages + 1] = page
            self.page_heights[#self.page_heights + 1] = tonumber(height) or 0
        end
        self._pagination_complete = done == true
        if not page then break end
    end

    if #self.pages == 0 then
        self.pages = {{}}
        self.page_heights = {0}
        self._pagination_complete = true
    end
    if self._pagination_complete and self._layout_cache_key_value then
        layout_cache_put(self._layout_cache_key_value, {
            pages = self.pages,
            page_heights = self.page_heights,
        })
    end
    return #self.pages >= target
end

function NativePopup:_paginate_comments(width, maximum_height, metrics)
    self._measurement_cache = {}
    local comments = type(self.comments) == "table" and self.comments or {}
    if #comments == 0 then
        self._measurement_cache = nil
        return {{}}, {0}
    end

    local pages, heights = {}, {}
    local page, used = {}, 0
    local function page_height(items)
        local total = 0
        for index, piece in ipairs(items or {}) do
            if index > 1 and needs_comment_separator(items[index - 1], piece) then
                total = total + metrics.comment_separator_height
            end
            local measured = self:_measure_piece(piece, width, metrics)
            total = total + measured
        end
        return total
    end
    local function flush()
        if #page > 0 then
            pages[#pages + 1] = page
            heights[#heights + 1] = used
            page, used = {}, 0
        end
    end
    local function add(piece, height)
        local gap = #page > 0 and needs_comment_separator(page[#page], piece)
            and metrics.comment_separator_height or 0
        page[#page + 1] = piece
        used = used + gap + height
    end

    for comment_index, raw in ipairs(comments) do
        local item = {
            author = clean(raw.author),
            likes = tonumber(raw.likes or 0) or 0,
            content = clean_body(raw.content),
            comment_index = comment_index,
        }
        if item.author == "" then item.author = "微信读书用户" end
        if item.content ~= "" then
            local remaining_content = item.content
            local continuation = false
            while remaining_content ~= "" do
                local probe_piece = {
                    author = item.author,
                    likes = item.likes,
                    content = remaining_content,
                    continuation = continuation,
                    comment_index = item.comment_index,
                }
                local gap = #page > 0 and needs_comment_separator(page[#page], probe_piece)
                    and metrics.comment_separator_height or 0
                local available = math.max(1, maximum_height - used - gap)
                local whole_piece = probe_piece
                local whole_height = self:_measure_piece(whole_piece, width, metrics)

                if whole_height <= available then
                    add(whole_piece, whole_height)
                    remaining_content = ""
                else
                    -- Do not abandon a large empty area merely because the next
                    -- comment is long. Fit as much of that comment as possible
                    -- into the current page, then continue it on the next page.
                    -- This keeps ordinary pages visually full without enlarging
                    -- the popup.
                    local prefix, remainder, piece_height = self:_fit_prefix(
                        item, remaining_content, available, width, metrics, continuation
                    )
                    if prefix ~= "" and piece_height <= available then
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = prefix,
                            continuation = continuation,
                            comment_index = item.comment_index,
                        }, piece_height)
                        remaining_content = remainder
                        continuation = true
                        if remaining_content ~= "" then flush() end
                    elseif #page > 0 then
                        flush()
                    else
                        -- A single glyph must always make progress, even with
                        -- unusual device font metrics.
                        local forced_prefix, forced_remainder, forced_height = self:_fit_prefix(
                            item, remaining_content, maximum_height, width, metrics, continuation
                        )
                        add({
                            author = item.author,
                            likes = item.likes,
                            content = forced_prefix,
                            continuation = continuation,
                            comment_index = item.comment_index,
                        }, math.min(maximum_height, forced_height))
                        remaining_content = forced_remainder
                        continuation = true
                        if remaining_content ~= "" then flush() end
                    end
                end
            end
        end
    end
    flush()
    if #pages == 0 then
        self._measurement_cache = nil
        return {{}}, {0}
    end

    -- Balance the last two pages when the final page would otherwise contain
    -- only a tiny amount of text. Moving complete trailing pieces preserves
    -- reading order and avoids a large, unnecessary blank block.
    if #pages >= 2 then
        local previous = pages[#pages - 1]
        local last = pages[#pages]
        local previous_h = page_height(previous)
        local last_h = page_height(last)
        local target = math.floor(maximum_height * 0.62)
        while last_h < target and #previous > 1 do
            local candidate = previous[#previous]
            table.remove(previous, #previous)
            table.insert(last, 1, candidate)
            local next_previous_h = page_height(previous)
            local next_last_h = page_height(last)
            if next_last_h > maximum_height or next_previous_h < maximum_height * 0.38 then
                table.remove(last, 1)
                previous[#previous + 1] = candidate
                break
            end
            previous_h, last_h = next_previous_h, next_last_h
        end
        heights[#heights - 1] = previous_h
        heights[#heights] = last_h
    end
    self._measurement_cache = nil
    return pages, heights
end

function NativePopup:_build_source(width, metrics, close_size)
    local source = clean(self.source_text)
    if source == "" then
        local empty = VerticalGroup:new{align = "left"}
        empty[#empty + 1] = Widget:new{dimen = Geom:new{w = width, h = close_size}}
        return empty, close_size
    end

    local available_w = math.max(1, width - close_size - math.max(8, Screen:scaleBySize(6)))
    local line_h = math.max(metrics.source_size + 4, math.floor(metrics.source_size * 1.30))
    local units_per_line = math.max(6, available_w / math.max(1, metrics.source_size))
    local source_units = display_units(source)
    local lines = source_units > units_per_line * 1.35 and 2 or 1
    local source_h = lines * line_h
    local group = VerticalGroup:new{align = "left"}
    group[#group + 1] = self:_text_box("“" .. source .. "”", metrics.source_face, available_w, {
        height = source_h,
        ellipsis = true,
        line_height = 0.10,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    local total_h = math.max(close_size, source_h)
    local current_h = group:getSize().h
    if current_h < total_h then
        group[#group + 1] = VerticalSpan:new{height = total_h - current_h}
        if group.resetLayout then group:resetLayout() end
    end
    return group, total_h
end

function NativePopup:_build_comment_page(width, metrics, target_height)
    local page = (self.pages and self.pages[self.page_index]) or {}
    local group = VerticalGroup:new{align = "left"}
    local hit_targets = {}
    local cursor_y = 0
    if #page == 0 then
        local empty_h = math.max(metrics.body_size * 2, Screen:scaleBySize(38))
        local top_gap = math.max(6, Screen:scaleBySize(5))
        group[#group + 1] = VerticalSpan:new{height = top_gap}
        cursor_y = cursor_y + top_gap
        group[#group + 1] = self:_text_box("没有评论内容", metrics.meta_face, width, {
            height = empty_h,
            alignment = "center",
            line_height = 0.08,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
        cursor_y = cursor_y + empty_h
    else
        for index, piece in ipairs(page) do
            if index > 1 and needs_comment_separator(page[index - 1], piece) then
                group[#group + 1] = self:_separator_widget(width, metrics, true, false)
                cursor_y = cursor_y + metrics.comment_separator_height
            end
            local widget, piece_h = self:_piece_widget(piece, width, metrics)
            piece_h = math.max(1, tonumber(piece_h) or widget:getSize().h)
            group[#group + 1] = widget
            local comment_index = tonumber(piece.comment_index)
            if comment_index then
                hit_targets[#hit_targets + 1] = {
                    y = cursor_y,
                    h = piece_h,
                    comment_index = comment_index,
                }
            end
            cursor_y = cursor_y + piece_h
        end
    end

    self.comment_hit_targets = hit_targets
    if group.resetLayout then group:resetLayout() end
    local natural_h = math.max(1, group:getSize().h)
    local final_h = natural_h
    target_height = tonumber(target_height)
    if target_height and target_height > natural_h then
        group[#group + 1] = VerticalSpan:new{height = target_height - natural_h}
        if group.resetLayout then group:resetLayout() end
        final_h = target_height
    end
    return group, math.max(1, final_h), natural_h
end

function NativePopup:_page_indicator_text()
    local count = #(self.pages or {})
    if self._pagination_complete ~= true then
        return tostring(math.max(1, tonumber(self.page_index) or 1)) .. " / …"
    end
    if count <= 1 then return "" end
    return tostring(clamp(self.page_index, 1, count)) .. " / " .. tostring(count)
end

function NativePopup:_build_page_indicator(width, metrics, height)
    local text = self:_page_indicator_text()
    if text == "" then return nil, 0, nil end

    local count = #(self.pages or {})
    local current = clamp(self.page_index, 1, math.max(1, count))
    local has_next = self._pagination_complete ~= true or current < count
    local face = make_face(
        self.font_name, math.max(10, math.floor(metrics.meta_size * .92 + .5)), "smallinfofont"
    )
    local label = TextWidget:new{
        text = text,
        face = face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local left = TextWidget:new{
        text = "‹",
        face = face,
        fgcolor = current > 1 and Blitbuffer.COLOR_DARK_GRAY or INACTIVE_TEXT_COLOR,
    }
    local right = TextWidget:new{
        text = "›",
        face = face,
        fgcolor = has_next and Blitbuffer.COLOR_DARK_GRAY or INACTIVE_TEXT_COLOR,
    }

    local label_size = label:getSize()
    local left_size = left:getSize()
    local right_size = right:getSize()
    local indicator_h = math.max(
        tonumber(height) or 0,
        label_size.h, left_size.h, right_size.h
    ) + math.max(2, Screen:scaleBySize(1))
    local side_w = math.max(
        left_size.w, right_size.w,
        math.floor(math.max(1, width) * .16)
    )
    side_w = math.min(side_w, math.max(1, math.floor((width - label_size.w) / 2)))
    local center_w = math.max(1, width - side_w * 2)

    local container = HorizontalGroup:new{
        CenterContainer:new{dimen = Geom:new{w = side_w, h = indicator_h}, left},
        CenterContainer:new{dimen = Geom:new{w = center_w, h = indicator_h}, label},
        CenterContainer:new{dimen = Geom:new{w = side_w, h = indicator_h}, right},
    }
    return container, indicator_h, label
end

function NativePopup:_current_comment()
    local page=(self.pages and self.pages[self.page_index]) or {}
    local index
    for _,piece in ipairs(page) do
        local candidate=tonumber(piece.comment_index)
        if candidate then index=candidate; break end
    end
    if not index and type(self.comments)=="table" and #self.comments==1 then index=1 end
    return index and self.comments and self.comments[index] or nil,index
end

function NativePopup:_comment_at_position(pos)
    if not pos or not self.comments_dimen then return nil,nil end
    local py=tonumber(pos.y)
    if not py then return nil,nil end
    local relative_y=py-tonumber(self.comments_dimen.y or 0)
    for _,target in ipairs(self.comment_hit_targets or {}) do
        local top=tonumber(target.y) or 0
        local height=math.max(1,tonumber(target.h) or 0)
        if relative_y>=top and relative_y<top+height then
            local index=tonumber(target.comment_index)
            return index and self.comments and self.comments[index] or nil,index
        end
    end
    return nil,nil
end

function NativePopup:_is_current_favorite(comment)
    comment=comment or self:_current_comment()
    if not comment or type(self.is_favorite_callback)~="function" then return false end
    local ok,value=pcall(self.is_favorite_callback,comment,self.source_text)
    return ok and value==true
end

function NativePopup:_action_texts(comment)
    return {"复制评论","复制原文+评论",self:_is_current_favorite(comment) and "取消收藏" or "收藏"}
end

function NativePopup:_handle_action(index,comment)
    comment=comment or self:_current_comment()
    if not comment then return true end
    if self.on_interact_callback then pcall(self.on_interact_callback) end
    if index==1 or index==2 then
        if type(self.copy_callback)=="function" then
            pcall(self.copy_callback,comment,self.source_text,index==2)
        end
        return true
    end
    if index==3 and type(self.toggle_favorite_callback)=="function" then
        pcall(self.toggle_favorite_callback,comment,self.source_text)
        return true
    end
    return true
end

function NativePopup:_close_action_dialog()
    local dialog=self.action_dialog
    self.action_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function NativePopup:_show_action_menu(comment)
    comment=comment or self:_current_comment()
    if not comment or self.closing then return true end
    self:_close_action_dialog()
    local texts=self:_action_texts(comment)
    local dialog
    local function run(index)
        if dialog then
            pcall(UIManager.close,UIManager,dialog)
            if self.action_dialog==dialog then self.action_dialog=nil end
        end
        return self:_handle_action(index,comment)
    end
    dialog=ButtonDialog:new{
        title="评论操作",
        title_align="center",
        buttons={
            {{text=texts[1],callback=function() return run(1) end}},
            {{text=texts[2],callback=function() return run(2) end}},
            {{text=texts[3],callback=function() return run(3) end}},
        },
        close_callback=function()
            if self.action_dialog==dialog then self.action_dialog=nil end
        end,
    }
    self.action_dialog=dialog
    UIManager:show(dialog,"ui")
    return true
end

function NativePopup:_build(reset_pages, anchor_comment)
    local previous_root = self[1]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local border = math.max(1, tonumber(Size.border.window) or 1)
    local radius = math.max(tonumber(Size.radius.window) or 0, Screen:scaleBySize(6))
    local padding = math.max(10, Screen:scaleBySize(8))
    local inset = border + padding
    local base_size = math.max(10, tonumber(self.font_size) or Screen:scaleBySize(15))
    local metrics = self:_layout_metrics(base_size)
    local close_size = math.max(28, math.min(40, math.floor(metrics.body_size * 1.55)))
    local close_inset = math.max(2, Screen:scaleBySize(2))

    local width_ratio = clamp(self.width_ratio, 0.88, 0.94)
    local height_ratio = clamp(self.height_ratio, 0.42, 0.56)
    local side_margin = math.max(14, math.floor(sw * 0.02))
    local vertical_margin = math.max(18, math.floor(sh * 0.03))
    local width = math.min(math.floor(sw * width_ratio), sw - side_margin * 2)
    local maximum_height = math.min(math.floor(sh * height_ratio), sh - vertical_margin * 2)
    local inner_w = math.max(1, width - inset * 2)
    local frame_guard = math.max(4, tonumber(metrics.frame_guard) or 0)
    local comment_w = math.max(1, inner_w - frame_guard * 2)

    local source_group, source_h = self:_build_source(inner_w, metrics, close_size)
    local has_source = clean(self.source_text) ~= ""
    local source_separator_h = has_source and metrics.source_separator_height or 0
    local bottom_padding = math.max(4, Screen:scaleBySize(3))
    local indicator_gap = math.max(4, Screen:scaleBySize(3))
    local indicator_height = math.max(metrics.meta_size + math.max(4, Screen:scaleBySize(2)), Screen:scaleBySize(14))
    local indicator_reserve = indicator_gap + indicator_height
    local maximum_comments_h = math.max(
        metrics.body_size * 3,
        maximum_height - inset * 2 - source_h - source_separator_h - bottom_padding - indicator_reserve
    )

    if reset_pages or not self.pages then
        local cache_key = self:_layout_cache_key(comment_w, maximum_comments_h, metrics)
        local cached = layout_cache_get(cache_key)
        self._layout_cache_key_value = cache_key
        self._pagination_layout = {
            width = comment_w,
            maximum_height = maximum_comments_h,
            metrics = metrics,
        }
        if cached then
            self.pages = cached.pages
            self.page_heights = cached.page_heights
            self._pagination_state = nil
            self._pagination_complete = true
            self._layout_cache_hit = true
        elseif tonumber(anchor_comment) then
            -- Font changes are explicit and infrequent. Preserve the current
            -- comment anchor even if that requires one complete repagination.
            self.pages, self.page_heights = self:_paginate_comments(comment_w, maximum_comments_h, metrics)
            self._pagination_state = nil
            self._pagination_complete = true
            layout_cache_put(cache_key, {pages = self.pages, page_heights = self.page_heights})
            self._layout_cache_hit = false
        else
            -- Cold opens only calculate the page that can be displayed now.
            -- Later pages are generated on demand when the user turns forward.
            self.pages, self.page_heights = {}, {}
            self._pagination_state = {comment_index = 1, item = nil, remaining_content = nil, continuation = false, done = false}
            self._pagination_complete = false
            self:_ensure_lazy_page(1)
            self._layout_cache_hit = false
        end
        self.page_index = clamp(self.page_index, 1, math.max(1, #self.pages))
        if tonumber(anchor_comment) then
            for page_index, page in ipairs(self.pages or {}) do
                local found = false
                for _, piece in ipairs(page or {}) do
                    if tonumber(piece.comment_index) == tonumber(anchor_comment) then
                        self.page_index = page_index
                        found = true
                        break
                    end
                end
                if found then break end
            end
        end
    end

    local fixed_comments_h = (self._pagination_complete ~= true or #(self.pages or {}) > 1)
        and maximum_comments_h or nil
    local comment_group, comments_h = self:_build_comment_page(comment_w, metrics, fixed_comments_h)
    local guarded_comments = HorizontalGroup:new{
        HorizontalSpan:new{width = frame_guard},
        comment_group,
        HorizontalSpan:new{width = frame_guard},
    }
    local indicator_container, indicator_h, indicator_label =
        self:_build_page_indicator(inner_w, metrics, indicator_height)

    local content_group = VerticalGroup:new{align = "left"}
    content_group[#content_group + 1] = source_group
    if has_source then
        content_group[#content_group + 1] = self:_separator_widget(
            inner_w, metrics, false, true, frame_guard
        )
    end
    content_group[#content_group + 1] = guarded_comments
    local indicator_index
    if indicator_container then
        content_group[#content_group + 1] = VerticalSpan:new{height = indicator_gap}
        indicator_index = #content_group + 1
        content_group[indicator_index] = indicator_container
    end
    content_group[#content_group + 1] = VerticalSpan:new{height = bottom_padding}
    if content_group.resetLayout then content_group:resetLayout() end

    local surface = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = border,
        radius = radius,
        padding = padding,
        margin = 0,
        content_group,
    }
    local natural_size = surface:getSize()
    local height = math.max(natural_size.h, close_size + inset * 2)
    local popup_x = math.floor((sw - width) / 2)
    local popup_y = math.floor((sh - maximum_height) / 2)
    local close_x = width - close_size - inset + close_inset
    local close_y = inset - close_inset

    self.width, self.height = width, height
    self.popup_dimen = Geom:new{x = popup_x, y = popup_y, w = width, h = height}
    self.comments_dimen = Geom:new{
        x = popup_x + inset + frame_guard,
        y = popup_y + inset + source_h + source_separator_h,
        w = comment_w,
        h = math.max(1, comments_h),
    }
    if indicator_container then
        self.page_indicator_dimen = Geom:new{
            x = popup_x + inset,
            y = self.comments_dimen.y + comments_h + indicator_gap,
            w = inner_w,
            h = indicator_h,
        }
    else
        self.page_indicator_dimen = nil
    end
    local refresh_bottom=self.page_indicator_dimen
        and (self.page_indicator_dimen.y+self.page_indicator_dimen.h)
        or (self.comments_dimen.y+self.comments_dimen.h)
    self.content_refresh_dimen = Geom:new{
        x = popup_x + inset,
        y = self.comments_dimen.y,
        w = inner_w,
        h = math.max(1, refresh_bottom - self.comments_dimen.y),
    }
    self.close_dimen = Geom:new{
        x = popup_x + close_x,
        y = popup_y + close_y,
        w = close_size,
        h = close_size,
    }
    self.frame_style = {bordersize = border, radius = radius}

    local close = CloseButton:new{
        dimen = Geom:new{w = close_size, h = close_size},
        callback = function() return self:_close() end,
    }
    close[1] = CenterContainer:new{
        dimen = Geom:new{w = close_size, h = close_size},
        TextWidget:new{
            text = "×",
            face = Font:getFace("cfont", math.max(13, math.floor(metrics.meta_size * .92))),
            bold = false,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }

    local popup_group = OverlapGroup:new{
        dimen = Geom:new{w = width, h = height},
        allow_mirroring = false,
        surface,
        OffsetContainer:new{x_off = close_x, y_off = close_y, close},
    }
    local root_offset = OffsetContainer:new{x_off = popup_x, y_off = popup_y, popup_group}
    self[1] = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        root_offset,
    }

    self._layout = {
        inset = inset,
        close_size = close_size,
        width = width,
        inner_w = inner_w,
        comment_w = comment_w,
        metrics = metrics,
        fixed_comments_h = fixed_comments_h,
        indicator_gap = indicator_gap,
        indicator_height = indicator_height,
        indicator_index = indicator_index,
    }
    self.comment_group = comment_group
    self.guarded_comments = guarded_comments
    self.content_group = content_group
    self.surface = surface
    self.popup_group = popup_group
    self.close_button = close
    self.page_indicator_container = indicator_container
    self.page_indicator_widget = indicator_label

    if previous_root and previous_root ~= self[1] and type(previous_root.free) == "function" then
        pcall(previous_root.free, previous_root)
    end
end

-- Keep the source, frame and close control alive across page turns. Only the
-- comment subtree is replaced, then the cached layout sizes are recalculated.
function NativePopup:_replace_comment_page()
    local layout = self._layout
    if not layout or not self.guarded_comments or not self.content_group or not self.surface then
        local previous = self.popup_dimen and self.popup_dimen:copy() or nil
        self:_build(false)
        return previous, self.popup_dimen and self.popup_dimen:copy() or nil
    end

    local previous_popup = self.popup_dimen and self.popup_dimen:copy() or nil
    local previous_group = self.comment_group
    local previous_indicator = self.page_indicator_container
    local comment_group, comments_h = self:_build_comment_page(
        layout.comment_w, layout.metrics, layout.fixed_comments_h
    )
    local indicator_container, indicator_h, indicator_label = self:_build_page_indicator(
        layout.inner_w, layout.metrics, layout.indicator_height
    )

    self.guarded_comments[2] = comment_group
    self.comment_group = comment_group
    if layout.indicator_index and indicator_container then
        self.content_group[layout.indicator_index] = indicator_container
        self.page_indicator_container = indicator_container
        self.page_indicator_widget = indicator_label
    end
    if self.guarded_comments.resetLayout then self.guarded_comments:resetLayout() end
    if self.content_group.resetLayout then self.content_group:resetLayout() end

    local natural_size = self.surface:getSize()
    local height = math.max(natural_size.h, layout.close_size + layout.inset * 2)
    self.height = height
    self.popup_dimen.h = height
    self.comments_dimen.h = math.max(1, comments_h)
    if self.page_indicator_dimen and indicator_container then
        self.page_indicator_dimen.y = self.comments_dimen.y + comments_h + layout.indicator_gap
        self.page_indicator_dimen.h = indicator_h
    end

    if self.surface.dimen then
        self.surface.dimen.w = natural_size.w
        self.surface.dimen.h = natural_size.h
    end
    if self.popup_group then
        self.popup_group.dimen.w = layout.width
        self.popup_group.dimen.h = height
        self.popup_group._size = self.popup_group._size or {}
        self.popup_group._size.w = layout.width
        self.popup_group._size.h = height
    end

    if previous_group and previous_group ~= comment_group and type(previous_group.free) == "function" then
        pcall(previous_group.free, previous_group)
    end
    if previous_indicator and previous_indicator ~= indicator_container
        and type(previous_indicator.free) == "function" then
        pcall(previous_indicator.free, previous_indicator)
    end
    return previous_popup, self.popup_dimen:copy()
end

function NativePopup:_change_page(delta)
    if self.closing or self.paint_failed or self.page_changing then return true end
    local target = self.page_index + (tonumber(delta) or 0)
    if target < 1 or target == self.page_index then return true end
    if target > #(self.pages or {}) and self._pagination_complete ~= true then
        self:_ensure_lazy_page(target)
    end
    local pages = self.pages or {}
    if target > #pages then return true end

    self.page_changing = true
    local previous_index = self.page_index
    local ok, err = xpcall(function()
        self.page_index = target
        local previous_popup, current_popup = self:_replace_comment_page()
        self.page_refresh_count = (tonumber(self.page_refresh_count) or 0) + 1
        local eink = type(Device.hasEinkScreen) == "function" and Device:hasEinkScreen()
        local flash_refresh = eink and self.page_refresh_count >= GHOSTING_REFRESH_INTERVAL
        if flash_refresh then self.page_refresh_count = 0 end
        local refresh_mode = flash_refresh and "flashui" or "ui"

        local dimensions_changed = previous_popup and current_popup
            and (previous_popup.x ~= current_popup.x or previous_popup.y ~= current_popup.y
                or previous_popup.w ~= current_popup.w or previous_popup.h ~= current_popup.h)
        if dimensions_changed then
            local left = math.min(previous_popup.x, current_popup.x)
            local top = math.min(previous_popup.y, current_popup.y)
            local right = math.max(previous_popup.x + previous_popup.w, current_popup.x + current_popup.w)
            local bottom = math.max(previous_popup.y + previous_popup.h, current_popup.y + current_popup.h)
            local dirty = Geom:new{x = left, y = top, w = right - left, h = bottom - top}
            UIManager:setDirty("all", function() return refresh_mode, dirty end)
        else
            local dirty = self.content_refresh_dimen or current_popup or previous_popup
            UIManager:setDirty(flash_refresh and "all" or self, function() return refresh_mode, dirty end)
        end
    end, debug.traceback)
    if not ok then
        self.page_changing = false
        self.page_index = previous_index
        self:_fail("page", err)
    else
        if self.on_interact_callback then pcall(self.on_interact_callback) end
        UIManager:scheduleIn(.10, function()
            if not self.closing then self.page_changing = false end
            collectgarbage("step", 12)
        end)
    end
    return true
end

function NativePopup:updateFont(font_size, font_name)
    if self.closing then return false end
    local previous = self.popup_dimen and self.popup_dimen:copy() or nil
    local current_page = self.pages and self.pages[self.page_index] or nil
    local anchor_comment = current_page and current_page[1] and current_page[1].comment_index or nil
    self.font_size = tonumber(font_size) or self.font_size
    self.font_name = font_name
    self.page_index = 1
    self:_build(true, anchor_comment)
    local current = self.popup_dimen and self.popup_dimen:copy() or nil
    local dirty = current or previous
    if previous and current then
        local left = math.min(previous.x, current.x)
        local top = math.min(previous.y, current.y)
        local right = math.max(previous.x + previous.w, current.x + current.w)
        local bottom = math.max(previous.y + previous.h, current.y + current.h)
        dirty = Geom:new{x = left, y = top, w = right - left, h = bottom - top}
    end
    UIManager:setDirty("all", function() return "ui", dirty end)
    return true
end

function NativePopup:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPage = {GestureRange:new{ges = "tap", range = self.dimen}},
            SwipePage = {GestureRange:new{ges = "swipe", range = self.dimen}},
            HoldComment = {GestureRange:new{ges = "hold", range = self.dimen}},
        }
    end
    if Device:hasKeys() and Device.input and Device.input.group then
        local group = Device.input.group
        self.key_events = {}
        if group.Back then self.key_events.Close = {{group.Back}} end
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.Previous = {{previous}} end
        if following then self.key_events.Next = {{following}} end
    end
    self:_build(true)
end

function NativePopup:onShow()
    UIManager:setDirty(self, function() return "partial", self.popup_dimen end)
end

function NativePopup:onTapPage(_, ges)
    local pos = ges and ges.pos
    if not pos then return false end
    if self.close_dimen and not pos:notIntersectWith(self.close_dimen) then return self:_close() end
    if pos:notIntersectWith(self.popup_dimen) then return self:_close() end
    if pos.x < self.popup_dimen.x + math.floor(self.popup_dimen.w / 2) then
        return self:_change_page(-1)
    end
    return self:_change_page(1)
end

function NativePopup:onHoldComment(_, ges)
    local pos=ges and ges.pos
    if not pos or not self.comments_dimen or pos:notIntersectWith(self.comments_dimen) then
        return false
    end
    local comment=self:_comment_at_position(pos)
    if not comment then return true end
    return self:_show_action_menu(comment)
end

function NativePopup:onSwipePage(_, ges)
    local pos = ges and ges.pos
    if pos and self.popup_dimen and pos:notIntersectWith(self.popup_dimen) then
        return true
    end
    local direction = ges and tostring(ges.direction or "") or ""
    local relative = ges and ges.relative
    if relative then
        local dx = math.abs(tonumber(relative.x) or 0)
        local dy = math.abs(tonumber(relative.y) or 0)
        local minimum = math.max(18, Screen:scaleBySize(14))
        if dy < minimum or dy <= dx * 1.15 then return true end
    end
    if direction == "north" then return self:_change_page(1) end
    if direction == "south" then return self:_change_page(-1) end
    -- Horizontal and diagonal swipes are consumed by the popup so they can
    -- never turn the book page underneath it.
    return true
end

function NativePopup:onPrevious() return self:_change_page(-1) end
function NativePopup:onNext() return self:_change_page(1) end
function NativePopup:onClose() return self:_close() end

function NativePopup:onCloseWidget()
    local region = self.popup_dimen and self.popup_dimen:copy() or nil
    self:_close_action_dialog()
    self.closing = true
    if live_popup == self then live_popup = nil end
    self.page_changing = false
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    if region then UIManager:setDirty("all", function() return "partial", region end) end
end

function NativePopup:_reopen(opts)
    opts = opts or {}
    self:_close_action_dialog()
    self.source_text = opts.source_text
    self.comments = opts.comments
    self.cache_key = opts.cache_key
    self.font_size = opts.font_size
    self.font_name = opts.font_name
    self.width_ratio = opts.width_ratio
    self.height_ratio = opts.height_ratio
    self.on_close_callback = opts.on_close
    self.on_interact_callback = opts.on_interact
    self.on_error_callback = opts.on_error
    self.is_favorite_callback = opts.is_favorite_callback
    self.toggle_favorite_callback = opts.toggle_favorite_callback
    self.copy_callback = opts.copy_callback
    self.closing = false
    self.paint_failed = false
    self.page_changing = false
    self.page_index = 1
    self.pages = nil
    self.page_heights = nil
    self._pagination_state = nil
    self._pagination_layout = nil
    self._pagination_complete = nil
    self.page_refresh_count = 0
    self._measurement_cache = nil
    self:init()
end

local M = {}
function M.show(opts)
    TransientGuard.close_all()
    opts = opts or {}
    local popup = pooled_popup
    if popup then
        popup:_reopen(opts)
    else
        popup = NativePopup:new{
            source_text = opts.source_text,
            comments = opts.comments,
            cache_key = opts.cache_key,
            font_size = opts.font_size,
            font_name = opts.font_name,
            width_ratio = opts.width_ratio,
            height_ratio = opts.height_ratio,
            on_close_callback = opts.on_close,
            on_interact_callback = opts.on_interact,
            on_error_callback = opts.on_error,
            is_favorite_callback = opts.is_favorite_callback,
            toggle_favorite_callback = opts.toggle_favorite_callback,
            copy_callback = opts.copy_callback,
        }
        pooled_popup = popup
    end
    live_popup = popup
    UIManager:show(popup, "partial", popup.popup_dimen)
    return popup
end

function M.close_visible()
    if not live_popup or live_popup.closing then return false end
    live_popup:_close()
    return true
end

function M.refresh_font(font_size, font_name)
    if not live_popup or live_popup.closing then return false end
    return live_popup:updateFont(font_size, font_name)
end

function M.clear_cache()
    clear_layout_cache()
    ThoughtFaceFactory:clearCache()
end

function M.cleanup()
    local popup = pooled_popup
    if live_popup and not live_popup.closing then
        pcall(live_popup._close, live_popup)
    end
    live_popup = nil
    pooled_popup = nil
    clear_layout_cache()
    ThoughtFaceFactory:clearCache()
    if popup then
        popup.on_close_callback = nil
        popup.on_interact_callback = nil
        popup.on_error_callback = nil
        if popup[1] and type(popup[1].free) == "function" then
            pcall(popup[1].free, popup[1])
        end
        popup[1] = nil
        popup.pages = nil
        popup.page_heights = nil
        popup.comments = nil
        popup.source_text = nil
    end
    collectgarbage("step", 48)
end

return M
