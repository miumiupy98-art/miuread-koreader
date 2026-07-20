local Device=require("device")
local logger=require("logger")
local QRMessage=require("ui/widget/qrmessage")
local ButtonDialog=require("ui/widget/buttondialog")
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
local function is_login_timeout(value)
    local text=tostring(value or ""):lower()
    return text:find("login_timeout",1,true)
        or text:find("login timeout",1,true)
        or text:find("otp_expired",1,true)
        or text:find("登录超时",1,true)
        or text:find("二维码已过期",1,true)
end
function Auth:new(http,store,host)
    return setmetatable({
        http=http, store=store, host=host, generation=0, jar={}, dialog=nil,
        retry_dialog=nil, started=0, active=false, closing=false, poll_failures=0,
        refresh_count=0,
    },self)
end
local function merge_auth_headers(jar,vid,key)
    return {Accept="application/json, text/plain, */*",Referer=BASE.."/r/weread-skills",Cookie=Cookies.header(jar),["X-Vid"]=vid,["X-Skey"]=key}
end
function Auth:_close_dialog()
    if not self.dialog then return end
    local d=self.dialog; self.dialog=nil; self.closing=true; UIManager:close(d); self.closing=false
end
function Auth:_close_retry_dialog()
    if not self.retry_dialog then return end
    local d=self.retry_dialog; self.retry_dialog=nil; self.closing=true; UIManager:close(d); self.closing=false
end
function Auth:cancel()
    self.generation=self.generation+1
    self.active=false
    self:_close_dialog()
    self:_close_retry_dialog()
    self.jar={}
    self.started=0
    self.poll_failures=0
    self.refresh_count=0
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
    local jar=Cookies.sanitize(self.jar)
    jar.wr_vid=vid; jar.wr_skey=key; jar.wr_ql="0"; if refresh~="" then jar.wr_rt=Protocol.escape(refresh) end
    -- Persist only the stable 0.3.6.7-compatible cookie set. QR-page and
    -- browser-session cookies remain temporary and are never saved.
    local user,user_headers=self.http:get_json(BASE.."/api/userInfo?userVid="..Protocol.escape(vid),{auth=false,headers=merge_auth_headers(jar,vid,key)})
    jar=Cookies.absorb(jar,header_value(user_headers,"set-cookie"))
    local skill,skill_headers=self.http:get_json(BASE.."/api/skills/apikeyGet?only_show=1",{auth=false,headers=merge_auth_headers(jar,vid,key)})
    jar=Cookies.absorb(jar,header_value(skill_headers,"set-cookie"))
    local api_key=tostring(skill.apikey or ""); if api_key=="" then error("No WeRead Skill API key returned") end
    self.store:save_auth({api_key=api_key,cookies=jar,account={name=tostring(user.name or ""),vid=vid,logged_at=os.time()}})
    logger.info("[MiuRead][Auth] stable cookies saved", "names=", table.concat(Cookies.names(jar), ","))
    return user.name or vid
end
function Auth:_show_retry(message)
    self.active=false
    self:_close_dialog()
    self:_close_retry_dialog()
    self.generation=self.generation+1
    local dialog
    dialog=ButtonDialog:new{
        title=tostring(message or "登录二维码已过期").."\n\n可在当前页面直接重新获取，不需要退出后再次进入扫码登录。",
        title_align="center",
        close_callback=function()
            if self.retry_dialog==dialog then self.retry_dialog=nil end
            if not self.closing then
                self:cancel()
                self.host:toast(_("Login cancelled"))
            end
        end,
        buttons={
            {{text="重新获取二维码",callback=function()
                self.closing=true
                if self.retry_dialog==dialog then self.retry_dialog=nil end
                UIManager:close(dialog)
                self.closing=false
                self:_begin(0)
            end}},
            {{text=_("Cancel"),callback=function()
                self.closing=true
                if self.retry_dialog==dialog then self.retry_dialog=nil end
                UIManager:close(dialog)
                self.closing=false
                self:cancel()
                self.host:toast(_("Login cancelled"))
            end}},
        },
    }
    self.retry_dialog=dialog
    UIManager:show(dialog)
end
function Auth:_begin(refresh_count)
    self:cancel()
    self.refresh_count=tonumber(refresh_count) or 0
    local gen=self.generation
    self.started=os.time()
    self.active=true
    self.poll_failures=0
    logger.info("[MiuRead][Auth] QR login started", "refresh=", tostring(self.refresh_count))

    if self.host.is_online and not self.host:is_online() then
        self:_show_retry("网络不可用，暂时无法获取登录二维码。")
        return
    end
    UIManager:scheduleIn(.05,function()
        if gen~=self.generation or not self.active then return end
        local ok,uid=pcall(self._uid,self)
        if not ok then
            logger.warn("[MiuRead][Auth] QR creation failed", tostring(uid):gsub("[%c]+"," "):sub(1,180))
            self:_show_retry("二维码获取失败："..Util.first_line(uid,120))
            return
        end
        if gen~=self.generation or not self.active then return end
        local size=math.floor(math.min(Device.screen:getWidth(),Device.screen:getHeight())*.72)
        local dialog
        dialog=QRMessage:new{
            text=BASE.."/web/confirm?uid="..Protocol.escape(uid),
            width=size,height=size,scale_factor=.9,
            dismiss_callback=function()
                if self.dialog==dialog then self.dialog=nil end
                if gen==self.generation and self.active and not self.closing then
                    self:cancel()
                    self.host:toast(_("Login cancelled"))
                end
            end,
        }
        self.dialog=dialog
        UIManager:show(dialog)
        self:_schedule(uid,gen,"")
    end)
end
function Auth:start()
    self:_begin(0)
end
function Auth:_expire(gen,message)
    if gen~=self.generation or not self.active then return end
    local refresh_count=tonumber(self.refresh_count) or 0
    self.active=false
    self:_close_dialog()
    if refresh_count<1 then
        local expected_generation=self.generation
        self.host:toast("登录二维码已过期，正在自动刷新……",3)
        UIManager:scheduleIn(.4,function()
            if self.generation~=expected_generation then return end
            self:_begin(refresh_count+1)
        end)
        return
    end
    self:_show_retry(message or "登录二维码已过期。")
end
function Auth:_schedule(uid,gen,otp)
    UIManager:scheduleIn(.8,function()
        if gen~=self.generation or not self.active then return end
        if os.time()-self.started>300 then self:_expire(gen,"登录二维码已过期。") return end
        local ok,data=pcall(function() return self:_poll(uid,otp) end)
        if not ok then
            if is_login_timeout(data) then
                self:_expire(gen,"登录已超时。")
                return
            end
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
        elseif code=="LOGIN_TIMEOUT" or code=="OTP_EXPIRED" then
            self:_expire(gen,"登录二维码已过期。")
        else
            self:_schedule(uid,gen,otp)
        end
    end)
end
function Auth:_otp(uid,gen,bad)
    local d
    d=InputDialog:new{title=_("Verification code"),input="",description=(bad and "验证码不正确。\n\n" or "").._("Enter the four-digit code shown on your phone."),buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d); self:cancel() end},{text=_("Confirm"),is_enter_default=true,callback=function() local otp=Util.trim(d:getInputText()); UIManager:close(d); self.dialog=nil; self:_schedule(uid,gen,otp) end}}}}
    UIManager:show(d); d:onShowKeyboard()
end
return Auth
