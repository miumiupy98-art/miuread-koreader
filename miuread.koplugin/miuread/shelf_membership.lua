-- One non-retrying write, followed by authoritative membership checks.
-- The caller persists uncertainty before invoking this worker so cancellation
-- and process loss can only lead to a later read, never automatic resubmission.
local M={}

function M.run(api,id,desired,verify_only)
    assert(type(desired)=="boolean","shelf target must be boolean")
    local read,present=pcall(api.book_on_shelf,api,id)
    if not read or type(present)~="boolean" then
        local message=not read and tostring(present) or "shelf membership is unknown"
        return {state=verify_only and "unconfirmed" or "blocked",stage="membership",
            error=message,read_error=message}
    end
    if present==desired then return {state="verified",already=true,present=present} end
    if verify_only then return {state="mismatch",present=present} end
    local mutate=desired and api.add_to_shelf or api.remove_from_shelf
    local sent,value=pcall(mutate,api,id)
    local write_error=not sent and tostring(value) or nil
    if not desired and write_error and write_error:find("[MiuReadShelfPreflight]",1,true) then
        return {state="blocked",stage="credentials",present=present,error=write_error}
    end
    local read_error,last_present
    for _=1,2 do
        local ok,on_shelf=pcall(api.book_on_shelf,api,id)
        if ok and type(on_shelf)=="boolean" then last_present=on_shelf end
        if ok and on_shelf==desired then
            return {state="verified",stage="readback",already=false,present=on_shelf,
                write_error=write_error,read_error=read_error}
        end
        if not ok then read_error=tostring(on_shelf)
        elseif type(on_shelf)~="boolean" then read_error="shelf membership is unknown" end
    end
    return {state="unconfirmed",stage="readback",present=last_present,write_error=write_error,read_error=read_error,
        error=write_error or read_error or "云端尚未确认书架变更结果"}
end

return M
