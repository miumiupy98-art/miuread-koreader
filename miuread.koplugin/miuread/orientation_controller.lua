local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen
local M = {}

local function setting_true(key)
    return G_reader_settings and type(G_reader_settings.isTrue) == "function"
        and G_reader_settings:isTrue(key) or false
end

local function active_ui()
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        return ReaderUI.instance
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then return FileManager.instance end
    if ok_reader and ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    return nil
end

local function device_listener()
    local ui = active_ui()
    return ui and ui.devicelistener or nil
end

local function native_call(name, ...)
    local listener = device_listener()
    local method = listener and listener[name] or nil
    if type(method) ~= "function" then return false, "KOReader 方向控制暂时不可用" end
    local ok, result = pcall(method, listener, ...)
    if not ok then
        logger.warn("[MiuRead][Orientation] native action failed", name, tostring(result))
        return false, "KOReader 方向控制执行失败"
    end
    return result == false and false or true
end

-- KOReader only gained the explicit onSetLockGSensor(flag) action recently.
-- Older releases expose onLockGSensor(), which toggles the persisted setting.
-- Normalize both APIs to an idempotent setter so MiuRead works with either one.
local function set_native_gsensor_lock(target)
    target = target == true
    if setting_true("input_lock_gsensor") == target then return true end

    local listener = device_listener()
    if not listener then return false, "KOReader 方向控制暂时不可用" end

    local ok, message
    if type(listener.onSetLockGSensor) == "function" then
        ok, message = native_call("onSetLockGSensor", target)
    elseif type(listener.onLockGSensor) == "function" then
        ok, message = native_call("onLockGSensor")
    else
        return false, "当前 KOReader 版本不支持方向锁定"
    end
    if not ok then return false, message end

    if setting_true("input_lock_gsensor") ~= target then
        logger.warn("[MiuRead][Orientation] lock state unchanged", "target=", tostring(target))
        return false, "KOReader 方向锁定状态未生效"
    end
    return true
end

-- KOReader's native "GSensor lock" only locks the orientation family: it
-- still allows Portrait <-> Inverted Portrait and Landscape <-> Inverted
-- Landscape. MiuRead's "lock current orientation" promises a complete freeze,
-- so suspend accelerometer rotation events instead.
local function set_gsensor_events(enabled)
    enabled = enabled == true
    local target_ignored = not enabled
    if setting_true("input_ignore_gsensor") == target_ignored then return true end

    local ok, message = native_call("onToggleGSensor")
    if not ok then return false, message end
    if setting_true("input_ignore_gsensor") ~= target_ignored then
        logger.warn("[MiuRead][Orientation] accelerometer state unchanged",
            "enabled=", tostring(enabled))
        return false, "KOReader 自动旋转状态未生效"
    end
    return true
end

local function set_orientation_locked(target)
    return set_gsensor_events(target ~= true)
end

function M.has_gsensor()
    if not Device or type(Device.hasGSensor) ~= "function" then return false end
    local ok, value = pcall(Device.hasGSensor, Device)
    return ok and value == true
end

function M.rotation_mode()
    if not Screen or type(Screen.getRotationMode) ~= "function" then return nil end
    local ok, value = pcall(Screen.getRotationMode, Screen)
    return ok and value or nil
end

function M.rotation_label()
    local mode = M.rotation_mode()
    if not Screen then return "未知" end
    if mode == Screen.DEVICE_ROTATED_CLOCKWISE then return "向右横屏" end
    if mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN then return "倒置竖屏" end
    if mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then return "向左横屏" end
    return "竖屏"
end

-- Compatibility name retained for existing MiuRead UI callers.
function M.is_session_locked()
    return setting_true("input_ignore_gsensor")
end

function M.status_label()
    if not M.has_gsensor() then return M.rotation_label() end
    if setting_true("input_ignore_gsensor") then return "已锁定 · " .. M.rotation_label() end
    if setting_true("input_lock_gsensor") then
        return "KOReader 已限制横竖屏 · " .. M.rotation_label()
    end
    return "自动旋转"
end

function M.icon_key()
    if setting_true("input_lock_gsensor") or setting_true("input_ignore_gsensor") then
        return "orientation-lock"
    end
    return "orientation-auto"
end

function M.lock_current()
    if not M.has_gsensor() then return false, "当前设备没有自动旋转传感器" end
    local ok, message = set_orientation_locked(true)
    return ok, ok and "已使用 KOReader 锁定当前方向" or message
end

function M.follow_koreader()
    if not M.has_gsensor() then return true, "当前设备使用手动方向" end
    if setting_true("input_ignore_gsensor") then
        local ok, message = set_orientation_locked(false)
        if not ok then return false, message end
    end
    if setting_true("input_lock_gsensor") then
        return true, "已跟随 KOReader；当前保留横竖屏限制"
    end
    return true, "已跟随 KOReader 自动旋转"
end

function M.enable_auto_rotation()
    if not M.has_gsensor() then return false, "当前设备没有自动旋转传感器" end
    if setting_true("input_lock_gsensor") then
        local ok, message = set_native_gsensor_lock(false)
        if not ok then return false, message end
    end
    if setting_true("input_ignore_gsensor") then
        local ok, message = set_gsensor_events(true)
        if not ok then return false, message end
    end
    return true, "已通过 KOReader 恢复自动旋转"
end

function M.set_fixed(mode)
    if mode == nil then return false, "无效的屏幕方向" end
    local ui = active_ui()
    if not (ui and type(ui.handleEvent) == "function") then
        return false, "KOReader 当前无法切换屏幕方向"
    end
    local ok, err = pcall(ui.handleEvent, ui, Event:new("SetRotationMode", mode))
    if not ok then
        logger.warn("[MiuRead][Orientation] SetRotationMode failed", tostring(err))
        return false, "屏幕方向切换失败"
    end
    if M.has_gsensor() then
        local locked, message = set_orientation_locked(true)
        if not locked then return false, message end
    end
    return true, M.has_gsensor() and "已通过 KOReader 固定屏幕方向" or "已切换屏幕方向"
end

function M.set_portrait()
    return M.set_fixed(Screen and Screen.DEVICE_ROTATED_UPRIGHT or 0)
end

function M.set_landscape()
    return M.set_fixed(Screen and Screen.DEVICE_ROTATED_CLOCKWISE or 1)
end

function M.toggle_session_lock()
    if not M.has_gsensor() then return false, "当前设备没有自动旋转传感器" end
    local target = not setting_true("input_ignore_gsensor")
    local ok, message = set_orientation_locked(target)
    if not ok then return false, message end
    return true, target and "已使用 KOReader 锁定当前方向" or "已解除方向锁定"
end

-- Older builds restored a private MiuRead session lock when leaving the desktop.
-- There is no private lock anymore, so leaving MiuRead must not alter KOReader.
function M.release_session(_reason)
    return false
end

return M
