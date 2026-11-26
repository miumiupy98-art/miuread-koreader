local UIManager = require("ui/uimanager")
local logger = require("logger")
local Geometry = require("miuread.modal_geometry")
local Geom = require("ui/geometry")
local Screen = require("device").screen

local M = {generation = 0}

function M.cancel_pending()
    M.generation = M.generation + 1
    return M.generation
end

-- CloseWidget can run before the widget is removed from UIManager's stack.
-- Never paint the retired window in place: ask UIManager to repaint the
-- CURRENT stack on the next turn.  "all" requests layout paint, whereas
-- nil requests waveform only and may leave an old frame behind.
function M.restore(region, mode)
    local safe = Geometry.rect(region, 3, Screen:getWidth(), Screen:getHeight())
    if safe then
        UIManager:setDirty("all", mode or "ui", Geom:new(safe))
    end
end

-- The newly revealed dialog may be larger than the retired one.  Include its
-- frame only, not its full-screen gesture capture layer.
local function current_modal_frame()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local window = stack[i]
        local widget = window and window.widget
        if widget and not widget.invisible and not widget.toast
            and (widget._miuread_modal_surface==true or widget.modal==true) then
            local rect=widget.bubble_dimen or widget.popup_dimen or widget.frame_dimen or widget.panel_dimen
                or (widget.frame and widget.frame.dimen) or (widget.movable and widget.movable.dimen)
            rect=Geometry.rect(rect,0)
            if rect then return rect end
        end
    end
    return nil
end

function M.after_close(region, action, label)
    local token = M.cancel_pending()
    local old = Geometry.rect(region, 0)
    UIManager:nextTick(function()
        -- Never run a stale action after a newer explicit navigation.
        -- A newer modal may have superseded the pending action, but its
        -- appearance does not erase the old surface's physical ink pixels.
        -- Restore the retired frame even when the action is stale.
        M.restore(old)
        if token ~= M.generation then return end
        if type(action) ~= "function" then return end
        -- The next turn follows the retired widget's removal, not an
        -- arbitrary 40/50ms delay which varies across e-ink devices.
        UIManager:nextTick(function()
            if token ~= M.generation then return end
            local ok, err = pcall(action)
            if not ok then
                logger.warn("[MiuRead][DialogTransition] action failed", tostring(label or "dialog"), tostring(err))
            end
            -- New UI may be larger or smaller; its own show() dirties its
            -- complete frame. Repaint the OLD footprint on the current stack
            -- even if the action opened another dialog (and changed token).
            UIManager:nextTick(function()
                -- Native dialogs often only know their frame origin after paint.
                UIManager:setDirty("all",function()
                    local region=Geometry.rect(Geometry.union(old,current_modal_frame()),3,
                        Screen:getWidth(),Screen:getHeight())
                    if region then return "ui",Geom:new(region) end
                end)
            end)
        end)
    end)
    return token
end

return M
