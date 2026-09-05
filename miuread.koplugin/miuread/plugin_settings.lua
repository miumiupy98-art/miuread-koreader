local ExtensionCenter=require("miuread.extension_center")
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
        {text="快捷入口",post_text="主页快捷栏 + 下滑控制中心",sub_item_table_func=function() return plugin:home_customization_menu() end},
        reader_toolbar_row(plugin),
        {text="字体与显示",post_text="大小 字体与时间",sub_item_table_func=function() return display_typography_settings(plugin) end},
        {text="锁屏与封面",post_text=plugin:_home_lockscreen_style_label(plugin:_home_preferences()),sub_item_table_func=function() return lockscreen_settings(plugin) end},
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
        {text="自动检查更新",checked_func=function()
            local _,u=plugin:_update_preferences(); return u.auto_check~=false
        end,keep_menu_open=true,callback=function()
            local _,u=plugin:_update_preferences(); u.auto_check=u.auto_check==false; plugin:_save_update_preferences(u)
        end},
        {text="检查频率",post_text=plugin:_update_interval_label(update.interval),sub_item_table_func=function() return plugin:update_frequency_menu() end},
        {text="更新完成后",post_text=restart_label,sub_item_table_func=function() return plugin:update_restart_menu() end},
        {text="更新通道",post_text=channel_label,sub_item_table_func=function() return plugin:update_channel_menu() end},
        {text="当前版本",post_text=tostring(plugin.version),enabled=false},
        {text="关于觅阅",callback=plugin:safe("about",function() plugin:show_about() end)},
        {text="许可证",post_text="AGPL-3.0-only",enabled=false},
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
        {text="同步诊断",sub_item_table_func=function() return plugin:sync_diagnostics_menu() end},
        {text="时间诊断",callback=function()
            local rows=plugin:diagnostics_menu()
            local row=rows and rows[2]
            if row and row.callback then row.callback() end
        end},
        {text="刷新本地书库",post_text="重新发现全部本地书",callback=function() plugin:_home_scan_local(true,true) end},
        {text="更新缺失书籍资料",callback=function() plugin:_home_reset_local_metadata(); plugin:_home_complete_refresh(true) end},
        {text="重建封面",callback=function() plugin:_clear_cover_cache() end},
        {text="重建书架索引",callback=function() plugin.store:reload(); plugin.store:prune_missing_files(); plugin:_show_miuread_home_now(false,true,true,"full") end},
        {text="检查下载完整性",callback=function() plugin:scan_downloaded_books_for_integrity_repair() end},
        {text="存储清理",post_text="临时文件、预下载与失效封面",callback=function() plugin:show_download_cleanup_dialog() end},
        {text="检查觅阅更新",post_text=plugin:_update_channel_label(plugin:_update_channel()),callback=plugin:safe("update",function() plugin:check_update(false) end)},
    }
end

function M.menu(plugin)
    local rows={
        {text="阅读与书库",post_text="微信读书 本地书与评论",sub_item_table_func=function() return M.reading_library(plugin) end},
        {text="同步与下载",post_text="同步 下载与存储",sub_item_table_func=function() return M.sync_download(plugin) end},
    }
    if plugin:_home_enabled() then
        rows[#rows+1]={text="首页与界面",post_text="主页 界面与快捷入口",sub_item_table_func=function() return M.home_interface(plugin) end}
    else
        rows[#rows+1]={text="阅读界面",post_text="觅阅阅读工具栏",sub_item_table_func=function() return M.plugin_interface(plugin) end}
    end
    rows[#rows+1]={text="运行与兼容",post_text="运行模式 性能与提醒",sub_item_table_func=function() return M.runtime_compat(plugin) end}
    rows[#rows+1]={text="更新与关于",post_text=tostring(plugin.version),sub_item_table_func=function() return M.update_about(plugin) end}
    return rows
end

return M
