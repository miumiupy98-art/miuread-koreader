-- Native writes are isolated from Api's read fallback and auth retry policy.
local Client=require("miuread.shelf_client")
local Protocol=require("miuread.readtime_protocol")
local Http=require("miuread.http")
local Log=require("miuread.diagnostic_log")
local M={}
local BASE="https://i.weread.qq.com"
function M.position(value)
    for _=1,4 do
        if type(value)~="table" then return nil end
        local uid=value.chapterUid or value.chapter_uid
        local offset=tonumber(value.chapterOffset or value.chapter_offset)
        if uid~=nil and offset then
            return {chapter_uid=tostring(uid),chapter_offset=offset,
                reading_seconds=tonumber(value.readingTime or value.recordReadingTime)}
        end
        value=value.book or value.data or value.result
    end
end
function M.prepare(native,book_id,rows)
    local config=native:request("GET","/config",{token=1},"reading_time_config")
    local feature=native:request("GET","/feature",{synckey=0},"reading_time_feature")
    if native.before_request then native.before_request("reading_time_signature") end
    local raw=type(feature.feature)=="table" and feature.feature.guest_token or nil
    local parameters={feature_token_present=type(raw)=="string" and raw~="",
        feature_token_type=type(raw),config_token_present=type(config.token)=="string" and config.token~=""}
    if native.on_readtime_parameters then native.on_readtime_parameters(parameters) end
    local token,source=Protocol.guest_token(feature)
    parameters.token_source=source
    if native.on_readtime_parameters then native.on_readtime_parameters(parameters) end
    local progress=native:request("GET","/book/getProgress",{bookId=book_id},"reading_time_position_before")
    local before=M.position(progress)
    if not before then error("reading_time_position_unavailable",0) end
    if native.on_readtime_server_clock then
        native.on_readtime_server_clock(progress.timestamp,config.server_time_max_offset
            or (type(config.config)=="table" and config.config.server_time_max_offset))
    end
    local credentials=Client.credentials(native.store:auth())
    if not credentials then error("E-Ink 阅读时间同步需要客户端授权",0) end
    local now,random=os.time(),math.random(0,999)
    local body=Protocol.batch(credentials,book_id,rows,token,config.token,now,random,
        {timestamp=math.floor(Log.now()*1000),random=math.random(0,999)})
    return {body=body,credentials=credentials,before=before,token_source=source}
end
function M.send(http,prepared,before_dispatch)
    -- Persist dispatch ownership before entering HTTP. No renewal, automatic
    -- transport retry or channel fallback is allowed after this boundary.
    if before_dispatch and before_dispatch()~=true then return {state="pending",dispatched=false,error="claim_failed"} end
    local options=Client.request_options(prepared.credentials,{5,20})
    local ok,value=pcall(http.post_json,http,BASE.."/book/batchUploadProgress",prepared.body,options)
    if ok and type(value)=="table" and (value.succ==true or tonumber(value.succ)==1) then
        return {state="confirmed",dispatched=true}
    end
    -- Even an HTTP error can follow a committed write. Keep a separate unknown
    -- state; neither restarting nor reconnecting may replay these seconds.
    local text=not ok and tostring(value) or ""
    local limited=not ok and Http.rate_limit_details(value)
    local code=type(value)=="table" and tonumber(value.errCode or value.errcode)
        or tonumber(text:match("error_code=(%-?%d+)"))
    return {state="unknown",dispatched=true,error=limited and "rate_limited"
        or (not ok and Http.is_auth_error(value) and "authentication")
        or (ok and "unconfirmed_response" or "request_failed"),
        retry_after=limited and limited.wait_seconds,
        code=limited and limited.code or code,status=tonumber(text:match("HTTP (%d+)"))}
end
return M
