local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local U = require("miuread.util")
local UiScale = require("miuread.ui_scale")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_widget
local home_generation = 0

local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local RoundedImageContainer = WidgetContainer:extend{width = 1, height = 1, radius = 0, ink_boost = 0}
function RoundedImageContainer:getSize()
    return Geom:new{w = self.width, h = self.height}
end
function RoundedImageContainer:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
    local boost = math.max(0, math.min(.18, tonumber(self.ink_boost) or 0))
    if boost > 0 and bb and type(bb.darkenRect) == "function" then
        -- A light contrast lift keeps pale covers legible on e-ink without
        -- turning dark covers into solid blocks.
        pcall(bb.darkenRect, bb, x, y, self.width, self.height, boost)
    end
    local r = math.max(0, math.min(math.floor(self.radius or 0), math.floor(math.min(self.width, self.height) / 2)))
    if r <= 1 or not bb or type(bb.paintRect) ~= "function" then return end
    -- Mask only the four corner pixels. This keeps the image flush with its
    -- box while giving the cover itself rounded corners, without a padded frame.
    for row = 0, r - 1 do
        local dy = r - row
        local inside = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.max(0, math.floor(r - inside + .5))
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local margin = tonumber(options.margin) or 0
    local inset = border + padding + margin
    return FrameContainer:new{
        bordersize = border,
        radius = options.radius or 0,
        padding = padding,
        margin = margin,
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

local function background(width, height)
    return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE})
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, hold_callback = nil, _hold_handled = false}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
        HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}},
        HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect(_, ges)
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    local now=os.clock()
    if now<(tonumber(self._miu_tap_block_until) or 0) then return true end
    self._miu_tap_block_until=now+.20
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil, ges) end
    return true
end
function TapBox:onHoldSelect()
    self._hold_handled = self.hold_callback ~= nil
    if self.hold_callback then self.hold_callback(self.dimen and self.dimen:copy() or nil) end
    return self.hold_callback ~= nil
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        self._miu_tap_block_until = os.clock() + .20
        return true
    end
    return false
end
function TapBox:handleEvent(event)
    -- Child cards only own taps. Let swipes reach HomeWidget first so the
    -- quick panel and shelf paging are not consumed by KOReader underneath.
    return InputContainer.handleEvent(self, event)
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

local function text_button(text, width, height, callback, options)
    options = options or {}
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = options.borderless and 0 or UiScale.line("thin"),
        padding = UiScale.dp(3, 2, 6),
        background = Blitbuffer.COLOR_WHITE,
    }, TextWidget:new{
        text = tostring(text or ""),
        face = face(options.font or "smallinfofont", options.size or 12, options.maximum or 16),
        bold = options.bold ~= false,
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    }), callback)
end

local function image_widget(path, width, height, ink_boost)
    if not path or path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            -- Stretch into the cover box. Book covers are already close to the
            -- target ratio, and this avoids the visible inner blank frame that
            -- scale-to-fit produced on Kindle.
            scale_factor = nil,
            -- Always use MuPDF scaling for covers. Legacy scaling is faster on
            -- a few old devices but visibly softer at small e-ink sizes.
            use_legacy_image_scaling = false,
            file_do_cache = true,
        }
        image:getSize()
    end)
    if ok and image then
        return RoundedImageContainer:new{
            width = width,
            height = height,
            radius = UiScale.radius(7, 5, 13),
            ink_boost = tonumber(ink_boost) or .08,
            image,
        }
    end
    if image and image.free then pcall(image.free, image) end
    return nil
end

local function placeholder(width, height, title, author)
    title = U.trim(tostring(title or "未命名"))
    author = U.trim(tostring(author or ""))
    if title == "" then title = "未命名" end
    local pad = UiScale.dp(3, 2, 5)
    local content_w = math.max(1, width - pad * 2)
    local content_h = math.max(1, height - pad * 2)
    local title_h = math.max(1, math.floor(content_h * (author ~= "" and .58 or .78)))
    local author_h = math.max(1, content_h - title_h)
    local body = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = U.utf8_truncate(title, 24, "…"),
            face = face("cfont", 10.8, 15.5), bold = true,
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = title_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    if author ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = U.utf8_truncate(author, 18, "…"),
            face = face("smallinfofont", 7.8, 10.8),
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = author_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    return fixed_frame(width, height, {
        bordersize = UiScale.line("thin"),
        radius = UiScale.radius(6, 4, 12),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, body)
end

local function solid_bar(width, height, color)
    return fixed_frame(width, height, {background = color or Blitbuffer.COLOR_BLACK})
end

local function progress_bar(width, height, progress)
    progress = math.max(0, math.min(1, tonumber(progress) or 0))
    local filled = math.floor(width * progress + .5)
    local rest = math.max(0, width - filled)
    local row = HorizontalGroup:new{align = "center"}
    if filled > 0 then table.insert(row, solid_bar(filled, height, Blitbuffer.COLOR_BLACK)) end
    if rest > 0 then table.insert(row, solid_bar(rest, height, Blitbuffer.COLOR_GRAY)) end
    return row
end

local function section_header(title, width, height, on_more, on_source, filter_label)
    local right_w = on_more and math.max(UiScale.dp(68, 58, 92), math.floor(width * .14)) or 0
    local gap = on_more and UiScale.dp(4, 3, 7) or 0
    local left_w = math.max(1, width - right_w - gap)
    local label = tostring(title or "") .. (on_source and " ▾" or "")
    local left_text = fixed_frame(left_w, height, {bordersize=0, background=Blitbuffer.COLOR_WHITE},
        LeftContainer:new{dimen=Geom:new{w=left_w,h=height}, TextWidget:new{
            text=label, face=face("smallinfofont",10.5,14.5), bold=false,
        }})
    local row = HorizontalGroup:new{align = "center"}
    if on_source then row[#row + 1] = tappable(left_w, height, left_text, on_source)
    else row[#row + 1] = left_text end
    if on_more then
        row[#row + 1] = HorizontalSpan:new{width=gap}
        row[#row + 1] = tappable(right_w, height,
            fixed_frame(right_w, height, {bordersize=0, background=Blitbuffer.COLOR_WHITE},
                Ui.text(tostring(filter_label or "筛选"),right_w,height,face("smallinfofont",10.5,14.5),{bold=true})), on_more)
    end
    return row
end

local function notice_strip(item, width, height)
    local pad = UiScale.dp(6, 5, 10)
    local progress_w = item.progress and math.max(92, math.floor(width * .20)) or 0
    local detail_w = math.max(1, width - progress_w - pad * 3)
    local text = tostring(item.title or "")
    if item.detail and tostring(item.detail) ~= "" then
        text = text .. "　" .. tostring(item.detail)
    end
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = detail_w, h = height - pad * 2}, TextBoxWidget:new{
            text = text,
            face = face("smallinfofont", 10.5, 15),
            bold = true,
            width = detail_w,
            height = height - pad * 2,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }},
    }
    if progress_w > 0 then
        table.insert(row, HorizontalSpan:new{width = pad})
        table.insert(row, progress_bar(progress_w, UiScale.dp(3, 2, 5), item.progress))
    end
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = item.important == true and UiScale.line("thick") or UiScale.line("thin"),
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, row), item.on_tap)
end

local function home_card_outer_inset()
    return math.max(1, UiScale.dp(2, 2, 3))
end

local function hero_card(book, width, height, callback, compact, hold_callback, shelf_cover_w, shelf_cover_h)
    local frame_inset = home_card_outer_inset()
    local frame_w = math.max(1, width - frame_inset * 2)
    local frame_h = math.max(1, height - frame_inset * 2)
    local mini = width < Screen:getWidth() * .62
    local pad = math.max(UiScale.dp(7, 6, 12), math.min(UiScale.dp(11, 9, 16), math.floor(math.min(frame_w, frame_h) * .027)))
    local inner_w = math.max(1, frame_w - pad * 2)
    local inner_h = math.max(1, frame_h - pad * 2)

    -- beta.24: the title owns a real two-line slot and the recent-reading
    -- cover uses the visible shelf cover as its minimum target.  This avoids
    -- the old situation where the hero cover could still look smaller than a
    -- normal bookshelf cover on some Kindle geometries.
    local section_gap = UiScale.dp(4, 3, 6)
    local title_face = face("cfont", mini and 13.0 or (compact and 13.8 or 14.6),
        mini and 17.4 or (compact and 18.6 or 19.6), mini and 11.2 or 12.2)
    local title_line_h = UiScale.dp(22, 19, 30)
    if title_face and title_face.ftsize and type(title_face.ftsize.getHeightAndAscender) == "function" then
        local ok, fh = pcall(title_face.ftsize.getHeightAndAscender, title_face.ftsize)
        if ok and tonumber(fh) and tonumber(fh) > 0 then title_line_h = math.floor(tonumber(fh) + .5) end
    end
    local title_h = math.max(UiScale.dp(38, 34, 52), title_line_h * 2 + UiScale.dp(2, 1, 3))
    local progress_h = math.max(UiScale.dp(29, 26, 40), math.min(UiScale.dp(38, 33, 48), math.floor(inner_h * .11)))
    local body_h = math.max(1, inner_h - title_h - progress_h - section_gap * 2)

    local baseline_h = math.max(0, tonumber(shelf_cover_h) or 0)
    local baseline_w = math.max(0, tonumber(shelf_cover_w) or 0)
    local minimum_h = UiScale.dp(mini and 126 or 136, mini and 108 or 116, mini and 184 or 198)
    local desired_h = math.max(minimum_h, baseline_h)
    local cover_h = math.min(body_h, desired_h)
    local width_cap = math.max(1, math.floor(inner_w * (mini and .50 or .46)))
    local desired_w = math.max(baseline_w, math.floor(cover_h * .715))
    local cover_w = math.min(width_cap, desired_w)
    -- Keep the same cover-box aspect rule as the shelf.  If width is the
    -- limiting factor, shrink height rather than squeezing the artwork.
    if cover_w < math.floor(cover_h * .715) then
        cover_h = math.min(body_h, math.max(1, math.floor(cover_w / .715)))
    else
        cover_w = math.min(width_cap, math.max(1, math.floor(cover_h * .715)))
    end
    local cover = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .05)
        or placeholder(cover_w, cover_h, book.title, book.author)
    local gap = math.max(UiScale.dp(8, 6, 13), math.floor(width * .018))
    local text_w = math.max(1, inner_w - cover_w - gap)
    local history_h = UiScale.dp(22, 20, 30)
    local history_w = book.on_history and math.max(UiScale.dp(52, 46, 72), math.floor(text_w * .31)) or 0

    local author = U.trim(tostring(book.author or ""))
    local category = U.trim(tostring(book.category or ""))
    local publisher = U.trim(tostring(book.publisher or ""))
    local published_date = U.trim(tostring(book.published_date or book.publishTime or ""))
    local published_number = tonumber(published_date)
    if published_number and published_number > 1000000000 then
        if published_number > 100000000000 then published_number = published_number / 1000 end
        local ok, year = pcall(os.date, "%Y", published_number)
        published_date = ok and tostring(year or "") or ""
    elseif published_date ~= "" then
        published_date = U.utf8_truncate(published_date, 16, "…")
    end
    local format = U.trim(tostring(book.format or "")):upper()
    local edition = U.trim(tostring(book.edition_text or ""))
    local recent_line = U.trim(tostring(book.last_read_text or ""))

    local source_line
    local unified_source = tostring(book.unified_source or book.external_source or book.source or "")
    if unified_source == "fanqie" then
        source_line = "番茄小说"
    elseif unified_source == "zlibrary" or unified_source == "z-lib" then
        source_line = "Z-Library"
    elseif unified_source == "wechat_mp" or unified_source == "wechat_mp_article"
        or unified_source == "mp" or unified_source == "mp_article" then
        source_line = "公众号"
    elseif unified_source == "local" or book.local_file == true then
        source_line = "本地书"
    else
        source_line = "微信读书"
    end

    local info_lines = {}
    local function add_info(label, value)
        value = U.trim(tostring(value or ""))
        if value ~= "" then info_lines[#info_lines + 1] = tostring(label or "") .. value end
    end
    add_info("作者  ", author)
    add_info("来源  ", source_line)
    add_info("分类  ", category)
    if publisher ~= "" then
        local pub = publisher
        if published_date ~= "" then pub = pub .. " · " .. published_date end
        add_info("出版  ", pub)
    elseif published_date ~= "" then
        add_info("出版  ", published_date)
    end
    if edition ~= "" then
        add_info("版本  ", edition)
    elseif (book.source == "local" or book.local_file == true) and format ~= "" then
        add_info("格式  ", format)
    end
    add_info("最近  ", recent_line)

    -- History only owns the top-right corner.  It no longer wastes a whole
    -- metadata row.  The first information line simply shortens around it;
    -- every following line uses the full information width.
    local info_h = body_h
    local min_line_h = math.max(UiScale.dp(18, 16, 25), math.floor(body_h * .105))
    local max_lines = math.max(1, math.floor(info_h / math.max(1, min_line_h)))
    while #info_lines > max_lines do table.remove(info_lines, #info_lines - 1) end
    local line_count = math.max(1, #info_lines)
    local line_h = math.max(1, math.floor(info_h / line_count))
    local info = OverlapGroup:new{dimen = Geom:new{w = text_w, h = info_h}, allow_mirroring = false}
    if #info_lines == 0 then
        info[#info + 1] = Widget:new{dimen = Geom:new{w = text_w, h = info_h}}
    else
        for index, value in ipairs(info_lines) do
            local line_w = text_w
            if index == 1 and history_w > 0 then
                line_w = math.max(1, text_w - history_w - UiScale.dp(5, 4, 8))
            end
            info[#info + 1] = OffsetContainer:new{x_off = 0, y_off = (index - 1) * line_h, TextBoxWidget:new{
                text = value,
                face = face("smallinfofont", mini and 9.2 or 9.8, mini and 12.6 or 13.4, mini and 7.8 or 8.2),
                bold = true,
                width = line_w, height = line_h, height_adjust = false,
                height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
            }}
        end
    end

    local title = TextBoxWidget:new{
        text = tostring(book.title or "未命名"),
        face = title_face,
        bold = true,
        width = inner_w, height = title_h, height_adjust = false,
        height_overflow_show_ellipsis = true, fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local progress_value = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local progress_number = string.format("%.1f", progress_value):gsub("%.0$", "")
    local progress_label = "阅读进度 " .. progress_number .. "%"
    local progress_label_h = math.max(UiScale.dp(18, 16, 25), math.floor(progress_h * .52))
    local progress_slot_h = math.max(1, progress_h - progress_label_h)
    local progress_track_h = math.max(UiScale.line("thick"), UiScale.dp(3, 2, 5))
    local progress_fill = math.max(0, math.min(inner_w, math.floor(inner_w * progress_value / 100 + .5)))
    local progress_layers = OverlapGroup:new{dimen = Geom:new{w = inner_w, h = progress_slot_h}, allow_mirroring = false}
    local bar_y = math.floor((progress_slot_h - progress_track_h) / 2)
    progress_layers[#progress_layers + 1] = OffsetContainer:new{x_off = 0, y_off = bar_y, LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY, dimen = Geom:new{w = inner_w, h = progress_track_h},
    }}
    if progress_fill > 0 then
        progress_layers[#progress_layers + 1] = OffsetContainer:new{x_off = 0, y_off = bar_y, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = progress_fill, h = progress_track_h},
        }}
    end

    local body = OverlapGroup:new{dimen = Geom:new{w = inner_w, h = inner_h}, allow_mirroring = false}
    body[#body + 1] = OffsetContainer:new{x_off = 0, y_off = 0, HorizontalGroup:new{
        align = "center",
        CenterContainer:new{dimen = Geom:new{w = cover_w, h = body_h}, cover},
        HorizontalSpan:new{width = gap},
        CenterContainer:new{dimen = Geom:new{w = text_w, h = body_h}, info},
    }}
    local title_y = body_h + section_gap
    body[#body + 1] = OffsetContainer:new{x_off = 0, y_off = title_y, title}
    local progress_y = title_y + title_h + section_gap
    body[#body + 1] = OffsetContainer:new{x_off = 0, y_off = progress_y, VerticalGroup:new{
        align = "left",
        Ui.textbox(progress_label, inner_w, progress_label_h,
            face("smallinfofont", 9.6, 13.2, 8.2), {bold = true, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK}),
        progress_layers,
    }}

    local content = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    content[#content + 1] = OffsetContainer:new{
        x_off = frame_inset,
        y_off = frame_inset,
        fixed_frame(frame_w, frame_h, {
            bordersize = math.max(UiScale.line("thin"), 1),
            radius = UiScale.radius(9, 6, 15),
            padding = pad,
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_DARK_GRAY,
        }, body),
    }

    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = content
    if history_w > 0 then
        layers[#layers + 1] = OffsetContainer:new{
            x_off = frame_inset + pad + cover_w + gap + math.max(0, text_w - history_w),
            y_off = frame_inset + pad,
            tappable(history_w, history_h,
                Ui.text("历史 ›", history_w, history_h, face("smallinfofont", 9.8, 13.5), {bold = true, fgcolor = Blitbuffer.COLOR_BLACK}),
                function() if book.on_history then book.on_history() end end),
        }
    end
    layers[#layers + 1] = tappable(width, height, Widget:new{dimen = Geom:new{w = width, h = height}}, callback, function(anchor)
        if hold_callback then hold_callback(book, anchor) end
    end)
    return layers
end

local function welcome_card(width, height, callback)
    local inset = math.max(1, UiScale.dp(2, 2, 3))
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = OffsetContainer:new{
        x_off = inset, y_off = inset,
        fixed_frame(math.max(1, width - inset * 2), math.max(1, height - inset * 2), {
            bordersize = math.max(UiScale.line("thin"), 1),
            radius = UiScale.radius(9, 6, 15),
            background = Blitbuffer.COLOR_WHITE,
        }, VerticalGroup:new{
            align = "center",
            TextWidget:new{text = "开始阅读", face = UiScale.iconFace("cfont", 18, 24), bold = true},
            VerticalSpan:new{height = UiScale.dp(7, 5, 10)},
            TextWidget:new{
                text = "从书架选择一本内容",
                face = face("smallinfofont", 11, 14),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }),
    }
    return tappable(width, height, layers, callback)
end

local function shelf_folder_card(folder, width, height, callback)
    -- A folder occupies exactly one normal book slot.  Its visual body uses the
    -- same cover geometry as a book, so mixed folders/books stay on one grid.
    local pad = math.max(UiScale.dp(1, 0, 2), math.floor(width * .004))
    local inner_w = math.max(1, width - pad * 2)
    local title_h = math.max(UiScale.dp(29, 25, 40), math.min(UiScale.dp(39, 32, 47), math.floor(height * .155)))
    local vgap = UiScale.dp(2, 2, 4)
    local cover_h = math.max(UiScale.dp(78, 64, 108), height - title_h - vgap)
    local cover_w = math.max(UiScale.dp(54, 46, 78), math.min(math.floor(inner_w * .995), math.floor(cover_h * .715)))
    local icon_key = folder.local_parent==true and "back" or "folder"
    local icon_size = math.max(UiScale.dp(36, 31, 52), math.min(math.floor(cover_w * .58), math.floor(cover_h * .35)))
    local cover_inset = UiScale.line("thin") + UiScale.dp(2, 1, 4)
    local icon_area_w = math.max(1, cover_w - cover_inset * 2)
    local icon_area_h = math.max(1, cover_h - cover_inset * 2)
    local cover = fixed_frame(cover_w, cover_h, {
        bordersize = UiScale.line("thin"),
        radius = UiScale.radius(7, 5, 12),
        padding = UiScale.dp(2, 1, 4),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_GRAY,
    }, Ui.icon(icon_key, icon_area_w, icon_area_h, icon_size, {
        face = UiScale.iconFace("cfont", 28, 40),
    }))
    local body = VerticalGroup:new{
        align = "center",
        cover,
        VerticalSpan:new{height = vgap},
        TextBoxWidget:new{
            text = tostring(folder.title or "文件夹"), face = face("cfont", 11.8, 16.5), bold = true,
            width = inner_w, height = title_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    return tappable(width, height, CenterContainer:new{dimen = Geom:new{w = width, h = height}, body}, function(anchor)
        if callback then callback(folder, anchor) end
    end)
end

local function outlined_badge_text(text, width, height, badge_face)
    local layer = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    local radius = math.max(2, UiScale.dp(2, 2, 3))
    local offsets = {
        {-radius,0},{radius,0},{0,-radius},{0,radius},
        {-radius,-radius},{-radius,radius},{radius,-radius},{radius,radius},
    }
    for _, off in ipairs(offsets) do
        layer[#layer + 1] = OffsetContainer:new{
            x_off = off[1], y_off = off[2],
            CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
                text = text, face = badge_face, bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
            }},
        }
    end
    layer[#layer + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
        text = text, face = badge_face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
    }}
    return layer
end

local function shelf_cover_target_size(width, height, oversample)
    width=math.max(1,tonumber(width) or 1)
    height=math.max(1,tonumber(height) or 1)
    local pad=math.max(UiScale.dp(1,0,2),math.floor(width*.004))
    local inner_w=math.max(1,width-pad*2)
    local title_h=math.max(UiScale.dp(29,25,40),math.min(UiScale.dp(39,32,47),math.floor(height*.155)))
    local vgap=UiScale.dp(2,2,4)
    -- Use the largest normal shelf-cover geometry. Cards with a status/progress
    -- row render a little smaller, so this remains a safe quality upper bound.
    local cover_h=math.max(UiScale.dp(78,64,108),height-title_h-vgap)
    local cover_w=math.max(UiScale.dp(54,46,78),math.min(math.floor(inner_w*.995),math.floor(cover_h*.715)))
    local scale=math.max(1.0,math.min(1.25,tonumber(oversample) or 1.12))
    return math.max(1,math.floor(cover_w*scale+.5)),math.max(1,math.floor(cover_h*scale+.5))
end

local function shelf_book_card(book, width, height, callback, hold_callback)
    if book and (book.local_folder==true or book.kind=="folder") then
        return shelf_folder_card(book,width,height,callback)
    end
    local pad = math.max(UiScale.dp(1, 0, 2), math.floor(width * .004))
    local inner_w = math.max(1, width - pad * 2)
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local status = U.trim(tostring(book.status_text or ""))
    local downloaded = status == "已生成" or status == "已下载" or book.generated == true
        or book.downloaded == true or tostring(book.shelf_section or "") == "generated"
        or (book.file and tostring(book.file) ~= "" and U.file_exists(tostring(book.file)))
    local reading_badge = ""
    if progress >= 100 then reading_badge = "已读"
    elseif progress > 0 then reading_badge = tostring(math.floor(progress + .5)) .. "%" end

    local download_active = book.download_active == true
    local download_progress = math.max(0, math.min(1, tonumber(book.download_progress) or 0))
    if status == "已生成" or status == "已下载" or status == "未生成" or status == "未开始"
        or status == "已读完" or status:match("^阅读%s+%d+%%$")
        or status:match("下载中") or status:match("生成中") then
        status = ""
    end
    status = U.utf8_truncate(status, 10, "")
    local status_important = status == "失败" or status == "待修复" or status == "排队中"
        or status == "批注待修复"
    if not status_important then status = "" end

    local title_h = math.max(UiScale.dp(29, 25, 40), math.min(UiScale.dp(39, 32, 47), math.floor(height * .155)))
    local status_h = status ~= "" and UiScale.dp(18, 15, 25) or 0
    local download_h = download_active and UiScale.dp(4, 3, 6) or 0
    local vgap = UiScale.dp(2, 2, 4)
    local extra_h = status_h + download_h
    local extra_gaps = (status_h > 0 and 1 or 0) + (download_h > 0 and 1 or 0)
    local cover_h = math.max(UiScale.dp(78, 64, 108), height - title_h - extra_h - vgap * (1 + extra_gaps))
    local cover_w = math.max(UiScale.dp(54, 46, 78), math.min(math.floor(inner_w * .995), math.floor(cover_h * .715)))
    local cover = image_widget(book.home_cover_path or book.cover_path, cover_w, cover_h, .06) or placeholder(cover_w, cover_h, book.title, book.author)

    local cover_layer = OverlapGroup:new{dimen = Geom:new{w = cover_w, h = cover_h}, allow_mirroring = false}
    cover_layer[#cover_layer + 1] = cover
    if downloaded then
        local badge = UiScale.dp(20, 17, 27)
        local inset = UiScale.dp(2, 1, 4)
        cover_layer[#cover_layer + 1] = OffsetContainer:new{
            x_off = inset, y_off = inset,
            outlined_badge_text("✓", badge, badge, face("cfont", 9.4, 13.5)),
        }
    end
    if reading_badge ~= "" then
        local chars = math.max(2, U.utf8_len(reading_badge))
        local badge_w = math.max(UiScale.dp(31, 26, 45), UiScale.dp(9, 8, 14) + chars * UiScale.dp(7, 6, 10))
        local badge_h = UiScale.dp(20, 17, 27)
        local inset = UiScale.dp(2, 1, 4)
        cover_layer[#cover_layer + 1] = OffsetContainer:new{
            x_off = math.max(0, cover_w - badge_w - inset), y_off = inset,
            outlined_badge_text(reading_badge, badge_w, badge_h, face("smallinfofont", 9.2, 13)),
        }
    end

    local body = VerticalGroup:new{align = "center", cover_layer, VerticalSpan:new{height = vgap}}
    body[#body + 1] = TextBoxWidget:new{
        text = tostring(book.title or "未命名"),
        face = face("cfont", 11.5, 16), bold = true, width = inner_w, height = title_h,
        height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
    }
    if download_h > 0 then
        body[#body + 1] = VerticalSpan:new{height = vgap}
        body[#body + 1] = CenterContainer:new{
            dimen = Geom:new{w = inner_w, h = download_h},
            progress_bar(math.max(UiScale.dp(44, 38, 68), math.floor(cover_w * .86)), download_h, download_progress),
        }
    elseif status_h > 0 then
        body[#body + 1] = TextBoxWidget:new{
            text = status, face = face("smallinfofont", 8.5, 12), bold = true, width = inner_w, height = status_h,
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    return tappable(width, height, CenterContainer:new{dimen = Geom:new{w = width, h = height}, body},
        function(anchor,ges) if callback then callback(book, anchor, ges) end end,
        function(anchor) if hold_callback then hold_callback(book, anchor) end end)
end

local function home_action_icon(icon, width, height, enabled)
    local size = math.min(width, height, UiScale.dp(25, 22, 34))
    return Ui.icon(icon, width, height, size, {
        icon_key = icon,
        face = UiScale.iconFace("cfont", 20, 27, 17),
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local function action_button(entry, width, height)
    local enabled = entry.enabled ~= false
    local icon_h = math.max(UiScale.dp(24, 21, 33), math.floor(height * .42))
    local gap_h = UiScale.dp(2, 1, 4)
    local label_h = math.max(UiScale.dp(17, 15, 23), math.floor(height * .27))
    local body = VerticalGroup:new{
        align = "center",
        home_action_icon(tostring(entry.icon_key or entry.icon or "•"), width, icon_h, enabled),
        VerticalSpan:new{height = gap_h},
        CenterContainer:new{
            dimen = Geom:new{w = width, h = label_h},
            TextWidget:new{
                text = tostring(entry.label or ""),
                face = face("smallinfofont", 9.5, 13),
                bold = true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        },
    }
    local child = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    child[#child + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, body}
    if entry.badge and tostring(entry.badge) ~= "" then
        local badge_w = math.max(UiScale.dp(22, 18, 32), math.min(UiScale.dp(42, 34, 56), UiScale.dp(12, 10, 18) + U.utf8_len(tostring(entry.badge)) * UiScale.dp(8, 6, 10)))
        local badge_h = math.max(UiScale.dp(18, 15, 24), math.floor(height * .24))
        child[#child + 1] = OffsetContainer:new{
            x_off = math.max(0, width - badge_w - UiScale.dp(4, 3, 7)), y_off = UiScale.dp(2, 1, 4),
            fixed_frame(badge_w, badge_h, {
                bordersize = UiScale.line("thin"),
                radius = UiScale.radius(4, 3, 7),
                padding = UiScale.dp(1, 1, 3),
                background = Blitbuffer.COLOR_WHITE,
            }, TextWidget:new{text = tostring(entry.badge), face = face("smallinfofont", 9, 11), bold = true}),
        }
    end
    return tappable(width, height, child, enabled and entry.callback or nil, enabled and entry.hold_callback or nil)
end

local function action_bar(actions, width, height)
    actions = actions or {}
    if #actions == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local gap = UiScale.dp(2, 2, 5)
    local item_w = math.floor((width - gap * (#actions - 1)) / #actions)
    local row = HorizontalGroup:new{align = "center"}
    for index, entry in ipairs(actions) do
        row[#row + 1] = action_button(entry, item_w, height)
        if index < #actions then row[#row + 1] = HorizontalSpan:new{width = gap} end
    end
    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = row
    layered[#layered + 1] = OffsetContainer:new{
        x_off = 0, y_off = math.max(0, height - UiScale.line("thin")),
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = width, h = UiScale.line("thin")}},
    }
    return layered
end

local function category_tabs(tabs, width, height, on_more)
    tabs = tabs or {}
    if #tabs == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local gap = UiScale.dp(3, 2, 6)
    local more_w = on_more and math.max(UiScale.dp(34, 30, 50), math.floor(width * .055)) or 0
    local tabs_w = math.max(1, width - (more_w > 0 and more_w + gap or 0))
    local item_w = math.floor((tabs_w - gap * (#tabs - 1)) / #tabs)
    local visual_x = UiScale.dp(2, 2, 4)
    local visual_y = UiScale.dp(3, 2, 5)
    local row = HorizontalGroup:new{align = "center"}
    for index, tab in ipairs(tabs) do
        local label = tostring(tab.title or "")
        if tonumber(tab.count) then label = label .. " " .. tostring(tab.count) end
        local visual_w = math.max(1, item_w - visual_x * 2)
        local visual_h = math.max(1, height - visual_y * 2)
        local visual = fixed_frame(visual_w, visual_h, {
            bordersize = 0,
            padding = UiScale.dp(1, 1, 2),
            radius = UiScale.radius(7, 5, 11),
            background = tab.selected and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        }, Ui.textbox(label, math.max(1, visual_w - UiScale.dp(8, 6, 12)), visual_h,
            face("smallinfofont", 10.8, 15), {
                bold = tab.selected == true, alignment = "center", halign = "center",
                fgcolor = Blitbuffer.COLOR_BLACK,
            }))
        local item = OverlapGroup:new{dimen = Geom:new{w = item_w, h = height}, allow_mirroring = false}
        item[#item + 1] = OffsetContainer:new{x_off = visual_x, y_off = visual_y, visual}
        -- Keep the full tab hit target even though the selected visual is a
        -- compact pill. This avoids shrinking touch targets on smaller Kindles.
        row[#row + 1] = tappable(item_w, height, item, tab.on_tap)
        if index < #tabs then row[#row + 1] = HorizontalSpan:new{width = gap} end
    end
    if on_more then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = tappable(more_w, height,
            Ui.icon("grid", more_w, height, UiScale.dp(20, 17, 27), {
                face = UiScale.iconFace("cfont", 15, 21, 12),
            }), on_more)
    end
    return row
end

local function empty_section(width, height, text, callback)
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = 0,
        padding = UiScale.dp(7, 6, 12),
        background = Blitbuffer.COLOR_WHITE,
    }, Ui.textbox(tostring(text or "暂时没有内容"), math.max(1, width - 32),
        math.max(1, height - UiScale.dp(14, 12, 24)), face("smallinfofont", 11, 15), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        })), callback)
end

local HomeWidget = InputContainer:extend{
    name = "miuread_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    header_dimen = nil,
    content_dimen = nil,
    section_dimen = nil,
    _miu_closed = false,
    _quick_panel_pending = false,
}


function HomeWidget:_notify_resume_interaction(kind)
    local callback=self._miu_resume_interaction_callback
    if not callback then return end
    local now=os.clock()
    if now-(tonumber(self._miu_last_interaction_at) or 0)<.06 then return end
    self._miu_last_interaction_at=now
    local first=self._miu_resume_waiting_interaction==true
    self._miu_resume_waiting_interaction=false
    pcall(callback,first,tostring(kind or "input"))
end

function HomeWidget:handleEvent(event)
    -- ReaderUI may keep the already-built home underneath the document during
    -- page transitions. A parked home must be completely inert so its gesture
    -- ranges and child TapBoxes can never compete with the reader.
    if self._miu_input_suspended==true then return true end
    if event and event.handler=="onGesture" then
        self:_notify_resume_interaction("gesture")
        local ges=event.args and event.args[1]
        local direction=ges and ges.direction
        local gesture=ges and ges.ges
        local pos=ges and (ges.start_pos or ges.pos)
        local shelf_owned=(direction=="west" or direction=="east") and pos and self.section_dimen
            and pos.x>=self.section_dimen.x and pos.x<=self.section_dimen.x+self.section_dimen.w
            and pos.y>=self.section_dimen.y and pos.y<=self.section_dimen.y+self.section_dimen.h
        local top_owned=direction=="south" and pos and self.top_swipe_dimen
            and pos.x>=self.top_swipe_dimen.x and pos.x<=self.top_swipe_dimen.x+self.top_swipe_dimen.w
            and pos.y>=self.top_swipe_dimen.y and pos.y<=self.top_swipe_dimen.y+self.top_swipe_dimen.h
        if top_owned and (gesture == "swipe" or gesture == "pan_release")
            and self:_open_quick_panel_from_gesture(ges) then
            return true
        end
        local pointer_action=gesture=="tap" or gesture=="hold" or gesture=="hold_release"
            or gesture=="double_tap" or gesture=="two_finger_tap"

        -- Visible MiuRead controls get pointer input first. If no child consumes
        -- the pointer gesture, hand it to KOReader's configured Gesture Manager
        -- before this fullscreen page stops propagation.
        if pointer_action then
            if self:propagateEvent(event) then return true end
            if GestureBridge.dispatch(ges) then return true end
            return true
        end

        -- Configured edge/corner gestures take priority over the shelf's broad
        -- horizontal swipe area. This keeps left/right edge actions available
        -- without letting ordinary shelf swipes leak through to KOReader.
        if GestureBridge.dispatchEdge and GestureBridge.dispatchEdge(ges) then return true end
        if not shelf_owned and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self,event)
end

function HomeWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function HomeWidget:_metrics()
    local scale = UiScale.metrics()
    local sw, sh = scale.sw, scale.sh
    local portrait = scale.portrait
    local margin = math.max(UiScale.dp(7, 7, 15), math.min(UiScale.dp(12, 9, 18), math.floor(scale.short * .016)))
    local header_h = portrait
        and math.max(UiScale.dp(42, 42, 58), math.min(UiScale.dp(56, 48, 64), math.floor(sh * .052)))
        or math.max(UiScale.dp(38, 38, 52), math.min(UiScale.dp(48, 42, 56), math.floor(sh * .068)))
    local gap = math.max(UiScale.dp(4, 4, 8), math.min(UiScale.dp(7, 5, 10), math.floor(sh * .006)))
    local line = UiScale.line("thin")
    return {
        sw = sw,
        sh = sh,
        portrait = portrait,
        margin = margin,
        gap = gap,
        line = line,
        content_w = sw - margin * 2,
        header_h = header_h,
        body_y = margin + header_h + line + gap,
        body_h = sh - (margin + header_h + line + gap) - margin,
    }
end

function HomeWidget:_register_top_swipe(m)
    if not Device:isTouchDevice() then self.ges_events={}; return end
    -- Own only the true status/header strip. The previous 18–26% zone
    -- overlapped the recent-reading card and competed with KOReader gestures,
    -- which made a pull-down feel delayed on Kindle.
    local top_h = math.max(m.header_h + m.margin + m.gap, math.floor(m.sh * .10))
    top_h = math.min(math.floor(m.sh * .14), math.max(top_h, UiScale.dp(82, 72, 118)))
    self.top_swipe_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, top_h)}
    self.ges_events={
        HomeQuickPanelSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeQuickPanelPanRelease={GestureRange:new{
            ges="pan_release",
            range=function() return self.top_swipe_dimen end,
        }},
        HomeShelfSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.section_dimen or self.content_dimen end,
        }},
    }
end

function HomeWidget:_open_quick_panel_from_gesture(ges)
    local direction = ges and ges.direction
    local start = ges and (ges.start_pos or ges.pos)
    local in_top = start and self.top_swipe_dimen
        and start.x >= self.top_swipe_dimen.x and start.x <= self.top_swipe_dimen.x + self.top_swipe_dimen.w
        and start.y >= self.top_swipe_dimen.y and start.y <= self.top_swipe_dimen.y + self.top_swipe_dimen.h
    if direction == "south" and in_top and self.opts and self.opts.on_quick_panel then
        if self._quick_panel_pending then return true end
        self._quick_panel_pending=true
        -- Finish the gesture dispatch before building the panel. This avoids
        -- competing with the underlying Gesture Manager in the same event.
        UIManager:nextTick(function()
            if self._miu_closed then return end
            self._quick_panel_pending=false
            if self.opts and self.opts.on_quick_panel then self.opts.on_quick_panel() end
        end)
        return true
    end
    return false
end
function HomeWidget:onHomeQuickPanelSwipe(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end
function HomeWidget:onHomeQuickPanelPanRelease(_, ges)
    return self:_open_quick_panel_from_gesture(ges)
end

function HomeWidget:onHomeShelfSwipe(_,ges)
    if not (ges and self.opts and self.opts.on_shelf_page) then return false end
    if ges.direction=="west" then self.opts.on_shelf_page(1); return true end
    if ges.direction=="east" then self.opts.on_shelf_page(-1); return true end
    return false
end

function HomeWidget:_build_header(children, m)
    -- Match the reader toolbar: only render capabilities that really exist,
    -- and keep a visible safe inset on both ends of the status strip.
    local edge_pad=math.max(UiScale.dp(7,6,12),math.floor(m.content_w*.010))
    local header_x=m.margin+edge_pad
    local header_w=math.max(1,m.content_w-edge_pad*2)
    local gap=math.max(UiScale.dp(2,2,4),math.floor(header_w*.004))
    local has_bluetooth=self.opts.bluetooth_visible==true
    local status_count=has_bluetooth and 5 or 4 -- wifi, [bt], sync, battery, more
    local title_w=math.max(UiScale.dp(62,54,82),math.floor(header_w*.085))
    local account_w=math.max(UiScale.dp(112,96,150),math.floor(header_w*.205))
    local available=math.max(1,header_w-title_w-account_w-gap*(status_count+1))
    local status_w=math.max(1,math.floor(available/status_count))
    local last_w=math.max(1,available-status_w*(status_count-1))

    local account_text=tostring(self.opts.account_name or "")
    if account_text=="" then account_text="未登录" end
    local wifi_text=tostring(self.opts.wifi_text or "")
    if wifi_text=="" then wifi_text="Wi-Fi" end
    local bluetooth_text=tostring(self.opts.bluetooth_text or "")
    if bluetooth_text=="" then bluetooth_text="蓝牙" end
    local sync_text=tostring(self.opts.sync_text or "已同步")

    local account_cell=Ui.textbox(account_text,account_w,m.header_h,face("smallinfofont",10.8,14.8),{
        bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
    })
    local function status_text(text,width,icon_space,size)
        return Ui.textbox(text,math.max(1,width-UiScale.dp(icon_space or 22,19,31)),m.header_h,
            face("smallinfofont",size or 10.1,(size or 10.1)+4),{
                bold=true,alignment="left",halign="left",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
            })
    end
    local wifi_value_cell=status_text(wifi_text,status_w,24,10.2)
    local bluetooth_value_cell=has_bluetooth and status_text(bluetooth_text,status_w,22,9.8) or nil
    local sync_value_cell=status_text(sync_text,status_w,22,10.0)
    local battery_target_w=has_bluetooth and status_w or status_w
    local battery_value_cell=status_text(tostring(self.opts.battery_text or "--%"),battery_target_w,24,10.5)

    local header=HorizontalGroup:new{align="center"}
    header[#header+1]=LeftContainer:new{dimen=Geom:new{w=title_w,h=m.header_h},TextWidget:new{
        text=self.opts.title or "觅阅",face=face("cfont",16.8,21),bold=true,
    }}
    header[#header+1]=HorizontalSpan:new{width=gap}
    header[#header+1]=tappable(account_w,m.header_h,account_cell,self.opts.on_account)
    header[#header+1]=HorizontalSpan:new{width=gap}

    local field_x=header_x+title_w+gap+account_w+gap
    self._header_field_dimens={account=Geom:new{x=header_x+title_w+gap,y=m.margin,w=account_w,h=m.header_h}}

    local function add_status(key,width,child,callback)
        header[#header+1]=tappable(width,m.header_h,child,callback)
        self._header_field_dimens[key]=Geom:new{x=field_x,y=m.margin,w=width,h=m.header_h}
        field_x=field_x+width
        header[#header+1]=HorizontalSpan:new{width=gap}
        field_x=field_x+gap
    end

    add_status("wifi",status_w,LeftContainer:new{dimen=Geom:new{w=status_w,h=m.header_h},HorizontalGroup:new{
        align="center",Ui.icon("wifi",UiScale.dp(22,19,29),m.header_h,UiScale.dp(18,16,24),{icon_key="wifi"}),
        HorizontalSpan:new{width=UiScale.dp(2,2,4)},wifi_value_cell,
    }},self.opts.on_quick_panel)

    if has_bluetooth then
        add_status("bluetooth",status_w,LeftContainer:new{dimen=Geom:new{w=status_w,h=m.header_h},HorizontalGroup:new{
            align="center",Ui.icon("bluetooth",UiScale.dp(20,18,27),m.header_h,UiScale.dp(16,14,21),{icon_key="bluetooth"}),
            HorizontalSpan:new{width=UiScale.dp(2,1,3)},bluetooth_value_cell,
        }},self.opts.on_bluetooth or self.opts.on_quick_panel)
    end

    add_status("sync",status_w,LeftContainer:new{dimen=Geom:new{w=status_w,h=m.header_h},HorizontalGroup:new{
        align="center",Ui.icon("sync",UiScale.dp(20,18,27),m.header_h,UiScale.dp(16,14,21),{icon_key="sync"}),
        HorizontalSpan:new{width=UiScale.dp(2,1,3)},sync_value_cell,
    }},self.opts.on_sync or self.opts.on_quick_panel)

    add_status("battery",status_w,CenterContainer:new{dimen=Geom:new{w=status_w,h=m.header_h},HorizontalGroup:new{
        align="center",Ui.icon("battery",UiScale.dp(22,19,29),m.header_h,UiScale.dp(17,15,22),{icon_key="battery"}),
        HorizontalSpan:new{width=UiScale.dp(2,1,3)},battery_value_cell,
    }},nil)

    -- The final cell owns the remainder and no trailing span is painted outside
    -- the safe inset. This is what keeps “工具” away from the bezel.
    local menu_w=last_w
    header[#header+1]=tappable(menu_w,m.header_h,
        fixed_frame(menu_w,m.header_h,{bordersize=0,background=Blitbuffer.COLOR_WHITE},
            Ui.text("工具",menu_w,m.header_h,face("smallinfofont",10.8,14.8),{bold=true})),function()
        logger.info("[MiuRead][Home] tools menu tapped")
        if self.opts and self.opts.on_menu then self.opts.on_menu()
        elseif self.opts and self.opts.on_quick_panel then self.opts.on_quick_panel() end
    end)

    self._header_text_refs={
        account=account_cell[1],wifi=wifi_value_cell[1],bluetooth=bluetooth_value_cell and bluetooth_value_cell[1] or nil,
        sync=sync_value_cell[1],battery=battery_value_cell[1],
    }
    self:_add(children,header_x,m.margin,header)
    self:_add(children,m.margin,m.margin+m.header_h,LineWidget:new{
        background=Blitbuffer.COLOR_GRAY,dimen=Geom:new{w=m.content_w,h=m.line or UiScale.line("thin")},
    })
end

function HomeWidget:_grid_geometry(m, width, available_h, count, force_rows)
    local columns = 4
    -- Keep every page on the same 4×2 grid. The last page leaves empty
    -- slots instead of enlarging the remaining covers.
    local rows = force_rows or 2
    rows = math.max(1, math.min(rows, 2))
    local col_gap = math.max(UiScale.dp(2, 2, 4), math.floor(m.gap * .55))
    local row_gap = math.max(UiScale.dp(3, 2, 5), math.floor(m.gap * .65))
    if rows == 2 and math.floor((available_h - row_gap) / 2) < UiScale.dp(118, 96, 170) then rows = 1 end
    local card_w = math.max(1, math.floor((width - col_gap * (columns - 1)) / columns))
    local raw_card_h = math.max(1, math.floor((available_h - row_gap * (rows - 1)) / rows))
    local preferred_card_h = math.max(UiScale.dp(160, 132, 228), math.floor(card_w * 1.80))
    local card_h = math.min(raw_card_h, preferred_card_h)
    return columns, rows, col_gap, row_gap, card_w, card_h
end

local function shelf_book_key(book)
    if type(book) ~= "table" then return "" end
    local id = tostring(book.bookId or book.book_id or "")
    if id ~= "" then return id end
    local file = tostring(book.file or "")
    if file ~= "" then return "file:" .. file end
    return ""
end

function HomeWidget:_render_grid(children, m, x, y, width, height, books, on_open, on_hold, force_rows)
    if #books == 0 then return 0 end
    local columns, rows, col_gap, row_gap, card_w, card_h = self:_grid_geometry(m, width, height, #books, force_rows)
    local capacity = columns * rows
    local slot = 0
    for _,book in ipairs(books) do
        local folder=book and (book.local_folder==true or book.kind=="folder")
        if slot>=capacity then break end
        local row = math.floor(slot / columns)
        local col = slot % columns
        local item_w = card_w
        local item_x = x + col * (card_w + col_gap)
        local item_y = y + row * (card_h + row_gap)
        self:_add(children,item_x,item_y,shelf_book_card(book, item_w, card_h, on_open, on_hold))
        if self._building_shelf_slots and not folder then
            local key=shelf_book_key(book)
            if key~="" then
                self._building_shelf_slots[key]={
                    parent=children,index=#children,x=item_x,y=item_y,w=item_w,h=card_h,book=book,
                }
            end
        end
        slot = slot + 1
    end
    return rows * card_h + math.max(0, rows - 1) * row_gap
end

local function page_footer(width, height, page, pages, on_page)
    page = math.max(1, tonumber(page) or 1)
    pages = math.max(1, tonumber(pages) or 1)
    local arrow_w = math.max(UiScale.dp(54, 48, 88), math.floor(width * .18))
    local middle_w = math.max(1, width - arrow_w * 2)
    local row = HorizontalGroup:new{align = "center"}
    table.insert(row, text_button("‹", arrow_w, height, page > 1 and function() on_page(-1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    table.insert(row, CenterContainer:new{dimen = Geom:new{w = middle_w, h = height}, TextWidget:new{
        text = tostring(page) .. " / " .. tostring(pages),
        face = face("smallinfofont", 9, 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }})
    table.insert(row, text_button("›", arrow_w, height, page < pages and function() on_page(1) end or nil, {
        borderless = true, font = "cfont", size = 17, maximum = 21,
        fgcolor = page < pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    return row
end

local function dashboard_clock_card(width, height, time_text, date_text)
    local pad = UiScale.dp(8, 7, 13)
    local inner_w = math.max(1, width - pad * 2)
    local inner_h = math.max(1, height - pad * 2)
    local time_h = math.max(UiScale.dp(42, 36, 58), math.floor(inner_h * .62))
    local date_h = math.max(1, inner_h - time_h)
    local time_box = Ui.textbox(tostring(time_text or "--:--"), inner_w, time_h,
        face("cfont", 25, 34, 21), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        })
    local date_box = Ui.textbox(tostring(date_text or ""), inner_w, date_h,
        face("smallinfofont", 10.2, 14), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = true,
        })
    local card = fixed_frame(width, height, {
        bordersize = UiScale.line("thin"), radius = UiScale.radius(9, 6, 15),
        padding = pad, background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_GRAY,
    }, VerticalGroup:new{align = "center", time_box, date_box})
    return card, {time = time_box[1], date = date_box[1]}
end

local DASH_WEEKDAY = {"一", "二", "三", "四", "五", "六", "日"}

local function dashboard_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. "小时" .. tostring(minutes) .. "分" end
    return tostring(minutes) .. "分钟"
end

local function dashboard_short_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. "时" .. tostring(minutes) .. "分" end
    return tostring(minutes) .. "分"
end

local function dashboard_week_cells(stats, width, height)
    stats = type(stats) == "table" and stats or {}
    local rows = type(stats.daily) == "table" and stats.daily or {}
    local threshold = math.max(0, tonumber(stats.threshold) or 1)
    local gap = math.max(1, UiScale.dp(2, 1, 3))
    local cell_w = math.max(1, math.floor((width - gap * 6) / 7))
    local label_h = math.max(UiScale.dp(14, 12, 19), math.floor(height * .34))
    local mark_h = math.max(1, height - label_h)
    local mark_size = math.max(UiScale.dp(12, 10, 17), math.min(math.floor(cell_w * .64), math.floor(mark_h * .76)))
    local marks = HorizontalGroup:new{align = "center"}
    local labels = HorizontalGroup:new{align = "center"}
    for index = 1, 7 do
        local row = rows[index] or {}
        local checked = (tonumber(row.seconds) or 0) >= threshold and row.future ~= true
        local mark
        if checked then
            mark = fixed_frame(mark_size, mark_size, {
                bordersize = 0, padding = 0, radius = math.floor(mark_size / 2),
                background = Blitbuffer.COLOR_BLACK, color = Blitbuffer.COLOR_BLACK,
            }, Widget:new{dimen = Geom:new{w = 1, h = 1}})
        else
            mark = fixed_frame(mark_size, mark_size, {
                bordersize = math.max(1, UiScale.line("thick")), padding = 0, radius = math.floor(mark_size / 2),
                background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_BLACK,
            }, Widget:new{dimen = Geom:new{w = 1, h = 1}})
        end
        marks[#marks + 1] = CenterContainer:new{dimen = Geom:new{w = cell_w, h = mark_h}, mark}
        labels[#labels + 1] = Ui.textbox(DASH_WEEKDAY[index], cell_w, label_h,
            face("smallinfofont", 8.1, 10.9, 6.8), {
                bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            })
        if index < 7 then
            marks[#marks + 1] = HorizontalSpan:new{width = gap}
            labels[#labels + 1] = HorizontalSpan:new{width = gap}
        end
    end
    return VerticalGroup:new{align = "left", marks, labels}
end

local function dashboard_stats_card(title, stats, width, height, callback, expanded)
    stats = type(stats) == "table" and stats or {}
    local pad = math.max(UiScale.dp(5, 4, 8), math.floor(math.min(width, height) * .025))
    local inner_w = math.max(1, width - pad * 2)
    local inner_h = math.max(1, height - pad * 2)
    local title_h = math.max(UiScale.dp(20, 18, 28), math.floor(inner_h * .17))
    local caption_h = math.max(UiScale.dp(17, 15, 23), math.floor(inner_h * .13))
    local main_h = math.max(UiScale.dp(30, 27, 42), math.floor(inner_h * .25))
    local secondary_h = math.max(UiScale.dp(18, 16, 25), math.floor(inner_h * .15))
    local checks_h = math.max(1, inner_h - title_h - caption_h - main_h - secondary_h)

    local available = stats.available ~= false and tonumber(stats.total_seconds) ~= nil
    local main_text = available and dashboard_duration(stats.total_seconds) or "--"
    local caption = available and "本周阅读" or tostring(stats.message or "暂无阅读数据")
    local secondary = ""
    if available then
        if tostring(stats.kind or "") == "local" then
            secondary = "今日 " .. dashboard_short_duration(stats.today_seconds or 0)
            if tonumber(stats.today_pages) then secondary = secondary .. " · " .. tostring(math.floor(stats.today_pages + .5)) .. "页" end
            if expanded==true then
                if tonumber(stats.average_seconds) then secondary = secondary .. " · 日均 " .. dashboard_short_duration(stats.average_seconds) end
                if tonumber(stats.read_days) then secondary = secondary .. " · 本周 " .. tostring(math.floor(stats.read_days + .5)) .. "天" end
            end
        else
            secondary = "今日 " .. dashboard_short_duration(stats.today_seconds or 0)
            if tonumber(stats.average_seconds) then secondary = secondary .. " · 日均 " .. dashboard_short_duration(stats.average_seconds) end
            if expanded==true and tonumber(stats.read_days) then
                secondary = secondary .. " · 本周 " .. tostring(math.floor(stats.read_days + .5)) .. "天"
            end
        end
    end

    local body = VerticalGroup:new{align = "left",
        Ui.textbox(tostring(title or "阅读数据") .. " ›", inner_w, title_h,
            face("cfont", 10.5, 14.3, 8.9), {
                bold = true, alignment = "left", halign = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                height_overflow_show_ellipsis = true,
            }),
        Ui.textbox(caption, inner_w, caption_h,
            face("smallinfofont", 8.8, 11.9, 7.4), {
                bold = true, alignment = "left", halign = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                height_overflow_show_ellipsis = true,
            }),
        Ui.textbox(main_text, inner_w, main_h,
            face("cfont", 18.5, 24.5, 15.0), {
                bold = true, alignment = "left", halign = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                height_overflow_show_ellipsis = true,
            }),
        Ui.textbox(secondary, inner_w, secondary_h,
            face("smallinfofont", 8.6, 11.6, 7.2), {
                bold = true, alignment = "left", halign = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                height_overflow_show_ellipsis = true,
            }),
    }
    if available and checks_h >= UiScale.dp(25, 22, 34) then
        body[#body + 1] = dashboard_week_cells(stats, inner_w, checks_h)
    else
        body[#body + 1] = Widget:new{dimen = Geom:new{w = inner_w, h = checks_h}}
    end

    local card = fixed_frame(width, height, {
        bordersize = UiScale.line("thin"), radius = UiScale.radius(9, 6, 15),
        padding = pad, background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_GRAY,
    }, body)
    return tappable(width, height, card, callback)
end

function HomeWidget:_build_sections(children, m, compact, mode)
    local build_static = mode ~= "section"
    local build_section = mode ~= "static"
    local x, y, w, gap = m.margin, m.body_y, m.content_w, m.gap
    local bottom = m.body_y + m.body_h
    local notice = (self.opts.alerts or {})[1] or self.opts.download_notice
    if notice then
        local h = math.max(42, math.min(52, math.floor(m.body_h * .07)))
        if build_static then self:_add(children, x, y, notice_strip(notice, w, h)) end
        y = y + h + gap
    end

    local action_h = math.max(UiScale.dp(58, 54, 76), math.min(UiScale.dp(76, 64, 86), math.floor(m.body_h * .070)))
    local actions = self.opts.home_actions or {}
    local tabs_h = math.max(UiScale.dp(34, 31, 44), math.min(UiScale.dp(46, 37, 52), math.floor(m.body_h * .050)))
    local shelf_subtabs = self.opts.shelf_subtabs or {}
    -- A second shelf-level selector is used by 本地书库 only. The root row is
    -- hidden when only one view is enabled; inside a child folder one compact
    -- breadcrumb row remains so the user can go back without leaving Home.
    local subtabs_h = #shelf_subtabs > 0
        and math.max(UiScale.dp(29, 26, 39), math.min(UiScale.dp(38, 32, 45), math.floor(m.body_h * .041)))
        or 0
    local books = self.opts.shelf_books or {}
    local title = tostring(self.opts.shelf_title or "")
    local section_h = title ~= "" and math.max(UiScale.dp(22, 20, 30), math.min(UiScale.dp(29, 25, 35), math.floor(m.body_h * .031))) or 0

    if not m.portrait then
        if #actions > 0 and y + action_h < bottom then
            if build_static then self:_add(children, x, y, action_bar(actions, w, action_h)) end
            y = y + action_h + gap
        end
        local available_h = math.max(1, bottom - y)
        local hero_w = math.max(UiScale.dp(205, 180, 300), math.floor(w * .245))
        local dashboard_w = math.max(UiScale.dp(205, 180, 300), math.floor(w * .245))
        local dashboard_x = x + hero_w + gap
        local shelf_x = dashboard_x + dashboard_w + gap
        local shelf_w = math.max(1, w - hero_w - dashboard_w - gap * 2)
        if build_static then
            local shelf_sy = y + tabs_h + math.max(3, math.floor(gap * .35))
            if subtabs_h > 0 then shelf_sy = shelf_sy + subtabs_h + math.max(2, math.floor(gap * .25)) end
            if section_h > 0 then shelf_sy = shelf_sy + section_h + math.max(2, math.floor(gap * .25)) end
            local shelf_footer_h = math.max(34, math.min(44, math.floor(available_h * .10)))
            local shelf_grid_h = math.max(1, bottom - shelf_sy - shelf_footer_h)
            local _, _, _, _, shelf_card_w, shelf_card_h = self:_grid_geometry(m, shelf_w, shelf_grid_h, #books, 2)
            local shelf_cover_w, shelf_cover_h = shelf_cover_target_size(shelf_card_w, shelf_card_h, 1.0)
            if self.opts.hero then
                self:_add(children, x, y, hero_card(self.opts.hero, hero_w, available_h, self.opts.hero.on_tap, compact,
                    self.opts.on_hold_book, shelf_cover_w, shelf_cover_h))
            else
                self:_add(children, x, y, welcome_card(hero_w, available_h, self.opts.on_empty_account))
            end
            local dash_gap = math.max(UiScale.dp(3, 3, 6), math.floor(gap * .72))
            local outer_inset=home_card_outer_inset()
            local dashboard_y=y+outer_inset
            local dashboard_h=math.max(1,available_h-outer_inset*2)
            local show_weread=self.opts.show_weread_stats~=false
            local show_local=self.opts.show_local_stats~=false
            local stats_count=(show_weread and 1 or 0)+(show_local and 1 or 0)
            local clock_h
            if stats_count==0 then
                clock_h=dashboard_h
            else
                clock_h=math.max(UiScale.dp(66, 58, 90), math.floor((dashboard_h - dash_gap * 2) * .32))
            end
            local clock_card, clock_refs = dashboard_clock_card(dashboard_w, clock_h,
                self.opts.clock_text, self.opts.date_text)
            self:_add(children, dashboard_x, dashboard_y, clock_card)
            self._dashboard_text_refs={clock=clock_refs.time, date=clock_refs.date}
            self._dashboard_card_slots={}
            self._dashboard_field_dimens={
                clock=Geom:new{x=dashboard_x,y=dashboard_y,w=dashboard_w,h=clock_h},
                date=Geom:new{x=dashboard_x,y=dashboard_y,w=dashboard_w,h=clock_h},
            }
            if stats_count>0 then
                local stats_y=dashboard_y+clock_h+dash_gap
                local stats_total_h=math.max(1,dashboard_h-clock_h-dash_gap)
                if stats_count==1 then
                    local title=show_weread and "微信读书" or "本地阅读"
                    local data=show_weread and self.opts.weread_stats or self.opts.local_stats
                    local callback=show_weread and self.opts.on_weread_stats or self.opts.on_local_stats
                    local card=dashboard_stats_card(title,data,dashboard_w,stats_total_h,callback,true)
                    self:_add(children,dashboard_x,stats_y,card)
                    local slot_key=show_weread and "weread" or "local_stats"
                    self._dashboard_card_slots[slot_key]={parent=children,index=#children,x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_total_h,title=title,callback=callback,expanded=true}
                    self._dashboard_field_dimens[slot_key]=Geom:new{x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_total_h}
                else
                    local stats_h=math.max(1,math.floor((stats_total_h-dash_gap)/2))
                    local final_stats_h=math.max(1,stats_total_h-dash_gap-stats_h)
                    local weread_card=dashboard_stats_card("微信读书",self.opts.weread_stats,dashboard_w,stats_h,self.opts.on_weread_stats)
                    self:_add(children,dashboard_x,stats_y,weread_card)
                    self._dashboard_card_slots.weread={parent=children,index=#children,x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_h,title="微信读书",callback=self.opts.on_weread_stats}
                    self._dashboard_field_dimens.weread=Geom:new{x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_h}
                    local local_y=stats_y+stats_h+dash_gap
                    local local_card=dashboard_stats_card("本地阅读",self.opts.local_stats,dashboard_w,final_stats_h,self.opts.on_local_stats)
                    self:_add(children,dashboard_x,local_y,local_card)
                    self._dashboard_card_slots.local_stats={parent=children,index=#children,x=dashboard_x,y=local_y,w=dashboard_w,h=final_stats_h,title="本地阅读",callback=self.opts.on_local_stats}
                    self._dashboard_field_dimens.local_stats=Geom:new{x=dashboard_x,y=local_y,w=dashboard_w,h=final_stats_h}
                end
            end
        end
        self.section_dimen = Geom:new{x = shelf_x, y = y, w = shelf_w, h = available_h}
        if build_section then
            self:_add(children, shelf_x, y, category_tabs(self.opts.tabs, shelf_w, tabs_h, self.opts.on_shelf_all))
            local sy = y + tabs_h + math.max(3, math.floor(gap * .35))
            if subtabs_h > 0 then
                self:_add(children, shelf_x, sy, category_tabs(shelf_subtabs, shelf_w, subtabs_h, nil))
                sy = sy + subtabs_h + math.max(2, math.floor(gap * .25))
            end
            if section_h > 0 then
                self:_add(children, shelf_x, sy, section_header(title, shelf_w, section_h, self.opts.on_shelf_filter, self.opts.on_shelf_source, self.opts.shelf_filter_label))
                sy = sy + section_h + math.max(2, math.floor(gap * .25))
            end
            local footer_h = math.max(34, math.min(44, math.floor(available_h * .10)))
            local grid_h = math.max(1, bottom - sy - footer_h)
            if #books > 0 then
                self:_render_grid(children, m, shelf_x, sy, shelf_w, grid_h, books, self.opts.on_open_book, self.opts.on_hold_book, 2)
            else
                self:_add(children, shelf_x, sy, empty_section(shelf_w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
            end
            self:_add(children, shelf_x, bottom - footer_h, page_footer(shelf_w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
        end
        return
    end

    local hero_h = compact
        and math.max(UiScale.dp(238, 215, 292), math.min(UiScale.dp(315, 276, 350), math.floor(m.body_h * .26)))
        or math.max(UiScale.dp(292, 265, 350), math.min(UiScale.dp(372, 326, 410), math.floor(m.body_h * .30)))
    if y + hero_h < bottom then
        if build_static then
            local hero_w = math.max(UiScale.dp(250, 215, 350), math.floor((w - gap) * .50))
            local dashboard_x = x + hero_w + gap
            local dashboard_w = math.max(1, w - hero_w - gap)
            local shelf_y = y + hero_h + gap
            if #actions > 0 and shelf_y + action_h < bottom then shelf_y = shelf_y + action_h + gap end
            if shelf_y + tabs_h < bottom then shelf_y = shelf_y + tabs_h + math.max(3, math.floor(gap * .35)) end
            if subtabs_h > 0 and shelf_y + subtabs_h < bottom then shelf_y = shelf_y + subtabs_h + math.max(2, math.floor(gap * .25)) end
            if section_h > 0 and shelf_y + section_h < bottom then shelf_y = shelf_y + section_h + math.max(2, math.floor(gap * .25)) end
            local shelf_footer_h = math.max(36, math.min(48, math.floor(m.body_h * .045)))
            local shelf_grid_h = math.max(1, bottom - shelf_y - shelf_footer_h)
            local _, _, _, _, shelf_card_w, shelf_card_h = self:_grid_geometry(m, w, shelf_grid_h, #books, 2)
            local shelf_cover_w, shelf_cover_h = shelf_cover_target_size(shelf_card_w, shelf_card_h, 1.0)
            if self.opts.hero then
                self:_add(children, x, y, hero_card(self.opts.hero, hero_w, hero_h, self.opts.hero.on_tap, compact,
                    self.opts.on_hold_book, shelf_cover_w, shelf_cover_h))
            else
                self:_add(children, x, y, welcome_card(hero_w, hero_h, self.opts.on_empty_account))
            end

            local dash_gap = math.max(UiScale.dp(3, 3, 6), math.floor(gap * .72))
            -- beta.26: the visible dashboard uses the same top/bottom inset as
            -- the recent-reading frame, so both outer borders align exactly.
            local outer_inset=home_card_outer_inset()
            local dashboard_y=y+outer_inset
            local dashboard_h=math.max(1,hero_h-outer_inset*2)
            local show_weread=self.opts.show_weread_stats~=false
            local show_local=self.opts.show_local_stats~=false
            local stats_count=(show_weread and 1 or 0)+(show_local and 1 or 0)
            local clock_h=stats_count==0 and dashboard_h
                or math.max(UiScale.dp(68, 60, 92), math.floor((dashboard_h - dash_gap) * .29))
            local clock_card, clock_refs = dashboard_clock_card(dashboard_w, clock_h,
                self.opts.clock_text, self.opts.date_text)
            self:_add(children, dashboard_x, dashboard_y, clock_card)
            self._dashboard_text_refs={clock=clock_refs.time, date=clock_refs.date}
            self._dashboard_card_slots={}
            self._dashboard_field_dimens={
                clock=Geom:new{x=dashboard_x,y=dashboard_y,w=dashboard_w,h=clock_h},
                date=Geom:new{x=dashboard_x,y=dashboard_y,w=dashboard_w,h=clock_h},
            }
            if stats_count>0 then
                local stats_y=dashboard_y+clock_h+dash_gap
                local stats_h=math.max(1,dashboard_h-clock_h-dash_gap)
                if stats_count==1 then
                    local title=show_weread and "微信读书" or "本地阅读"
                    local data=show_weread and self.opts.weread_stats or self.opts.local_stats
                    local callback=show_weread and self.opts.on_weread_stats or self.opts.on_local_stats
                    local card=dashboard_stats_card(title,data,dashboard_w,stats_h,callback,true)
                    self:_add(children,dashboard_x,stats_y,card)
                    local slot_key=show_weread and "weread" or "local_stats"
                    self._dashboard_card_slots[slot_key]={parent=children,index=#children,x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_h,title=title,callback=callback,expanded=true}
                    self._dashboard_field_dimens[slot_key]=Geom:new{x=dashboard_x,y=stats_y,w=dashboard_w,h=stats_h}
                else
                    local pair_gap=dash_gap
                    local weread_w=math.max(1,math.floor((dashboard_w-pair_gap)/2))
                    local local_w=math.max(1,dashboard_w-pair_gap-weread_w)
                    local local_x=dashboard_x+weread_w+pair_gap
                    local weread_card=dashboard_stats_card("微信读书",self.opts.weread_stats,weread_w,stats_h,self.opts.on_weread_stats)
                    self:_add(children,dashboard_x,stats_y,weread_card)
                    self._dashboard_card_slots.weread={parent=children,index=#children,x=dashboard_x,y=stats_y,w=weread_w,h=stats_h,title="微信读书",callback=self.opts.on_weread_stats}
                    self._dashboard_field_dimens.weread=Geom:new{x=dashboard_x,y=stats_y,w=weread_w,h=stats_h}
                    local local_card=dashboard_stats_card("本地阅读",self.opts.local_stats,local_w,stats_h,self.opts.on_local_stats)
                    self:_add(children,local_x,stats_y,local_card)
                    self._dashboard_card_slots.local_stats={parent=children,index=#children,x=local_x,y=stats_y,w=local_w,h=stats_h,title="本地阅读",callback=self.opts.on_local_stats}
                    self._dashboard_field_dimens.local_stats=Geom:new{x=local_x,y=stats_y,w=local_w,h=stats_h}
                end
            end
        end
        y = y + hero_h + gap
    end
    if #actions > 0 and y + action_h < bottom then
        if build_static then self:_add(children, x, y, action_bar(actions, w, action_h)) end
        y = y + action_h + gap
    end
    self.section_dimen = Geom:new{x = x, y = y, w = w, h = math.max(1, bottom - y)}
    if not build_section then return end
    if y + tabs_h < bottom then
        self:_add(children, x, y, category_tabs(self.opts.tabs, w, tabs_h, self.opts.on_shelf_all))
        y = y + tabs_h + math.max(3, math.floor(gap * .35))
    end
    if subtabs_h > 0 and y + subtabs_h < bottom then
        self:_add(children, x, y, category_tabs(shelf_subtabs, w, subtabs_h, nil))
        y = y + subtabs_h + math.max(2, math.floor(gap * .25))
    end
    if section_h > 0 and y + section_h < bottom then
        self:_add(children, x, y, section_header(title, w, section_h, self.opts.on_shelf_filter, self.opts.on_shelf_source, self.opts.shelf_filter_label))
        y = y + section_h + math.max(2, math.floor(gap * .25))
    end
    local footer_h = math.max(36, math.min(48, math.floor(m.body_h * .045)))
    local grid_h = math.max(1, bottom - y - footer_h)
    if #books > 0 then
        self:_render_grid(children, m, x, y, w, grid_h, books, self.opts.on_open_book, self.opts.on_hold_book, 2)
    else
        self:_add(children, x, y, empty_section(w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
    end
    self:_add(children, x, bottom - footer_h, page_footer(w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
end

function HomeWidget:_section_cache_id(opts)
    opts=opts or self.opts or {}
    local key=tostring(opts.section_cache_key or "")
    local revision=tostring(opts.section_revision or "")
    if key=="" or revision=="" then return nil end
    return key.."|"..revision
end

function HomeWidget:_clear_inactive_section_cache()
    local cache=self._section_layer_cache
    if type(cache)~="table" then return end
    for _,entry in pairs(cache) do
        local layer=type(entry)=="table" and entry.layer or nil
        if layer and layer~=self._section_layer and layer.free then pcall(layer.free,layer) end
    end
    self._section_layer_cache=nil
    self._section_cache_clock=0
end

function HomeWidget:_remember_section_layer(cache_id,layer,region,slots)
    if not cache_id or not layer then return end
    self._section_layer_cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
    self._section_layer_cache[cache_id]={
        layer=layer,
        region=region and region:copy() or nil,
        slots=slots,
        used=self._section_cache_clock,
    }
    local count=0
    for _ in pairs(self._section_layer_cache) do count=count+1 end
    while count>8 do
        local oldest_id,oldest_entry
        for id,entry in pairs(self._section_layer_cache) do
            if entry.layer~=self._section_layer
                and (not oldest_entry or (tonumber(entry.used) or 0)<(tonumber(oldest_entry.used) or 0)) then
                oldest_id,oldest_entry=id,entry
            end
        end
        if not oldest_id then break end
        self._section_layer_cache[oldest_id]=nil
        if oldest_entry.layer and oldest_entry.layer.free then pcall(oldest_entry.layer.free,oldest_entry.layer) end
        count=count-1
    end
end

function HomeWidget:_rebuild()
    self:_clear_inactive_section_cache()
    UiScale.setDisplayMode(self.opts and self.opts.display_size or "standard")
    local m = self:_metrics()
    self._last_screen_w, self._last_screen_h = m.sw, m.sh
    self._last_rotation = Screen.getRotationMode and Screen:getRotationMode() or nil
    self._metrics_cache = m
    self.dimen = Geom:new{x = 0, y = 0, w = m.sw, h = m.sh}
    self.header_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, m.body_y)}
    self.content_dimen = Geom:new{x = 0, y = m.body_y, w = m.sw, h = math.max(1, m.sh - m.body_y)}
    self.section_dimen = self.content_dimen:copy()
    self:_register_top_swipe(m)
    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    children[#children + 1] = background(m.sw, m.sh)
    self:_build_header(children, m)
    local compact = tostring(self.opts.layout_style or "standard") == "compact"
    local static_body_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(static_body_layer, m, compact, "static")
    children[#children + 1] = static_body_layer
    self._static_body_layer = static_body_layer
    self._static_body_layer_index = #children
    local section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self._building_shelf_slots={}
    self:_build_sections(section_layer, m, compact, "section")
    local section_slots=self._building_shelf_slots
    self._building_shelf_slots=nil
    children[#children + 1] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    self._section_layer_index = #children
    self:_remember_section_layer(self:_section_cache_id(self.opts),section_layer,self.section_dimen,section_slots)
    local previous = self[1]
    self[1] = children
    if previous and previous ~= children and previous.free then pcall(previous.free, previous) end
end

function HomeWidget:_mark_dirty(kind, previous_region)
    local region
    if kind == "section" then region = self.section_dimen
    elseif kind == "header" then region = self.header_dimen
    elseif kind == "content" then region = self.content_dimen
    elseif kind == "page" then region = self.dimen
    else
        UIManager:setDirty(self, "full")
        return
    end
    if previous_region and region then region = previous_region:combine(region)
    else region = region or previous_region end
    if region then
        local safety=UiScale.dp(4,3,7)
        local x=math.max(0,(region.x or 0)-safety)
        local y=math.max(0,(region.y or 0)-safety)
        local right=math.min(Screen:getWidth(),(region.x or 0)+(region.w or 1)+safety)
        local bottom=math.min(Screen:getHeight(),(region.y or 0)+(region.h or 1)+safety)
        region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
        UIManager:setDirty(self, function() return kind == "section" and "full" or "ui", region end)
    else
        UIManager:setDirty(self, "full")
    end
end

function HomeWidget:update(opts, refresh_kind)
    local previous_region
    if refresh_kind == "section" and self.section_dimen then previous_region = self.section_dimen:copy()
    elseif refresh_kind == "header" and self.header_dimen then previous_region = self.header_dimen:copy()
    elseif refresh_kind == "content" and self.content_dimen then previous_region = self.content_dimen:copy()
    elseif refresh_kind == "page" and self.dimen then previous_region = self.dimen:copy() end
    self.opts = opts or self.opts or {}
    if type(self.opts.on_interaction)=="function" then
        self._miu_resume_interaction_callback=self.opts.on_interaction
    end
    self:_rebuild()
    self:_mark_dirty(refresh_kind or "full", previous_region)
    return self
end

function HomeWidget:updateHeader(fields)
    fields=type(fields)=="table" and fields or {}
    self.opts=self.opts or {}
    if fields.bluetooth_visible~=nil and (self.opts.bluetooth_visible==true)~=(fields.bluetooth_visible==true) then
        self.opts.bluetooth_visible=fields.bluetooth_visible==true
        if fields.bluetooth_text~=nil then self.opts.bluetooth_text=tostring(fields.bluetooth_text or "") end
        return self:update(self.opts,"header")
    end
    local refs=type(self._header_text_refs)=="table" and self._header_text_refs or {}
    local dimens=type(self._header_field_dimens)=="table" and self._header_field_dimens or {}
    local mapping={
        account_name={ref="account",default="未登录"},
        wifi_text={ref="wifi",default="Wi-Fi"},
        bluetooth_text={ref="bluetooth",default="蓝牙 --"},
        sync_text={ref="sync",default="已同步"},
        battery_text={ref="battery",default="--%"},
    }
    local changed_region
    local changed=false
    local fallback=false
    for key,spec in pairs(mapping) do
        if fields[key]~=nil then
            local value=tostring(fields[key] or "")
            local display=value~="" and value or spec.default
            if tostring(self.opts[key] or "")~=value then
                self.opts[key]=value
                changed=true
                local ref=refs[spec.ref]
                if ref and type(ref.setText)=="function" then
                    ref:setText(display)
                    local region=dimens[spec.ref]
                    if region then changed_region=changed_region and changed_region:combine(region) or region:copy() end
                else
                    fallback=true
                end
            end
        end
    end
    if not changed then return true end
    if fallback or not changed_region then return self:update(self.opts,"header") end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,(changed_region.x or 0)-safety)
    local y=math.max(0,(changed_region.y or 0)-safety)
    local right=math.min(Screen:getWidth(),(changed_region.x or 0)+(changed_region.w or 1)+safety)
    local bottom=math.min(Screen:getHeight(),(changed_region.y or 0)+(changed_region.h or 1)+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    return true
end

function HomeWidget:updateDashboard(fields)
    fields=type(fields)=="table" and fields or {}
    self.opts=self.opts or {}
    local refs=type(self._dashboard_text_refs)=="table" and self._dashboard_text_refs or {}
    local dimens=type(self._dashboard_field_dimens)=="table" and self._dashboard_field_dimens or {}
    local changed_region
    local changed=false
    local fallback=false

    local text_mapping={
        clock_text={ref="clock",default="--:--"},
        date_text={ref="date",default=""},
    }
    for key,spec in pairs(text_mapping) do
        if fields[key]~=nil then
            local value=tostring(fields[key] or "")
            local display=value~="" and value or spec.default
            if tostring(self.opts[key] or "")~=value then
                self.opts[key]=value
                changed=true
                local ref=refs[spec.ref]
                if ref and type(ref.setText)=="function" then
                    ref:setText(display)
                    local region=dimens[spec.ref]
                    if region then changed_region=changed_region and changed_region:combine(region) or region:copy() end
                else
                    fallback=true
                end
            end
        end
    end

    -- Statistics cards contain independent check-in cells, so updating only a
    -- TextWidget is no longer enough. Replace just the relevant card in the
    -- static layer; the recent-reading cover and shelf stay untouched.
    local slots=type(self._dashboard_card_slots)=="table" and self._dashboard_card_slots or {}
    local card_fields={weread_stats="weread",local_stats="local_stats"}
    for key,slot_key in pairs(card_fields) do
        if fields[key]~=nil then
            self.opts[key]=fields[key]
            changed=true
            local slot=slots[slot_key]
            if slot and slot.parent and slot.index and slot.w and slot.h then
                local card=dashboard_stats_card(slot.title,fields[key],slot.w,slot.h,slot.callback,slot.expanded==true)
                local old=slot.parent[slot.index]
                slot.parent[slot.index]=OffsetContainer:new{x_off=slot.x,y_off=slot.y,card}
                if old and old~=slot.parent[slot.index] and old.free then pcall(old.free,old) end
                local region=dimens[slot_key]
                if region then changed_region=changed_region and changed_region:combine(region) or region:copy() end
            else
                local visible=(slot_key=="weread" and self.opts.show_weread_stats~=false)
                    or (slot_key=="local_stats" and self.opts.show_local_stats~=false)
                if visible then fallback=true end
            end
        end
    end

    if not changed then return true end
    if fallback or not changed_region then return self:update(self.opts,"content") end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,(changed_region.x or 0)-safety)
    local y=math.max(0,(changed_region.y or 0)-safety)
    local right=math.min(Screen:getWidth(),(changed_region.x or 0)+(changed_region.w or 1)+safety)
    local bottom=math.min(Screen:getHeight(),(changed_region.y or 0)+(changed_region.h or 1)+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    return true
end

function HomeWidget:updateSection(opts)
    local started=os.clock()
    opts = opts or {}
    self.opts.tabs = opts.tabs or self.opts.tabs
    self.opts.shelf_subtabs = opts.shelf_subtabs or {}
    self.opts.shelf_title = opts.shelf_title or self.opts.shelf_title
    self.opts.shelf_books = opts.shelf_books or {}
    self.opts.empty_text = opts.empty_text or self.opts.empty_text
    self.opts.on_open_book = opts.on_open_book or self.opts.on_open_book
    self.opts.on_hold_book = opts.on_hold_book or self.opts.on_hold_book
    self.opts.home_actions = opts.home_actions or self.opts.home_actions
    if opts.on_shelf_all ~= nil then self.opts.on_shelf_all = opts.on_shelf_all end
    if opts.on_shelf_filter ~= nil then self.opts.on_shelf_filter = opts.on_shelf_filter end
    if opts.on_shelf_source ~= nil then self.opts.on_shelf_source = opts.on_shelf_source end
    if opts.shelf_filter_label ~= nil then self.opts.shelf_filter_label = opts.shelf_filter_label end
    self.opts.on_shelf_page = opts.on_shelf_page or self.opts.on_shelf_page
    self.opts.shelf_page = opts.shelf_page or self.opts.shelf_page
    self.opts.shelf_pages = opts.shelf_pages or self.opts.shelf_pages
    self.opts.section_cache_key = opts.section_cache_key or self.opts.section_cache_key
    self.opts.section_revision = opts.section_revision or self.opts.section_revision

    local m = self._metrics_cache
    local root = self[1]
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not m or not root or sw ~= self._last_screen_w or sh ~= self._last_screen_h
        or not self._section_layer_index then
        return self:update(self.opts, "section")
    end
    local previous_region = self.section_dimen and self.section_dimen:copy() or nil
    local cache_id=self:_section_cache_id(self.opts)
    local cache=type(self._section_layer_cache)=="table" and self._section_layer_cache or {}
    local cached=cache_id and cache[cache_id] or nil
    local section_layer=cached and cached.layer or nil
    local cache_hit=section_layer~=nil
    local section_slots
    if not section_layer then
        section_layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
        self._building_shelf_slots={}
        self:_build_sections(section_layer, m, tostring(self.opts.layout_style or "standard") == "compact", "section")
        section_slots=self._building_shelf_slots
        self._building_shelf_slots=nil
        self:_remember_section_layer(cache_id,section_layer,self.section_dimen,section_slots)
    else
        section_slots=cached.slots
        if cached.region then
            self.section_dimen=cached.region:copy()
            self._section_cache_clock=(tonumber(self._section_cache_clock) or 0)+1
            cached.used=self._section_cache_clock
        end
    end
    local old = root[self._section_layer_index]
    root[self._section_layer_index] = section_layer
    self._section_layer = section_layer
    self._section_book_slots=section_slots
    -- Old layers stay alive in the bounded cache. They are freed on eviction,
    -- full rebuild or home close, so switching back does not recreate covers.
    self:_mark_dirty("section", previous_region)
    logger.info("[MiuRead][HomeSwitch] layer",
        "key=",tostring(cache_id or "none"),"cache_hit=",tostring(cache_hit),
        "ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    return self
end


function HomeWidget:updateHero(hero)
    self.opts = self.opts or {}
    self.opts.hero = hero
    local m = self._metrics_cache
    local root = self[1]
    if not m or not root or not self._static_body_layer_index
        or Screen:getWidth() ~= self._last_screen_w or Screen:getHeight() ~= self._last_screen_h then
        return self:update(self.opts, "content")
    end
    local previous_region = self.content_dimen and self.content_dimen:copy() or nil
    local previous_section = self.section_dimen and self.section_dimen:copy() or nil
    local layer = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_build_sections(layer, m, tostring(self.opts.layout_style or "standard") == "compact", "static")
    local current_section = self.section_dimen and self.section_dimen:copy() or nil
    local same_geometry = previous_section and current_section
        and previous_section.x == current_section.x and previous_section.y == current_section.y
        and previous_section.w == current_section.w and previous_section.h == current_section.h
    if not same_geometry then
        if layer.free then pcall(layer.free, layer) end
        return self:update(self.opts, "content")
    end
    local old = root[self._static_body_layer_index]
    root[self._static_body_layer_index] = layer
    self._static_body_layer = layer
    if old and old ~= layer and old.free then pcall(old.free, old) end
    self:_mark_dirty("content", previous_region)
    return self
end

function HomeWidget:updateBook(book_id)
    local key=tostring(book_id or "")
    if key=="" then return false end
    local slots=type(self._section_book_slots)=="table" and self._section_book_slots or {}
    local slot=slots[key]
    if not slot or not slot.parent or not slot.index then return false end
    local book
    for _,candidate in ipairs(self.opts.shelf_books or {}) do
        if shelf_book_key(candidate)==key then book=candidate; break end
    end
    if not book then return false end
    local old=slot.parent[slot.index]
    local replacement=OffsetContainer:new{
        x_off=slot.x,y_off=slot.y,
        shelf_book_card(book,slot.w,slot.h,self.opts.on_open_book,self.opts.on_hold_book),
    }
    slot.parent[slot.index]=replacement
    slot.book=book
    if old and old~=replacement and old.free then pcall(old.free,old) end
    local safety=UiScale.dp(3,2,5)
    local x=math.max(0,slot.x-safety)
    local y=math.max(0,slot.y-safety)
    local right=math.min(Screen:getWidth(),slot.x+slot.w+safety)
    local bottom=math.min(Screen:getHeight(),slot.y+slot.h+safety)
    local region=Geom:new{x=x,y=y,w=math.max(1,right-x),h=math.max(1,bottom-y)}
    UIManager:setDirty(self,function() return "ui",region end)
    logger.info("[MiuRead][HomeBook] updated", "book=",key,"w=",tostring(slot.w),"h=",tostring(slot.h))
    return true
end

function HomeWidget:init()
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        if Device.input and Device.input.group and Device.input.group.Back then
            self.key_events.Back = {{Device.input.group.Back}}
        end
        self.key_events.Menu = {{"Menu"}}
        self.key_events.Home = {{"Home"}}
        if Device.input and Device.input.group then
            if Device.input.group.PgFwd then self.key_events.ShelfNext = {{Device.input.group.PgFwd}} end
            if Device.input.group.PgBack then self.key_events.ShelfPrevious = {{Device.input.group.PgBack}} end
        end
    end
    self:_rebuild()
end

function HomeWidget:onShelfNext()
    self:_notify_resume_interaction("page-next")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(1) end
    return true
end
function HomeWidget:onShelfPrevious()
    self:_notify_resume_interaction("page-previous")
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(-1) end
    return true
end

function HomeWidget:onMenu()
    self:_notify_resume_interaction("menu")
    logger.info("[MiuRead][Home] physical menu")
    if self.opts and self.opts.on_menu then self.opts.on_menu() end
    return true
end
function HomeWidget:onBack()
    self:_notify_resume_interaction("back")
    if self.opts and self.opts.on_back then
        local ok,handled=pcall(self.opts.on_back)
        if ok and handled==true then
            logger.info("[MiuRead][Home] back handled by current section")
            return true
        end
    end
    -- The MiuRead home is the root page. Back must not leak to FileManager.
    logger.info("[MiuRead][Home] back consumed at root")
    return true
end
function HomeWidget:onHome()
    self:_notify_resume_interaction("home")
    logger.info("[MiuRead][Home] home consumed at root")
    return true
end

function HomeWidget:onSetDimensions()
    return self:_schedule_dimension_refresh()
end
function HomeWidget:_close_rotation_transients()
    local stack = UIManager._window_stack or {}
    for index = #stack, 1, -1 do
        local widget = stack[index] and stack[index].widget or nil
        if widget and widget ~= self and widget._miuread_transient == true
            and widget.name ~= "miuread_full_shelf"
            and UIManager:isWidgetShown(widget) then
            pcall(UIManager.close, UIManager, widget)
        end
    end
end

function HomeWidget:_capture_pending_dimensions()
    self._pending_screen_w=Screen:getWidth()
    self._pending_screen_h=Screen:getHeight()
    self._pending_rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_dimension_refresh=true
    return true
end

function HomeWidget:_commit_pending_dimensions(force_rebuild)
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
    self._pending_screen_w,self._pending_screen_h=sw,sh
    self._pending_rotation=rotation
    local changed=force_rebuild==true or sw~=self._last_screen_w or sh~=self._last_screen_h
        or rotation~=self._last_rotation
    self._pending_dimension_refresh=false
    if not changed then return false end
    self:_close_rotation_transients()
    self:_clear_inactive_section_cache()
    self:_rebuild()
    return true
end

function HomeWidget:_schedule_dimension_refresh()
    self._dimension_refresh_generation = (tonumber(self._dimension_refresh_generation) or 0) + 1
    local generation = self._dimension_refresh_generation
    if self._dimension_refresh_task then
        UIManager:unschedule(self._dimension_refresh_task)
        self._dimension_refresh_task=nil
    end
    self:_capture_pending_dimensions()

    -- Parked Home and the lock-screen path must stay completely passive. The
    -- latest geometry is applied once, immediately before Home becomes active.
    if self._miu_input_suspended==true or self._miu_device_suspended==true then
        return true
    end

    local last_w,last_h,last_rotation,stable,attempts=nil,nil,nil,0,0
    local task
    task=function()
        if self._miu_closed or self._dimension_refresh_task~=task
            or generation ~= self._dimension_refresh_generation then return end
        if self._miu_input_suspended==true or self._miu_device_suspended==true then
            self._dimension_refresh_task=nil
            self:_capture_pending_dimensions()
            return
        end
        attempts=attempts+1
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
        if sw==last_w and sh==last_h and rotation==last_rotation then
            stable=stable+1
        else
            last_w,last_h,last_rotation,stable=sw,sh,rotation,0
        end
        if stable<2 and attempts<8 then
            UIManager:scheduleIn(.12,task)
            return
        end
        self._dimension_refresh_task=nil
        local changed=self:_commit_pending_dimensions(false)
        if changed then UIManager:setDirty(self,"full") end
        logger.info("[MiuRead][Rotation] home committed",
            "samples=",tostring(attempts),"changed=",tostring(changed),
            "size=",tostring(sw).."x"..tostring(sh),"rotation=",tostring(rotation))
    end
    self._dimension_refresh_task=task
    UIManager:scheduleIn(.30,task)
    return true
end
function HomeWidget:onScreenResize() return self:_schedule_dimension_refresh() end
function HomeWidget:onRotation() return self:_schedule_dimension_refresh() end

function HomeWidget:onCloseWidget()
    self._miu_closed = true
    self._dimension_refresh_generation=(tonumber(self._dimension_refresh_generation) or 0)+1
    if self._dimension_refresh_task then UIManager:unschedule(self._dimension_refresh_task); self._dimension_refresh_task=nil end
    self:_clear_inactive_section_cache()
    if live_widget == self then live_widget = nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close, self) end
end

local HomeView = {}
local function stacked_home_widgets()
    local rows = {}
    for _, window in ipairs(UIManager._window_stack or {}) do
        local widget = window and window.widget or nil
        if widget and widget.name == "miuread_home" and not widget._miu_closed then rows[#rows + 1] = widget end
    end
    return rows
end
function HomeView.prune_duplicates()
    local rows = stacked_home_widgets()
    if #rows == 0 then
        if live_widget and (live_widget._miu_closed or not UIManager:isWidgetShown(live_widget)) then live_widget = nil end
        return 0
    end
    local keep = nil
    if live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget) then keep = live_widget end
    if not keep then keep = rows[#rows]; live_widget = keep end
    local closed = 0
    for _, widget in ipairs(rows) do
        if widget ~= keep then
            widget._miu_superseded = true
            widget._miu_suppress_restore = true
            pcall(UIManager.close, UIManager, widget)
            closed = closed + 1
        end
    end
    if closed > 0 then logger.warn("[MiuRead][Home] duplicate roots removed", tostring(closed)) end
    return closed
end
function HomeView.current() return live_widget end
function HomeView.is_shown()
    HomeView.prune_duplicates()
    return live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget)
end
function HomeView.is_parked()
    return HomeView.is_shown() and live_widget._miu_input_suspended==true
end
-- Keep the rendered home in UIManager's stack while ReaderUI owns the screen.
-- This avoids briefly exposing FileManager during open/close, while disabling
-- all home input prevents the stale gesture-zone issue seen in older builds.
function HomeView.park()
    if not HomeView.is_shown() then return false end
    live_widget._miu_input_suspended=true
    live_widget._miu_resume_interaction_callback=nil
    live_widget._miu_resume_waiting_interaction=false
    return true
end
function HomeView.suspend()
    if not HomeView.is_shown() then return false end
    live_widget._miu_device_suspended=true
    live_widget._dimension_refresh_generation=(tonumber(live_widget._dimension_refresh_generation) or 0)+1
    if live_widget._dimension_refresh_task then
        UIManager:unschedule(live_widget._dimension_refresh_task)
        live_widget._dimension_refresh_task=nil
    end
    live_widget:_capture_pending_dimensions()
    return true
end
function HomeView.unpark(skip_dirty,opts)
    if not HomeView.is_shown() then return false end
    opts=type(opts)=="table" and opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(false)
    live_widget._miu_input_suspended=false
    if type(opts.on_interaction)=="function" then
        live_widget._miu_resume_interaction_callback=opts.on_interaction
        live_widget._miu_resume_waiting_interaction=true
        live_widget._miu_last_interaction_at=0
    end
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    if skip_dirty~=true then UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    elseif rebuilt then UIManager:setDirty(live_widget,"full") end
    return true
end
-- FileManager is recreated after ReaderUI closes so KOReader's docless
-- plugins (including Gesture Manager) remain alive beneath MiuRead. Move the
-- already-built home above that native base without closing/rebuilding it.
function HomeView.raise(skip_dirty)
    HomeView.prune_duplicates()
    if not HomeView.is_shown() then return false end
    local stack = UIManager._window_stack or {}
    local window, index
    for i = #stack, 1, -1 do
        if stack[i] and stack[i].widget == live_widget then
            window, index = stack[i], i
            break
        end
    end
    if not window then return false end
    table.remove(stack, index)
    local insert_at = 1
    -- Match UIManager:show ordering for a standard non-modal widget: below
    -- modal dialogs/toasts, above the uppermost normal page.
    for i = #stack, 0, -1 do
        local top = stack[i]
        if top and top.widget and top.widget.toast then
            -- Keep looking below the toast group.
        elseif not top or not top.widget or not top.widget.modal then
            insert_at = i + 1
            break
        end
    end
    table.insert(stack, insert_at, window)
    if skip_dirty~=true then UIManager:setDirty(live_widget, "ui") end
    return true
end
function HomeView.resume(opts)
    if not HomeView.is_shown() then return false end
    opts=opts or {}
    live_widget._miu_device_suspended=false
    local rebuilt=live_widget:_commit_pending_dimensions(opts.rebuild_visual==true)
    live_widget._miu_input_suspended=false
    live_widget._miu_resume_interaction_callback=opts.on_interaction
    live_widget._miu_resume_waiting_interaction=true
    live_widget._miu_last_interaction_at=0
    if live_widget._metrics_cache then live_widget:_register_top_swipe(live_widget._metrics_cache) end
    -- Resume never reorders UIManager._window_stack. If the long-sleep visual
    -- geometry is stale, rebuild this existing widget in place and repaint it.
    UIManager:setDirty(live_widget,rebuilt and "full" or "ui")
    return true
end

function HomeView.close(full_refresh)
    HomeView.prune_duplicates()
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    live_widget = nil
    if full_refresh == true then
        UIManager:scheduleIn(.04, function()
            if UIManager._exit_code == nil then UIManager:setDirty("all", "full") end
        end)
    end
end
function HomeView.refresh(kind)
    if not HomeView.is_shown() then return false end
    local ok, err = pcall(live_widget.update, live_widget, live_widget.opts or {}, kind or "content")
    if not ok then logger.warn("[MiuRead][Home] refresh failed", tostring(err)); return false end
    return true
end
function HomeView.update_header(fields)
    if not HomeView.is_shown() or not live_widget.updateHeader then return false end
    local ok, updated = pcall(live_widget.updateHeader, live_widget, fields or {})
    if not ok then logger.warn("[MiuRead][Home] header update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_time(text)
    if not HomeView.is_shown() or not live_widget.updateDashboard then return false end
    local ok, updated = pcall(live_widget.updateDashboard, live_widget, {clock_text=tostring(text or "--:--")})
    if not ok then logger.warn("[MiuRead][Home] clock update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_dashboard(fields)
    if not HomeView.is_shown() or not live_widget.updateDashboard then return false end
    local ok, updated = pcall(live_widget.updateDashboard, live_widget, fields or {})
    if not ok then logger.warn("[MiuRead][Home] dashboard update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.update_section(opts)
    if not HomeView.is_shown() or not live_widget.updateSection then return false end
    local ok, err = pcall(live_widget.updateSection, live_widget, opts or {})
    if not ok then logger.warn("[MiuRead][Home] section update failed", tostring(err)); return false end
    return true
end
function HomeView.shelf_thumbnail_size(oversample)
    if HomeView.is_shown() and live_widget then
        local slots=type(live_widget._section_book_slots)=="table" and live_widget._section_book_slots or {}
        for _,slot in pairs(slots) do
            if slot and tonumber(slot.w) and tonumber(slot.h) then
                return shelf_cover_target_size(slot.w,slot.h,oversample)
            end
        end
    end
    -- Conservative 4-column fallback used before the first shelf slots exist.
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local card_w=math.max(1,math.floor(sw/4))
    local card_h=math.max(1,math.floor(sh*.30))
    return shelf_cover_target_size(card_w,card_h,oversample)
end

function HomeView.update_book(book_id)
    if not HomeView.is_shown() or not live_widget.updateBook then return false end
    local ok, updated = pcall(live_widget.updateBook, live_widget, book_id)
    if not ok then logger.warn("[MiuRead][Home] book update failed", tostring(updated)); return false end
    return updated==true
end
function HomeView.update_hero(hero)
    if not HomeView.is_shown() or not live_widget.updateHero then return false end
    local ok, updated = pcall(live_widget.updateHero, live_widget, hero)
    if not ok then logger.warn("[MiuRead][Home] hero update failed", tostring(updated)); return false end
    return updated~=false
end
function HomeView.show(opts, refresh_kind)
    opts = opts or {}
    HomeView.prune_duplicates()
    if HomeView.is_shown() then
        local ok, err = pcall(live_widget.update, live_widget, opts, refresh_kind)
        if ok then return live_widget end
        logger.warn("[MiuRead][Home] in-place update failed", tostring(err))
    end
    if live_widget and not live_widget._miu_closed then
        live_widget._miu_superseded = true
        live_widget._miu_suppress_restore = true
        UIManager:close(live_widget)
    end
    local ok, widget = pcall(HomeWidget.new, HomeWidget, {opts = opts})
    if not ok or not widget then
        logger.err("[MiuRead][Home] build failed", tostring(widget))
        return nil, tostring(widget)
    end
    home_generation = home_generation + 1
    widget._miu_home_generation = home_generation
    widget._miu_resume_interaction_callback=opts.on_interaction
    widget._miu_resume_waiting_interaction=false
    live_widget = widget
    UIManager:show(widget, "ui", widget.dimen)
    HomeView.prune_duplicates()
    return widget
end
return HomeView
