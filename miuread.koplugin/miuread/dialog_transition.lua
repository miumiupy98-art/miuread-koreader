local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {generation = 0}

local function copied(region)
    if not region then return nil end
    if type(region.copy) == "function" then
        local ok, value = pcall(region.copy, region)
        if ok and value then return value end
    end
    return region
end

function M.cancel_pending()
    M.generation = (tonumber(M.generation) or 0) + 1
    return M.generation
end

-- CloseWidget is emitted before UIManager has actually removed the old widget.
-- First repaint the whole old frame on the next UI turn, then reopen the parent
-- after one short paint window. A final repaint of the same old frame makes the
-- newly exposed parent/new smaller dialog participate in the refresh as well.
-- The generation guard prevents a delayed parent callback from reopening after
-- the user has already navigated somewhere else.
function M.after_close(region, action, label)
    local token = M.cancel_pending()
    local dirty = copied(region)
    UIManager:nextTick(function()
        if dirty then UIManager:setDirty("all", "ui", dirty) end
        if type(action) ~= "function" then return end
        UIManager:scheduleIn(.05, function()
            if token ~= M.generation then return end
            local ok, err = pcall(action)
            if not ok then
                logger.warn("[MiuRead][DialogTransition] action failed", tostring(label or "dialog"), tostring(err))
                return
            end
            if dirty then
                UIManager:nextTick(function()
                    UIManager:setDirty("all", "ui", dirty)
                end)
            end
        end)
    end)
    return token
end

return M
