local UIManager = require("ui/uimanager")
local logger = require("logger")
local DialogTransition = require("miuread.dialog_transition")

local M = {}

-- Keep MiuRead modal surfaces exclusive without touching full-screen views,
-- progress overlays or toasts. A new primary panel retires the previous primary
-- panel before it is submitted to UIManager.
function M.close_all(except)
    -- A fresh modal request invalidates any delayed parent reopen left by a
    -- previous navigation gesture.
    DialogTransition.cancel_pending()
    local closed = 0
    local seen = {}
    local stack = UIManager._window_stack or {}
    for index = #stack, 1, -1 do
        local window = stack[index]
        local widget = window and window.widget or nil
        if widget and widget ~= except and not seen[widget]
            and widget._miuread_modal_surface == true
            and widget._miuread_recovery_surface ~= true
            and UIManager:isWidgetShown(widget) then
            seen[widget] = true
            local ok, err
            if type(widget._close) == "function" then
                ok, err = pcall(widget._close, widget, nil, true)
            else
                ok, err = pcall(UIManager.close, UIManager, widget)
            end
            if ok then
                closed = closed + 1
            else
                logger.warn("[MiuRead][TransientGuard] close failed", tostring(widget.name or "widget"), tostring(err))
            end
        end
    end
    return closed
end

return M
