--[[--
渲染主流程：renderBB（离屏画布 → RGB32 BlitBuffer）与 render（写 PNG 落盘）。

渲染管线：
  BlitBuffer（RGB32）+ RenderText 离屏绘制，写 PNG 落盘。
  文字用 RenderText:renderUtf8Text（colorblitFrom 染色），
  不依赖 Screen:isColorEnabled，灰度 e-ink 上导出的卡片也是彩色 PNG。
  不上屏，预览由调用方用 ImageWidget 显示（file=path）。

@module koplugin.miuread.book_excerpt_card.render
--]]--

local Config = require("miuread.book_excerpt_card.config")
local Templates = require("miuread.book_excerpt_card.templates")
local Device = require("miuread.book_excerpt_card.device")
local Fonts = require("miuread.book_excerpt_card.fonts")
local Text = require("miuread.book_excerpt_card.text")
local Draw = require("miuread.book_excerpt_card.draw")
local Vertical = require("miuread.book_excerpt_card.vertical")
local Assets = require("miuread.book_excerpt_card.assets")
local Runes = require("miuread.book_excerpt_card.runes")
local BlitBuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderText = require("ui/rendertext")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")

-- 别名:renderBB 实现主体
local DESIGN_WIDTH_PT = Config.DESIGN_WIDTH_PT
local RENDER_SCALE = Config.RENDER_SCALE
local ds = Config.ds
local wrapText = Text.wrapText
local wrapHeight = Text.wrapHeight
local renderLines = Text.renderLines
local formatDateSlash = Text.formatDateSlash
local footerBrandText = Device.footerBrandText
local safeGetFace = Fonts.safeGetFace
local getReaderFont = Fonts.getReaderFont
local hexToColor = Draw.hexToColor
local mixColor = Draw.mixColor
local drawVGradient = Draw.drawVGradient
local drawVGradientDiag = Draw.drawVGradientDiag
local drawQR = Draw.drawQR
local drawOrnateDivider = Draw.drawOrnateDivider
local verticalTitleHeight = Vertical.verticalTitleHeight
local renderVerticalTitle = Vertical.renderVerticalTitle
local drawLineImage = Assets.drawLineImage
local getStillnessHeadBB = Assets.getStillnessHeadBB

-- 正式保存的自增序号（防同秒覆盖；预览固定文件名不走此路径）
local save_seq = 0

-- ---------------------------------------------------------------------------
-- 渲染
-- ---------------------------------------------------------------------------

--- 渲染书摘卡片 PNG。
-- @param opts table:
--   text         选中文字（必填）
--   book_title   书名
--   book_author  作者
--   date_str     日期字符串（默认今天）
--   template_idx 模板下标（1=经典 2=墨白）
--   color_idx    配色下标（1-10）
--   font_face    书籍字体族名（CRE cre_font，如 LXGW WenKai；内部解析成文件）
--   qr_url       二维码 URL（可选；提供则印入页脚右侧）
--   out_dir      输出目录（默认 <data>/miuread/cards，可覆盖）
-- @return bb, dimen  渲染好的 RGB32 BlitBuffer（未 free，调用方负责释放）与 { w=, h= }；失败返回 nil, err
local function renderBB(opts)
    opts = opts or {}
    local text = tostring(opts.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil, "empty text"
    end
    local template = Templates.TEMPLATES[opts.template_idx] or Templates.TEMPLATES[1]
    local color = Templates.COLORS[opts.color_idx] or Templates.COLORS[1]

    local bg_color = hexToColor(color.bg)
    local fg_color = hexToColor(color.fg)
    -- 静影：头部渐变区白字 + 正文区深色字(双背景双色)
    local header_fg, content_fg = fg_color, fg_color
    if template.id == "stillness" then
        header_fg = hexToColor("FFFFFF")
        content_fg = hexToColor("2D1F16")
    end
    local divider_ratio = template.divider_ratio or 0.35
    local dim_color = mixColor(color.fg, color.bg, divider_ratio)

    -- 画布：固定 375pt 设计稿 × @3x = 1125px（不随设备屏幕变化）
    local W = DESIGN_WIDTH_PT * RENDER_SCALE
    local pad = ds(template.padding)

    -- 手札内面板：外框左右 16 / 上下 44
    local inner_off_h, inner_off_v = 0, 0
    local inner_border_w = 0
    local inner_bg_color = bg_color
    local inner_border_color = dim_color
    if template.inner_panel then
        inner_off_h = ds(template.inner_pad_h or template.inner_padding or 16)
        inner_off_v = ds(template.inner_pad_v or template.inner_padding or 44)
        inner_border_w = ds(1)
        -- 手札内面板背景：浅底 90% 白、深底 10% 白
        inner_bg_color = mixColor(color.dark and "FFFFFF" or "FFFFFF", color.bg, color.dark and 0.10 or 0.90)
        -- 内框 15% 主题色
        inner_border_color = mixColor(color.fg, color.bg, 0.15)
    end

    -- 内容区起点与可用宽度（含内面板偏移）
    local content_x = pad + inner_off_h + inner_border_w
    local content_top = inner_off_v + inner_border_w
    local content_w = W - 2 * (pad + inner_off_h + inner_border_w)

    -- 日期统一为 "YYYY/M/D" 格式（经典页眉/墨白竖排/页脚共用）
    local date_str = formatDateSlash(opts.date_str or os.time())
    -- 页脚文案按设备品牌定制(footerBrandText:Kindle/Kobo 加前缀,其余保持原文);
    -- 日期在经典页眉第二行 / 竖排日期列 / 日历头部。
    -- 静影/锦书页脚为两行:第一行「摘录于 日期」(固定色),第二行为页脚文案。
    local footer_text = footerBrandText()
    local footer_date_text
    if template.footer_two_lines then
        footer_date_text = (template.footer_date_prefix or "摘录于 ") .. date_str
    end

    local qr_on = type(opts.qr_url) == "string" and opts.qr_url ~= ""
    local qr_size = 0
    local qr_gap = 0
    if qr_on then
        qr_size = ds(template.qr_size or 64)
        qr_gap = ds(10)
    end

    -- 字体：优先调用方传入的书籍字体族名，否则 cre_font；再解析成真实文件
    local font_name = opts.font_face or getReaderFont() or template.font

    -- 页眉 / 正文 / 页脚 face 与排版参数
    local header_face = safeGetFace(font_name, template.header_size, template.font)
    local content_face = safeGetFace(font_name, template.content_size, template.font)
    local footer_face = safeGetFace(font_name, template.footer_size, template.font)

    local function faceMetrics(face, line_height)
        local face_height, face_ascender = face.ftsize:getHeightAndAscender()
        local line_h = math.floor((1 + line_height) * face.size)
        local baseline0 = math.floor(face_ascender + math.max(0, line_h - face_height) / 2)
        return line_h, baseline0
    end

    -- 绝对行高（行高为绝对 px）：行盒内文字垂直居中，返回 (line_h, baseline0)
    local function faceMetricsAbs(face, line_h)
        local face_height, face_ascender = face.ftsize:getHeightAndAscender()
        local baseline0 = math.floor(face_ascender + math.max(0, line_h - face_height) / 2)
        return line_h, baseline0
    end

    local header_line_h, header_baseline0
    if template.header_line_height then
        header_line_h, header_baseline0 = faceMetricsAbs(header_face, ds(template.header_line_height))
    else
        header_line_h, header_baseline0 = faceMetrics(header_face, 1.3)
    end
    local content_line_h, content_baseline0 =
        faceMetricsAbs(content_face, ds(template.content_line_height))
    local footer_line_h, footer_baseline0 = faceMetricsAbs(footer_face, ds(16))
    local para_gap = ds(template.para_gap or 0)

    -- 页眉：经典/手札为书名 + 日期两行（页眉 = 用户名 + 动作/日期）
    local header_text = opts.book_title or ""
    if not template.classic_header and not template.vertical_title and not template.calendar then
        if opts.book_author and opts.book_author ~= "" then
            if header_text ~= "" then
                header_text = header_text .. " · " .. opts.book_author
            else
                header_text = opts.book_author
            end
        end
    end
    local header_lines = wrapText(header_text, header_face, content_w, false, false)
    local content_align = template.align
    if template.center_if_short then
        local nrunes = #Runes.toRunes(text)
        if nrunes < 50 then
            content_align = "center"
        end
    end
    local content_lines, content_line_is_end = wrapText(text, content_face, content_w, false, false)
    local content_truncated = #content_lines > template.content_max_lines
    -- 正文行数上限（同步截断段末标记；被截断的最后一行视为段末，避免拉伸）
    if content_truncated then
        local kept = {}
        local kept_end = {}
        for i = 1, template.content_max_lines do
            kept[i] = content_lines[i]
            kept_end[i] = content_line_is_end[i]
        end
        kept_end[template.content_max_lines] = true
        content_lines = kept
        content_line_is_end = kept_end
    end
    -- 页脚：留出二维码空间
    local footer_w = qr_on and (content_w - qr_size - qr_gap) or content_w
    local footer_lines = wrapText(footer_text, footer_face, math.max(1, footer_w), false, false)

    local header_h = wrapHeight(header_lines, header_line_h)
    local content_h = wrapHeight(content_lines, content_line_h, content_line_is_end, para_gap)
    local footer_h = wrapHeight(footer_lines, footer_line_h)
    local footer_date_h = 0
    local footer_date_lines
    if footer_date_text then
        footer_date_lines = wrapText(footer_date_text, footer_face, math.max(1, footer_w), false, false)
        footer_date_h = wrapHeight(footer_date_lines, footer_line_h)
    end
    -- 页脚文字垂直居中于 footer 容器;流式布局下 footer_area 取内容实际高
    -- (经典/手札: 微信读书 16px; 二维码时 ≥ qr_size; 两行页脚含 7px 行距)
    local footer_area_h = math.max(footer_h + footer_date_h, qr_on and qr_size or 0)
    -- 墨白页脚 content 盒(高 80,带二维码 96):上分隔线与下粗线之间
    if template.footer_content_h then
        footer_area_h = math.max(footer_area_h,
            ds(template.footer_content_h) + (qr_on and ds(template.footer_qr_extra or 16) or 0))
    end
    -- 固定页脚容器高度(手札 102):微信读书在其中垂直居中
    if template.footer_height then
        footer_area_h = math.max(footer_area_h, ds(template.footer_height))
    end
    -- 页脚两行(摘录于日期 + 微信读书)之间的行距 7
    if footer_date_text and footer_h > 0 then
        footer_area_h = footer_area_h + ds(7)
    end
    -- 静影/锦书:摘录于行前留白(页脚容器内两行垂直居中的上边距;
    -- 锦书有固定 footer_height=112 时已含,不再叠加)
    if footer_date_text and template.footer_date_pad_top and not template.footer_height then
        footer_area_h = footer_area_h + ds(template.footer_date_pad_top)
    end

    local divider_h = ds(2)
    local gap = ds(28)

    -- 日历模板：页眉区 = 日期大字 + 英文月份年份 + 中文星期（今日卡片式，无月历网格）
    local header_area_h = header_h
    -- 竖排标题（墨白/静影/锦书）：标题按字数分列 + 作者 + 日期，多列横排
    local vparts
    if template.vertical_title then
        vparts = {}
        if opts.book_title and opts.book_title ~= "" then
            vparts[#vparts + 1] = opts.book_title
        end
        if opts.book_author and opts.book_author ~= "" then
            vparts[#vparts + 1] = opts.book_author
        end
        if template.id == "inkwhite" then
            -- 墨白右侧装饰列 = 竖线 + 动作「摘录于」+ 竖线 + 中文日期 + 竖线
            -- (昵称留空 → 动作列直接显示「摘录于」)
            vparts[#vparts + 1] = (template.subheader_prefix or "摘录于 ")
            vparts[#vparts + 1] = date_str -- 墨白:日期在右侧装饰列(中文日期)
        end
        header_area_h = verticalTitleHeight(vparts, template, font_name)
    end
    local cal_day_line_h, cal_day_baseline0 = 0, 0
    local cal_month_line_h, cal_month_baseline0 = 0, 0
    local cal_weekday_line_h, cal_weekday_baseline0 = 0, 0
    local cal_month_face, cal_weekday_face
    -- 日历头部：日期字号 100(默认行盒≈1.2x)、
    -- 月份 24(上边距 -5, 透明度 .9)、星期 12(行高 14, 上边距 11,
    -- 透明度 .85)、分割线上边距 33
    local cal_month_color, cal_weekday_color
    if template.calendar then
        cal_month_face = safeGetFace(font_name, 24, template.font)
        cal_weekday_face = safeGetFace(font_name, 12, template.font)
        cal_day_line_h, cal_day_baseline0 = faceMetrics(header_face, 0.2)
        cal_month_line_h, cal_month_baseline0 = faceMetrics(cal_month_face, 0.2)
        cal_weekday_baseline0 = select(2, faceMetrics(cal_weekday_face, 14 / 12 - 1))
        cal_weekday_line_h = ds(14) -- 行高 14
        cal_month_color = mixColor(color.fg, color.bg, 0.9)
        cal_weekday_color = mixColor(color.fg, color.bg, 0.85)
        -- 行间留白：月份 -5、星期 +11、分割线 +33（负值上移紧凑）
        header_area_h = cal_day_line_h + cal_month_line_h + cal_weekday_line_h
            - ds(5) + ds(11) + ds(33)
    end
    local header_pad_top = ds(template.header_pad_top or 56)
    local header_pad_bottom = ds(template.header_pad_bottom or 0)
    local footer_pad_top = ds(template.footer_pad_top or 28)
    local footer_pad_bottom = ds(template.footer_pad_bottom or 56)
    local subheader_face, subheader_line_h, subheader_baseline0
    if template.classic_header then
        subheader_face = safeGetFace(font_name, template.subheader_size or 12, template.font)
        local sub_lh = template.subheader_line_height or 18
        subheader_line_h, subheader_baseline0 = faceMetricsAbs(subheader_face, ds(sub_lh))
        -- 页眉第二行上边距 4;顶部只保留摘录于(无书名行)
        header_area_h = subheader_line_h + ds(4)
    elseif template.notebook_header then
        -- 手札页眉高 102:只显示「摘录于 日期」,垂直居中
        subheader_face = safeGetFace(font_name, template.subheader_size or 12, template.font)
        local sub_lh = template.subheader_line_height or 17
        subheader_line_h, subheader_baseline0 = faceMetricsAbs(subheader_face, ds(sub_lh))
        header_area_h = ds(102)
        header_pad_top = 0 -- 102 容器已含顶部留白,「摘录于」在其中垂直居中
    end

    -- 书信息行（日历模板：正文后 《书名》 17/24 + 作者 13/18 opacity 0.75）
    local book_title_face = footer_face
    local book_author_face = footer_face
    local book_line_h = math.floor((1 + 0.36) * footer_face.size)
    local book_author_line_h = book_line_h
    if template.show_book_info then
        book_title_face = safeGetFace(font_name, template.book_title_size or 17, template.font)
        book_author_face = safeGetFace(font_name, template.book_author_size or 13, template.font)
        book_line_h = ds(template.book_title_line_height or 24)
        book_author_line_h = ds(template.book_author_line_height or 18)
    end
    local book_info_h = 0
    local book_title_lines, book_author_lines
    local source_face, source_line_h, source_baseline0
    local source_h = 0
    local source_title, source_author
    if template.source_after_content then
        source_face = safeGetFace(font_name, 14, template.font)
        local src_lh = template.source_line_height or 20
        source_line_h, source_baseline0 = faceMetricsAbs(source_face, ds(src_lh))
        source_h = ds(template.source_margin_top or 4)
        local title = opts.book_title or ""
        local author = opts.book_author or ""
        local chapter = opts.chapter or ""
        -- 出处行:
        --   经典  : "/ 书名 · 章节"  + 作者(第二行)
        --   墨白  : "/ 章节"(MP 书追加作者)
        --   锦书/静影: "/ 章节"
        --   手札  : "书名 · 章节" + 作者(第二行,无斜杠)
        if chapter ~= "" then
            if template.source_two_lines then
                -- 手札：第一行「书名 · 章节」，第二行作者
                source_title = title ~= "" and (title .. " · " .. chapter) or chapter
            else
                local body = chapter
                if template.source_show_book and title ~= "" then
                    body = title .. " · " .. chapter
                end
                source_title = "/  " .. body
            end
            source_h = source_h + source_line_h
            if template.source_author_line and author ~= "" then
                source_author = author
                source_h = source_h + source_line_h + ds(2)
            end
        else
            -- 无章节信息：回退旧逻辑
            if template.source_two_lines then
                -- 手札：第一行「书名 · 」，第二行作者
                if title ~= "" then
                    source_title = title
                    source_h = source_h + source_line_h
                end
                if author ~= "" then
                    source_author = author
                    source_h = source_h + source_line_h + ds(2)
                end
            else
                -- 经典/墨白/锦书/静影：`/  书名 · 作者` 单行
                local bits = {}
                if template.source_slash ~= false then
                    bits[#bits + 1] = "/"
                end
                if title ~= "" then
                    bits[#bits + 1] = title
                end
                if author ~= "" then
                    bits[#bits + 1] = author
                end
                if #bits > 0 then
                    if template.source_slash ~= false then
                        -- "/" + "  " + title + " · " + author
                        local body = title
                        if title ~= "" and author ~= "" then
                            body = title .. " · " .. author
                        elseif author ~= "" then
                            body = author
                        end
                        source_title = "/  " .. body
                    else
                        source_title = table.concat(bits, " · ")
                    end
                    source_h = source_h + source_line_h
                end
            end
        end
    end

    local book_has_title = template.show_book_info
        and opts.book_title and opts.book_title ~= ""
    local book_has_author = template.show_book_info
        and opts.book_author and opts.book_author ~= ""
    if book_has_title then
        book_title_lines = wrapText("《" .. opts.book_title .. "》",
            book_title_face, content_w, false, false)
        book_info_h = book_info_h + wrapHeight(book_title_lines, book_line_h)
    end
    if book_has_author then
        book_author_lines = wrapText(opts.book_author, book_author_face, content_w, false, false)
        book_info_h = book_info_h + wrapHeight(book_author_lines, book_author_line_h)
    end
    local book_info_gap = ds(template.book_info_gap or 6)
    if book_has_title and book_has_author then book_info_h = book_info_h + book_info_gap end
    if book_has_title or book_has_author then book_info_h = book_info_h + ds(7) end -- 出处块上边距

    -- 高度 = 页眉区 + 分隔线 + 正文 + 书信息 + 分隔线 + 页脚（+ 内面板边距）
    -- 日历模板的分割线紧贴页眉区（上边距 33 已计入 header_area_h），
    -- 不再叠加 header→content 的 gap
    local content_pad_top = ds(template.content_pad_top or 0)
    local header_top_bar_h = ds(template.header_top_bar_h or 0)
    local header_after_top_bar = ds(template.header_after_top_bar or 0)
    local header_bottom_bar_h = ds(template.header_bottom_bar_h or 0)

    local H = header_pad_top + header_top_bar_h + header_after_top_bar
        + header_area_h + header_bottom_bar_h + header_pad_bottom
        + content_pad_top + content_h + source_h + book_info_h
        + footer_pad_top + footer_area_h + footer_pad_bottom
    if template.header_divider then
        H = H + divider_h
        if not template.calendar then
            H = H + gap
        end
    elseif template.header_deco and not template.vertical_title then
        H = H + gap + ds(6)
    end
    if template.footer_divider then
        local fd_h = 0
        if template.footer_hairline then
            fd_h = math.max(1, ds(1))
        end
        if template.footer_sep_317 then
            fd_h = fd_h + ds(3)
        end
        if template.footer_bold_line then
            fd_h = fd_h + ds(10)
        end
        if fd_h == 0 then
            fd_h = divider_h
        end
        H = H + fd_h
    end
    H = H + 2 * (inner_off_v + inner_border_w)
    H = math.max(H, ds(560))

    local bb = BlitBuffer.new(W, H, BlitBuffer.TYPE_BBRGB32)
    -- 背景：支持垂直渐变(双色渐变、米纸渐变)；
    -- 静影模板为「头部背景图 + 正文浅色区」双背景(cover 等比缩放)。
    if template.id == "stillness" then
        local head_h = ds(340)
        -- 背景图经 assets.getStillnessHeadBB 缓存:首次解码 + cover 裁剪成
        -- W×head_h 的 RGB32 bb,后续命中只做一次 blitFrom(预览切换配色零解码)。
        -- 资产缺失 / WebP 解码失败(老 KOReader 无 libwebp)时返回 nil,
        -- 逐级回退 bg_1 → 纯背景色(与改动前等价)。
        local function blitBgImage(idx)
            local head = getStillnessHeadBB(idx, W, head_h)
            if not head then return false end
            local ok, err = pcall(bb.blitFrom, bb, head, 0, 0, 0, 0, W, head_h)
            if not ok then
                logger.warn("miuread: stillness head image blit error: idx=" .. tostring(idx)
                    .. " err=" .. tostring(err))
                return false
            end
            return true
        end
        local bg_blitted = false
        if not opts.background_idx then
            logger.info("miuread: stillness no background_idx set, try default bg_1")
        end
        if opts.background_idx then
            bg_blitted = blitBgImage(opts.background_idx)
        end
        if not bg_blitted then
            -- 指定背景图加载失败时回退默认 bg_1(海景图,cover 等比缩放)
            bg_blitted = blitBgImage(1)
        end
        if not bg_blitted then
            -- 只使用打包资产;缺失时头部回退纯背景色
            logger.warn("miuread: stillness head image unavailable, use plain background")
            bb:paintRectRGB32(0, 0, W, head_h, bg_color)
        end
        -- 静影正文区背景 #FAFAFA
        bb:paintRectRGB32(0, head_h, W, H - head_h, hexToColor("FAFAFA"))
    elseif color.bg2 then
        if template.id == "inkwhite" then
            -- 墨白:start{0,0}→end{1,1} 对角线渐变
            -- (color_6: #F3E5E8 左上 → #F3F1E5 右下;其余模板为垂直渐变)
            drawVGradientDiag(bb, 0, 0, W, H, hexToColor(color.bg), hexToColor(color.bg2))
        else
            drawVGradient(bb, 0, 0, W, H, hexToColor(color.bg), hexToColor(color.bg2))
        end
    else
        bb:paintRectRGB32(0, 0, W, H, bg_color)
    end

    -- 手札内面板：内背景 + 双线内边框（外圈 20% 主题色 + 内圈 15% 主题色缩进）
    if template.inner_panel then
        local ox, oy = inner_off_h, inner_off_v
        local ow, oh = W - 2 * inner_off_h, H - 2 * inner_off_v
        local ix, iy = ox + ds(3), oy + ds(3)
        local iw, ih = ow - ds(6), oh - ds(6)
        bb:paintRectRGB32(ox, oy, ow, oh, inner_bg_color)
        local out_border = mixColor(color.fg, color.bg, 0.2) -- 手札外圈边框色
        local in_border = mixColor(color.fg, color.bg, 0.15) -- 手札内圈边框色
        -- 外圈(贴面板边缘)
        bb:paintRectRGB32(ox, oy, ow, inner_border_w, out_border)
        bb:paintRectRGB32(ox, oy + oh - inner_border_w, ow, inner_border_w, out_border)
        bb:paintRectRGB32(ox, oy, inner_border_w, oh, out_border)
        bb:paintRectRGB32(ox + ow - inner_border_w, oy, inner_border_w, oh, out_border)
        -- 内圈(缩进 3px)
        bb:paintRectRGB32(ix, iy, iw, inner_border_w, in_border)
        bb:paintRectRGB32(ix, iy + ih - inner_border_w, iw, inner_border_w, in_border)
        bb:paintRectRGB32(ix, iy, inner_border_w, ih, in_border)
        bb:paintRectRGB32(ix + iw - inner_border_w, iy, inner_border_w, ih, in_border)
    end

    local y = content_top + header_pad_top
    if template.calendar then
        -- 今日卡片：日期大字（居中，加粗；字号 100）
        local now = os.date("*t")
        local day_str = tostring(now.day)
        local dw = RenderText:sizeUtf8Text(0, content_w, header_face, day_str, false, true).x
        RenderText:renderUtf8Text(bb, content_x + math.floor((content_w - dw) / 2),
            y + cal_day_baseline0, header_face, day_str, false, true, header_fg, content_w)
        -- 月份行上边距 -5（上移紧凑）
        y = y + cal_day_line_h - ds(5)
        -- 英文月份 + 年份（字号 24, 透明度 0.9）
        local month_year = string.format("%s %d", Config.MONTHS_EN[now.month] or "", now.year)
        local mw = RenderText:sizeUtf8Text(0, content_w, cal_month_face, month_year, false, false).x
        RenderText:renderUtf8Text(bb, content_x + math.floor((content_w - mw) / 2),
            y + cal_month_baseline0, cal_month_face, month_year, false, false, cal_month_color, content_w)
        -- 星期行上边距 11
        y = y + cal_month_line_h + ds(11)
        -- 中文星期（字号 12, 行高 14, 透明度 0.85）
        local weekday_str = Config.WEEKDAYS_CN[now.wday] or ""
        local ww = RenderText:sizeUtf8Text(0, content_w, cal_weekday_face, weekday_str, false, false).x
        RenderText:renderUtf8Text(bb, content_x + math.floor((content_w - ww) / 2),
            y + cal_weekday_baseline0, cal_weekday_face, weekday_str, false, false, cal_weekday_color, content_w)
        -- 分割线（上边距 33、宽 48 居中）
        y = y + cal_weekday_line_h + ds(33)
        if template.header_divider then
            local sep_w = ds(48)
            bb:paintRectRGB32(content_x + math.floor((content_w - sep_w) / 2),
                y, sep_w, divider_h, dim_color)
            y = y + divider_h + content_pad_top
        end
    elseif template.vertical_title then
        local deco_w = ds(317)
        local deco_x = content_x + math.floor((content_w - deco_w) / 2)
        -- 墨白装饰线用纯主题色,不用淡化混合
        local deco_color = (template.id == "inkwhite") and fg_color or dim_color
        -- 顶部粗条 = icon_line_header 图片(资产 alpha≈0.8,两端圆角):
        -- 实际渲染色 = 主题色 × 资产 alpha 叠在背景上,纯色会过深
        local bar_color = (template.id == "inkwhite")
            and mixColor(color.fg, color.bg, 0.84) or deco_color
        if header_top_bar_h > 0 then
            -- 用 icon_line_header 图片渲染;资产缺失回退纯色(alpha 0.84)
            if template.id ~= "inkwhite"
                or not drawLineImage(bb, deco_x, y, "icon_line_header", deco_w, header_top_bar_h, fg_color) then
                bb:paintRectRGB32(deco_x, y, deco_w, header_top_bar_h, bar_color)
            end
            y = y + header_top_bar_h + header_after_top_bar
        end
        -- 竖排标题（标题分列 + 作者 + 日期，多列横排 + 左右竖线）
        -- 墨白右侧装饰列竖线:icon_line_left 图片透明度低(≈主题色 15%)
        local vline_color = (template.id == "inkwhite")
            and mixColor(color.fg, color.bg, 0.15) or deco_color
        renderVerticalTitle(bb, content_x, y, content_w, font_name,
            vparts, header_fg, dim_color, template, deco_color, vline_color)
        y = y + header_area_h
        if header_bottom_bar_h > 0 then
            bb:paintRectRGB32(deco_x, y, deco_w, header_bottom_bar_h, deco_color)
            y = y + header_bottom_bar_h
        end
        -- 锦书/静影页眉下留白(标题→正文)
        if header_pad_bottom > 0 then
            y = y + header_pad_bottom
        end
        y = y + content_pad_top
    else
        if template.notebook_header then
            -- 手札页眉高 102:「摘录于 日期」垂直居中(无昵称/书名)
            local sub_color = mixColor(color.fg, color.bg, 0.7) -- 透明度 0.7
            local sub_text = (template.subheader_prefix or "摘录于 ") .. date_str
            local y_mid = y + math.floor((ds(102) - subheader_line_h) / 2)
            RenderText:renderUtf8Text(bb, content_x, y_mid + subheader_baseline0, subheader_face,
                sub_text, false, false, sub_color, content_w)
            y = y + ds(102)
            -- 手札页眉→正文留白 24(不走下方 header_pad_bottom/gap)
            y = y + content_pad_top
        else
            if template.classic_header then
                -- 经典:顶部只保留「摘录于 日期」(无昵称/书名行,用户确认)
                local sub_color = mixColor(color.fg, color.bg, 0.8)
                y = y + ds(4)
                local sub_text = (template.subheader_prefix or "摘录于 ") .. date_str
                RenderText:renderUtf8Text(bb, content_x, y + subheader_baseline0, subheader_face,
                    sub_text, false, false, sub_color, content_w)
                y = y + subheader_line_h
            else
                renderLines(bb, content_x, y + (header_baseline0 or 0), header_face, header_lines, header_line_h, header_fg, content_w,
                    template.header_align)
                y = y + header_h
            end
        end
        if not template.notebook_header then
            y = y + (header_pad_bottom > 0 and header_pad_bottom or gap)
        end
        if template.header_divider then
            if template.header_deco then
                drawOrnateDivider(bb, content_x, y, content_w, dim_color)
            else
                bb:paintRectRGB32(content_x, y, content_w, divider_h, dim_color)
            end
            y = y + divider_h + gap
        elseif template.header_deco then
            -- 锦书：无标准分隔线时仍画装饰线
            drawOrnateDivider(bb, content_x, y, content_w, dim_color)
            y = y + ds(6) + gap
        end
    end
    y = y + content_baseline0
    renderLines(bb, content_x, y, content_face, content_lines, content_line_h, content_fg, content_w,
        content_align, content_line_is_end, para_gap)
    y = y - content_baseline0 + content_h
    if template.source_after_content then
        local src_color = mixColor(color.fg, color.bg, 0.8)
        y = y + ds(template.source_margin_top or 4)
        if source_title then
            RenderText:renderUtf8Text(bb, content_x, y + source_baseline0, source_face,
                source_title, false, false, src_color, content_w)
            y = y + source_line_h
        end
        if source_author then
            y = y + ds(2)
            local ax = content_x
            -- 出处行为一行:「/ 」+ 列[书名·章节, 作者]:
            -- 作者与书名首个全字(如「全」)对齐,而非与「/」对齐;
            -- 用 source_title 的「/」前缀实际宽度作缩进
            if template.source_slash ~= false and source_title then
                local slash_prefix = source_title:match("^/+%s*")
                if slash_prefix then
                    ax = content_x + RenderText:sizeUtf8Text(0, nil, source_face, slash_prefix, false, false).x
                end
            end
            RenderText:renderUtf8Text(bb, ax, y + source_baseline0, source_face,
                source_author, false, false, src_color, content_w)
            y = y + source_line_h
        end
    end
    -- 书信息（日历模板：正文后显示书名/作者，居中；行数与高度计算一致）
    if template.show_book_info then
        y = y + ds(7)
        if book_title_lines then
            local _, tb0 = faceMetricsAbs(book_title_face, book_line_h)
            renderLines(bb, content_x, y + tb0, book_title_face, book_title_lines,
                book_line_h, fg_color, content_w, "center")
            y = y + wrapHeight(book_title_lines, book_line_h)
        end
        if book_author_lines then
            if book_title_lines then
                y = y + book_info_gap
            end
            local author_color = mixColor(color.fg, color.bg, 0.75)
            local _, ab0 = faceMetricsAbs(book_author_face, book_author_line_h)
            renderLines(bb, content_x, y + ab0, book_author_face, book_author_lines,
                book_author_line_h, author_color, content_w, "center")
            y = y + wrapHeight(book_author_lines, book_author_line_h)
        end
    end
    y = y + footer_pad_top
    -- 手札页脚容器顶 = 上边距(40) 之后;其高 102 含 1px 上边框,
    -- 微信读书/二维码均相对容器顶垂直居中
    local footer_container_top = y
    local deco_w = ds(317)
    local deco_x = content_x + math.floor((content_w - deco_w) / 2)
    -- 墨白装饰线(317x3 / 317x10)用主题色图片
    local deco_color = (template.id == "inkwhite") and fg_color or dim_color
    -- 墨白横条为图片:粗条 icon_line_header/footer(资产 alpha≈0.8→0.84 叠背景)、
    -- 细线 icon_line_bottom(资产 alpha 0.21-0.37→0.28 半透明,带中间缺口);
    -- 纯主题色渲染会明显过深(粗条 ~0.84、细线 ~0.1-0.16)
    local bar_color = (template.id == "inkwhite") and mixColor(color.fg, color.bg, 0.84) or deco_color
    local thin_color = (template.id == "inkwhite") and mixColor(color.fg, color.bg, 0.28) or deco_color
    local footer_bold_line_drawn = false
    if template.footer_divider then
        -- 静影页脚分隔线固定 #ADB4BE;其他模板用主题色 25% 淡化
        local hair_color = template.footer_line_color
            and hexToColor(template.footer_line_color)
            or mixColor(color.fg, color.bg, 0.25)
        if template.footer_hairline then
            local hh = math.max(1, ds(1))
            bb:paintRectRGB32(content_x, y, content_w, hh, hair_color)
            y = y + hh
        end
        if template.footer_sep_317 then
            -- 墨白:顶部细线 317x3(icon_line_bottom 图片,半透明带中间缺口)
            local sh = ds(3)
            if template.id ~= "inkwhite"
                or not drawLineImage(bb, deco_x, y, "icon_line_bottom", deco_w, sh, fg_color) then
                bb:paintRectRGB32(deco_x, y, deco_w, sh, thin_color)
            end
            y = y + sh
        end
        if template.footer_bold_line then
            -- 墨白:底部粗线 317x10 在内容之后(见下方文字渲染后)
            footer_bold_line_drawn = true
        end
        if not template.footer_hairline and not template.footer_sep_317 and not template.footer_bold_line then
            bb:paintRectRGB32(content_x, y, content_w, divider_h, dim_color)
            y = y + divider_h
        end
    end
    local footer_top = y
    local footer_content_bottom
    y = y + footer_baseline0
    -- 页脚文字色:各模板文字透明度 0.5~0.8(经典/墨白/手札 0.7~0.8)
    local footer_text_color = mixColor(color.fg, color.bg, template.footer_text_ratio or 0.8)
    if template.footer_text_white then
        -- 手札页脚微信读书 = 白 70% 透明度,叠在浅色面板上
        -- 实际渲染值 = 白*0.7 + 面板底*0.3 = (214,222,235)
        -- (纯白会偏亮;"应为白色"指相对旧版 #BBC8DE 灰蓝而言)
        footer_text_color = BlitBuffer.ColorRGB32(
            math.floor(255 * 0.7 + inner_bg_color.r * 0.3),
            math.floor(255 * 0.7 + inner_bg_color.g * 0.3),
            math.floor(255 * 0.7 + inner_bg_color.b * 0.3), 0xFF)
    end
    if footer_date_lines then
        -- 静影/锦书:第一行「摘录于 日期」距分隔线留白 = footer_date_pad_top
        -- (页脚容器 112 内两行垂直居中的上边距)
        y = y + ds(template.footer_date_pad_top or 0)
        -- 两行行距 = 行高(16) + 7
        local dc = template.footer_date_color
            and hexToColor(template.footer_date_color)
            or mixColor(color.fg, color.bg, 0.9)
        renderLines(bb, content_x, y, footer_face, footer_date_lines, footer_line_h, dc, footer_w,
            template.footer_align or "left", nil, 0, true)
        y = y + wrapHeight(footer_date_lines, footer_line_h) + ds(7)
    end
    if template.footer_height and not footer_date_lines then
        -- 手札页脚容器高 102:微信读书在其中垂直居中
        -- (footer_container_top = 容器顶,含上边框;文字块高 = footer_h)
        -- 光学修正:字形(≈字号 12)在 16px 行盒内偏上(下行留白多),
        -- 下移 (行盒-字号)/2 使微信读书到上分隔线/下边框的视觉间距相等
        local opt_shift = math.floor((footer_h - ds(template.footer_size or 12)) / 2)
        y = footer_container_top
            + math.floor((ds(template.footer_height) - footer_h) / 2)
            + footer_baseline0 + opt_shift
    elseif template.footer_content_h and not footer_date_lines then
        -- 墨白/经典:上分隔线与下粗线之间的 content 盒
        -- (墨白 80/96、经典 80/112),微信读书在其中垂直居中;footer_top = 盒顶
        local ch = ds(template.footer_content_h)
            + (qr_on and ds(template.footer_qr_extra or 16) or 0)
        y = footer_top + math.floor((ch - footer_h) / 2) + footer_baseline0
        -- 记录盒底,粗线画在盒底
        footer_content_bottom = footer_top + ch
    end
    renderLines(bb, content_x, y, footer_face, footer_lines, footer_line_h, footer_text_color, footer_w,
        template.footer_align or "left")
    if footer_content_bottom then
        y = footer_content_bottom
    end
    if footer_bold_line_drawn then
        local bh = ds(10)
        -- 墨白:底部粗线 317x10(icon_line_footer 图片,主题色染色)
        if template.id ~= "inkwhite"
            or not drawLineImage(bb, deco_x, y, "icon_line_footer", deco_w, bh, fg_color) then
            bb:paintRectRGB32(deco_x, y, deco_w, bh, bar_color)
        end
    end
    if qr_on then
        local qr_y_base = template.footer_height and footer_container_top or footer_top
        drawQR(bb, W - pad - inner_off_h - inner_border_w - qr_size,
            qr_y_base + math.floor((footer_area_h - qr_size) / 2),
            qr_size, opts.qr_url, fg_color, bg_color)
        -- 手札:微信读书与二维码之间的 1px 竖分隔线
        -- (二维码左侧右边距 20 + 左边距 10,高 100%)
        if template.footer_qrcode_line then
            local qr_x = W - pad - inner_off_h - inner_border_w - qr_size
            local ql_x = qr_x - ds(20)
            bb:paintRectRGB32(ql_x, qr_y_base, math.max(1, ds(1)),
                footer_area_h, inner_border_color)
        end
    end

    return bb, { w = W, h = H, truncated = content_truncated == true, rendered_lines = #content_lines }
end

--- 渲染书摘卡片并写 PNG（内部调 renderBB + writePNG）。
-- @param opts table（同 renderBB；out_dir/filename 控制输出位置与文件名）
-- @return path, dimen  PNG 路径 与 { w=, h= }；失败返回 nil, err
local function render(opts)
    local bb, dimen = renderBB(opts)
    if not bb then
        return nil, dimen
    end

    -- 写盘
    local out_dir = opts and opts.out_dir
    if not out_dir then
        -- MiuRead 数据目录（对齐 miuread/config.lua DATA_DIR，默认 <data>/miuread/cards）
        out_dir = ffiutil.joinPath(DataStorage:getFullDataDir(), "miuread/cards")
    end
    util.makePath(out_dir)
    -- filename 固定（预览覆盖写）时用传入值；否则时间戳命名（正式保存）
    local filename = opts and opts.filename
    if type(filename) ~= "string" or filename == "" then
        save_seq = (save_seq % 999) + 1
        local stamp = string.format("%s_%03d",
            os.date("%Y%m%d_%H%M%S"), save_seq)
        filename = string.format("book_excerpt_%s_%s.png",
            tostring(opts and opts.book_id or "book"), stamp)
    end
    local path = ffiutil.joinPath(out_dir, filename)
    local ok_write, err_write = pcall(function() bb:writePNG(path) end)
    bb:free()
    if not ok_write then
        return nil, tostring(err_write or "writePNG failed")
    end
    return path, dimen
end

return {
    renderBB = renderBB,
    render = render,
}
