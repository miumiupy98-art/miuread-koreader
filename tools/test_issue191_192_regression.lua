-- Regression suite for Issue #191 (UX clarity & entry points)
-- and Issue #192 (E-Ink client authorization lifecycle & token renewal).
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
package.path=TOOL_DIR.."/../miuread.koplugin/?.lua;"..package.path

local function clone(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}
    if seen[value] then return seen[value] end
    local out={};seen[value]=out
    for k,v in pairs(value) do out[clone(k,seen)]=clone(v,seen) end
    return out
end

package.preload["miuread.util"]=function()
    return {
        copy=clone,
        trim=function(s) return tostring(s or ""):gsub("^%s+",""):gsub("%s+$","") end,
        first_line=function(s) return tostring(s or ""):match("^[^\r\n]*") end,
        redact_url=function(u) return u end,
    }
end
package.preload["miuread.protocol"]=function()
    return {
        escape=function(v) return tostring(v) end,
    }
end
package.preload["miuread.digests"]=function()
    return {
        sha256=function(v) return "hash:"..tostring(v) end,
    }
end
package.preload["logger"]=function()
    return {
        info=function() end,
        warn=function() end,
        error=function() end,
    }
end
package.preload["miuread.http"]=function()
    return {
        auth_error_code=function(v) return tostring(v):match("error_code=([%-]?%d+)") end,
        is_auth_error=function(v)
            local s=tostring(v or ""):lower()
            return s:find("[miureadauth]",1,true)~=nil
                or s:find("http 401",1,true)~=nil
                or s:find("error_code=-2012",1,true)~=nil
        end,
        is_rate_limit_error=function(v) return tostring(v):find("[MiuReadRateLimit]",1,true)~=nil end,
        rate_limit_details=function(v) return nil end,
    }
end
package.preload["miuread.diagnostic_log"]=function()
    return {
        now=function() return os.time() end,
        record=function() end,
    }
end
package.preload["ui/uimanager"]=function()
    return {
        scheduleIn=function(_,fn) if type(fn)=="function" then fn() end end,
        setDirty=function() end,
        show=function() end,
        close=function() end,
    }
end
package.preload["miuread.async"]=function() return {} end
package.preload["miuread.readtime_outbox"]=function() return {} end
package.preload["miuread.readtime_stats"]=function() return {} end
package.preload["miuread.readtime_clock"]=function() return {} end
package.preload["miuread.readtime_metadata"]=function() return {} end
package.preload["miuread.api_transport"]=function() return {} end
package.preload["datastorage"]=function() return {getDataDir=function() return "data" end} end
package.preload["miuread.extension_center"]=function() return {} end
package.preload["ui/widget/buttondialog"]=function()
    return {
        new=function(_,opts) return setmetatable(opts or {},{__index=opts}) end,
    }
end
package.preload["ui/widget/confirmbox"]=function()
    return {
        new=function(_,opts) return setmetatable(opts or {},{__index=opts}) end,
    }
end
package.preload["miuread.menu_icons"]=function()
    local icons={
        ["微信读书账号"]="user",
        ["账号"]="user",
        ["阅读与书库"]="book",
        ["同步与下载"]="sync",
    }
    return {
        key=function(label) return icons[label] end,
    }
end

-- =========================================================================
-- Test 1: ShelfClient.refresh under concurrent Web auth revisions (Issue #192)
-- =========================================================================
local ShelfClient=require("miuread.shelf_client")

local initial_auth={
    login_session_id="session-123",
    auth_revision=5,
    account={vid="user_abc",name="Tester"},
    native_shelf={
        vid="user_abc",
        accessToken="old_access_token",
        refreshToken="valid_refresh_token",
        deviceId="eink_dev_1",
    },
    cookies={wr_vid="user_abc",wr_skey="web_skey_v1"},
}

local current_store_auth=clone(initial_auth)
local mock_store={
    auth=function(self) return clone(current_store_auth) end,
    save_auth=function(self,auth,opt)
        opt=opt or {}
        local expected=opt.expected_revision
        local curr_rev=tonumber(current_store_auth.auth_revision or 0) or 0
        if expected~=nil and expected~=curr_rev then
            return false,"revision_mismatch"
        end
        current_store_auth=clone(auth)
        current_store_auth.auth_revision=curr_rev+1
        return true
    end,
}

local mock_http={
    post_json=function(self,url,body,opt)
        if url:find("/login") then
            -- Simulate concurrent Web cookie renewal happening while /login is in flight!
            current_store_auth.cookies.wr_skey="web_skey_v2"
            current_store_auth.auth_revision=current_store_auth.auth_revision+1
            return {
                vid="user_abc",
                accessToken="new_renewed_access_token",
                refreshToken="valid_refresh_token",
            }
        end
        error("unexpected URL: "..tostring(url))
    end,
}

local renewed=ShelfClient.refresh(mock_http,mock_store)
assert(renewed.accessToken=="new_renewed_access_token","expected renewed accessToken")
assert(current_store_auth.native_shelf.accessToken=="new_renewed_access_token","store auth should have new native token")
assert(current_store_auth.cookies.wr_skey=="web_skey_v2","concurrent web cookie update should be preserved")
print("test_issue192_shelf_client_refresh_concurrent_revision: PASS")

-- =========================================================================
-- Test 2: EinkReadtime.send keeps status pending on 401 auth error (Issue #192)
-- =========================================================================
local EinkReadtime=require("miuread.eink_readtime")
local Http=require("miuread.http")

local prepared={
    credentials={
        vid="user_abc",
        accessToken="expired_token",
        refreshToken="valid_refresh_token",
        deviceId="eink_dev_1",
    },
    body={dummy="payload"},
}

local mock_http_auth_fail={
    post_json=function(self,url,body,opt)
        if opt and opt.before_dispatch then opt.before_dispatch() end
        error("HTTP 401 [MiuReadAuth] error_code=-2012: 登录凭证需要更新")
    end,
}

local claimed=false
local result=EinkReadtime.send(mock_http_auth_fail,prepared,function()
    claimed=true
    return true
end)

assert(claimed==true,"batch should have been claimed")
assert(result.state=="pending","auth error (HTTP 401) must NOT be marked unknown; it must remain pending for retry")
assert(result.error=="authentication","error kind must be authentication")
print("test_issue192_readtime_send_pending_on_auth_error: PASS")

-- =========================================================================
-- Test 3: readtime_controller:adopt_auth adopts native_shelf when parent rev is higher (Issue #192)
-- =========================================================================
local ReadtimeController=require("miuread.readtime_controller")

local parent_auth={
    login_session_id="session-123",
    auth_revision=10, -- Parent had web cookie updates
    account={vid="user_abc",name="Tester"},
    native_shelf={
        vid="user_abc",
        accessToken="old_token",
        refreshToken="refresh_token",
        deviceId="dev_1",
    },
}

local disk_persisted_auth={
    login_session_id="session-123",
    auth_revision=8, -- Subprocess refreshed token with revision 8
    account={vid="user_abc",name="Tester"},
    native_shelf={
        vid="user_abc",
        accessToken="newly_refreshed_worker_token",
        refreshToken="refresh_token",
        deviceId="dev_1",
    },
}

local deferred_set_auth=nil
local stub_store={
    data_dir="test_adopt_auth",
    auth=function() return clone(parent_auth) end,
    read_persisted=function(self,key)
        if key=="auth" then return clone(disk_persisted_auth) end
    end,
    set_deferred=function(self,key,value)
        if key=="auth" then deferred_set_auth=clone(value) end
    end,
    preferences=function() return {sync={}} end,
}

local ctrl=setmetatable({store=stub_store},ReadtimeController)
ctrl:adopt_auth("user_abc")
assert(deferred_set_auth~=nil,"adopt_auth should have updated deferred auth")
assert(deferred_set_auth.native_shelf.accessToken=="newly_refreshed_worker_token",
    "parent should adopt worker's renewed native token")
print("test_issue192_readtime_controller_adopt_auth: PASS")

-- =========================================================================
-- Test 4: Issue #191 UX - Menu structure and return_koreader label
-- =========================================================================
local PluginSettings=require("miuread.plugin_settings")
local mock_plugin={
    _account_status_label=function() return "已登录 · Tester" end,
    account_menu=function() return {{text="账号状态"}} end,
    _home_enabled=function() return true end,
    _home_preferences=function() return {layout_style="standard"} end,
    _home_header_visibility_label=function() return "显示" end,
    _home_stats_visibility_label=function() return "显示" end,
    _home_ui_font_label=function() return "默认" end,
    _home_lockscreen_style_label=function() return "默认" end,
    _time_settings_label=function() return "设备时间" end,
    _home_mode_label=function() return "桌面模式" end,
    _performance_mode_label=function() return "标准" end,
    _reader_toolbar_setting_summary=function() return "开启" end,
    _reader_toolbar_enabled=function() return true end,
    _update_preferences=function() return {},{auto_check=true,restart_mode="ask"} end,
    _update_channel=function() return "beta" end,
    _update_channel_label=function() return "Beta" end,
    logged_in=function() return true end,
    version="6.4.1",
    store={
        preferences=function() return {} end,
    },
}

local settings_menu=PluginSettings.menu(mock_plugin)
assert(#settings_menu>=1,"settings menu must not be empty")
assert(settings_menu[1].text=="微信读书账号","top-level settings item 1 must be 微信读书账号 for direct access")
assert(settings_menu[1].post_text=="已登录 · Tester","account status must be displayed in post_text")
print("test_issue191_settings_menu_account_top_level: PASS")

-- Verify return_koreader label in main.lua
local main_source=io.open(TOOL_DIR.."/../miuread.koplugin/main.lua","r"):read("*a")
assert(main_source:find('return_koreader={icon="←",icon_key="return",label="返回KO"',1,true)~=nil,
    "return_koreader button must be clearly labeled '返回KO'")
print("test_issue191_return_koreader_label: PASS")

print("ALL ISSUE #191 AND #192 REGRESSION TESTS PASSED!")
