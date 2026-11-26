-- Check shelf membership only to reconcile an uncertain operation.
-- The caller persists uncertainty before invoking this worker so cancellation
-- and process loss can only lead to a later read, never automatic resubmission.
local M={}

function M.run(api,id,desired,verify_only)
    assert(type(desired)=="boolean","shelf target must be boolean")
    if type(api.scope)=="function" then api=api:scope() end
    if verify_only then
        local ok,present=pcall(api.book_on_shelf,api,id)
        if not ok or type(present)~="boolean" then
            return {state="unconfirmed",stage="membership",error=ok and "shelf membership is unknown" or tostring(present)}
        end
        return {state=present==desired and "verified" or "mismatch",present=present}
    end
    local writer=type(api.for_channel)=="function" and api:for_channel("eink") or api
    local mutate=desired and writer.add_to_shelf or writer.remove_from_shelf
    local sent,value=pcall(mutate,writer,id)
    if sent and type(value)=="table" and require("miuread.eink_client").write_succeeded(value) then
        return {state="verified",stage="write",present=desired}
    end
    local write_error=not sent and tostring(value) or nil
    if not desired and write_error and (write_error:find("[MiuReadShelfPreflight]",1,true)
        or write_error:find("E-Ink 来源暂不可用",1,true)) then
        -- Transport-level native cooldown is also a preflight block: no
        -- DELETE was dispatched. Offer authorization, not an upload retry.
        local authorization_error=write_error:find("[MiuReadShelfPreflight]",1,true)
            and write_error or "[MiuReadShelfAuthorization] E-Ink 书架管理凭据暂不可用，请重新授权"
        return {state="blocked",stage="credentials",error=authorization_error}
    end
    local ok,last_present=pcall(api.book_on_shelf,api,id)
    local read_error=not ok and tostring(last_present) or nil
    if not ok or type(last_present)~="boolean" then last_present=nil end
    if last_present==desired then
        return {state="verified",stage="readback",present=last_present,write_error=write_error}
    end
    return {state="unconfirmed",stage="readback",present=last_present,write_error=write_error,read_error=read_error,
        error=write_error or read_error or "云端尚未确认书架变更结果"}
end

return M
