local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local lfs = require("libs/libkoreader-lfs")

local Registry = {}

local source = debug.getinfo(1, "S").source or ""
if source:sub(1, 1) == "@" then source = source:sub(2) end
local module_dir = source:match("^(.*[/\\])") or ""
local plugin_root = module_dir:gsub("miuread[/\\]$", "")
local icon_root = plugin_root .. "resources/icons/miuread/"

local MAP = {
    ["‹"] = "back", ["←"] = "back", back = "back",
    ["⌂"] = "home", home = "home",
    ["×"] = "close", close = "close",
    ["›"] = "chevron-right", [">"] = "chevron-right", ["chevron-right"] = "chevron-right",
    ["+"] = "plus", plus = "plus", ["−"] = "minus", ["-"] = "minus", minus = "minus",
    ["☰"] = "toc", toc = "toc", catalog = "toc",
    ["◴"] = "progress", progress = "progress",
    ["Aa"] = "font", ["T"] = "font", font = "font",
    ["☼"] = "frontlight", frontlight = "frontlight",
    ["⇅"] = "sync", sync = "sync",
    ["▦"] = "grid", grid = "grid", all = "grid",
    ["↻"] = "refresh", refresh = "refresh",
    ["⌕"] = "search", search = "search",
    ["⇩"] = "download", download = "download",
    ["⇧"] = "upload", upload = "upload",
    ["⚙"] = "settings", settings = "settings",
    ["◷"] = "history", history = "history",
    ["▤"] = "file-manager", ["file-manager"] = "file-manager", file = "file-manager",
    ["▣"] = "screenshot", screenshot = "screenshot",
    ["▧"] = "image", image = "image",
    ["□"] = "current-book", ["current-book"] = "current-book",
    ["▯"] = "bookmark", bookmark = "bookmark",
    comment = "comment", highlight = "highlight", thought = "thought", ["line-spacing"] = "line-spacing",
    ["edge-guard"] = "edge-guard", ["edge-guard-off"] = "edge-guard-off",
    ["◐"] = "sleep", ["☾"] = "sleep", sleep = "sleep",
    ["→"] = "page-jump", ["page-jump"] = "page-jump",
    ["↶"] = "undo", undo = "undo",
    ["≡"] = "menu", menu = "menu",
    ["◉"] = "diagnostics", diagnostics = "diagnostics",
    ["✚"] = "repair", repair = "repair",
    ["⋯"] = "more", more = "more",
    ["i"] = "info", info = "info",
    ["!"] = "warning", warning = "warning",
    ["▶"] = "play", play = "play",
    ["⏻"] = "power", power = "power", quit = "power",
    ["↺"] = "restart", restart = "restart",
    rotate = "rotate", ["旋转"] = "rotate",
    ["orientation-lock"] = "orientation-lock", ["orientation-auto"] = "orientation-auto",
    night = "night", warmth = "warmth", battery = "battery",
    ["full-refresh"] = "full-refresh",
    ["return"] = "return",
    ["ko-reader"] = "ko-reader", koreader = "ko-reader",
    display = "display", tools = "repair", device = "device", book = "book", folder = "folder", ["📁"] = "folder", wifi = "wifi", ["⌁"] = "wifi",
    bluetooth = "bluetooth", bt = "bluetooth",
}

function Registry.key(value)
    value = tostring(value or "")
    return MAP[value] or value
end

function Registry.path(value)
    local key = Registry.key(value)
    if key == "" then return nil end
    return icon_root .. key .. ".svg"
end

function Registry.widget(value, size, opts)
    opts = opts or {}
    size = math.max(1, math.floor(tonumber(size) or 20))
    local path = opts.path or Registry.path(value)
    if path and path ~= "" and lfs.attributes(path, "mode") == "file" then
        local image
        local ok = pcall(function()
            image = ImageWidget:new{
                file = path,
                width = size,
                height = size,
                scale_factor = 0,
                file_do_cache = true,
                is_icon = true,
            }
            image:getSize()
        end)
        if ok and image then return image end
        if image and type(image.free) == "function" then pcall(image.free, image) end
    end
    return TextWidget:new{
        text = tostring(opts.fallback_text or value or "•"),
        face = opts.face,
        bold = opts.bold ~= false,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
end

return Registry
