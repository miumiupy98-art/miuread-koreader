-- Native thought-popup font construction and per-glyph fallback support.
-- The module prefers the selected/document font, then adds KOReader symbol,
-- CJK and optional monochrome Emoji faces. All failures fall back to KOReader's
-- normal Font:getFace path so a missing font can never block the popup.

local Font = require("ui/font")
local FontList = require("fontlist")
local Freetype = require("ffi/freetype")
local Screen = require("device").screen
local logger = require("logger")

local FaceFactory = {
    initialized = false,
    emoji_path = nil,
    emoji_checked = false,
    emoji_missing_logged = false,
    font_paths_cache = {},
    face_cache = {},
    fallback_cache = {},
}

local function file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.attributes) == "function" then
        return lfs.attributes(path, "mode") == "file"
    end
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
end

local function realpath(path)
    if not file_exists(path) then return nil end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and type(ffiutil.realpath) == "function" then
        return ffiutil.realpath(path) or path
    end
    return path
end

local function resolve_bundled_font(fontname)
    if type(fontname) ~= "string" or fontname == "" then return nil end
    local direct = FontList.fontdir and (FontList.fontdir .. "/" .. fontname) or nil
    if direct and file_exists(direct) then return realpath(direct) end

    local ok, fonts = pcall(FontList.getFontList, FontList)
    if not ok or type(fonts) ~= "table" then return nil end
    for _, path in ipairs(fonts) do
        if type(path) == "string" then
            local basename = path:match("([^/]+)$") or path
            if basename == fontname or path:find(fontname, 1, true) then
                return realpath(path)
            end
        end
    end
    return nil
end

local EMOJI_FONT_NAMES = {
    "NotoEmoji-VariableFont_wght.ttf",
    "NotoEmoji-Regular.ttf",
    "NotoColorEmoji.ttf",
    "Symbola.ttf",
    "SegoeUIEmoji.ttf",
    "Segoe UI Emoji.ttf",
}

function FaceFactory:findEmojiFont()
    if self.emoji_path and file_exists(self.emoji_path) then
        self.emoji_checked = true
        return self.emoji_path
    end
    if self.emoji_checked then return nil end

    -- Release packages stage a pinned Google Noto Emoji monochrome font inside
    -- MiuRead. Prefer that deterministic asset before any device/user font so
    -- Kindle, Kobo and Android render the same real Emoji glyphs.
    local bundled_candidates = {
        "plugins/miuread.koplugin/fonts/NotoEmoji-VariableFont_wght.ttf",
        "/mnt/us/koreader/plugins/miuread.koplugin/fonts/NotoEmoji-VariableFont_wght.ttf",
        "/mnt/onboard/.adds/koreader/plugins/miuread.koplugin/fonts/NotoEmoji-VariableFont_wght.ttf",
        "/sdcard/koreader/plugins/miuread.koplugin/fonts/NotoEmoji-VariableFont_wght.ttf",
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        for _, method in ipairs({"getDataDir", "getFullDataDir"}) do
            if type(DataStorage[method]) == "function" then
                local ok_dir, data_dir = pcall(DataStorage[method], DataStorage)
                if ok_dir and type(data_dir) == "string" and data_dir ~= "" then
                    bundled_candidates[#bundled_candidates + 1] = data_dir .. "/plugins/miuread.koplugin/fonts/NotoEmoji-VariableFont_wght.ttf"
                end
            end
        end
    end
    for _, path in ipairs(bundled_candidates) do
        local resolved = realpath(path)
        if resolved then
            self.emoji_path = resolved
            self.emoji_checked = true
            logger.info("[MiuRead][ThoughtEmoji] bundled emoji font:", resolved)
            return resolved
        end
    end

    -- Development/source installs may not contain the release-staged font.
    -- Fall back to fonts already known to KOReader or installed by the user.
    for _, fontname in ipairs(EMOJI_FONT_NAMES) do
        local resolved = resolve_bundled_font(fontname)
        if resolved then
            self.emoji_path = resolved
            self.emoji_checked = true
            logger.info("[MiuRead][ThoughtEmoji] fallback emoji font:", resolved)
            return resolved
        end
    end

    local candidates = {
        "plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf",
        "/mnt/us/koreader/plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf",
        "/mnt/us/koreader/fonts/NotoEmoji-Regular.ttf",
        "/mnt/us/fonts/NotoEmoji-Regular.ttf",
        "/mnt/onboard/.adds/koreader/fonts/NotoEmoji-Regular.ttf",
        "/mnt/onboard/fonts/NotoEmoji-Regular.ttf",
        "/sdcard/koreader/fonts/NotoEmoji-Regular.ttf",
        "/sdcard/fonts/NotoEmoji-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
    }
    if ok_ds and DataStorage then
        if type(DataStorage.getDataDir) == "function" then
            local ok_dir, data_dir = pcall(DataStorage.getDataDir, DataStorage)
            if ok_dir and type(data_dir) == "string" and data_dir ~= "" then
                candidates[#candidates + 1] = data_dir .. "/plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf"
                candidates[#candidates + 1] = data_dir .. "/fonts/NotoEmoji-Regular.ttf"
            end
        end
        if type(DataStorage.getFullDataDir) == "function" then
            local ok_dir, data_dir = pcall(DataStorage.getFullDataDir, DataStorage)
            if ok_dir and type(data_dir) == "string" and data_dir ~= "" then
                candidates[#candidates + 1] = data_dir .. "/plugins/miuread.koplugin/fonts/NotoEmoji-Regular.ttf"
                candidates[#candidates + 1] = data_dir .. "/fonts/NotoEmoji-Regular.ttf"
            end
        end
    end

    for _, path in ipairs(candidates) do
        local resolved = realpath(path)
        if resolved then
            self.emoji_path = resolved
            self.emoji_checked = true
            logger.info("[MiuRead][ThoughtEmoji] fallback emoji font:", resolved)
            return resolved
        end
    end

    -- Last chance: some KOReader builds expose user/system font paths without
    -- a predictable basename. Accept only paths whose names explicitly say
    -- Emoji, avoiding accidental dependency on unrelated plugin assets.
    local ok, fonts = pcall(FontList.getFontList, FontList)
    if ok and type(fonts) == "table" then
        for _, path in ipairs(fonts) do
            if type(path) == "string" and path:lower():find("emoji", 1, true) then
                local resolved = realpath(path)
                if resolved then
                    self.emoji_path = resolved
                    self.emoji_checked = true
                    logger.info("[MiuRead][ThoughtEmoji] fallback emoji font:", resolved)
                    return resolved
                end
            end
        end
    end

    self.emoji_path = nil
    self.emoji_checked = true
    if not self.emoji_missing_logged then
        self.emoji_missing_logged = true
        logger.info("[MiuRead][ThoughtEmoji] bundled/system emoji font missing; using emergency text fallbacks")
    end
    return nil
end


local EMOJI_TEXT_FALLBACKS = {
    {"❤️", "[爱心]"}, {"❤", "[爱心]"}, {"💔", "[心碎]"},
    {"🤣", "[笑哭]"}, {"😂", "[笑哭]"}, {"😄", "[笑]"}, {"😁", "[笑]"},
    {"😊", "[微笑]"}, {"😅", "[汗]"}, {"😭", "[哭]"}, {"😢", "[难过]"},
    {"😍", "[喜欢]"}, {"😘", "[亲亲]"}, {"😡", "[生气]"}, {"🤔", "[思考]"},
    {"😱", "[惊讶]"}, {"😎", "[酷]"}, {"👍", "[赞]"}, {"👎", "[不赞]"},
    {"👏", "[鼓掌]"}, {"🙏", "[谢谢]"}, {"🔥", "[火]"}, {"🎉", "[庆祝]"},
    {"✨", "[闪亮]"}, {"💯", "[100]"}, {"🥹", "[感动]"}, {"🥰", "[喜欢]"},
}

function FaceFactory:displayText(value)
    local text = tostring(value or "")
    self:init()
    if self.emoji_path then return text end
    for _, pair in ipairs(EMOJI_TEXT_FALLBACKS) do
        text = text:gsub(pair[1], pair[2])
    end
    -- Variation selectors are useful only to Emoji-capable fonts. Removing
    -- them prevents visible tofu boxes after a known Emoji was converted.
    text = text:gsub("️", "")
    return text
end

function FaceFactory:init()
    if self.initialized then return end
    pcall(function()
        local cre = require("document/credocument")
        if cre and type(cre.engineInit) == "function" then cre:engineInit() end
    end)
    self:findEmojiFont()
    self.initialized = true
end

function FaceFactory:getFontPaths(font_name)
    if type(font_name) ~= "string" or font_name == "" then return {} end
    local cached = self.font_paths_cache[font_name]
    if cached then return cached end

    local direct = realpath(font_name)
    if direct then
        local paths = {{path = direct, bold = false, italic = false}}
        self.font_paths_cache[font_name] = paths
        return paths
    end

    local paths, seen = {}, {}
    local ok, cre = pcall(function()
        local module = require("document/credocument")
        return module and type(module.engineInit) == "function" and module:engineInit() or module
    end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        for index = 1, 4 do
            local bold = index >= 3
            local italic = index == 2 or index == 4
            local ok_path, path = pcall(cre.getFontFaceFilenameAndFaceIndex, font_name, bold, italic)
            path = ok_path and realpath(path) or nil
            if path and not seen[path] then
                seen[path] = true
                paths[#paths + 1] = {path = path, bold = bold, italic = italic}
            end
        end
    end
    self.font_paths_cache[font_name] = paths
    return paths
end

function FaceFactory:_buildFace(path, size, scale_size)
    path = realpath(path)
    local orig_size = math.max(8, math.floor(tonumber(size) or 0))
    if not path or orig_size <= 0 then return nil end
    -- Font:getFace() treats its size argument as a logical KOReader size and
    -- applies Screen:scaleBySize() before opening FreeType. Custom UI fonts
    -- must do the same or they become dramatically smaller on 300-ppi Kindles.
    local scaled_size = orig_size
    if scale_size ~= false and Screen and type(Screen.scaleBySize) == "function" then
        local ok_scale, value = pcall(Screen.scaleBySize, Screen, orig_size)
        if ok_scale and tonumber(value) and tonumber(value) > 0 then
            scaled_size = math.max(8, math.floor(tonumber(value) + .5))
        end
    end

    local ok, ftsize = pcall(Freetype.newFaceSize, path, scaled_size)
    if not ok or not ftsize then
        logger.warn("[MiuRead][ThoughtPopup] unable to open fallback font:", tostring(path))
        return nil
    end

    local face = {
        orig_font = path,
        realname = path,
        size = scaled_size,
        orig_size = orig_size,
        ftsize = ftsize,
        hash = path .. "|" .. tostring(scaled_size),
        is_real_bold = false,
        hb_features = {"+kern", "+liga"},
        fallbacks = {},
    }
    face.getFallbackFont = function(number)
        if not number or number == 0 then return face end
        if face.fallbacks[number] ~= nil then return face.fallbacks[number] end
        return false
    end
    return face
end

function FaceFactory:_getFallbackFace(path, size, scale_size)
    if not path then return nil end
    local key = path .. "|" .. tostring(size) .. "|" .. (scale_size == false and "final" or "logical")
    if self.fallback_cache[key] then return self.fallback_cache[key] end
    local face = self:_buildFace(path, size, scale_size)
    if face then self.fallback_cache[key] = face end
    return face
end

local FALLBACK_FONT_NAMES = {
    "FreeSans.ttf",
    "NotoSansCJKsc-Regular.otf",
    "freefont/FreeSerif.ttf",
    "nerdfonts/symbols.ttf",
    "NotoSansSymbols2-Regular.ttf",
}

function FaceFactory:_addFallbacks(face, size, scale_size)
    if not face then return end
    local paths, seen = {}, {}
    if face.orig_font then seen[face.orig_font] = true end

    for _, fontname in ipairs(FALLBACK_FONT_NAMES) do
        local path = resolve_bundled_font(fontname)
        if path and not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end
    local emoji = self:findEmojiFont()
    if emoji and not seen[emoji] then paths[#paths + 1] = emoji end

    local fallbacks = {}
    for _, path in ipairs(paths) do
        local fallback = self:_getFallbackFace(path, size, scale_size)
        if fallback then fallbacks[#fallbacks + 1] = fallback end
    end
    fallbacks[#fallbacks + 1] = false
    face.fallbacks = fallbacks
end

local function unscale_size(final_size)
    final_size = math.max(8, math.floor(tonumber(final_size) or 12))
    if not Screen or type(Screen.scaleBySize) ~= "function" then return final_size end
    local best, best_diff = final_size, math.huge
    for logical = 8, math.min(255, final_size + 32) do
        local ok, scaled = pcall(Screen.scaleBySize, Screen, logical)
        scaled = ok and tonumber(scaled) or nil
        if scaled then
            local diff = math.abs(scaled - final_size)
            if diff < best_diff then best, best_diff = logical, diff end
            if diff == 0 then break end
        end
    end
    return best
end

local function legacy_face(font_name, size, fallback_name, size_is_final)
    local logical_size = size_is_final and unscale_size(size) or size
    if type(font_name) == "string" and font_name ~= "" then
        local ok, face = pcall(Font.getFace, Font, font_name, logical_size)
        if ok and face then return face end
    end
    return Font:getFace(fallback_name or "cfont", logical_size)
end

function FaceFactory:_getFace(font_name, size, fallback_name, scale_size)
    self:init()
    size = math.max(8, math.floor(tonumber(size) or 12))
    fallback_name = fallback_name or "cfont"
    local mode = scale_size == false and "final" or "logical"
    local key = table.concat({tostring(font_name or ""), tostring(size), fallback_name, self.emoji_path or "", mode}, "|")
    if self.face_cache[key] then return self.face_cache[key] end

    local path
    local paths = self:getFontPaths(font_name)
    for _, item in ipairs(paths) do
        if not item.bold and not item.italic then path = item.path; break end
    end
    if not path and paths[1] then path = paths[1].path end

    if not path then
        if fallback_name == "smallinfofont" then
            path = resolve_bundled_font("NotoSans-Regular.ttf")
                or resolve_bundled_font("FreeSans.ttf")
        else
            path = resolve_bundled_font("NotoSansCJKsc-Regular.otf")
                or resolve_bundled_font("NotoSans-Regular.ttf")
        end
    end

    local face = path and self:_buildFace(path, size, scale_size) or nil
    if face then
        self:_addFallbacks(face, size, scale_size)
        self.face_cache[key] = face
        return face
    end

    -- Compatibility fallback for KOReader builds whose font internals differ.
    return legacy_face(font_name, size, fallback_name, scale_size == false)
end

-- Logical KOReader size: used by MiuRead UI and preview widgets. The factory
-- applies Screen:scaleBySize exactly once, matching Font:getFace semantics.
function FaceFactory:getFace(font_name, size, fallback_name)
    return self:_getFace(font_name, size, fallback_name, true)
end

-- Final device-scaled size: used by the native comment popup, whose layout and
-- pagination metrics are already calculated from the final scaled size.
function FaceFactory:getFinalFace(font_name, size, fallback_name)
    return self:_getFace(font_name, size, fallback_name, false)
end

function FaceFactory:signature()
    self:init()
    return self.emoji_path or "no-emoji-font"
end

function FaceFactory:clearCache()
    self.font_paths_cache = {}
    self.face_cache = {}
    self.fallback_cache = {}
    self.emoji_path = nil
    self.emoji_checked = false
    self.emoji_missing_logged = false
    self.initialized = false
end

return FaceFactory
