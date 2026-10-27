-- Common timing policy for every hibernated-download wake source.
-- There is one timer in Plugin; this module never touches UIManager.
local Policy={}
function Policy.next_delay(reason,attempt,cooldown_remaining,config)
    attempt=math.max(0,math.min(5,tonumber(attempt) or 0))
    local base=math.max(1,tonumber(config and config.DOWNLOAD_INTERACTION_RESUME_DELAY) or 2.5)
    local maximum=math.max(15,tonumber(config and config.DOWNLOAD_IDLE_PUMP_SECONDS) or 75)
    local interval=math.min(maximum,math.max(2,base*(2^attempt)))
    if reason=="network_offline" then interval=math.min(maximum,8) end
    local remaining=math.max(0,tonumber(cooldown_remaining) or 0)
    -- Cooldown is a *minimum* wait. Re-check no later than the idle interval
    -- for resumed UI sessions; do not count cooldown as a low-memory failure.
    if remaining>0 then interval=math.max(1,math.min(maximum,remaining)) end
    return interval
end
return Policy
