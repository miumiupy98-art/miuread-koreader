-- Actual user-position event sequence, independent of cloud write/readback IDs.
local M={}
local function val(value)
    return math.max(0,math.floor(tonumber(value) or 0))
end
function M.next_sequence(session)
    session=type(session)=="table" and session or {}
    local guard=type(session.progress_write_guard)=="table" and session.progress_write_guard or {}
    local pending=type(session.pending_progress)=="table" and session.pending_progress or {}
    local state=type(session.position_state)=="table" and session.position_state or {}
    local stored=type(state.local_position)=="table" and state.local_position or {}
    return math.max(val(session.local_position_event_seq),
        val(session.progress_verified_read_event_seq),
        val(guard.blocked_event_seq),val(pending.local_position_event_seq),
        val(stored.local_position_event_seq))+1
end
return M
