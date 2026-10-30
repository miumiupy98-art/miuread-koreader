local ExtensionCenter=require("miuread.extension_center")
local M={}
local MenuIcons=require("miuread.menu_icons")

local function append(rows,items)
    for _,row in ipairs(items or {}) do rows[#rows+1]=row end
    return rows
end

function M.sync(plugin)
    return {
        {text="同步状态",post_text=plugin:_home_sync_status_label(),callback=function() plugin:show_sync_status(false) end},
        {text="手动同步",sub_item_table_func=function() return plugin:sync_now_menu() end},
        {text="重试失败项目",callback=function() plugin:_confirm_sync_retry() end},
        {text="同步设置",sub_item_table_func=function() return plugin:sync_settings_menu() end},
    }
end

function M.comments(plugin)
    -- 收藏、历史和记录列表属于内容页，不放进“设置”。
    local rows={
        {text="在线评论点赞",post_text=plugin:_online_comment_likes_enabled() and "已开启" or "已关闭",
            checked_func=function() return plugin:_online_comment_likes_enabled() end,keep_menu_open=true,
            callback=function() plugin:_toggle_online_comment_likes() end},
    }
    return append(rows,plugin:thought_font_settings_menu())
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
    return rows
end

local function weread_settings(plugin)
    return {
        {text="账号",post_text=plugin:logged_in() and "已登录" or "未登录",sub_item_table_func=function() return plugin:account_menu() end},
        {text="微信分组",post_text=plugin:_shelf_filter_label(),sub_item_table_func=function() return plugin:shelf_filter_settings_menu() end},
    }
end

function M.reading_library(plugin)
    return {
        {text="微信读书",post_text=plugin:logged_in() and "已登录" or "未登录",sub_item_table_func=function() return weread_settings(plugin) end},
        {text="本地书库",post_text=plugin:_local_library_root_label(),sub_item_table_func=function() return plugin:local_library_preferences_menu() end},
        {text="公众号阅读",sub_item_table_func=function() return plugin:mp_settings_menu() end},
        {text="评论显示",post_text=plugin:_thought_display_label(),sub_item_table_func=function() return M.comments(plugin) end},
    }
end

function M.sync_download(plugin)
    return {
        {text="接口通道",post_text=require("miuread.api_transport").preference(plugin.store)=="web" and "Web" or "自动",sub_item_table_func=function() return plugin:api_transport_menu() end},
        {text="同步",sub_item_table_func=function() return plugin:sync_settings_menu() end},
        {text="下载",sub_item_table_func=function() return plugin:download_settings_menu() end},
        {text="存储",sub_item_table_func=function() return plugin:storage_management_menu() end},
    }
end

local function home_page_settings(plugin)
    local home=plugin:_home_preferences()
    return {
        {text="页面布局",post_text=(home.layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return plugin:home_layout_settings_menu() end},
        {text="主页顶栏显示",post_text=plugin:_home_header_visibility_label(),sub_item_table_func=function() return plugin:home_header_settings_menu() end},
        {text="主页阅读统计",post_text=plugin:_home_stats_visibility_label(home),sub_item_table_func=function() return plugin:home_stats_settings_menu() end},
        {text="显示书架封面",checked_func=function() return plugin.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() plugin:_toggle_preference("shelf_covers") end},
        {text="网络补全图书信息",checked_func=function() return plugin:_home_preferences().network_metadata~=false end,keep_menu_open=true,callback=function() plugin:_toggle_home_network_metadata() end},
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
    return plugin:home_lockscreen_settings_menu()
end

local function reader_toolbar_row(plugin)
    return {text="觅阅阅读工具栏",post_text=plugin:_reader_toolbar_setting_summary(),
        checked_func=function() return plugin:_reader_toolbar_enabled() end,keep_menu_open=true,
        callback=function() plugin:_set_reader_toolbar_enabled(not plugin:_reader_toolbar_enabled()) end}
end

function M.home_interface(plugin)
    return {
        {text="主页",sub_item_table_func=function() return home_page_settings(plugin) end},
        {text="快捷入口",sub_item_table_func=function() return plugin:home_customization_menu() end},
        reader_toolbar_row(plugin),
        {text="字体与显示",sub_item_table_func=function() return display_typography_settings(plugin) end},
        {text="锁屏壁纸",post_text=plugin:_home_lockscreen_style_label(plugin:_home_preferences()),sub_item_table_func=function() return lockscreen_settings(plugin) end},
    }
end

function M.plugin_interface(plugin)
    return {
        reader_toolbar_row(plugin),
    }
end

function M.runtime_compat(plugin)
    return {
        {text="运行模式",post_text=plugin:_home_mode_label(),sub_item_table_func=function() return plugin:home_mode_menu() end},
        {text="性能与兼容性",post_text=plugin:_performance_mode_label(),sub_item_table_func=function() return M.performance(plugin) end},
        {text="使用提醒",sub_item_table_func=function() return M.notices(plugin) end},
    }
end

function M.update_about(plugin)
    local _,update=plugin:_update_preferences()
    local channel=plugin:_update_channel()
    local channel_label=plugin:_update_channel_label(channel)
    local restart_label=update.restart_mode=="auto" and "自动重启" or (update.restart_mode=="never" and "稍后手动重启" or "询问是否重启")
    return {
        {text="检查更新",callback=plugin:safe("update",function() plugin:check_update(false) end)},
        {text="更新通道",post_text=channel_label,sub_item_table_func=function() return plugin:update_channel_menu() end},
        {text="自动检查更新",checked_func=function()
            local _,u=plugin:_update_preferences(); return u.auto_check~=false
        end,keep_menu_open=true,callback=function()
            local _,u=plugin:_update_preferences(); u.auto_check=u.auto_check==false; plugin:_save_update_preferences(u)
        end},
        {text="检查频率",post_text=plugin:_update_interval_label(update.interval),sub_item_table_func=function() return plugin:update_frequency_menu() end},
        {text="更新完成后",post_text=restart_label,sub_item_table_func=function() return plugin:update_restart_menu() end},
        {text="关于觅阅",callback=plugin:safe("about",function() plugin:show_about() end)},
        {text="第三方声明",callback=function() plugin:show_third_party_notices() end},
    }
end

function M.plugins_extensions(plugin)
    return ExtensionCenter.menu(plugin)
end

function M.koreader_tools(plugin)
    local start=tostring(plugin:_home_root() or "")
    return {
        {text="KOReader 设置",callback=function() plugin:_show_native_koreader_menu() end},
        {text="KOReader 文件管理",callback=function() plugin:_home_open_koreader_filemanager(start~="" and start or nil,true) end},
        {text="返回 KOReader",callback=function() plugin:_home_close_to_native(true) end},
    }
end

function M.system_maintenance(plugin)
    return {
        {text="日志与状态",sub_item_table_func=function() return {
            {text="导出运行日志",callback=function() plugin:export_runtime_log() end},
            {text="时间诊断",callback=function()
                local rows=plugin:diagnostics_menu(); local row=rows and rows[2]
                if row and row.callback then row.callback() end
            end},
        } end},
        {text="书库修复",sub_item_table_func=function() return {
            {text="刷新本地书库",callback=function() plugin:_home_scan_local(true,true) end},
            {text="更新缺失书籍资料",callback=function() plugin:_home_reset_local_metadata();plugin:_home_complete_refresh(true) end},
            {text="重建封面",callback=function() plugin:_clear_cover_cache() end},
            {text="重建书架索引",callback=function() plugin.store:reload();plugin.store:prune_missing_files();plugin:_show_miuread_home_now(false,true,true,"full") end},
            {text="检查下载完整性",callback=function() plugin:scan_downloaded_books_for_integrity_repair() end},
        } end},
        {text="存储管理",sub_item_table_func=function() return {
            {text="查看存储占用",callback=function() plugin:show_storage_usage() end},
            {text="清理可再生缓存",callback=function() plugin:show_download_cleanup_dialog() end},
        } end},
        {text="高级诊断",sub_item_table_func=function() return {
            {text="同步诊断",sub_item_table_func=function() return plugin:sync_diagnostics_menu() end},
            {text="同步状态详情",sub_item_table_func=function() return plugin:sync_diagnostics_status_menu() end},
        } end},
    }
end

function M.menu(plugin)
    local rows={
        {text="阅读与书库",sub_item_table_func=function() return M.reading_library(plugin) end},
        {text="同步与下载",sub_item_table_func=function() return M.sync_download(plugin) end},
    }
    if plugin:_home_enabled() then
        rows[#rows+1]={text="首页与界面",sub_item_table_func=function() return M.home_interface(plugin) end}
    else
        rows[#rows+1]={text="阅读界面",sub_item_table_func=function() return M.plugin_interface(plugin) end}
    end
    rows[#rows+1]={text="运行与兼容",sub_item_table_func=function() return M.runtime_compat(plugin) end}
    rows[#rows+1]={text="插件与扩展",sub_item_table_func=function() return M.plugins_extensions(plugin) end}
    rows[#rows+1]={text="系统维护",sub_item_table_func=function() return M.system_maintenance(plugin) end}
    rows[#rows+1]={text="更新与关于",post_text=tostring(plugin.version),sub_item_table_func=function() return M.update_about(plugin) end}
    return rows
end

-- All public settings menus share the icon vocabulary, including lazy
-- submenu providers. Preserve callback identity and native checked items.
local function decorate(items)
    for _,item in ipairs(items or {}) do
        if type(item)=="table" and not item.icon_key and not item.separator then
            item.icon_key=MenuIcons.key(item.text)
        end
    end
    return items
end
for _,name in ipairs({"sync","comments","notices","performance","reading_library",
    "sync_download","home_interface","plugin_interface","runtime_compat",
    "update_about","plugins_extensions","koreader_tools","system_maintenance","menu"}) do
    local original=M[name]
    if original then M[name]=function(plugin) return decorate(original(plugin)) end end
end
return M
