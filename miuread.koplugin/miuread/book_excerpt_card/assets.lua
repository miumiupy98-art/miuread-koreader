--[[--
卡片资产：墨白横条/竖线图片与静影背景图（只使用随插件打包的资产）。

墨白横条/竖线图片渲染：
墨白模板的横条(icon_line_header/footer/bottom)与竖线(icon_line_left/
middle/right)都是带透明通道的图片 + 主题色染色:源图片 alpha 作蒙版填主题色,
叠在背景上(纯色矩形只是近似)。这里加载插件自带资产,缩放到目标尺寸后
用 colorblitFromRGB32 染色叠加(与 koreader 文本染色同一路径);资产缺失
时回退纯色矩形,保证功能不依赖图片文件。

@module koplugin.miuread.book_excerpt_card.assets
--]]--

local BlitBuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- 插件目录:由本文件所在路径推导(本文件位于 book_excerpt_card/ 下)
-- 匹配 .../book_excerpt_card/assets.lua，插件目录 = book_excerpt_card/ 所在目录，
-- 资产随模块打包于 book_excerpt_card/assets/cards/
local plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.*/book_excerpt_card)/assets%.lua$") or ""

local line_raws = {} -- name -> { w, h, data } 原始 RGBA(缓存)
local function getLineRaw(name)
    if line_raws[name] ~= nil then return line_raws[name] end
    -- 用 lodepng 直接解码 RGBA(不依赖 mupdf;RenderImage 的 PNG 路径走 mupdf,
    -- 在无 mupdf 的构建/测试环境会失败)。ffi/png decodeFromFile 用
    -- lodepng_decode,内存由 lodepng malloc,复制进 Lua 字符串后须 free。
    local ok_png, Png = pcall(require, "ffi/png")
    if not (ok_png and Png) then
        line_raws[name] = false
        return nil
    end
    -- koreader ffi/util joinPath 只拼两参,多余参数会被静默丢弃,须单段拼接
    local path = ffiutil.joinPath(plugin_dir, "assets/cards/inkwhite/" .. name .. ".png")
    local ok_dec, _, dec = pcall(Png.decodeFromFile, path, 4)
    if ok_dec and dec and dec.width and dec.height and dec.data then
        local n = dec.width * dec.height * 4
        local data = ffi.string(dec.data, n)
        if ffi.C.free then pcall(ffi.C.free, dec.data) end
        line_raws[name] = { w = dec.width, h = dec.height, data = data }
        return line_raws[name]
    end
    line_raws[name] = false
    return nil
end

local tinted_cache = {} -- name:tint -> 已染色的原尺寸 RGB32 bb(缓存)
-- 画一张主题色染色的横条/竖线图片。染色语义:源图片 alpha 作蒙版,
-- RGB 替换为主题色,alpha 混合叠加(纯色矩形只是近似)。
-- @return true=图片绘制成功;false=资产缺失(调用方应回退纯色矩形)
local function drawLineImage(bb, x, y, name, w, h, tint)
    local raw = getLineRaw(name)
    if not raw then return false end
    if w <= 0 or h <= 0 then return false end
    local key = name .. ":" .. tostring(tint.r) .. "," .. tostring(tint.g) .. "," .. tostring(tint.b)
    local tinted = tinted_cache[key]
    if not tinted then
        -- 逐像素:RGB = tint,alpha = 源 alpha
        local n = raw.w * raw.h
        local tr, tg, tb = tint.r, tint.g, tint.b
        local data = raw.data
        local parts = {}
        for i = 0, n - 1 do
            local o = i * 4
            parts[i + 1] = string.char(tr, tg, tb, data:byte(o + 4))
        end
        tinted = BlitBuffer.fromstring(raw.w, raw.h,
            BlitBuffer.TYPE_BBRGB32, table.concat(parts))
        tinted_cache[key] = tinted
    end
    local scaled = tinted:scale(w, h)
    bb:alphablitFrom(scaled, x, y, 0, 0, w, h)
    scaled:free()
    return true
end

--- 背景图本地路径:只使用随插件打包的资产(assets/cards/stillness/bg_N.jpg,
-- 与墨白 icon_line 同目录约定);缺失返回 nil(渲染回退纯色,见 render.lua)。
local function backgroundImagePath(idx)
    -- koreader ffi/util 的 joinPath 只拼两个参数,多余参数会被静默丢弃
    -- (曾把路径截断成 .../assets 目录,导致头图永远回退),须单段拼接
    local asset = ffiutil.joinPath(plugin_dir,
        "assets/cards/stillness/bg_" .. tostring(idx) .. ".jpg")
    if lfs.attributes(asset) then
        return asset
    end
    logger.warn("miuread: stillness bg asset not bundled: ", asset)
    return nil
end

-- ---------------------------------------------------------------------------
-- 静影头部背景图缓存
-- ---------------------------------------------------------------------------

-- 诊断:资产 bg_*.jpg 实际是 WebP 伪装(RIFF/VP8),老 KOReader 无 libwebp 时
-- RenderImage 解码失败;首解码打一条日志,便于 Kindle 上定位回退纯色原因。
local function sniffImageFormat(path)
    local f = io.open(path, "rb")
    if not f then return "unreadable" end
    local head = f:read(12) or ""
    f:close()
    local b1, b2, b3, b4 = head:byte(1), head:byte(2), head:byte(3), head:byte(4)
    if b1 == 0xFF and b2 == 0xD8 then return "JPEG" end
    if b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46 then
        local tag = head:sub(9, 12)
        return tag ~= "" and ("WebP/RIFF(" .. tag .. ")") or "WebP/RIFF"
    end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "PNG" end
    return string.format("unknown(%02X %02X %02X %02X)",
        b1 or 0, b2 or 0, b3 or 0, b4 or 0)
end

-- idx -> 已「解码 + scale cover 裁剪」的 W×head_h RGB32 bb(单进程内复用)。
-- 预览反复切换配色时避免重复解码同一张 WebP/JPEG;上限 HEAD_CACHE_CAP 条,
-- 超出按插入序淘汰最旧并 free(手写 LRU,与 tinted_cache 同风格,不引入 ffi/lru)。
local HEAD_CACHE_CAP = 3
local head_cache = {}    -- idx(int) -> bb
local head_order = {}    -- 插入序(淘汰最旧用)

--- 取静影头部背景图(已 cover 裁剪为 W×head_h 的 RGB32 bb;调用方只读、勿 free)。
--- 资产缺失 / 解码失败(老 KOReader 无 libwebp)返回 nil,调用方逐级回退。
-- @return BlitBuffer|nil
local function getStillnessHeadBB(idx, W, head_h)
    idx = tonumber(idx) or 0
    local cached = head_cache[idx]
    if cached then
        -- 防御性尺寸校验:理论 W/head_h 恒定,不匹配则丢弃重建
        if cached.getWidth and cached:getWidth() == W
            and cached.getHeight and cached:getHeight() == head_h then
            return cached
        end
        pcall(cached.free, cached)
        head_cache[idx] = nil
        for i, v in ipairs(head_order) do
            if v == idx then table.remove(head_order, i) break end
        end
    end
    -- 缓存未命中:按需解析 ui/renderimage(require 自带 package.loaded 缓存;
    -- 后续命中直接 return cached,不再走到此)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_ri and RenderImage) then
        logger.warn("miuread: ui/renderimage unavailable, stillness head image disabled")
        return nil
    end
    local path = backgroundImagePath(idx)
    if not path then
        -- backgroundImagePath 已打 warn
        return nil
    end
    logger.info("miuread: stillness head image decode: idx=" .. tostring(idx)
        .. " path=" .. path .. " format=" .. sniffImageFormat(path))
    local ok_img, img = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok_img then
        logger.warn("miuread: stillness head image render error: idx=" .. tostring(idx)
            .. " path=" .. path .. " err=" .. tostring(img))
        return nil
    end
    if not img then
        logger.warn("miuread: stillness head image render returned nil: idx="
            .. tostring(idx) .. " path=" .. path)
        return nil
    end
    local iw, ih = img:getWidth(), img:getHeight()
    if not (iw and ih and iw > 0 and ih > 0) then
        logger.warn("miuread: stillness head image invalid size: idx=" .. tostring(idx)
            .. " iw=" .. tostring(iw) .. " ih=" .. tostring(ih))
        img:free()
        return nil
    end
    local type_map = { [BlitBuffer.TYPE_BB8] = "BB8", [BlitBuffer.TYPE_BBRGB32] = "RGB32" }
    local bb_type = type_map[img:getType()] or ("type#" .. tostring(img:getType()))
    local ratio = math.max(W / iw, head_h / ih)
    local sw, sh = math.floor(iw * ratio), math.floor(ih * ratio)
    local cropped
    local ok_scaled, scale_err = pcall(function()
        -- RenderImage:scaleBlitBuffer 默认走 MuPDF scaler，远快于 bb:scale（legacy 最近邻）；
        -- free_orig_bb=false：仍由下方 img:free() 统一释放，避免缩放异常时泄漏。
        local scaled = RenderImage:scaleBlitBuffer(img, sw, sh, false)
        cropped = BlitBuffer.new(W, head_h, BlitBuffer.TYPE_BBRGB32)
        cropped:blitFrom(scaled, 0, 0,
            math.floor((sw - W) / 2), math.floor((sh - head_h) / 2), W, head_h)
        scaled:free()
    end)
    img:free()
    if not ok_scaled or not cropped then
        logger.warn("miuread: stillness head image scale/blit error: idx=" .. tostring(idx)
            .. " err=" .. tostring(scale_err))
        if cropped then pcall(cropped.free, cropped) end
        return nil
    end
    logger.info("miuread: stillness head image OK: idx=" .. tostring(idx)
        .. " " .. bb_type .. " " .. iw .. "x" .. ih .. " -> " .. sw .. "x" .. sh
        .. " (cached " .. W .. "x" .. head_h .. ")")
    head_cache[idx] = cropped
    head_order[#head_order + 1] = idx
    while #head_order > HEAD_CACHE_CAP do
        local old = table.remove(head_order, 1)
        local old_bb = head_cache[old]
        head_cache[old] = nil
        if old_bb then pcall(old_bb.free, old_bb) end
    end
    return cropped
end

--- 释放全部静影头图缓存(卡片编辑器关闭时调用,避免长会话常驻多张头图)。
local function clearStillnessHeadCache()
    for idx, bb in pairs(head_cache) do
        if bb then pcall(bb.free, bb) end
        head_cache[idx] = nil
    end
    for i = #head_order, 1, -1 do head_order[i] = nil end
end

return {
    drawLineImage = drawLineImage,
    backgroundImagePath = backgroundImagePath,
    getStillnessHeadBB = getStillnessHeadBB,
    clearStillnessHeadCache = clearStillnessHeadCache,
}
