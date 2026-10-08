-- Optional native credentials for shelf deletion. QR transport follows:
-- https://github.com/teng-lin/weread-omni/blob/main/src/auth/qrlogin.ts
-- The existing Auth controller owns QR UI, cancellation and commit retries.
local U=require("miuread.util")
local Protocol=require("miuread.protocol")
local Http=require("miuread.http")
local M={}
local BASE="https://i.weread.qq.com"

local function account(auth)
    local vid=tostring((auth.account or {}).vid or "")
    if vid=="" then vid=tostring((auth.cookies or {}).wr_vid or "") end
    return vid,tostring(auth.login_session_id or "")
end
local function nonempty(value) return type(value)=="string" and value~="" end
function M.credentials(auth)
    local value=type(auth.native_shelf)=="table" and auth.native_shelf or {}
    local vid=account(auth)
    if vid~="" and tostring(value.vid or "")==vid and nonempty(value.accessToken)
        and nonempty(value.refreshToken) and nonempty(value.deviceId) then return U.copy(value) end
end
function M.headers(credentials)
    local headers={baseapi="30",appver="2.1.2.10245900",basever="2.1.2.10245900",osver="11",channelId="900",
        ["User-Agent"]="WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)"}
    if credentials then headers.vid=credentials.vid; headers.accessToken=credentials.accessToken end
    return headers
end
function M.request_options(credentials,timeout)
    return {auth=false,redirects=0,retries=0,rate_limit_retries=0,rate_limit_fail_fast=true,
        timeout=timeout or {5,10},headers=M.headers(credentials)}
end
local function request(http,method,url,body,opt)
    local ok,value
    if method=="POST" then ok,value=pcall(http.post_json,http,url,body,opt)
    else ok,value=pcall(http.get_json,http,url,opt) end
    if not ok then
        -- QR IDs, authorization codes and tokens must never enter UI/log errors.
        local status=tostring(value):match("HTTP (%d+)")
        local code=tonumber(Http.auth_error_code(value))
            or tonumber(tostring(value):lower():match('"errcode"%s*:%s*(%-?%d+)'))
        error("客户端授权请求失败"..(status and (" HTTP "..status) or "")
            ..(code and (" error_code="..tostring(code)) or ""))
    end
    if type(value)~="table" then error("客户端授权响应无效") end
    return value
end
local function digits(count)
    local out={}
    for i=1,count do out[i]=tostring(math.random(0,i==1 and 8 or 9)) end
    return table.concat(out)
end
local function login_body(device_id)
    local timestamp=os.time()*1000
    local random=math.random(1,999)
    return {deviceId=device_id,deviceName="BOOX",deviceType=3,timestamp=timestamp,random=random,trackId="",
        signature=require("miuread.digests").sha256(tostring(timestamp)..device_id..tostring(random))}
end
local function tokens(data,previous)
    local vid=tostring(data.vid or (previous or {}).vid or "")
    local refresh=data.refreshToken or (previous or {}).refreshToken
    if vid=="" or not nonempty(data.accessToken) or not nonempty(refresh) then
        error("客户端授权未返回完整登录凭证")
    end
    return {vid=vid,accessToken=data.accessToken,refreshToken=refresh,deviceId=previous.deviceId}
end

function M.refresh(http,store)
    local auth=store:auth()
    local credential=M.credentials(auth)
    if not credential then error("书架管理尚未授权") end
    local body=login_body(credential.deviceId)
    body.refreshToken=credential.refreshToken; body.inBackground=0; body.kickType=1; body.refCgi=""
    local data=request(http,"POST",BASE.."/login",body,M.request_options())
    local renewed=tokens(data,credential)
    if renewed.vid~=credential.vid then error("客户端续期返回了其他账号，已忽略") end
    local current=store:auth()
    local vid,session=account(auth)
    local current_vid,current_session=account(current)
    if current_vid~=vid or current_session~=session
        or tonumber(current.auth_revision or 0)~=tonumber(auth.auth_revision or 0) then
        error("登录账号或凭据已变更，已忽略客户端续期")
    end
    current.native_shelf=renewed
    local saved=store:save_auth(current,{expected_revision=tonumber(auth.auth_revision or 0) or 0})
    if saved~=true then error("客户端续期凭证未保存，请重试授权") end
    return renewed
end

local Client={}; Client.__index=Client
function M.new(http,store)
    local auth=store:auth()
    local vid,session=account(auth)
    if vid=="" or session=="" then error("请先登录微信读书，再授权书架管理") end
    local previous=M.credentials(auth)
    return setmetatable({http=http,store=store,vid=vid,session=session,
        device_id=previous and previous.deviceId or "eink334691225"..digits(19)},Client)
end
function Client:uid()
    local ticket=request(self.http,"GET",BASE.."/wxticket?nonceStr=weread",nil,M.request_options())
    if not nonempty(ticket.signature) or not tonumber(ticket.timeStamp) then error("客户端二维码票据无效") end
    local url="https://open.weixin.qq.com/connect/sdk/qrconnect?appid=wxab9b71ad2b90ff34&noncestr=weread"
        .."&timestamp="..Protocol.escape(ticket.timeStamp).."&scope="..Protocol.escape("snsapi_userinfo,snsapi_timeline,snsapi_friend")
        .."&signature="..Protocol.escape(ticket.signature)
    local data=request(self.http,"GET",url,nil,M.request_options())
    if tonumber(data.errcode)~=0 or not nonempty(data.uuid) then error("微信未返回客户端授权二维码") end
    self.last=nil
    return data.uuid
end
function Client:qr_url(uid)
    return "https://open.weixin.qq.com/connect/confirm?uuid="..Protocol.escape(uid)
end
function Client:poll(uid)
    local url="https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid="..Protocol.escape(uid)
    if self.last then url=url.."&last="..Protocol.escape(self.last) end
    local data=request(self.http,"GET",url,nil,M.request_options(nil,{3,9}))
    local code=tonumber(data.wx_errcode)
    if code==405 then
        if not nonempty(data.wx_code) then error("微信确认未返回客户端授权码") end
        return {succeed=true,wx_code=data.wx_code}
    end
    if code==402 then return {logicCode="LOGIN_TIMEOUT"} end
    if code~=404 and code~=408 then return {logicCode="LOGIN_DECLINED"} end
    self.last=code
    return {}
end
function Client:validate_commit(auth)
    local current_vid,current_session=account(self.store:auth())
    local vid,session=account(auth)
    if current_vid~=self.vid or current_session~=self.session or vid~=self.vid or session~=self.session
        or not M.credentials(auth) then return false,"当前账号已变更，请重新授权书架管理" end
    return true
end
function Client:persisted_matches(expected,persisted)
    local a=M.credentials(expected); local b=M.credentials(persisted)
    if not a or not b then return false,"客户端凭据未保存" end
    for _,key in ipairs({"vid","accessToken","refreshToken","deviceId"}) do
        if a[key]~=b[key] then return false,"客户端凭据保存不完整" end
    end
    return true
end
function Client:finish(data)
    local current=self.store:auth()
    local vid,session=account(current)
    if vid~=self.vid or session~=self.session then error("当前账号已变更，请重新授权书架管理") end
    if not nonempty(data.wx_code) then error("客户端授权码缺失") end
    local body=login_body(self.device_id)
    body.code=data.wx_code; body.appFirstInstall=1; body.installId="eink31"..digits(26)
    body.isAutoLogout=0; body.isFromQrcode=1
    local result=request(self.http,"POST",BASE.."/login",body,M.request_options())
    local credential=tokens(result,{deviceId=self.device_id})
    if credential.vid~=self.vid then error("扫码账号与觅阅当前账号不同，请使用同一账号授权") end
    local shelf=request(self.http,"GET",BASE.."/shelf/sync",nil,M.request_options(credential))
    if type(shelf.books)~="table" then error("客户端书架验证失败，未保存授权") end
    -- Merge with the current Web session, allowing ordinary cookie renewal
    -- during the QR scan without overwriting it with an older snapshot.
    current=self.store:auth()
    current.native_shelf=credential
    local valid,err=self:validate_commit(current)
    if not valid then error(err) end
    return current,tostring((current.account or {}).name or self.vid)
end
return M
