-- Offline download tasks removed. Stream reading builds single-chapter EPUBs on demand.
local DownloadTask = {}
DownloadTask.__index = DownloadTask

local function noop() end
local function noop_false() return false end
local function noop_true() return true end
local function noop_nil() return nil end
local function noop_descriptor() return nil end

function DownloadTask:new(_store)
    return setmetatable({}, self)
end

DownloadTask.set_backgrounded = noop
DownloadTask.set_network_mode = function() return true end
DownloadTask.dismiss_network_suggestion = noop
DownloadTask.is_paused = noop_false
DownloadTask.pause = noop_true
DownloadTask.resume = noop_true
DownloadTask.on_suspend = noop_true
DownloadTask.on_resume = noop_true
DownloadTask.stop_for_foreground = noop_false
DownloadTask.last_state = noop_nil
DownloadTask.descriptor = noop_descriptor
DownloadTask.available = noop_false
DownloadTask.busy = noop_false
DownloadTask.cancel = noop
DownloadTask.attach = function() return false, "download disabled" end
DownloadTask.start = function() return false, "download disabled" end

return DownloadTask
