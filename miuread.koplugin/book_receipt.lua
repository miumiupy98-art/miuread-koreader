local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local datetime = require("datetime")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")
local SQ3 = require("lua-ljsqlite3/init")
local _ = require("gettext")

local Screen = Device.screen 
local T = ffiUtil.template
local BOOK_RECEIPT_BG_SETTING = "book_receipt_screensaver_background"
local BOOK_RECEIPT_BG_IMAGE_MODE_SETTING = "book_receipt_bg_image_mode"
local BOOK_RECEIPT_CONTENT_MODE_SETTING = "book_receipt_content_mode"
local BOOK_RECEIPT_COVER_SCALE_SETTING = "book_receipt_cover_scale"

local MAX_HIGHLIGHT_SIZE = 500
local HIDE_COVER_FOR_LARGE_HIGHLIGHTS = 300
								  
local STATISTICS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local CONTENT_MODE_BOOK_RECEIPT = "book_receipt"
local CONTENT_MODE_HIGHLIGHT_PROGRESS = "highlight_progress"
local CONTENT_MODE_RANDOM = "random"

-- 缓存随机高亮索引
local cached_random_highlight_index = 1

-- ---------- 工具函数 ----------
local function utf8TrimToLength(str, max_chars)
    if not str or max_chars <= 0 then
        return "", 0, str ~= nil and str ~= ""
    end
    local len = #str
    local index = 1
    local char_count = 0
    local cut_index
    while index <= len do
        local byte = string.byte(str, index)
        if not byte then break end
        local char_len = 1
        if byte >= 0xF0 then
            char_len = 4
        elseif byte >= 0xE0 then
            char_len = 3
        elseif byte >= 0xC0 then
            char_len = 2
        end
        char_count = char_count + 1
        index = index + char_len
        if not cut_index and char_count == max_chars + 1 then
            cut_index = index - char_len
        end
    end
    if cut_index then
        return str:sub(1, cut_index - 1), char_count, true
    end
    return str, char_count, false
end

local function getLocalizedDayName(timestamp)
    local day_key = timestamp and os.date("%A", timestamp)
    if not day_key then
        return ""
    end
    if datetime and datetime.longDayTranslation and datetime.longDayTranslation[day_key] then
        return datetime.longDayTranslation[day_key]
    end
    return day_key
end

local function getBookTodayDuration(statistics)
    if not statistics then
        return nil
    end

    if statistics.isEnabled and not statistics:isEnabled() then
        return nil
    end

    if statistics.insertDB then
        pcall(statistics.insertDB, statistics)
    end

    local id_book = statistics.id_curr_book
    if (not id_book) and statistics.getIdBookDB then
        local ok, book_id = pcall(statistics.getIdBookDB, statistics)
        if ok then
            id_book = book_id
        end
    end
    if not id_book then
        return nil
    end

    if not STATISTICS_DB_PATH or STATISTICS_DB_PATH == "" then
        return nil
    end

    local attrs = lfs.attributes(STATISTICS_DB_PATH, "mode")
    if attrs ~= "file" then
        return nil
    end

    local now_stamp = os.time()
    local now_t = os.date("*t", now_stamp)
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today_time = now_stamp - from_begin_day

    local ok_conn, conn = pcall(SQ3.open, STATISTICS_DB_PATH)
    if not ok_conn or not conn then
        return nil
    end

    local sql_stmt = string.format([[SELECT sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d AND id_book = %d
            GROUP BY page
        );
    ]], start_today_time, id_book)

    local ok_row, today_duration = pcall(function()
        return conn:rowexec(sql_stmt)
    end)
    conn:close()

    if not ok_row or today_duration == nil then
        return nil
    end

    today_duration = tonumber(today_duration)
    if not today_duration then
        return nil
    end

    if today_duration < 0 then
        today_duration = 0
    end
    return today_duration
end

-- ---------- 随机高亮 ----------
local function getRandomHighlightAnnotation(ui)
    if not ui or not ui.annotation or not ui.annotation.annotations then
        return nil
    end
    local candidates = {}
    for _, item in ipairs(ui.annotation.annotations) do
        if item.drawer and item.text then
            local trimmed = util.trim(item.text)
            if trimmed ~= "" then
                table.insert(candidates, item)
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    local index = math.random(#candidates)
    while #candidates > 1 and index == cached_random_highlight_index do
        index = math.random(#candidates)
    end
    cached_random_highlight_index = index
    return candidates[index]
end

-- ---------- 背景图片相关 ----------
local function getBookReceiptBackgroundDir()
    local base_dir = DataStorage:getDataDir()
    if not base_dir or base_dir == "" then
        return nil
    end
    return string.format("%s/%s", base_dir, "book_receipt_background")
end

local function pickRandomReceiptBackgroundImage()
    local dir = getBookReceiptBackgroundDir()
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end

    local files = {}
    util.findFiles(dir, function(file)
        if not util.stringStartsWith(ffiUtil.basename(file), "._") and DocumentRegistry:isImageFile(file) then
            table.insert(files, file)
        end
    end, false, 512)

    if #files == 0 then
        return nil
    end
    return files[math.random(#files)]
end

local function buildBackgroundImageWidget(image_source)
    if not image_source then
        return nil
    end

    local mode = G_reader_settings:readSetting(BOOK_RECEIPT_BG_IMAGE_MODE_SETTING) or "stretch"
    if mode ~= "center" and mode ~= "stretch" and mode ~= "fit" then
        mode = "stretch"
    end

    local screen_size = Screen:getSize()
    local screen_w, screen_h = screen_size.w, screen_size.h
    local image_opts = {
        alpha = true,
        file_do_cache = false,
    }

    if type(image_source) == "string" then
        image_opts.file = image_source
    else
        image_opts.image = image_source
    end

    if mode == "stretch" then
        image_opts.width = screen_w
        image_opts.height = screen_h
    elseif mode == "fit" then
        image_opts.width = screen_w
        image_opts.height = screen_h
        image_opts.scale_factor = 0
    end

    local image_widget = ImageWidget:new(image_opts)

    if mode == "center" then
        return CenterContainer:new{
            dimen = screen_size,
            image_widget,
        }
    end

    return image_widget
end

local function getActiveDocumentCover(ui)
    if not ui or not ui.document or not ui.bookinfo then
        return nil
    end
    return ui.bookinfo:getCoverImage(ui.document)
end

local function getReceiptBackground(ui)
    local choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING) or "white"

    if choice == "transparent" then
        return nil, nil
    elseif choice == "black" then
        return Blitbuffer.COLOR_BLACK, nil
    elseif choice == "random_image" then
        local image_path = pickRandomReceiptBackgroundImage()
        if image_path then
            local widget = buildBackgroundImageWidget(image_path)
            if widget then
                return nil, widget
            end
        end
        return nil, nil
    elseif choice == "book_cover" then
        local cover_bb = getActiveDocumentCover(ui)
        if cover_bb then
            local widget = buildBackgroundImageWidget(cover_bb)
            if widget then
                return nil, widget
            end
        end
        return nil, nil
    end

    return Blitbuffer.COLOR_WHITE, nil
end

-- ---------- 票据式齿孔边框容器 ----------
-- 上下连续半圆齿孔，左右半圆票根缺口，右下方带第一版的轻微偏移阴影。
local ReceiptBorderContainer = WidgetContainer:extend{
    background = Blitbuffer.COLOR_WHITE,
    outside_color = Blitbuffer.COLOR_WHITE,
    color = Blitbuffer.COLOR_GRAY_3,
    shadow_color = Blitbuffer.COLOR_GRAY_7,
    shadow_offset = 4,
    bordersize = 2,
    padding = 24,
    padding_top = nil,
    padding_right = nil,
    padding_bottom = nil,
    padding_left = nil,
    stamp_radius = 7,
    stamp_spacing = 22,
    side_notch_radius = 22,
}

function ReceiptBorderContainer:getSize()
    local content_size = self[1]:getSize()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding

    local paper_w = content_size.w + self.bordersize * 2 + self._padding_left + self._padding_right
    local paper_h = content_size.h + self.bordersize * 2 + self._padding_top + self._padding_bottom
    local shadow_offset = self.shadow_offset or 0

    return Geom:new{
        w = paper_w + shadow_offset,
        h = paper_h + shadow_offset,
    }
end

function ReceiptBorderContainer:paintTo(bb, x, y)
    local my_size = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new{
            x = x, y = y,
            w = my_size.w, h = my_size.h,
        }
    else
        self.dimen.x = x
        self.dimen.y = y
        self.dimen.w = my_size.w
        self.dimen.h = my_size.h
    end

    local w, h = my_size.w, my_size.h
    local border_size = self.bordersize or 2
    local bg = self.background or Blitbuffer.COLOR_WHITE
    local outside_color = self.outside_color
    local border_color = self.color or Blitbuffer.COLOR_BLACK
    local shadow_offset = self.shadow_offset or 0
    local paper_w = w - shadow_offset
    local paper_h = h - shadow_offset
    local paper_x = x
    local paper_y = y

    -- 第一版轻微偏移阴影：只在纸张右下露出一点，不再使用大方块投影。
    if shadow_offset > 0 and self.shadow_color then
        bb:paintRect(paper_x + shadow_offset, paper_y + shadow_offset, paper_w, paper_h, self.shadow_color)
    end

    bb:paintRect(paper_x, paper_y, paper_w, paper_h, bg)
    bb:paintBorder(paper_x, paper_y, paper_w, paper_h, border_size, border_color, 0)

    local function eraseOutsideTop(cx, cy, r)
        if outside_color then
            bb:paintRect(cx - r - border_size, cy - r - border_size, (r + border_size) * 2, r + border_size, outside_color)
        end
    end

    local function eraseOutsideBottom(cx, cy, r)
        if outside_color then
            bb:paintRect(cx - r - border_size, cy + 1, (r + border_size) * 2, r + border_size + 1, outside_color)
        end
    end

    local function eraseOutsideLeft(cx, cy, r)
        if outside_color then
            bb:paintRect(cx - r - border_size, cy - r - border_size, r + border_size, (r + border_size) * 2, outside_color)
        end
    end

    local function eraseOutsideRight(cx, cy, r)
        if outside_color then
            bb:paintRect(cx + 1, cy - r - border_size, r + border_size + 1, (r + border_size) * 2, outside_color)
        end
    end

    local function paintHalfCutout(cx, cy, r, erase_outside)
        if not outside_color then
            return
        end
        bb:paintCircle(cx, cy, r, bg, r)
        bb:paintCircle(cx, cy, r, border_color, border_size)
        erase_outside(cx, cy, r)
    end

    local stamp_radius = self.stamp_radius or 7
    local stamp_spacing = self.stamp_spacing or (stamp_radius * 3)
    local usable_width = math.max(paper_w - stamp_radius * 4, 1)
    local stamp_count = math.max(1, math.floor(usable_width / stamp_spacing))
    local first_stamp_x = paper_x + math.floor((paper_w - (stamp_count - 1) * stamp_spacing) / 2)
    for i = 0, stamp_count - 1 do
        local cx = first_stamp_x + i * stamp_spacing
        paintHalfCutout(cx, paper_y, stamp_radius, eraseOutsideTop)
        paintHalfCutout(cx, paper_y + paper_h - 1, stamp_radius, eraseOutsideBottom)
    end

    local side_notch_radius = self.side_notch_radius or 22
    local side_notches = {
        paper_y + math.floor(paper_h * 0.48),
        paper_y + math.floor(paper_h * 0.72),
    }
    for _, cy in ipairs(side_notches) do
        paintHalfCutout(paper_x, cy, side_notch_radius, eraseOutsideLeft)
        paintHalfCutout(paper_x + paper_w - 1, cy, side_notch_radius, eraseOutsideRight)
    end

    if self[1] then
        self[1]:paintTo(
            bb,
            paper_x + border_size + self._padding_left,
            paper_y + border_size + self._padding_top
        )
    end
end

local function hasActiveDocument(ui)
    return ui and ui.document ~= nil
end

local function getBookReceiptFallbackType()
    local random_dir = G_reader_settings:readSetting("screensaver_dir")
    if random_dir and lfs.attributes(random_dir, "mode") == "directory" then
        return "random_image"
    end

    local document_cover = G_reader_settings:readSetting("screensaver_document_cover")
    if document_cover and lfs.attributes(document_cover, "mode") == "file" then
        return "document_cover"
    end

    local lastfile = G_reader_settings:readSetting("lastfile")
    if lastfile and lfs.attributes(lastfile, "mode") == "file" then
        return "cover"
    end

    return "random_image"
end

local function getEventFromPrefix(prefix)
    if prefix and prefix ~= "" then
        return prefix:sub(1, -2)
    end
    return nil
end

local function showFallbackScreensaver(self, orig_show)
    local fallback_type = getBookReceiptFallbackType()

    local original_type = self.screensaver_type
    local event = getEventFromPrefix(self.prefix)

    local settings = G_reader_settings
    local primary_key = "screensaver_type"
    local had_primary = settings:has(primary_key)
    local original_primary = settings:readSetting(primary_key)
    settings:saveSetting(primary_key, fallback_type)

    local prefixed_key = self.prefix and self.prefix ~= "" and (self.prefix .. "screensaver_type") or nil
    local had_prefixed, original_prefixed
    if prefixed_key then
        had_prefixed = settings:has(prefixed_key)
        original_prefixed = settings:readSetting(prefixed_key)
        settings:saveSetting(prefixed_key, fallback_type)
    end

    self:setup(event, self.event_message)
    self.screensaver_type = fallback_type
    orig_show(self)

    if prefixed_key then
        if had_prefixed then
            settings:saveSetting(prefixed_key, original_prefixed)
        else
            settings:delSetting(prefixed_key)
        end
    end

    if had_primary then
        settings:saveSetting(primary_key, original_primary)
    else
        settings:delSetting(primary_key)
    end

    self.screensaver_type = original_type
end

-- ---------- 主构建函数 ----------
local function buildReceipt(ui, state)
    if not hasActiveDocument(ui) then return nil end

    local doc_props = ui.doc_props or {}
    local book_title = doc_props.display_title or ""
    local book_author = doc_props.authors or ""
    if book_author:find("\n") then
        local authors = util.splitToArray(book_author, "\n")
        if authors and authors[1] then
            book_author = T(_("%1 等"), authors[1] .. ",")
        end
    end

    local doc_settings = ui.doc_settings and ui.doc_settings.data or {}
    local doc_page_no = (state and state.page) or 1
    local doc_page_total = doc_settings.doc_pages or 1
    if doc_page_total <= 0 then doc_page_total = 1 end
    if doc_page_no < 1 then doc_page_no = 1 end
    if doc_page_no > doc_page_total then doc_page_no = doc_page_total end

    local page_no_numeric = doc_page_no
    local page_total_numeric = doc_page_total
    local page_no_display = tostring(page_no_numeric)
    local page_total_display = tostring(page_total_numeric)

    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        local label, idx, count = ui.pagemap:getCurrentPageLabel(true)
        local last_label = ui.pagemap:getLastPageLabel(true)
        if idx and count then
            page_no_numeric = idx
            page_total_numeric = count
        end
        if label and label ~= "" then
            page_no_display = label
        else
            page_no_display = tostring(page_no_numeric)
        end
        if last_label and last_label ~= "" then
            page_total_display = last_label
        else
            page_total_display = tostring(page_total_numeric)
        end
    end

    local page_left = math.max(page_total_numeric - page_no_numeric, 0)
    local toc = ui.toc
    local chapter_title = ""
    local chapter_total = page_total_numeric
    local chapter_left = 0
    local chapter_done = 0
    if toc then
        chapter_title = toc:getTocTitleByPage(doc_page_no) or ""
        chapter_total = toc:getChapterPageCount(doc_page_no) or chapter_total
        chapter_left = toc:getChapterPagesLeft(doc_page_no) or 0
        chapter_done = toc:getChapterPagesDone(doc_page_no) or 0
    end
    chapter_total = chapter_total > 0 and chapter_total or page_total_numeric
    chapter_done = math.max(chapter_done + 1, 1)

    local statistics = ui.statistics
    local avg_time_per_page = statistics and statistics.avg_time
    local function secs_to_timestring(secs)
        if not secs then return _("计算时间中") end
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local htext = (h == 1) and _("小时") or _("小时")
        local mtext = (m == 1) and _("分钟") or _("分钟")
        if h == 0 and m > 0 then
            return string.format(_("%i %s"), m, mtext)
        elseif h > 0 and m == 0 then
            return string.format(_("%i %s"), h, htext)
        elseif h > 0 and m > 0 then
            return string.format(_("%i %s %i %s"), h, htext, m, mtext)
        elseif h == 0 and m == 0 then
            return _("不到一分钟")
        end
        return _("计算时间中")
    end
    local function time_left(pages)
        if not avg_time_per_page then return nil end
        return avg_time_per_page * pages
    end

    local book_time_left = secs_to_timestring(time_left(page_left))
    local chapter_time_left = secs_to_timestring(time_left(chapter_left))

    local current_time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""

    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
        battery = batt_prefix .. batt_lvl .. "%"
    end

    -- ====== 尺寸适度放大 ======
    local widget_width = Screen:getWidth() * 0.75
    local db_font_color = Blitbuffer.COLOR_BLACK
    local db_font_color_lighter = Blitbuffer.COLOR_GRAY_3
    local db_font_color_lightest = Blitbuffer.COLOR_GRAY_9
    local db_font_face = "NotoSans-Regular.ttf"
    local db_font_face_italics = "NotoSans-Italic.ttf"
    -- 书名使用衬线字体，更优雅
    local db_font_face_serif = "NotoSerif-Regular.ttf"
    local db_font_size_big = 28
    local db_font_size_mid = 20
    local db_font_size_small = 16
    local db_padding = 24
    local db_padding_internal = 8
    -- ============================

    -- ====== 日期 ======
    local now_time = os.time()
    local date_str = os.date(_("%Y年%m月%d日"), now_time)
    local year_month_str = os.date("%Y.%m", now_time)
    local day_str = os.date("%d", now_time)
    local weekday_str = getLocalizedDayName(now_time)
    -- =================

    local message_text
    if Device.screen_saver_mode and G_reader_settings:isTrue("screensaver_show_message") then
        local configured_message = G_reader_settings:readSetting("screensaver_message")
        configured_message = configured_message and util.trim(configured_message)
        if configured_message and configured_message ~= "" then
            if ui and ui.bookinfo and ui.bookinfo.expandString then
                message_text = ui.bookinfo:expandString(configured_message) or configured_message
            else
                message_text = configured_message
            end
            if message_text then
                message_text = util.trim(message_text)
                if message_text == "" then
                    message_text = nil
                end
            end
        end
    end

    -- ---------- databox 函数 ----------
    local function databox(typename, itemname, pages_done, pages_total, time_left_text, pages_done_display, pages_total_display, options)
        options = options or {}
        local pages_done_num = tonumber(pages_done) or 0
        local pages_total_num = tonumber(pages_total) or 0
        local denom = pages_total_num > 0 and pages_total_num or 1
        local percentage_value = math.max(math.min(pages_done_num / denom, 1), 0)
        local display_done = pages_done_display or pages_done
        local display_total = pages_total_display or pages_total

        local elements = {}

        -- 【修改】统一使用 TextBoxWidget 显示标题，与章节名保持一致
        if not options.hide_title then
            table.insert(elements, TextBoxWidget:new{
                text = typename,
                face = Font:getFace(db_font_face, db_font_size_mid),
                width = widget_width,
                fgcolor = db_font_color,
                alignment = "left",
            })
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
        end

        -- itemname 可以隐藏（书籍进度不显示书名）
        if not options.hide_itemname then
            table.insert(elements, TextBoxWidget:new{
                face = Font:getFace(db_font_face, db_font_size_mid),
                text = itemname,
                width = widget_width,
                fgcolor = db_font_color,
                alignment = "left",
            })
        end

        local progressbarwidth = widget_width
        local progress_bar = ProgressWidget:new{
            width = progressbarwidth,
            height = Screen:scaleBySize(5),
            percentage = percentage_value,
            margin_v = 0,
            margin_h = 0,
            radius = 20,
            bordersize = 0,
            bgcolor = db_font_color_lightest,
            fillcolor = db_font_color,
        }

        local page_progress = TextWidget:new{
            text = string.format(_("第%s页/共%s页"), display_done, display_total),
            face = Font:getFace("cfont", db_font_size_small),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "left",
        }

        local percentage_display = TextWidget:new{
            text = string.format(_("%i%%"), math.floor(percentage_value * 100 + 0.5)),
            face = Font:getFace("cfont", db_font_size_small),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "right",
        }

        table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
        table.insert(elements, VerticalGroup:new{
            progress_bar,
            HorizontalGroup:new{
                page_progress,
                HorizontalSpan:new{ width = progressbarwidth - page_progress:getSize().w - percentage_display:getSize().w },
                percentage_display,
            },
        })

        if not options.hide_time and time_left_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = string.format(_("剩余时间：%s"), time_left_text),
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        if options.total_time_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = options.total_time_text,
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        if options.today_time_text then
            table.insert(elements, VerticalSpan:new{ width = db_padding_internal })
            table.insert(elements, TextWidget:new{
                text = options.today_time_text,
                face = Font:getFace(db_font_face_italics, db_font_size_small),
                bold = false,
                fgcolor = db_font_color,
                padding = 0,
                align = "right",
            })
        end

        table.insert(elements, VerticalSpan:new{ width = db_padding_internal })

        return VerticalGroup:new(elements)
    end

    -- ---------- 底部状态栏（电量左、日期中、时间右） ----------
    local batt_pct_box = TextWidget:new{
        text = "⚡ " .. battery,
        face = Font:getFace("cfont", db_font_size_small),
        bold = false,
        fgcolor = db_font_color,
        padding = 0,
    }

    local date_box = TextWidget:new{
        text = date_str,
        face = Font:getFace("cfont", db_font_size_small),
        bold = false,
        fgcolor = db_font_color_lighter,
        padding = 0,
        align = "center",
    }

    local time_box = TextWidget:new{
        text = "🕐 " .. current_time,
        face = Font:getFace("cfont", db_font_size_small),
        bold = false,
        fgcolor = db_font_color,
        padding = 0,
    }

    -- 计算各元素宽度，让日期居中，电量靠左，时间靠右
    local batt_w = batt_pct_box:getSize().w
    local date_w = date_box:getSize().w
    local time_w = time_box:getSize().w
    -- 中间空白 = 总宽度 - 三个元素的宽度，然后分成两半
    local space = (widget_width - batt_w - date_w - time_w) / 2
    if space < 0 then space = 0 end  -- 防止负数

    local bottom_bar = HorizontalGroup:new{
        batt_pct_box,
        HorizontalSpan:new{ width = space },
        date_box,
        HorizontalSpan:new{ width = space },
        time_box,
    }

    -- 无标注时顶部已经显示大日期，底部状态栏不再重复显示日期。
    local space_no_date = widget_width - batt_w - time_w
    if space_no_date < 0 then space_no_date = 0 end
    local bottom_bar_no_date = HorizontalGroup:new{
        batt_pct_box,
        HorizontalSpan:new{ width = space_no_date },
        time_box,
    }

    -- ---------- 书籍统计信息 ----------
    local bookboxtitle = string.format("%s - %s", book_title, book_author)
    local content_mode_setting = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT
    local content_mode = content_mode_setting
    if content_mode_setting == CONTENT_MODE_RANDOM then
        local candidates = { CONTENT_MODE_BOOK_RECEIPT, CONTENT_MODE_HIGHLIGHT_PROGRESS }
        content_mode = candidates[math.random(#candidates)]
    end
    local book_total_time_text
    local book_today_time_text
    if statistics and content_mode ~= CONTENT_MODE_HIGHLIGHT_PROGRESS then
        book_total_time_text = string.format(_("总阅读时间：%s"), secs_to_timestring(statistics.book_read_time))
        local today_duration = getBookTodayDuration(statistics)
        if today_duration then
            local day_label = getLocalizedDayName(os.time())
            book_today_time_text = string.format(_("今日阅读时间（%s）：%s"), day_label, secs_to_timestring(today_duration))
        end
    end

    -- ---------- 书名（左右各一条横线，用 LineWidget） ----------
    -- 创建书名文本
    local title_text_widget = TextWidget:new{
        text = book_title,
        face = Font:getFace(db_font_face_serif, db_font_size_big),
        bold = true,
        fgcolor = db_font_color,
        padding = 0,
        align = "center",
    }
    local title_text_width = title_text_widget:getSize().w

    -- 计算左右横线的宽度：总宽度 - 书名宽度 - 两边间距（各留db_padding_internal*2）
    local side_width = (widget_width - title_text_width - 2 * db_padding_internal) / 2
    if side_width < 10 then side_width = 10 end
    local line_height = 2  -- 横线高度2px

    -- 左侧横线
    local line_left = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY_5,
        dimen = Geom:new{ w = side_width, h = line_height },
    }
    -- 右侧横线
    local line_right = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY_5,
        dimen = Geom:new{ w = side_width, h = line_height },
    }

    local title_widget = HorizontalGroup:new{
        align = "center",  -- 垂直居中
        line_left,
        HorizontalSpan:new{ width = db_padding_internal },
        title_text_widget,
        HorizontalSpan:new{ width = db_padding_internal },
        line_right,
    }

    -- ---------- 书籍进度条（标题“书籍进度”，隐藏书名） ----------
    local bookbox = databox(_("书籍进度"), bookboxtitle, page_no_numeric, page_total_numeric, book_time_left, page_no_display, page_total_display, {
        hide_title = false,
        hide_itemname = true,
        hide_time = false,
        total_time_text = book_total_time_text,
        today_time_text = book_today_time_text,
    })

    -- ---------- 章节进度条（保留章节名，隐藏“章节”标题） ----------
    local chapterbox = databox(_("章节"), chapter_title, chapter_done, chapter_total, chapter_time_left, nil, nil, {
        hide_title = true,
        hide_itemname = false,
        hide_time = false,
    })

    -- ---------- 封面 ----------
    local bg_choice = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING)
    local show_cover = not (Device.screen_saver_mode and bg_choice == "book_cover")
    local cover_widget
    local cover_display_width = 0
    local cover_display_height = 0

    if show_cover and ui.bookinfo and ui.document then
        local cover_bb = ui.bookinfo:getCoverImage(ui.document)
        if cover_bb then
            local cover_scale = G_reader_settings:readSetting(BOOK_RECEIPT_COVER_SCALE_SETTING) or 1
            local orig_cover_width = cover_bb:getWidth()
            local orig_cover_height = cover_bb:getHeight()
            local max_cover_width = math.floor(widget_width * 0.55 * cover_scale)
            local max_cover_height = math.floor(Screen:getHeight() / 3 * cover_scale)
            local scale = math.min(1, max_cover_width / orig_cover_width, max_cover_height / orig_cover_height)
            if scale < 1 then
                cover_display_width = math.max(1, math.floor(orig_cover_width * scale))
                cover_display_height = math.max(1, math.floor(orig_cover_height * scale))
                cover_bb = RenderImage:scaleBlitBuffer(cover_bb, cover_display_width, cover_display_height, true)
            else
                cover_display_width = orig_cover_width
                cover_display_height = orig_cover_height
            end
            cover_widget = ImageWidget:new{
                image = cover_bb,
                width = cover_display_width,
                height = cover_display_height,
            }
        end
    end

    -- ---------- 大日期组件：无标注时显示 ----------
    local function buildLargeDateWidget(target_width, target_height)
        target_width = math.max(1, math.floor(target_width or widget_width))
        target_height = math.max(1, math.floor(target_height or Screen:getHeight() / 4))

        local small_font_size = math.min(28, db_font_size_small * 1.8)
        small_font_size = math.max(20, small_font_size)
        local other_height = small_font_size * 2 + 6
        local avail = target_height - other_height
        local day_font_size = math.max(42, math.min(120, avail * 1.1))

        local year_month_widget = TextWidget:new{
            text = year_month_str,
            face = Font:getFace("cfont", small_font_size),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "right",
        }

        local day_widget = TextWidget:new{
            text = day_str,
            face = Font:getFace("cfont", day_font_size),
            bold = true,
            fgcolor = db_font_color,
            padding = 0,
            align = "right",
        }

        local weekday_widget = TextWidget:new{
            text = weekday_str,
            face = Font:getFace("cfont", small_font_size),
            bold = false,
            fgcolor = db_font_color_lighter,
            padding = 0,
            align = "right",
        }

        local date_vgroup = VerticalGroup:new{
            year_month_widget,
            VerticalSpan:new{ width = 2 },
            day_widget,
            VerticalSpan:new{ width = 2 },
            weekday_widget,
        }

        return CenterContainer:new{
            dimen = Geom:new{ w = target_width, h = target_height },
            date_vgroup,
        }
    end

    -- ---------- 高亮内容（带竖线装饰） ----------
    -- 【修改】当背景为"book_cover"时，不显示高亮
    local highlight_widget = nil
    local has_highlight = false
    if bg_choice ~= "book_cover" then
        local highlight_item = getRandomHighlightAnnotation(ui)
        if highlight_item then
            local highlight_text = util.trim(highlight_item.text or "")
            if highlight_text ~= "" then
                local truncated_text, char_count, was_truncated = utf8TrimToLength(highlight_text, MAX_HIGHLIGHT_SIZE)
                if was_truncated then
                    truncated_text = truncated_text .. "..."
                end

                local highlight_max_width = widget_width - cover_display_width - db_padding_internal * 2
                if highlight_max_width < 50 then
                    highlight_max_width = widget_width * 0.6
                end

                local highlight_height = cover_display_height > 0 and cover_display_height or Screen:getHeight() / 4
                local highlight_text_widget = TextBoxWidget:new{
                    text = truncated_text,
                    face = Font:getFace(db_font_face_italics, db_font_size_mid + 2),
                    width = highlight_max_width - 20,
                    fgcolor = db_font_color,
                    bold = false,
                    alignment = "left",
                    height = highlight_height,
                    height_adjust = true,
                    justified = false,
                }

                local text_size = highlight_text_widget:getSize()
                local line_height = text_size and text_size.h or (db_font_size_mid + 2) * 1.5

                local accent_line = LineWidget:new{
                    background = Blitbuffer.COLOR_GRAY_5,
                    dimen = Geom:new{
                        w = Screen:scaleBySize(2),
                        h = line_height,
                    },
                }

                highlight_widget = HorizontalGroup:new{
                    align = "top",
                    accent_line,
                    HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                    highlight_text_widget,
                }
                has_highlight = true
            end
        end
    end

    -- ---------- 构建内容 ----------
    local content_children = {}
    local has_top_content = false

    -- 1. 顶部：有标注显示标注；无标注显示大日期。
    if has_highlight then
        if cover_widget and show_cover then
            local top_row = HorizontalGroup:new{
                cover_widget,
                HorizontalSpan:new{ width = db_padding_internal },
                highlight_widget,
            }
            table.insert(content_children, top_row)
        else
            table.insert(content_children, highlight_widget)
        end
        has_top_content = true
    else
        if bg_choice ~= "book_cover" then
            local large_date_widget
            if cover_widget and show_cover then
                local remaining_width = widget_width - cover_display_width - db_padding_internal
                if remaining_width < 80 then
                    remaining_width = widget_width * 0.45
                end
                large_date_widget = buildLargeDateWidget(remaining_width, cover_display_height)
                table.insert(content_children, HorizontalGroup:new{
                    cover_widget,
                    HorizontalSpan:new{ width = db_padding_internal },
                    large_date_widget,
                })
            else
                large_date_widget = buildLargeDateWidget(widget_width, Screen:getHeight() / 4)
                table.insert(content_children, large_date_widget)
            end
            has_top_content = true
        end
    end
    if has_top_content then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    end

    -- 2. 书名（左右横线，无菱形）
    table.insert(content_children, title_widget)
    table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })

    -- 3. 章节进度条（不显示“章节”标题，保留章节名）
    table.insert(content_children, chapterbox)
    table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })

    -- 4. 书籍进度条（标题“书籍进度”，不显示书名）
    table.insert(content_children, bookbox)

    -- 5. 自定义消息
    if message_text then
        table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
        table.insert(content_children, VerticalGroup:new{
            TextBoxWidget:new{
                face = Font:getFace(db_font_face, db_font_size_mid),
                text = message_text,
                width = widget_width,
                fgcolor = db_font_color,
                bold = true,
                alignment = "center",
            },
            VerticalSpan:new{ width = db_padding_internal },
        })
    end

    -- 6. 底部状态栏：有标注或封面背景时把日期放到底部；无标注大日期模式下避免重复日期。
    table.insert(content_children, VerticalSpan:new{ width = db_padding_internal })
    table.insert(content_children, (has_highlight or bg_choice == "book_cover") and bottom_bar or bottom_bar_no_date)

    -- 白色/透明背景保留票据齿孔；黑色/图片/封面背景彻底改用普通方框。
    local use_ticket_border = bg_choice == "white" or bg_choice == "transparent" or not bg_choice
    local final_frame
    if use_ticket_border then
        final_frame = ReceiptBorderContainer:new{
            bordersize = 2,
            padding_top = math.floor(db_padding / 2),
            padding_right = db_padding,
            padding_bottom = db_padding,
            padding_left = db_padding,
            background = Blitbuffer.COLOR_WHITE,
            outside_color = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_GRAY_3,
            shadow_color = Blitbuffer.COLOR_GRAY_7,
            shadow_offset = Screen:scaleBySize(2),
            stamp_radius = 7,
            stamp_spacing = 22,
            side_notch_radius = 22,
            VerticalGroup:new(content_children),
        }
    else
        final_frame = FrameContainer:new{
            radius = 0,
            bordersize = 2,
            padding_top = math.floor(db_padding / 2),
            padding_right = db_padding,
            padding_bottom = db_padding,
            padding_left = db_padding,
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_GRAY_3,
            VerticalGroup:new(content_children),
        }
    end

    return CenterContainer:new{
        dimen = Screen:getSize(),
        final_frame,
    }
end

-- ---------- 快捷查看控件 ----------
local quicklookbox = InputContainer:extend{  
    modal = true,  
    name = "quick_look_box",  
    covers_fullscreen = true,
}  

function quicklookbox:init()
    local receipt_widget = buildReceipt(self.ui, self.state)
    if receipt_widget then
        self[1] = receipt_widget
    else
        self[1] = CenterContainer:new{
            dimen = Screen:getSize(),
            TextWidget:new{
                text = _("无法获取收据"),
                face = Font:getFace("cfont", 20),
            },
        }
    end

    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function() return self.dimen end,
            }
        }
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            }
        }
        self.ges_events.MultiSwipe = {
            GestureRange:new{
                ges = "multiswipe",
                range = function() return self.dimen end,
            }
        }
    end
end

function quicklookbox:onTap()
    UIManager:close(self)
end

function quicklookbox:onSwipe(arg, ges_ev)
    if ges_ev.direction == "south" then
        self:onClose()
    elseif ges_ev.direction == "east" or ges_ev.direction == "west" or ges_ev.direction == "north" then
        self:onClose()
    else
        self:onClose()
    end
end

function quicklookbox:onClose()
    UIManager:close(self)
    return true
end

quicklookbox.onAnyKeyPressed = quicklookbox.onClose
quicklookbox.onMultiSwipe = quicklookbox.onClose

-- ---------- Dispatcher 注册 ----------
Dispatcher:registerAction("quicklookbox_action", {
    category = "none",
    event = "QuickLook",
    title = _("书籍收据"),
    reader = true,
})

function ReaderUI:onQuickLook()
    local ui = self
    UIManager:nextTick(function()
        if not ui then return end
        local widget = quicklookbox:new{
            ui = ui,
            document = ui.document,
            state = ui.view and ui.view.state,
        }
        UIManager:show(widget)
    end)
end

-- ---------- 屏保集成 ----------
local Screensaver = require("ui/screensaver")
local orig_screensaver_show = Screensaver.show

Screensaver.show = function(self)
    if self.screensaver_type ~= "book_receipt" then
        return orig_screensaver_show(self)
    end

    local ui = self.ui or ReaderUI.instance
    if not hasActiveDocument(ui) then
        showFallbackScreensaver(self, orig_screensaver_show)
        return
    end

    if self.screensaver_widget then
        UIManager:close(self.screensaver_widget)
        self.screensaver_widget = nil
    end

    Device.screen_saver_mode = true

    local rotation_mode = Screen:getRotationMode()
    Device.orig_rotation_mode = rotation_mode
    if bit.band(rotation_mode, 1) == 1 then
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end

    local state = ui and ui.view and ui.view.state
    local receipt_widget = buildReceipt(ui, state)

    if receipt_widget then
        local background_color, background_widget = getReceiptBackground(ui)
        local widget_to_show = receipt_widget

        if background_widget then
            widget_to_show = OverlapGroup:new{
                dimen = Screen:getSize(),
                background_widget,
                receipt_widget,
            }
        end

        self.screensaver_widget = ScreenSaverWidget:new{
            widget = widget_to_show,
            background = background_color,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
    else
        logger.warn("Book receipt: failed to build widget, falling back to default screensaver")
        showFallbackScreensaver(self, orig_screensaver_show)
    end
end

-- ---------- 屏保菜单选项 ----------
local orig_dofile = dofile

_G.dofile = function(filepath)
    local result = orig_dofile(filepath)

    if filepath and filepath:match("screensaver_menu%.lua$") then
        if result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table

            local function genMenuItem(text, setting, value, enabled_func, separator)
                return {
                    text = text,
                    enabled_func = enabled_func,
                    checked_func = function()
                        return G_reader_settings:readSetting(setting) == value
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(setting, value)
                    end,
                    radio = true,
                    separator = separator,
                }
            end

            local function isBookReceiptEnabled()
                return G_reader_settings:readSetting("screensaver_type") == "book_receipt"
            end

            table.insert(wallpaper_submenu, 6,
                genMenuItem(_("在休眠屏显示书籍收据"), "screensaver_type", "book_receipt")
            )

            local background_menu = {
                text = _("背景"),
                sub_item_table = {
                    genMenuItem(_("白色填充"), BOOK_RECEIPT_BG_SETTING, "white"),
                    genMenuItem(_("透明"), BOOK_RECEIPT_BG_SETTING, "transparent"),
                    genMenuItem(_("黑色填充"), BOOK_RECEIPT_BG_SETTING, "black"),
                    genMenuItem(_("随机图片"), BOOK_RECEIPT_BG_SETTING, "random_image"),
                    genMenuItem(_("书籍封面"), BOOK_RECEIPT_BG_SETTING, "book_cover"),
                    {
                        text = _("背景图片放置方式"),
                        enabled_func = function()
                            local value = G_reader_settings:readSetting(BOOK_RECEIPT_BG_SETTING)
                            return value == "random_image" or value == "book_cover"
                        end,
                        sub_item_table = {
                            genMenuItem(_("适应屏幕"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "fit"),
                            genMenuItem(_("拉伸至屏幕"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "stretch"),
                            genMenuItem(_("居中不缩放"), BOOK_RECEIPT_BG_IMAGE_MODE_SETTING, "center"),
                        },
                    },
                },
            }

            local function isContentMode(value)
                local current = G_reader_settings:readSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING) or CONTENT_MODE_BOOK_RECEIPT
                return current == value
            end

            local content_menu = {
                text = _("内容"),
                sub_item_table = {
                    {
                        text = _("书籍收据（默认）"),
                        checked_func = function() return isContentMode(CONTENT_MODE_BOOK_RECEIPT) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_BOOK_RECEIPT)
                        end,
                        radio = true,
                    },
                    {
                        text = _("高亮 + 进度"),
                        checked_func = function() return isContentMode(CONTENT_MODE_HIGHLIGHT_PROGRESS) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_HIGHLIGHT_PROGRESS)
                        end,
                        radio = true,
                    },
                    {
                        text = _("随机"),
                        checked_func = function() return isContentMode(CONTENT_MODE_RANDOM) end,
                        callback = function()
                            G_reader_settings:saveSetting(BOOK_RECEIPT_CONTENT_MODE_SETTING, CONTENT_MODE_RANDOM)
                        end,
                        radio = true,
                    },
                    {
                        text = _("封面缩放"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local current_value = G_reader_settings:readSetting(BOOK_RECEIPT_COVER_SCALE_SETTING) or 1
                            local input_dialog
                            input_dialog = InputDialog:new{
                                title = _("封面缩放（默认：1.0）\n设为0隐藏封面"),
                                input = tostring(current_value),
                                input_type = "number",
                                buttons = {
                                    {
                                        {
                                            text = _("取消"),
                                            id = "close",
                                            callback = function()
                                                UIManager:close(input_dialog)
                                            end,
                                        },
                                        {
                                            text = _("设置"),
                                            is_enter_default = true,
                                            callback = function()
                                                local input_text = input_dialog:getInputText()
                                                input_text = input_text:gsub(",", ".")
                                                local new_value = tonumber(input_text)
                                                if new_value and new_value >= 0 then
                                                    G_reader_settings:saveSetting(BOOK_RECEIPT_COVER_SCALE_SETTING, new_value)
                                                    UIManager:close(input_dialog)
                                                end
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(input_dialog)
                            input_dialog:onShowKeyboard()
                        end,
                    },
                },
            }

            table.insert(wallpaper_submenu, 7, {
                text = _("书籍收据设置"),
                enabled_func = isBookReceiptEnabled,
                sub_item_table = {
                    background_menu,
                    content_menu,
                },
            })
        end
    end

    return result
end
