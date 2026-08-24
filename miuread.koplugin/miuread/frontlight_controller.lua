local Device = require("device")
local logger = require("logger")

local M = {}
local warned = {}

local function warn_once(key, ...)
    if warned[key] then return end
    warned[key] = true
    logger.warn(...)
end

local function round(value)
    value = tonumber(value)
    if not value then return nil end
    return math.floor(value + .5)
end

local function clamp(value, minimum, maximum)
    value = tonumber(value)
    if not value then return nil end
    return math.max(minimum, math.min(maximum, value))
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

local function has_frontlight()
    if not Device or type(Device.hasFrontlight) ~= "function" then return false end
    local ok, value = pcall(Device.hasFrontlight, Device)
    return ok and value == true
end

local function power_device()
    if not has_frontlight() or type(Device.getPowerDevice) ~= "function" then return nil end
    local ok, powerd = pcall(Device.getPowerDevice, Device)
    return ok and powerd or nil
end

local function valid_range(minimum, maximum)
    minimum, maximum = tonumber(minimum), tonumber(maximum)
    if not (minimum and maximum) or maximum <= minimum then return nil, nil end
    return minimum, maximum
end

local function should_log(interaction)
    return interaction ~= "drag"
end

function M.power_device()
    return power_device()
end

function M.has_frontlight()
    return has_frontlight()
end

function M.brightness_state()
    local powerd = power_device()
    if not powerd then return nil end
    local minimum, maximum = valid_range(powerd.fl_min, powerd.fl_max)
    if not minimum then return nil end

    local current
    if type(powerd.frontlightIntensity) == "function" then
        local ok, value = pcall(powerd.frontlightIntensity, powerd)
        if ok then current = tonumber(value) end
    end
    current = current or tonumber(powerd.fl_intensity) or tonumber(powerd.hw_intensity)
    current = clamp(current or minimum, minimum, maximum)

    local enabled
    if type(powerd.isFrontlightOn) == "function" then
        local ok, value = pcall(powerd.isFrontlightOn, powerd)
        if ok then enabled = value == true end
    end
    if enabled == nil then enabled = current > minimum end

    return {
        min = minimum,
        max = maximum,
        value = current,
        enabled = enabled,
    }
end

function M.warmth_state()
    local powerd = power_device()
    local has_natural = type(Device.hasNaturalLight) == "function" and Device:hasNaturalLight()
    if not (powerd and has_natural) then return nil end

    local minimum, maximum = valid_range(powerd.fl_warmth_min, powerd.fl_warmth_max)
    if not minimum then return nil end
    if type(powerd.toNativeWarmth) ~= "function" then
        warn_once("warmth_conversion", "[MiuRead][Frontlight] KOReader warmth conversion unavailable")
        return nil
    end

    local ko_value
    if type(powerd.frontlightWarmth) == "function" then
        local ok, value = pcall(powerd.frontlightWarmth, powerd)
        if ok then ko_value = tonumber(value) end
    end
    ko_value = ko_value or tonumber(powerd.fl_warmth)
    if ko_value == nil then return nil end

    local ok, native = pcall(powerd.toNativeWarmth, powerd, ko_value)
    if not ok or tonumber(native) == nil then
        warn_once("warmth_readback", "[MiuRead][Frontlight] KOReader native warmth readback failed", tostring(native))
        return nil
    end
    native = clamp(tonumber(native), minimum, maximum)

    return {
        min = minimum,
        max = maximum,
        value = native,
        ko_value = ko_value,
    }
end

function M.set_brightness(value, source, interaction, listener_override)
    local before = M.brightness_state()
    if not before then return false, nil end
    local listener = listener_override or device_listener()
    if not (listener and type(listener.onSetFlIntensity) == "function") then return false, before end

    local target = round(clamp(tonumber(value) or before.value, before.min, before.max))
    local ok, err = pcall(listener.onSetFlIntensity, listener, target)
    if not ok then
        logger.warn("[MiuRead][Frontlight] native intensity failed", tostring(err))
        return false, before
    end

    local after = M.brightness_state() or before
    if should_log(interaction) then
        logger.info("[MiuRead][Frontlight] brightness",
            "source=", tostring(source or "unknown"),
            "requested=", tostring(target),
            "before=", tostring(round(before.value) or "-"),
            "after=", tostring(round(after.value) or "-"),
            "range=", tostring(round(before.min) or "-") .. "-" .. tostring(round(before.max) or "-"))
    end
    return true, after
end

function M.adjust_brightness(delta, source, interaction, listener_override)
    local state = M.brightness_state()
    if not state then return false, nil end
    -- One tap equals one KOReader/device-native level. Do not compress a 48- or
    -- 255-level device into an artificial 25-step MiuRead scale.
    local target = state.value + (tonumber(delta) or 0)
    return M.set_brightness(target, source, interaction, listener_override)
end

function M.toggle(source, listener_override)
    local before = M.brightness_state()
    local listener = listener_override or device_listener()
    if not (before and listener and type(listener.onToggleFrontlight) == "function") then return false, before end
    local ok, err = pcall(listener.onToggleFrontlight, listener)
    if not ok then
        logger.warn("[MiuRead][Frontlight] native toggle failed", tostring(err))
        return false, before
    end
    local after = M.brightness_state() or before
    logger.info("[MiuRead][Frontlight] toggle",
        "source=", tostring(source or "unknown"),
        "before=", tostring(before.enabled == true),
        "after=", tostring(after.enabled == true),
        "brightness=", tostring(round(after.value) or "-"))
    return true, after
end

function M.set_warmth(value, source, interaction, listener_override)
    local before = M.warmth_state()
    if not before then return false, nil end
    local powerd = power_device()
    if not powerd then return false, before end

    local target = round(clamp(tonumber(value) or before.value, before.min, before.max))
    local applied = false
    local path = "powerd"

    -- Keep the exact same value flow as KOReader's FrontLightWidget:
    -- native/display level -> KOReader 0..100 warmth -> PowerD:setWarmth().
    -- This avoids DeviceListener's historical 0..100 clamp truncating devices
    -- whose native warmth range is not 0..100.
    if type(powerd.fromNativeWarmth) == "function" and type(powerd.setWarmth) == "function" then
        local ok_convert, ko_target = pcall(powerd.fromNativeWarmth, powerd, target)
        ko_target = ok_convert and tonumber(ko_target) or nil
        if ko_target ~= nil then
            local ok_set, err = pcall(powerd.setWarmth, powerd, ko_target)
            if not ok_set then
                logger.warn("[MiuRead][Frontlight] PowerD warmth failed", tostring(err))
                return false, before
            end
            applied = true
        else
            logger.warn("[MiuRead][Frontlight] native warmth conversion failed", tostring(ko_target))
        end
    end

    -- Compatibility fallback for older/custom KOReader builds.
    if not applied then
        path = "listener"
        local listener = listener_override or device_listener()
        if not (listener and type(listener.onSetFlWarmth) == "function") then return false, before end
        local ok, err = pcall(listener.onSetFlWarmth, listener, target)
        if not ok then
            logger.warn("[MiuRead][Frontlight] listener warmth failed", tostring(err))
            return false, before
        end
    end

    -- Always reflect the level KOReader actually retained after conversion/rounding.
    local after = M.warmth_state() or before
    if should_log(interaction) then
        logger.info("[MiuRead][Frontlight] warmth",
            "source=", tostring(source or "unknown"),
            "path=", path,
            "requested_native=", tostring(target),
            "before_native=", tostring(round(before.value) or "-"),
            "after_native=", tostring(round(after.value) or "-"),
            "ko_value=", tostring(round(after.ko_value) or "-"),
            "range=", tostring(round(before.min) or "-") .. "-" .. tostring(round(before.max) or "-"))
    end
    return true, after
end

function M.adjust_warmth(delta, source, interaction, listener_override)
    local state = M.warmth_state()
    if not state then return false, nil end
    local target = state.value + (tonumber(delta) or 0)
    return M.set_warmth(target, source, interaction, listener_override)
end

return M
