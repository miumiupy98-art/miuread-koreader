local Device=require("device")
local logger=require("logger")
local RawQRMessage=require("ui/widget/qrmessage")
local RawButtonDialog=require("ui/widget/buttondialog")
local RawInputDialog=require("ui/widget/inputdialog")
local GestureBridge=require("miuread.gesture_bridge")
local function gesture_aware_class(base)
    local class=base:extend{_miuread_transient=true}
    function class:handleEvent(event)
        return GestureBridge.handle(base,self,event)
    end
    return class
end
local QRMessage=gesture_aware_class(RawQRMessage)
local ButtonDialog=gesture_aware_class(RawButtonDialog)
local InputDialog=gesture_aware_class(RawInputDialog)
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
        refresh_count=0, pending_auth=nil, pending_name="", pending_expected_revision=nil,
    },self)
end
local function merge_auth_headers(jar,vid,key)
    return {Accept="application/json, text/plain, */*",Referer=BASE.."/r/weread-skills",Cookie=Cookies.session_header(jar),["X-Vid"]=vid,["X-Skey"]=key}
end
local function cookie_count(jar)
    local count=0
    for k,v in pairs(jar or {}) do
        if type(k)=="string" and v~=nil and tostring(v)~="" then count=count+1 end
    end
    return count
end
local function skill_api_key(value)
    if type(value)~="table" or type(value.apikey)~="string" then return "" end
    return value.apikey
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
    self.pending_auth=nil
    self.pending_name=""
    self.pending_expected_revision=nil
end
function Auth:_uid()
    local _,code,h=self.http:request{url=BASE.."/r/weread-skills",method="GET",auth=false,headers={Referer=BASE.."/"}}
    if code<200 or code>=400 then error("login page HTTP "..tostring(code)) end
    self.jar=Cookies.session_absorb({},header_value(h,"set-cookie"))
    local data,headers=self.http:get_json(BASE.."/api/auth/getLoginUid",{auth=false,headers={Referer=BASE.."/r/weread-skills",Cookie=Cookies.session_header(self.jar)}})
    self.jar=Cookies.session_absorb(self.jar,header_value(headers,"set-cookie"))
    if type(data.uid)~="string" or data.uid=="" then error("login UID missing") end
    return data.uid
end
function Auth:_poll(uid,otp)
    local url=BASE.."/api/auth/getLoginInfo?uid="..Protocol.escape(uid).."&otp"
    if type(otp)=="string" and otp~="" then url=url.."="..Protocol.escape(otp) end
    local data,headers=self.http:get_json(url,{auth=false,timeout={5,9},headers={Referer=BASE.."/r/weread-skills",Cookie=Cookies.session_header(self.jar)}})
    self.jar=Cookies.session_absorb(self.jar,header_value(headers,"set-cookie"))
    return data
end
function Auth:_persisted_auth_matches(expected)
    if type(self.store.read_persisted)~="function" then return true end
    local persisted,err=self.store:read_persisted("auth")
    if type(persisted)~="table" then return false,err or "saved auth missing" end
    local expected_account=type(expected.account)=="table" and expected.account or {}
    local persisted_account=type(persisted.account)=="table" and persisted.account or {}
    local expected_cookies=type(expected.cookies)=="table" and expected.cookies or {}
    local persisted_cookies=type(persisted.cookies)=="table" and persisted.cookies or {}
    if tostring(expected.login_session_id or "")==""
        or tostring(persisted.login_session_id or "")~=tostring(expected.login_session_id or "") then
        return false,"login session mismatch"
    end
    if tostring(persisted_account.vid or "")~=tostring(expected_account.vid or "") then
        return false,"account mismatch"
    end
    if tostring(persisted.api_key or "")~=tostring(expected.api_key or "") then
        return false,"api key mismatch"
    end
    if tostring(persisted_cookies.wr_vid or "")~=tostring(expected_cookies.wr_vid or "")
        or tostring(persisted_cookies.wr_skey or "")~=tostring(expected_cookies.wr_skey or "") then
        return false,"core cookie mismatch"
    end
    return true
end

function Auth:_commit_auth(auth,expected_revision)
    local saved,save_error=self.store:save_auth(auth,{expected_revision=expected_revision,replace_login=true})
    if saved~=true then return false,save_error or "settings write failed" end
    local verified,verify_error=self:_persisted_auth_matches(auth)
    if verified~=true then
        if self.store.reload then self.store:reload() end
        return false,verify_error or "saved auth verification failed"
    end
    return true
end

function Auth:_complete_login(name)
    local completed_name=tostring(name or self.pending_name or "")
    logger.info("[MiuRead][Auth] QR login completed")
    self:cancel()
    if self.host.on_auth_success then
        pcall(self.host.on_auth_success,self.host,completed_name)
    else
        self.host:info(_("Logged in")..": "..completed_name)
    end
end

function Auth:_abandon_pending_commit()
    self.pending_auth=nil
    self.pending_name=""
    self.pending_expected_revision=nil
    if self.host.on_auth_commit_failed then pcall(self.host.on_auth_commit_failed,self.host) end
end

function Auth:_show_commit_retry(detail)
    self.active=false
    self:_close_dialog()
    self:_close_retry_dialog()
    self.generation=self.generation+1
    local message="微信已经确认登录，但设备没有保存登录状态。\n\n可以直接重试保存，无需重新扫码。"
    local reason=Util.first_line(detail or "",120)
    if reason~="" then message=message.."\n\n原因："..reason end
    local dialog
    dialog=ButtonDialog:new{
        title=message,title_align="center",
        close_callback=function()
            if self.retry_dialog==dialog then self.retry_dialog=nil end
            if not self.closing then
                self:_abandon_pending_commit()
                self:cancel()
                self.host:toast("登录状态未保存",3)
            end
        end,
        buttons={
            {{text="重试保存",callback=function()
                self.closing=true
                if self.retry_dialog==dialog then self.retry_dialog=nil end
                UIManager:close(dialog)
                self.closing=false
                local pending=Util.copy(self.pending_auth)
                local pending_name=tostring(self.pending_name or "")
                local pending_expected_revision=self.pending_expected_revision
                if type(pending)~="table" then
                    self:_abandon_pending_commit()
                    self:_begin(0)
                    return
                end
                UIManager:scheduleIn(.05,function()
                    local old_auth=self.store:auth()
                    local saved,save_error=self:_commit_auth(pending,pending_expected_revision)
                    if saved==true then
                        logger.info("[MiuRead][Auth] pending login state saved after retry")
                        self.pending_auth=nil
                        self.pending_name=""
                        self.pending_expected_revision=nil
                        if self.host.on_auth_replaced then
                            pcall(self.host.on_auth_replaced,self.host,old_auth,self.store:auth())
                        end
                        self:_complete_login(pending_name)
                    else
                        logger.warn("[MiuRead][Auth] pending login save retry failed",Util.first_line(save_error or "unknown",160))
                        self.pending_auth=pending
                        self.pending_name=pending_name
                        self:_show_commit_retry(save_error)
                    end
                end)
            end}},
            {{text="重新扫码",callback=function()
                self.closing=true
                if self.retry_dialog==dialog then self.retry_dialog=nil end
                UIManager:close(dialog)
                self.closing=false
                self:_abandon_pending_commit()
                self:_begin(0)
            end}},
            {{text=_("Cancel"),callback=function()
                self.closing=true
                if self.retry_dialog==dialog then self.retry_dialog=nil end
                UIManager:close(dialog)
                self.closing=false
                self:_abandon_pending_commit()
                self:cancel()
            end}},
        },
    }
    self.retry_dialog=dialog
    UIManager:show(dialog)
end

function Auth:_finish(data)
    local vid=tostring(data.webLoginVid or ""); local key=tostring(data.accessToken or ""); local refresh=tostring(data.refreshToken or "")
    if vid=="" or key=="" then error("login credentials missing") end

    -- Keep the complete QR/browser session in memory until account verification
    -- and the first public-account credential renewal have both finished.
    local session=Cookies.session_absorb(self.jar,nil)
    session.wr_vid=vid; session.wr_skey=key; session.wr_ql="0"
    if refresh~="" then session.wr_rt=Protocol.escape(refresh) end

    local user,user_headers=self.http:get_json(BASE.."/api/userInfo?userVid="..Protocol.escape(vid),{auth=false,headers=merge_auth_headers(session,vid,key)})
    session=Cookies.session_absorb(session,header_value(user_headers,"set-cookie"))
    local account_name=tostring(user.name or user.nickName or user.nickname or user.userName or "")
    local skill,skill_headers=self.http:get_json(BASE.."/api/skills/apikeyGet?only_show=1",{auth=false,headers=merge_auth_headers(session,vid,key)})
    session=Cookies.session_absorb(session,header_value(skill_headers,"set-cookie"))
    local api_key=skill_api_key(skill)
    if api_key=="" then
        -- only_show=1 does not create a key for first-time Skills users.
        skill,skill_headers=self.http:get_json(BASE.."/api/skills/apikeyGet",{auth=false,headers=merge_auth_headers(session,vid,key)})
        session=Cookies.session_absorb(session,header_value(skill_headers,"set-cookie"))
        api_key=skill_api_key(skill)
    end
    if api_key=="" then error("No WeRead Skill API key returned") end

    -- Try once while the QR/browser session is still intact. Failure here must
    -- not invalidate the ordinary WeRead login. Only presence flags are logged.
    local renewal_ok,renewal,renewal_headers=pcall(function()
        return self.http:post_json(BASE.."/web/login/renewal",{rq="%2Fweb%2Fbook%2Fread",ql=false},{
            auth=false,retries=1,timeout={10,20},
            headers={
                Origin=BASE,Referer=BASE.."/",Accept="application/json, text/plain, */*",
                Cookie=Cookies.session_header(session),
            },
        })
    end)
    local renewal_succ=false
    local wr_ticket,wr_wrpa="",""
    if renewal_ok then
        session=Cookies.session_absorb(session,header_value(renewal_headers,"set-cookie"))
        renewal_succ=type(renewal)=="table"
            and renewal.succ~=false and tostring(renewal.succ or "")~="0"
        wr_ticket=tostring(header_value(renewal_headers,"x-wr-ticket") or "")
        wr_wrpa=tostring(header_value(renewal_headers,"x-wrpa-0") or "")
    else
        logger.warn("[MiuRead][Auth] QR-session public-account renewal failed",Util.first_line(tostring(renewal),160))
    end

    -- Persist only the proven long-lived cookie boundary. Browser-only session
    -- cookies are discarded after the immediate renewal attempt.
    local jar=Cookies.sanitize(session)
    local now=os.time()
    local ok_channel={state="ok",checked_at=now,error="",code=""}
    local pending_channel={state="unknown",checked_at=now,error="",code=""}
    local web_ready=renewal_ok and renewal_succ
    local new_auth={
        login_session_id=self.store:generate_login_session_id(),
        api_key=api_key,cookies=jar,wr_ticket=wr_ticket,wr_wrpa=wr_wrpa,
        ticket_updated_at=(wr_ticket~="" or wr_wrpa~="") and now or 0,
        account={name=account_name,vid=vid,logged_at=now},
        health={
            state="unknown",last_checked_at=now,last_ok_at=web_ready and now or 0,last_error_at=0,
            last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,
            channels={
                shelf=Util.copy(ok_channel),progress=Util.copy(ok_channel),
                download=Util.copy(web_ready and ok_channel or pending_channel),
                annotations=Util.copy(pending_channel),
                read_report=Util.copy(web_ready and ok_channel or pending_channel),
            },
        },
    }
    local old_auth=self.store:auth()
    local old_revision=math.max(0,tonumber(old_auth.auth_revision or 0) or 0)
    local committed,commit_error=self:_commit_auth(new_auth,old_revision)
    local display_name=account_name~="" and account_name or vid
    if committed~=true then
        self.pending_auth=Util.copy(new_auth)
        self.pending_name=display_name
        self.pending_expected_revision=old_revision
        logger.warn("[MiuRead][Auth] QR login confirmed but local commit failed",Util.first_line(commit_error or "unknown",160))
        return nil,commit_error
    end
    if self.host.on_auth_replaced then
        local replaced,replace_error=pcall(self.host.on_auth_replaced,self.host,old_auth,self.store:auth())
        if not replaced then logger.warn("[MiuRead][Auth] post-commit transition failed",tostring(replace_error)) end
    end
    logger.info("[MiuRead][Auth] QR session finalized",
        "session_cookies=",tostring(cookie_count(session)),
        "persistent_cookies=",tostring(#Cookies.names(jar)),
        "renewal_ok=",tostring(renewal_ok),
        "renewal_succ=",tostring(renewal_succ),
        "ticket=",tostring(wr_ticket~=""),
        "wrpa=",tostring(wr_wrpa~=""),
        "persisted=",tostring(true))
    return display_name
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
            logger.warn("[MiuRead][Auth] QR creation failed", Util.first_line(tostring(uid):gsub("[%c]+"," "),180))
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
                logger.warn("[MiuRead][Auth] login poll failed", Util.first_line(tostring(data):gsub("[%c]+"," "),180))
            end
            self:_schedule(uid,gen,otp); return
        end
        self.poll_failures=0
        if data.succeed==true then
            self.active=false; self:_close_dialog()
            self.host:online(_("QR login"),function()
                local name,commit_error=self:_finish(data)
                if not name then
                    self:_show_commit_retry(commit_error)
                    return
                end
                self:_complete_login(name)
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
