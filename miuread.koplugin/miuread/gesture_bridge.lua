-- Let KOReader Gesture Manager actions remain available while a MiuRead
-- fullscreen page or dialog is the topmost widget.
--
-- We deliberately dispatch only zones owned by Gesture Manager. Forwarding
-- every FileManager/ReaderUI zone would also trigger native page swipes and
-- menu fallbacks underneath MiuRead, which would make the two UIs fight over
-- the same gesture.
local logger = require("logger")
local UIManager = require("ui/uimanager")

local Bridge = {}
local dispatching = false

local function active_ui()
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        return ReaderUI.instance
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then
        return FileManager.instance
    end
    return nil
end

local function gesture_manager(ui)
    if not ui then return nil end
    local ok_direct, direct = pcall(function() return ui.gestures end)
    if ok_direct and type(direct) == "table" and type(direct.gestures) == "table" then
        return direct
    end
    -- Keep compatibility with builds where plugins are attached under a
    -- different field name.
    for _, value in pairs(ui) do
        if type(value) == "table" and value.name == "gestures"
            and type(value.gestures) == "table" then
            return value
        end
    end
    return nil
end

local function stabilize_miuread_root()
    local function settle()
        local session = rawget(_G, "__MIUREAD_HOME_SESSION")
        if type(session) ~= "table" or session.suppressed == true
            or session.native_visit == true or session.exiting == true
            or UIManager._exit_code ~= nil then return end
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then return end
        local ok_home, HomeView = pcall(require, "miuread.home_view")
        if ok_home and HomeView and HomeView.is_shown and HomeView.is_shown() then
            HomeView.raise()
        end
    end
    UIManager:nextTick(settle)
    UIManager:scheduleIn(.12, settle)
end

local function configured(gm, id, ges)
    if type(id) ~= "string" then return false end
    if id == "multiswipe" then
        if gm.multiswipes_enabled == false then return false end
        local directions = ges and ges.multiswipe_directions
        if not directions or directions == "" then return false end
        local safe = directions:gsub(" ", "_")
        return gm.gestures["multiswipe_" .. safe] ~= nil
    end
    -- The Gesture Manager also registers helper pan/pan_release zones for
    -- swipes. Those helpers merely suppress native panning and are not user
    -- actions, so only exact configured gesture ids are forwarded.
    return gm.gestures[id] ~= nil
end

function Bridge.dispatch(ges, options)
    if dispatching or type(ges) ~= "table" then return false end
    local ui = active_ui()
    local gm = gesture_manager(ui)
    local zones = ui and ui._ordered_touch_zones
    if not gm or type(zones) ~= "table" then return false end

    dispatching = true
    for _, zone in ipairs(zones) do
        local def = zone and zone.def
        local id = def and def.id
        local allowed = true
        if type(options) == "table" and type(options.id_filter) == "function" then
            local ok_filter, value = pcall(options.id_filter, id)
            allowed = ok_filter and value == true
        end
        if allowed and configured(gm, id, ges) and zone.gs_range and type(zone.handler) == "function" then
            local ok_match, matches = pcall(zone.gs_range.match, zone.gs_range, ges)
            if ok_match and matches then
                local ok_action, consumed = xpcall(function()
                    return zone.handler(ges)
                end, debug.traceback)
                dispatching = false
                if not ok_action then
                    logger.warn("[MiuRead][GestureBridge] action failed", tostring(id), tostring(consumed))
                    return false
                end
                if consumed then
                    logger.info("[MiuRead][GestureBridge] KOReader gesture handled", tostring(id))
                    -- A configured action may create or reorder native widgets.
                    -- Keep MiuRead above non-modal FileManager pages, while
                    -- leaving ReaderUI and modal KOReader dialogs untouched.
                    stabilize_miuread_root()
                    return true
                end
                return false
            end
        end
    end
    dispatching = false
    return false
end


function Bridge.dispatchEdge(ges)
    return Bridge.dispatch(ges, {
        id_filter = function(id)
            if type(id) ~= "string" then return false end
            return id:find("_corner", 1, true) ~= nil
                or id:find("_edge_", 1, true) ~= nil
        end,
    })
end

function Bridge.handle(base, widget, event)
    if event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local gesture = ges and ges.ges
        local pointer_action = gesture == "tap" or gesture == "touch"
            or gesture == "hold" or gesture == "hold_release"
            or gesture == "double_tap" or gesture == "two_finger_tap"
        -- Buttons, cards and title-bar controls on the visible MiuRead surface
        -- always get pointer input first. Temporarily disable the fullscreen
        -- propagation fence while asking the widget tree whether it actually
        -- consumed the gesture; otherwise that fence would make every blank
        -- tap look consumed and KOReader corner gestures could never run.
        if pointer_action then
            local old_stop = widget.stop_events_propagation
            if old_stop == true then widget.stop_events_propagation = false end
            local ok_base, consumed = xpcall(function()
                return base.handleEvent(widget, event)
            end, debug.traceback)
            widget.stop_events_propagation = old_stop
            if not ok_base then
                logger.warn("[MiuRead][GestureBridge] visible surface handler failed", tostring(consumed))
                return old_stop == true
            end
            if consumed then return true end
            if Bridge.dispatch(ges) then return true end
            -- A fullscreen MiuRead surface still owns otherwise-unused taps;
            -- only configured Gesture Manager actions are allowed through.
            if old_stop == true then return true end
            return consumed
        end
        if Bridge.dispatch(ges) then return true end
    end
    return base.handleEvent(widget, event)
end

return Bridge
