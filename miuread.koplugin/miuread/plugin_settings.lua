local ExtensionCenter=require("miuread.extension_center")
local Device=require("device")
local M={}

local function append(rows,items)
    for _,row in ipairs(items or {}) do rows[#rows+1]=row end
    return rows
end

function M.sync(plugin)
    return {
        {text="同步状态",post_text=plugin:_home_sync_status_label(),callback=function() plugin:show_sync_status(false) end},
        {text="同步未完成内容",post_text="进度 划线 想法",callback=function() plugin:_sync_home_pending() end},
        {text="同步设置",post_text="时间 进度 批注",sub_item_table_func=function() return plugin:sync_settings_menu() end},
    }
end

function M.comments(plugin)
    -- Keep only behavior/display settings here. Favorites, history and record
    -- lists are content pages and no longer live inside Settings.
    return plugin:thought_font_settings_menu()
end

function M.notices(plugin)
    local labels={
        reader_download="阅读时下载提醒",low_battery="低电量下载提醒",low_storage="存储空间提醒",
        mode_switch="运行模式切换说明",mode_environment="进入模式说明",
    }
    local order={"reader_download","low_battery","low_storage","mode_switch","mode_environment"}
    local rows={}
    for _,key in ipairs(order) do
        local notice_key=key
        rows[#rows+1]={text=labels[notice_key],checked_func=function() return plugin:_notice_enabled(notice_key) end,keep_menu_open=true,callback=function()
            plugin:_set_notice_enabled(notice_key,not plugin:_notice_enabled(notice_key))
        end}
    end
    rows[#rows+1]={text="恢复全部使用提醒",callback=function()
        for _,key in ipairs(order) do plugin:_set_notice_enabled(key,true) end
        plugin:toast("使用提醒已恢复")
    end}
    return rows
end

function M.performance(plugin)
    local rows={}
    append(rows,plugin:performance_settings_menu())
    rows[#rows+1]={text="使用提醒",sub_item_table_func=function() return M.notices(plugin) end}
    return rows
end

local function weread_settings(plugin)
    return {
        {text="账号",post_text=plugin:logged_in() and "已登录" or "未登录",sub_item_table_func=function() return plugin:account_menu() end},
        {text="微信书架范围",post_text=plugin:_shelf_filter_label(),sub_item_table_func=function() return plugin:shelf_filter_settings_menu() end},
    }
end

function M.reading_library(plugin)
    return {
        {text="微信读书",post_text=plugin:logged_in() and "已登录" or "未登录",sub_item_table_func=function() return weread_settings(plugin) end},
        {text="本地书库",post_text=plugin:_local_library_root_label(),sub_item_table_func=function() return plugin:local_library_preferences_menu() end},
        {text="公众号阅读",post_text="图片与缓存",sub_item_table_func=function() return plugin:mp_settings_menu() end},
        {text="评论显示",post_text=plugin:_thought_display_label(),sub_item_table_func=function() return M.comments(plugin) end},
    }
end

function M.sync_download(plugin)
    return {
        {text="同步",post_text="时间 进度 批注",sub_item_table_func=function() return plugin:sync_settings_menu() end},
        {text="下载",post_text=plugin:_download_settings_summary(),sub_item_table_func=function() return plugin:download_settings_menu() end},
        {text="存储",post_text="缓存与清理",sub_item_table_func=function() return plugin:storage_management_menu() end},
    }
end

local function home_page_settings(plugin)
    local home=plugin:_home_preferences()
    return {
        {text="页面布局",post_text=(home.layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return plugin:home_layout_settings_menu() end},
        {text="主页阅读统计",post_text=plugin:_home_stats_visibility_label(home),sub_item_table_func=function() return plugin:home_stats_settings_menu() end},
        {text="显示书架封面",checked_func=function() return plugin.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() plugin:_toggle_preference("shelf_covers") end},
        {text="网络补全图书信息",post_text="只补充缺失资料",checked_func=function() return plugin:_home_preferences().network_metadata~=false end,keep_menu_open=true,callback=function() plugin:_toggle_home_network_metadata() end},
    }
end


local function display_typography_settings(plugin)
    local home=plugin:_home_preferences()
    local size_labels={compact="紧凑",standard="标准",large="大号"}
    return {
        {text="觅阅显示大小",post_text=size_labels[home.display_size] or "标准",sub_item_table_func=function() return plugin:home_display_size_menu() end},
        {text="觅阅界面字体",post_text=plugin:_home_ui_font_label(home),sub_item_table_func=function() return plugin:home_ui_font_menu() end},
        {text="时间与时区",post_text=plugin:_time_settings_label(),sub_item_table_func=function() return plugin:time_display_settings_menu() end},
    }
end

local function lockscreen_settings(plugin)
    local home=plugin:_home_preferences()
    return {
        {text="主页锁屏显示最近阅读封面",checked_func=function() return plugin:_home_preferences().lockscreen_recent~=false end,keep_menu_open=true,callback=function() plugin:_toggle_home_lockscreen() end},
        {text="锁屏封面样式",post_text=plugin:_home_lockscreen_style_label(home),enabled_func=function() return plugin:_home_preferences().lockscreen_recent~=false end,sub_item_table_func=function() return plugin:home_lockscreen_style_menu() end},
    }
end

local function reader_toolbar_row(plugin)
    return {text="觅阅阅读工具栏",post_text=plugin:_reader_toolbar_setting_summary(),
        checked_func=function() return plugin:_reader_toolbar_enabled() end,keep_menu_open=true,
        callback=function() plugin:_set_reader_toolbar_enabled(not plugin:_reader_toolbar_enabled()) end}
end

function M.home_interface(plugin)
    return {
        {text="主页",post_text="布局与内容",sub_item_table_func=function() return home_page_settings(plugin) end},
        {text="快捷工具",post_text="主页 + 下滑工具栏",sub_item_table_func=function() return plugin:home_customization_menu() end},
        reader_toolbar_row(plugin),
        {text="字体与显示",post_text="大小 字体与时间",sub_item_table_func=function() return display_typography_settings(plugin) end},
        {text="锁屏与封面",post_text=plugin:_home_lockscreen_style_label(plugin:_home_preferences()),sub_item_table_func=function() return lockscreen_settings(plugin) end},
    }
end

function M.plugins_extensions(plugin)
    return {
        {text="查找扩展",post_text="搜索与社区热门",sub_item_table_func=function() return ExtensionCenter.discovery_menu(plugin) end},
        {text="我的插件",post_text=tostring(ExtensionCenter.installed_count(plugin)),sub_item_table_func=function() return ExtensionCenter.installed_menu(plugin) end},
    }
end

local function power_menu(plugin)
    local rows={}
    if Device:canSuspend() then rows[#rows+1]={text="休眠",callback=function() plugin:_home_sleep() end} end
    rows[#rows+1]={text="重启 KOReader",callback=function() plugin:_restart_koreader("settings") end}
    rows[#rows+1]={text="退出 KOReader",callback=function() plugin:_quit_koreader() end}
    if type(Device.canReboot)=="function" and Device:canReboot() then rows[#rows+1]={text="重启设备",callback=function() plugin:_home_reboot_device() end} end
    if type(Device.canPowerOff)=="function" and Device:canPowerOff() then rows[#rows+1]={text="关机",callback=function() plugin:_home_poweroff_device() end} end
    return rows
end

local function koreader_menu(plugin)
    local start=tostring(plugin:_home_root() or "")
    return {
        {text="KOReader 设置",callback=function() plugin:_show_native_koreader_menu() end},
        {text="KOReader 文件管理",callback=function() plugin:_home_open_koreader_filemanager(start~="" and start or nil,true) end},
        {text="返回 KOReader",callback=function() plugin:_home_close_to_native(true) end},
    }
end

function M.device_koreader(plugin)
    local rows={
        {text="Wi-Fi",callback=function() plugin:_home_wifi_settings() end},
    }
    local bt=plugin:_bluetooth_state(false)
    if bt.supported==true then
        rows[#rows+1]={text="Bluetooth",post_text=bt.enabled==true and "已开启" or "已关闭",callback=function() plugin:_bluetooth_show_devices() end}
    end
    if Device:hasFrontlight() then
        rows[#rows+1]={text="前光与色温",callback=function() plugin:_show_reader_frontlight_panel(function() plugin:_show_home_settings_center() end) end}
    end
    rows[#rows+1]={text="屏幕方向",post_text=plugin:_orientation_status_label(),callback=function() plugin:_show_orientation_panel() end}
    rows[#rows+1]={text="休眠与电源",sub_item_table_func=function() return power_menu(plugin) end}
    rows[#rows+1]={text="KOReader",sub_item_table_func=function() return koreader_menu(plugin) end}
    return rows
end

function M.system_maintenance(plugin)
    return {
        {text="诊断",post_text="同步与时间",sub_item_table_func=function() return plugin:diagnostics_menu() end},
        {text="数据修复",post_text="书库与书籍完整性",sub_item_table_func=function() return plugin:data_repair_menu() end},
        {text="性能与兼容性",post_text=plugin:_performance_mode_label(),sub_item_table_func=function() return M.performance(plugin) end},
        {text="运行模式",post_text=plugin:_home_mode_label(),sub_item_table_func=function() return plugin:home_mode_menu() end},
        {text="更新",post_text=plugin:_update_channel_label(plugin:_update_channel()),sub_item_table_func=function() return plugin:update_settings_menu() end},
    }
end

function M.about(plugin)
    return {
        {text="当前版本",post_text=tostring(plugin.version),enabled=false},
        {text="许可证",post_text="AGPL-3.0-only",enabled=false},
        {text="关于觅阅",callback=plugin:safe("about",function() plugin:show_about() end)},
    }
end

function M.menu(plugin)
    local rows={
        {text="阅读与书库",post_text="微信读书 本地书与评论",sub_item_table_func=function() return M.reading_library(plugin) end},
        {text="同步与下载",post_text="同步 下载与存储",sub_item_table_func=function() return M.sync_download(plugin) end},
    }
    if plugin:_home_enabled() then
        rows[#rows+1]={text="首页与界面",post_text="主页 书架与快捷工具",sub_item_table_func=function() return M.home_interface(plugin) end}
    else
        -- 插件模式没有觅阅主页，但阅读工具栏仍是独立可用功能。
        -- 保留直接开关，避免移除“阅读界面”子菜单后失去设置入口。
        rows[#rows+1]=reader_toolbar_row(plugin)
    end
    rows[#rows+1]={text="插件与扩展",post_text="查找扩展与我的插件",sub_item_table_func=function() return M.plugins_extensions(plugin) end}
    rows[#rows+1]={text="设备与 KOReader",post_text="设备控制与原生入口",sub_item_table_func=function() return M.device_koreader(plugin) end}
    rows[#rows+1]={text="系统与维护",post_text="诊断 修复 性能与更新",sub_item_table_func=function() return M.system_maintenance(plugin) end}
    rows[#rows+1]={text="关于觅阅",post_text=tostring(plugin.version),sub_item_table_func=function() return M.about(plugin) end}
    return rows
end

return M
