local Device=require("device")
local logger=require("logger")
local QRMessage=require("ui/widget/qrmessage")
local InputDialog=require("ui/widget/inputdialog")
local UIManager=require("ui/uimanager")
local Cookies=require("miuread.cookies")
local Protocol=require("miuread.protocol")
local Text=require("miuread.text")
local Util=require("miuread.util")
local _=Text.tr
local Auth={}; Auth.__index=Auth
local BASE="https://weread.qq.com"
local function header_value(headers,name)
    local target=name:lower()
    for k,v in pairs(headers or {}) do if type(k)=="string" and k:lower()==target then return v end end
end
function Auth:new(http,store,host)
    return setmetatable({
        http=http, store=store, host=host, generation=0, jar={}, dialog=nil,
        started=0, active=false, closing=false, poll_failures=0,
    },self)
end
local function merge_auth_headers(jar,vid,key)
    return {Accept="application/json, text/plain, */*",Referer=BASE.."/r/weread-skills",Cookie=Cookies.header(jar),["X-Vid"]=vid,["X-Skey"]=key}
end
function Auth:_close_dialog()
    if not self.dialog then return end
    local d=self.dialog; self.dialog=nil; self.closing=true; UIManager:close(d); self.closing=false
end
function Auth:cancel()
    self.generation=self.generation+1; self.active=false; self:_close_dialog(); self.jar={}; self.started=0
end
function Auth:_uid()
    local _,code,h=self.http:request{url=BASE.."/r/weread-skills",method="GET",auth=false,headers={Referer=BASE.."/"}}
    if code<200 or code>=400 then error("login page HTTP "..tostring(code)) end
    self.jar=Cookies.absorb({},header_value(h,"set-cookie"))
    local data,headers=self.http:get_json(BASE.."/api/auth/getLoginUid",{auth=false,headers={Referer=BASE.."/r/weread-skills",Cookie=Cookies.header(self.jar)}})
    self.jar=Cookies.absorb(self.jar,header_value(headers,"set-cookie"))
    if type(data.uid)~="string" or data.uid=="" then error("login UID missing") end
    return data.uid
end
function Auth:_poll(uid,otp)
    local url=BASE.."/api/auth/getLoginInfo?uid="..Protocol.escape(uid).."&otp"
    if type(otp)=="string" and otp~="" then url=url.."="..Protocol.escape(otp) end
    local data,headers=self.http:get_json(url,{auth=false,timeout={5,9},headers={Referer=BASE.."/r/weread-skills",Cookie=Cookies.header(self.jar)}})
    self.jar=Cookies.absorb(self.jar,header_value(headers,"set-cookie"))
    return data
end
function Auth:_finish(data)
    local vid=tostring(data.webLoginVid or ""); local key=tostring(data.accessToken or ""); local refresh=tostring(data.refreshToken or "")
    if vid=="" or key=="" then error("login credentials missing") end
    local jar=self.jar; jar.wr_vid=vid; jar.wr_skey=key; jar.wr_ql="0"; if refresh~="" then jar.wr_rt=Protocol.escape(refresh) end
    -- 0.3.6.7 merged Set-Cookie from both authenticated follow-up requests.
    -- These cookies are required by some accounts for /web/book/read; dropping
    -- them leaves downloads working while read-time reports only receive {}.
    local user,user_headers=self.http:get_json(BASE.."/api/userInfo?userVid="..Protocol.escape(vid),{auth=false,headers=merge_auth_headers(jar,vid,key)})
    jar=Cookies.absorb(jar,header_value(user_headers,"set-cookie"))
    local skill,skill_headers=self.http:get_json(BASE.."/api/skills/apikeyGet?only_show=1",{auth=false,headers=merge_auth_headers(jar,vid,key)})
    jar=Cookies.absorb(jar,header_value(skill_headers,"set-cookie"))
    local api_key=tostring(skill.apikey or ""); if api_key=="" then error("No WeRead Skill API key returned") end
    self.store:save_auth({api_key=api_key,cookies=jar,account={name=tostring(user.name or ""),vid=vid,logged_at=os.time()}})
    return user.name or vid
end
function Auth:start()
    self:cancel(); local gen=self.generation; self.started=os.time(); self.active=true; self.poll_failures=0
    logger.info("[MiuRead][Auth] QR login started")
    self.host:online(_("QR login"),function()
        local uid=self:_uid(); if gen~=self.generation then return end
        local size=math.floor(math.min(Device.screen:getWidth(),Device.screen:getHeight())*.72)
        local dialog
        dialog=QRMessage:new{text=BASE.."/web/confirm?uid="..Protocol.escape(uid),width=size,height=size,scale_factor=.9,dismiss_callback=function() if self.dialog==dialog then self.dialog=nil end; if gen==self.generation and self.active and not self.closing then self:cancel(); self.host:toast(_("Login cancelled")) end end}
        self.dialog=dialog; UIManager:show(dialog); self:_schedule(uid,gen,"")
    end)
end
function Auth:_schedule(uid,gen,otp)
    UIManager:scheduleIn(.8,function()
        if gen~=self.generation or not self.active then return end
        if os.time()-self.started>300 then self:cancel(); self.host:info(_("QR code expired")); return end
        local ok,data=pcall(function() return self:_poll(uid,otp) end)
        if not ok then
            self.poll_failures=(self.poll_failures or 0)+1
            if self.poll_failures==1 or self.poll_failures%5==0 then
                logger.warn("[MiuRead][Auth] login poll failed", tostring(data):gsub("[%c]+"," "):sub(1,180))
            end
            self:_schedule(uid,gen,otp); return
        end
        self.poll_failures=0
        if data.succeed==true then
            self.active=false; self:_close_dialog()
            self.host:online(_("QR login"),function()
                local name=self:_finish(data)
                logger.info("[MiuRead][Auth] QR login completed")
                self:cancel()
                self.host:info(_("Logged in")..": "..tostring(name))
            end)
            return
        end
        local code=tostring(data.logicCode or "")
        if code=="NEED_OTP" or code=="OTP_NOT_MATCH" then
            local d=self.dialog; self.dialog=nil; if d then UIManager:close(d) end; self:_otp(uid,gen,code=="OTP_NOT_MATCH")
        elseif code=="LOGIN_TIMEOUT" or code=="OTP_EXPIRED" then self:cancel(); self.host:info(_("QR code expired"))
        else self:_schedule(uid,gen,otp) end
    end)
end
function Auth:_otp(uid,gen,bad)
    local d
    d=InputDialog:new{title=_("Verification code"),input="",description=(bad and "验证码不正确。\n\n" or "").._("Enter the four-digit code shown on your phone."),buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d); self:cancel() end},{text=_("Confirm"),is_enter_default=true,callback=function() local otp=Util.trim(d:getInputText()); UIManager:close(d); self.dialog=nil; self:_schedule(uid,gen,otp) end}}}}
    UIManager:show(d); d:onShowKeyboard()
end
return Auth
