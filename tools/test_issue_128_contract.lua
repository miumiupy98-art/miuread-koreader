local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local auth=read("miuread.koplugin/miuread/auth.lua")

local function auth_request(url,stop)
    local start=assert(auth:find(url,1,true),"missing "..url)
    local finish=assert(auth:find(stop,start+1,true),"missing terminator for "..url)
    return auth:sub(start,finish)
end

local requests={
    uid_page=auth_request('BASE.."/r/weread-skills"','if code<200'),
    uid_json=auth_request('BASE.."/api/auth/getLoginUid"','self.jar=Cookies.session_absorb'),
    poll_json=auth_request('BASE.."/api/auth/getLoginInfo?uid="','self.jar=Cookies.session_absorb'),
}
for name,block in pairs(requests) do
    assert(block:find('rate_limit_scope="login"',1,true),name.." missing login scope")
    assert(block:find("pacing=false",1,true),name.." still paces")
    assert(block:find("rate_limit_retries=0",1,true),name.." retries rate limit")
    assert(block:find("rate_limit_fail_fast=true",1,true),name.." can block on cooldown")
end
assert(auth:find("login_rate_limit_message",1,true),"missing rate-limit message helper")
assert(auth:find('"登录请求暂时受限',1,true),"missing user-facing rate-limit message")

print("issue 128 contract: PASS")
