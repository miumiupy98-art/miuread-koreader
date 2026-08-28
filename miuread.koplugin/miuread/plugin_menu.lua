local PluginSettings=require("miuread.plugin_settings")

local M={}

local function comment_and_thought_menu(plugin)
    local rows={
        {text="我的想法",callback=function()
            plugin:_show_reader_records("thought",function() plugin:_show_koreader_reader_menu() end)
        end},
        {text="阅读评论",post_text=plugin:_thoughts_enabled_label(),checked_func=function()
            return plugin:_thoughts_enabled()
        end,keep_menu_open=true,callback=function() plugin:_toggle_thoughts_enabled() end},
    }
    if plugin:_current_book_supports_miuread_marks() then
        rows[#rows+1]={text="显示划线",post_text=plugin:_marks_enabled_label(),checked_func=function()
            return plugin:_marks_enabled()
        end,keep_menu_open=true,callback=function() plugin:_toggle_marks_enabled() end}
    end
    rows[#rows+1]={text="评论显示设置",sub_item_table_func=function() return plugin:thought_font_settings_menu() end}
    rows[#rows+1]={text="评论数据管理",sub_item_table_func=function() return PluginSettings.comment_data(plugin) end}
    return rows
end

function M.home(plugin)
    plugin:maybe_auto_check_update(false)
    return {
        {text="我的书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)},
        {text="搜索书籍",callback=plugin:safe("search",function() plugin:search_dialog() end)},
        {text=plugin:_download_menu_text(),callback=plugin:safe("downloads",function() plugin:show_downloads() end)},
        {text=plugin:_sync_menu_text(),sub_item_table_func=function() return PluginSettings.sync(plugin) end},
        {text="公众号",callback=plugin:safe("mp-shelf",function() plugin:show_mp_shelf(false) end)},
        {text="账号",sub_item_table_func=function() return plugin:account_menu() end},
        {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
    }
end

function M.reader(plugin)
    plugin:maybe_auto_check_update(false)
    local current_path=plugin:_current_document_path()
    local mp_context=plugin.mp and plugin.mp:identify_path(current_path) or nil
    if mp_context then
        return {
            {text="返回文章列表",callback=plugin:safe("mp-back",function() plugin:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=plugin:safe("mp-prev",function() plugin:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=plugin:safe("mp-next",function() plugin:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return plugin:current_mp_article_menu(mp_context) end},
            {text=plugin:_download_menu_text(),callback=function() plugin:show_downloads() end},
            {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
        }
    end
    return {
        {text="当前书籍",sub_item_table_func=function() return plugin:current_book_menu() end},
        {text="打开觅阅书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)},
        {text=plugin:_sync_menu_text(),sub_item_table_func=function() return PluginSettings.sync(plugin) end},
        {text=plugin:_download_menu_text(),callback=function() plugin:show_downloads() end},
        {text="评论与想法",sub_item_table_func=function() return comment_and_thought_menu(plugin) end},
        {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
    }
end

return M
