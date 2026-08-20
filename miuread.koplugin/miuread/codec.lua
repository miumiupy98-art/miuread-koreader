local ffi = require("ffi")
local Util = require("miuread.util")

ffi.cdef[[
    char* miucodec_decode_parts(const char** parts, const int* parts_len, int count, int* out_len);
    char* miucodec_shard_body(const char* raw, int raw_len, int* out_len);
    char* miucodec_b64decode(const char* input, int input_len, int* out_len);
    char* miucodec_b64encode(const char* input, int input_len, int* out_len);
    char* miucodec_md5(const char* input, int input_len);
    char* miucodec_sha256(const char* input, int input_len);
    void  miucodec_free(void* ptr);
    void  free(void* ptr);
]]

local Codec = {}

local _lib

-- KOReader kindle/device.lua model constants → koxtoolchain lib folder.
-- otaModel() returns kindle-legacy/kindle/kindlepw2/kindlehf; our folders use
-- kindle for legacy TC and kindle5 for the "kindle" OTA target (K4/Touch/PW1).
local KINDLE_LEGACY_MODELS = {
    Kindle2 = true,
    KindleDXG = true,
    Kindle3 = true,
}
local KINDLE5_MODELS = {
    Kindle4 = true,
    KindleTouch = true,
    KindlePaperWhite = true,
}

local function kindle_lib_dir_from_ota(ota_model)
    if ota_model == "kindle-legacy" then return "kindle" end
    if ota_model == "kindle" then return "kindle5" end
    if ota_model == "kindlepw2" then return "kindlepw2" end
    if ota_model == "kindlehf" then return "kindlehf" end
end

local function kindle_platform_dir(Device)
    if type(Device.otaModel) == "function" then
        local ota_model = Device:otaModel()
        local dir = kindle_lib_dir_from_ota(ota_model)
        if dir then return dir end
    end
    local model = tostring(Device.model or "")
    if KINDLE_LEGACY_MODELS[model] then return "kindle" end
    if KINDLE5_MODELS[model] then return "kindle5" end
    -- KindlePaperWhite2 and all later touch models (see kindle/device.lua).
    return "kindlepw2"
end

local function native_platform_dirs()
    local os_name = (jit and jit.os) or ffi.os or ""
    if os_name == "OSX" then return {"osx", "host"} end
    if os_name == "Linux" then return {"linux", "host"} end
    return {"osx", "linux", "host"}
end

local function device_ota_model(Device)
    if type(Device.ota_model) == "string" and Device.ota_model ~= "" then
        return Device.ota_model
    end
    if type(Device.otaModel) == "function" then
        return Device:otaModel()
    end
end

local function preferred_platform_dirs()
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return native_platform_dirs() end
    if Device.isSDL and Device:isSDL() then return native_platform_dirs() end
    if Device.isKobo and Device:isKobo() then
        local ota = device_ota_model(Device)
        if ota == "kobov5" then return {"kobov5", "kobov4", "kobo", "nickel"} end
        if ota == "kobov4" then return {"kobov4", "kobov5", "kobo"} end
        return {"kobo", "kobov4", "kobov5", "nickel"}
    end
    if Device.isCervantes and Device:isCervantes() then return {"cervantes"} end
    if Device.isRemarkable and Device:isRemarkable() then
        local ota = device_ota_model(Device)
        if ota == "remarkable-aarch64" then
            return {"remarkable-aarch64", "remarkable"}
        end
        return {"remarkable", "remarkable-aarch64"}
    end
    if Device.isPocketBook and Device:isPocketBook() then
        return {"pocketbook", "pocketbookhf"}
    end
    if Device.isKindle and Device:isKindle() then
        local primary = kindle_platform_dir(Device)
        return {primary, "kindlehf", "kindlepw2", "kindle5", "kindle"}
    end
    return native_platform_dirs()
end

local function lib_extensions()
    local os_name = (jit and jit.os) or ffi.os or ""
    if os_name == "OSX" then return {"dylib", "so"} end
    return {"so", "dylib"}
end

local function lib_candidates(plugin_dir)
    local seen, candidates = {}, {}
    local function add(path)
        if path == "" or seen[path] then return end
        seen[path] = true
        candidates[#candidates + 1] = path
    end

    for _, ext in ipairs(lib_extensions()) do
        add(plugin_dir .. "/native/libmiucodec." .. ext)
    end
    for _, platform in ipairs(preferred_platform_dirs()) do
        for _, ext in ipairs(lib_extensions()) do
            add(plugin_dir .. "/libs/" .. platform .. "/libmiucodec." .. ext)
        end
    end
    for _, ext in ipairs(lib_extensions()) do
        add(plugin_dir .. "/libs/libmiucodec." .. ext)
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        local libs_dir = plugin_dir .. "/libs"
        if lfs.attributes(libs_dir, "mode") == "directory" then
            for name in lfs.dir(libs_dir) do
                if name ~= "." and name ~= ".." then
                    local sub = libs_dir .. "/" .. name
                    if lfs.attributes(sub, "mode") == "directory" then
                        for _, ext in ipairs(lib_extensions()) do
                            add(sub .. "/libmiucodec." .. ext)
                        end
                    end
                end
            end
        end
    end
    return candidates
end

local function lib()
    if _lib then return _lib end
    local plugin_dir = Util.plugin_dir()
    local errors = {}
    for _, path in ipairs(lib_candidates(plugin_dir)) do
        local ok, handle = pcall(ffi.load, path)
        if ok then _lib = handle; return _lib end
        errors[#errors + 1] = path .. ": " .. tostring(handle)
    end
    error("libmiucodec not found:\n" .. table.concat(errors, "\n"))
end

function Codec.native_lib()
    return lib()
end

local function ffi_string_free(ptr, len)
    if ptr == nil then return "" end
    local s = ffi.string(ptr, len)
    ffi.C.free(ptr)
    return s
end

local function ffi_hex_free(ptr)
    if ptr == nil then return "" end
    local s = ffi.string(ptr)
    ffi.C.free(ptr)
    return s
end

function Codec.b64decode(data)
    local s = tostring(data or "")
    local out_len = ffi.new("int[1]")
    local ptr = lib().miucodec_b64decode(s, #s, out_len)
    return ffi_string_free(ptr, out_len[0])
end

function Codec.b64encode(data)
    local s = tostring(data or "")
    local out_len = ffi.new("int[1]")
    local ptr = lib().miucodec_b64encode(s, #s, out_len)
    return ffi_string_free(ptr, out_len[0])
end

function Codec.shard_body(raw)
    raw = tostring(raw or "")
    if #raw <= 32 then return "" end
    local out_len = ffi.new("int[1]")
    local ptr = lib().miucodec_shard_body(raw, #raw, out_len)
    if ptr == nil or out_len[0] == 0 then
        if ptr ~= nil then ffi.C.free(ptr) end
        error("chapter checksum mismatch")
    end
    return ffi_string_free(ptr, out_len[0])
end

function Codec.decode_parts(parts)
    parts = parts or {}
    local count = #parts
    if count == 0 then return "" end
    local c_parts = ffi.new("const char*[?]", count)
    local c_lens = ffi.new("int[?]", count)
    for i = 1, count do
        local s = tostring(parts[i] or "")
        c_parts[i - 1] = s
        c_lens[i - 1] = #s
    end
    local out_len = ffi.new("int[1]")
    local ptr = lib().miucodec_decode_parts(c_parts, c_lens, count, out_len)
    return ffi_string_free(ptr, out_len[0])
end

function Codec.text_xhtml(text)
    local out = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local normalized = Util.trim(line)
        if normalized ~= "" then
            out[#out + 1] = "<p>" .. Util.xml(normalized) .. "</p>"
        end
    end
    return table.concat(out, "\n")
end

function Codec.body_fragment(html)
    local source = tostring(html or "")
    local bodies = {}
    local remaining = source
    while remaining ~= "" do
        local lower = remaining:lower()
        local body_start = lower:find("<body", 1, true)
        if not body_start then break end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then break end
        local body_close = lower:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end
    if #bodies > 0 then return table.concat(bodies, "\n"), #bodies end
    source = source:gsub("<%?xml.-%?>", "")
    source = source:gsub("<!DOCTYPE.-?>", "")
    return source, 0
end

function Codec.body(html)
    return Codec.body_fragment(html)
end

function Codec.mp_body(html)
    local s = tostring(html or ""):gsub("<script[%s%S]-</script>", ""):gsub("<style[%s%S]-</style>", "")
    local start = s:find('id="js_content"', 1, true) or s:find('class="rich_media_content', 1, true)
    if not start then return Codec.body(s) end
    start = s:find(">", start, true)
    if not start then return Codec.body(s) end
    local tail = s:sub(start + 1)
    local stop = tail:find("</div>", 1, true)
    return stop and tail:sub(1, stop - 1) or tail
end

local function tar_text(value)
    return tostring(value or ""):match("^[^%z]*") or ""
end
local function tar_octal(value)
    value = tar_text(value):gsub("^%s+", ""):gsub("%s+$", "")
    return tonumber(value, 8) or 0
end
local function tar_pax_path(body)
    for line in tostring(body or ""):gmatch("[^\n]+") do
        local path = line:match("%d+ path=(.*)")
        if path and path ~= "" then return path end
    end
end

function Codec.tar(data)
    local out, p = {}, 1
    local long_name, pax_name
    data = tostring(data or "")
    while p + 511 <= #data do
        local h = data:sub(p, p + 511)
        if h:gsub("\0", "") == "" then break end
        local name = tar_text(h:sub(1, 100))
        local prefix = tar_text(h:sub(346, 500))
        if prefix ~= "" then name = prefix .. "/" .. name end
        local size = tar_octal(h:sub(125, 136))
        local kind = h:sub(157, 157)
        local body = data:sub(p + 512, p + 511 + size)
        if kind == "L" then
            long_name = tar_text(body)
        elseif kind == "x" then
            pax_name = tar_pax_path(body)
        elseif kind == "0" or kind == "\0" or kind == "" then
            local final_name = pax_name or long_name or name
            if final_name ~= "" and size > 0 then out[final_name] = body end
            long_name, pax_name = nil, nil
        end
        p = p + 512 + math.ceil(size / 512) * 512
    end
    return out
end

function Codec.media(data, hint)
    data = tostring(data or "")
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png", "image/png" end
    if data:sub(1, 3) == "\255\216\255" then return ".jpg", "image/jpeg" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return ".gif", "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return ".webp", "image/webp" end
    if data:sub(1, 2) == "BM" then return ".bmp", "image/bmp" end
    local head = data:sub(1, 512):lower()
    if head:find("<svg", 1, true) then return ".svg", "image/svg+xml" end
    if data:sub(5, 12) == "ftypavif" or data:sub(5, 12) == "ftypavis" then return ".avif", "image/avif" end
    local clean_hint = tostring(hint or ""):lower():match("^[^%?#]+") or ""
    local ext = clean_hint:match("%.([%w]+)$")
    local by_ext = {
        png = {".png", "image/png"}, jpg = {".jpg", "image/jpeg"}, jpeg = {".jpg", "image/jpeg"},
        gif = {".gif", "image/gif"}, webp = {".webp", "image/webp"}, svg = {".svg", "image/svg+xml"},
        bmp = {".bmp", "image/bmp"}, avif = {".avif", "image/avif"},
    }
    if ext and by_ext[ext] then return by_ext[ext][1], by_ext[ext][2] end
    return ".bin", "application/octet-stream"
end

function Codec.md5(input)
    local s = tostring(input or "")
    local ptr = lib().miucodec_md5(s, #s)
    if ptr == nil then return "" end
    local hex = ffi.string(ptr)
    ffi.C.free(ptr)
    return hex
end

function Codec.sha256(input)
    local s = tostring(input or "")
    local ptr = lib().miucodec_sha256(s, #s)
    if ptr == nil then return "" end
    local hex = ffi.string(ptr)
    ffi.C.free(ptr)
    return hex
end

return Codec
