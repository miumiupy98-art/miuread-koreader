local PluginLoader=require("pluginloader")
local logger=require("logger")
local PluginMenuAdapter=require("miuread.plugin_menu_adapter")

local M={}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function plugin_label(module)
    local name=trim(module and (module.fullname or module.name) or "")
    return name~="" and name or "未命名插件"
end

local function plugin_version(module)
    return trim(module and module.version or "")
end

local function user_plugin_labels(enabled,disabled)
    local labels={}
    local ok,groups=pcall(PluginLoader.genPluginManagerSubItem,PluginLoader)
    if not ok or type(groups)~="table" then return labels,false end

    -- Reuse KOReader's own user-plugin classification instead of maintaining a
    -- second built-in plugin list. Find the user group by locating MiuRead
    -- itself (which is necessarily a user plugin); fall back to KOReader's
    -- current two-group order only on older builds where metadata is incomplete.
    local miuread_label
    for _,module in ipairs(enabled or {}) do
        if tostring(module.name or "")=="miuread" then miuread_label=plugin_label(module); break end
    end
    if not miuread_label then
        for _,module in ipairs(disabled or {}) do
            if tostring(module.name or "")=="miuread" then miuread_label=plugin_label(module); break end
        end
    end

    local user_group
    if miuread_label and miuread_label~="" then
        for _,group in ipairs(groups) do
            local items=type(group)=="table" and group.sub_item_table or nil
            if type(items)=="table" then
                for _,item in ipairs(items) do
                    local text=trim(item and item.text or "")
                    if text==miuread_label or text:sub(1,#miuread_label)==miuread_label then
                        user_group=group
                        break
                    end
                end
            end
            if user_group then break end
        end
    end
    user_group=user_group or groups[2]
    local items=type(user_group)=="table" and user_group.sub_item_table or nil
    if type(items)~="table" then return labels,false end
    for _,item in ipairs(items) do
        local text=trim(item and item.text or "")
        if text~="" then labels[text]=true end
    end
    return labels,true
end

local function label_matches(labels,module)
    local fullname=plugin_label(module)
    if labels[fullname] then return true end
    -- Deprecated plugins may get a short suffix in KOReader's manager label.
    -- Accept a label that begins with the exact native fullname, but do not use
    -- fuzzy matching that could merge unrelated plugins.
    for label in pairs(labels) do
        if label:sub(1,#fullname)==fullname then return true end
    end
    return false
end

local function collect_modules()
    local enabled,disabled=PluginLoader:loadPlugins()
    enabled=type(enabled)=="table" and enabled or {}
    disabled=type(disabled)=="table" and disabled or {}
    local labels,classified=user_plugin_labels(enabled,disabled)
    local rows={}

    local function add(module,is_enabled)
        if type(module)~="table" or tostring(module.name or "")=="miuread" then return end
        if classified and not label_matches(labels,module) then return end
        rows[#rows+1]={module=module,enabled=is_enabled==true}
    end
    for _,module in ipairs(enabled) do add(module,true) end
    for _,module in ipairs(disabled) do add(module,false) end

    -- Very old KOReader builds may not expose the two plugin-manager groups.
    -- In that case, stay conservative: show only currently loaded non-MiuRead
    -- plugins that actually expose a user-facing menu or settings function.
    if not classified then
        rows={}
        for _,module in ipairs(enabled) do
            local instance=PluginLoader:getPluginInstance(module.name)
            if module.name~="miuread" and instance
                and (type(instance.openSettings)=="function" or type(instance.addToMainMenu)=="function") then
                rows[#rows+1]={module=module,enabled=true}
            end
        end
    end

    table.sort(rows,function(a,b)
        return plugin_label(a.module):lower()<plugin_label(b.module):lower()
    end)
    return rows
end

local function runtime_instance(owner,module)
    if type(module)~="table" then return nil end
    local instance=PluginLoader:getPluginInstance(module.name)
    if instance then return instance end
    local ui=owner and owner.ui or nil
    if type(ui)=="table" and module.name and ui[module.name] then return ui[module.name] end
    return nil
end

local function native_menu_items(instance)
    return PluginMenuAdapter.menu_items(instance)
end

local function open_plugin_settings(owner,module,instance)
    if type(instance.openSettings)~="function" then return false end
    local ok,result=xpcall(function()
        return instance:openSettings({source="miuread"})
    end,debug.traceback)
    if not ok then
        logger.warn("[MiuRead][NativePlugins] openSettings crashed",tostring(module.name),tostring(result))
        if owner and owner.info then owner:info("无法打开“"..plugin_label(module).."”的设置。\n\n"..tostring(result)) end
        return true
    end
    if result==false and owner and owner.info then
        owner:info("“"..plugin_label(module).."”当前没有可直接打开的设置。")
    end
    return true
end

local function unavailable_message(owner,module,reason)
    local detail=reason or "当前没有可直接打开的原生菜单"
    if owner and owner.info then
        owner:info(plugin_label(module).."\n\n"..detail.."。\n\n你仍可以从 KOReader 原生插件菜单管理这个插件。")
    end
end

local function entry_for(owner,record)
    local module=record.module
    local label=plugin_label(module)
    local version=plugin_version(module)
    if record.enabled~=true then
        return {
            text=label,
            post_text=(version~="" and (version.." · ") or "").."未启用",
            callback=function()
                unavailable_message(owner,module,"插件已经安装，但当前被 KOReader 禁用；启用后需要重启 KOReader")
            end,
        }
    end

    local instance=runtime_instance(owner,module)
    if not instance then
        local doc_only=module.is_doc_only==true
        return {
            text=label,
            post_text=(version~="" and (version.." · ") or "")..(doc_only and "阅读时可用" or "重启后可用"),
            callback=function()
                unavailable_message(owner,module,doc_only and "这个插件只会在阅读器中加载，请打开一本书后再进入" or "当前界面没有加载这个插件，请完整重启 KOReader 后再试")
            end,
        }
    end

    -- Prefer the standard KOReader menu definition when a plugin provides it.
    -- MiuRead adapts that list into ReaderListDialog, preserving the plugin's
    -- callbacks/dynamic states while keeping the beta.10 visual language.
    local items,err=native_menu_items(instance)
    if type(items)=="table" and #items>0 then
        if #items==1 then
            local source=items[1]
            if source.sub_item_table_func or source.sub_item_table then
                return {
                    text=label,
                    post_text=version~="" and version or "菜单",
                    sub_item_table_func=source.sub_item_table_func,
                    sub_item_table=source.sub_item_table,
                }
            end
            if type(source.callback)=="function" then
                return {
                    text=label,
                    post_text=version~="" and version or "打开",
                    callback=source.callback,
                    keep_menu_open=source.keep_menu_open==true,
                }
            end
        end
        return {
            text=label,
            post_text=version~="" and version or "菜单",
            sub_item_table_func=function() return native_menu_items(instance) or {} end,
        }
    end

    -- Some plugins expose only a dedicated settings/widget entry. In that case
    -- execute the plugin-owned UI directly rather than inventing a fake menu.
    if type(instance.openSettings)=="function" then
        return {
            text=label,
            post_text=version~="" and version or "设置",
            callback=function() open_plugin_settings(owner,module,instance) end,
        }
    end

    return {
        text=label,
        post_text=version~="" and version or "原生菜单",
        callback=function()
            -- Never let MiuRead's adapter become a dead end. If a plugin cannot
            -- be represented safely here, hand control back to KOReader's own
            -- plugin/menu entry instead of hiding the plugin's remaining UI.
            if owner and type(owner._show_native_koreader_menu)=="function" then
                owner:_show_native_koreader_menu()
                return
            end
            unavailable_message(owner,module,err and "读取插件菜单失败" or "这个插件没有注册可直接进入的菜单")
        end,
    }
end

function M.label(record_or_module)
    local module=type(record_or_module)=="table" and (record_or_module.module or record_or_module) or nil
    return plugin_label(module)
end

function M.version(record_or_module)
    local module=type(record_or_module)=="table" and (record_or_module.module or record_or_module) or nil
    return plugin_version(module)
end

function M.module_name(record_or_module)
    local module=type(record_or_module)=="table" and (record_or_module.module or record_or_module) or nil
    return trim(module and module.name or "")
end

function M.entry(owner,record)
    if type(record)~="table" or type(record.module)~="table" then return nil end
    return entry_for(owner,record)
end

function M.settings_entry(owner,record)
    if type(record)~="table" or record.enabled~=true or type(record.module)~="table" then return nil end
    local module=record.module
    local instance=runtime_instance(owner,module)
    if not instance or type(instance.openSettings)~="function" then return nil end
    return {
        text="插件设置",
        callback=function() open_plugin_settings(owner,module,instance) end,
    }
end

function M.records()
    return collect_modules()
end

function M.count()
    return #collect_modules()
end

function M.menu(owner)
    local out={}
    for _,record in ipairs(collect_modules()) do
        out[#out+1]=entry_for(owner,record)
    end
    if #out==0 then
        out[1]={text="暂无用户插件",post_text="可从“查找扩展”安装",enabled=false}
    end
    return out
end

return M
