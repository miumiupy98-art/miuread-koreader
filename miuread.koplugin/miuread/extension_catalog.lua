--[[--
MiuRead curated KOReader extension catalogue.

This file is data first on purpose: recommendation policy, compatibility hints
and install strategy metadata live here, while extension_center.lua owns the UI.
Entries marked recommended=false remain discoverable through GitHub search and
community ranking; they are simply not promoted by MiuRead.
--]]--

local M = {}

M.CATEGORIES = {
    { key = "chinese_reading", label = "中文阅读", detail = "微信读书、网文与在线书库" },
    { key = "reading_tools", label = "阅读增强", detail = "AI、学习与书库增强" },
    { key = "chinese_input", label = "中文输入", detail = "拼音输入与候选增强" },
    { key = "transfer_files", label = "传书与文件", detail = "无线传书与文件管理" },
    { key = "data_sync", label = "资料与同步", detail = "文献、稍后读与批注同步" },
    { key = "plugin_market", label = "插件市场", detail = "其他 KOReader 插件下载市场" },
    { key = "experimental", label = "实验性扩展", detail = "仍处于 Beta 或需要额外谨慎的扩展", aggregate_experimental = true },
}

M.CAPABILITY_LABELS = {
    book_source = "阅读来源",
    reading_tool = "阅读工具",
    selection_action = "选中文字操作",
    input_method = "输入法",
    transfer = "文件传输",
    file_manager = "文件管理",
    sync = "同步",
    library = "书库",
    plugin_market = "插件市场",
    ui_extension = "界面增强",
    ui_replacement = "完整界面替代",
}

M.ENTRIES = {
    {
        id = "weread_finlater",
        repo = "finlater/weread.koplugin",
        name = "WeRead",
        author = "finlater",
        aliases = { "weread", "微信读书", "微信阅读", "finlater" },
        description = "在 KOReader 中阅读微信读书书籍和公众号，并同步阅读进度、时长、划线与想法。",
        category = "chinese_reading",
        capabilities = { "book_source" },
        recommended = true,
        featured = true,
        featured_order = 1,
        recommendation = "微信读书",
        min_koreader = "2026.03",
        platforms = { "kindle", "kobo", "android", "desktop", "other" },
        tested_platforms = { "Kindle", "Kobo" },
        dependencies = { "微信读书 Skill / API Key" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "fanqie",
        repo = "hesan1232/fanqie.koplugin",
        name = "番茄小说",
        author = "hesan1232",
        aliases = { "番茄", "番茄小说", "fanqie" },
        description = "在 KOReader 中浏览、阅读和管理番茄及聚合书源小说。",
        category = "chinese_reading",
        capabilities = { "book_source" },
        recommended = true,
        recommendation = "中文网络小说",
        dependencies = { "书源账号或 Cookie（按所选书源）" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "legado",
        repo = "pengcw/legado.koplugin",
        name = "Legado",
        author = "pengcw",
        aliases = { "legado", "阅读", "阅读3.0", "书源" },
        description = "连接 Legado / 阅读 3.0、Reader3 或轻阅读后端，在 KOReader 中阅读网文。",
        category = "chinese_reading",
        capabilities = { "book_source" },
        recommended = true,
        featured = true,
        featured_order = 5,
        recommendation = "书源与在线阅读",
        min_koreader = "2024.01",
        tested_platforms = { "Kobo Libra 2", "Kindle K3/K5/PW4" },
        dependencies = { "Legado / 阅读后端或手机阅读 App Web 服务" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "zlibrary",
        repo = "ZlibraryKO/zlibrary.koplugin",
        name = "Z-Library",
        author = "ZlibraryKO",
        aliases = { "zlibrary", "z-library", "z lib", "zlibraryko" },
        description = "在 KOReader 中搜索、浏览和下载 Z-Library 图书。",
        category = "chinese_reading",
        capabilities = { "book_source", "library" },
        recommended = true,
        recommendation = "图书搜索与下载",
        dependencies = { "Z-Library 账号" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "assistant",
        repo = "omer-faruq/assistant.koplugin",
        name = "Assistant",
        author = "omer-faruq",
        aliases = { "assistant", "ai assistant", "ai助手", "ai阅读" },
        description = "KOReader AI 阅读助手，支持翻译、解释、总结、问答与自定义提示词。",
        category = "reading_tools",
        capabilities = { "reading_tool", "selection_action" },
        recommended = true,
        featured = true,
        featured_order = 2,
        recommendation = "AI 阅读助手",
        dependencies = { "支持的 AI 服务与 API Key" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "inkstain",
        repo = "miumiupy98-art/inkstain.koplugin",
        name = "墨痕壁纸",
        author = "Estela-Zelin84",
        aliases = { "墨痕", "墨痕壁纸", "inkstain", "ink stain", "账单壁纸", "休眠壁纸" },
        description = "根据 KOReader 阅读统计或觅阅书架数据生成墨痕账单风格休眠壁纸，支持阅读时长、Top 书单与每日趋势。",
        category = "reading_tools",
        capabilities = { "reading_tool", "ui_extension" },
        recommended = true,
        featured = true,
        featured_order = 7,
        recommendation = "阅读统计与休眠壁纸",
        platforms = { "kindle", "kobo", "android", "desktop", "other" },
        tested_platforms = { "Kindle Paperwhite 4" },
        network_required = false,
        install_strategy = "standard",
        warning = "当前作者仅在 Kindle Paperwhite 4 上完成真机测试；其他设备首次启用前建议备份 KOReader 屏保与设置。",
    },
    {
        id = "anki",
        repo = "Ajatt-Tools/anki.koplugin",
        name = "Anki",
        author = "Ajatt-Tools",
        aliases = { "anki", "ankiconnect", "生词卡" },
        description = "从 KOReader 查词或选中文字创建 Anki 笔记。",
        category = "reading_tools",
        capabilities = { "reading_tool", "selection_action" },
        recommended = true,
        recommendation = "语言学习与生词卡片",
        dependencies = { "可访问的 AnkiConnect" },
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "opds_plus",
        repo = "greywolf1499/opds_plus.koplugin",
        name = "OPDS Plus",
        author = "greywolf1499",
        aliases = { "opds plus", "opds_plus", "opds" },
        description = "增强 KOReader 的 OPDS 浏览体验，提供封面与更丰富的列表/网格浏览。",
        category = "reading_tools",
        capabilities = { "library" },
        recommended = true,
        recommendation = "增强在线书库浏览",
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "pinyinime",
        repo = "Merpyzf/pinyinime.koplugin",
        name = "Pinyin IME",
        author = "Merpyzf",
        aliases = { "pinyin ime", "pinyinime", "拼音输入法", "中文输入" },
        description = "基于 KOReader 简体中文键盘的完整拼音增强：候选栏、整句、混拼、双拼、学习与联想。",
        category = "chinese_input",
        capabilities = { "input_method" },
        recommended = true,
        featured = true,
        featured_order = 3,
        recommendation = "完整中文输入",
        min_koreader = "2025.10",
        tested_platforms = { "KOReader 2025.10", "2026.03", "2026.07" },
        network_required = false,
        package_note = "解压后约 170 MiB",
        required_free_bytes = 220 * 1024 * 1024,
        max_plugin_bytes = 256 * 1024 * 1024,
        install_strategy = "standard",
    },
    {
        id = "pinyin_enhancement",
        repo = "gytwo/pinyin_enhancement.koplugin",
        name = "拼音输入增强",
        author = "gytwo",
        aliases = { "pinyin enhancement", "pinyin_enhancement", "拼音增强", "候选栏" },
        description = "轻量拼音候选栏增强，可选词库、词频排序与自定义表。",
        category = "chinese_input",
        capabilities = { "input_method" },
        recommended = true,
        recommendation = "轻量中文候选增强",
        network_required = false,
        warning = "启用大量或超大扩展词库会明显增加内存占用，低内存设备请谨慎。",
        install_strategy = "standard",
    },
    {
        id = "filebrowserplus",
        repo = "patelneeraj/filebrowserplus.koplugin",
        name = "FilebrowserPlus",
        author = "patelneeraj",
        aliases = { "filebrowserplus", "file browser plus", "filebrowser", "无线文件管理" },
        description = "在阅读器上启动 Filebrowser Web 服务，用手机或电脑浏览器上传、下载、删除、编辑和预览文件。",
        category = "transfer_files",
        capabilities = { "file_manager", "transfer" },
        recommended = true,
        featured = true,
        featured_order = 4,
        recommendation = "无线文件管理",
        tested_platforms = { "Kindle Paperwhite 12th", "Kindle Basic 10/11th", "Kobo Libra Colour" },
        network_required = true,
        install_strategy = "architecture_binary",
        architecture_sensitive = true,
        supported_arches = { "armv7" },
        asset_patterns = { armv7 = { "linux-armv7", "armv7" } },
        binary_relpath = "filebrowser/filebrowser",
        allow_archived_install = true,
        warning = "当前仓库已归档；觅阅仅在 ARMv7 设备上使用其已发布的 ARMv7 Release，不从源码包猜测二进制。",
    },
    {
        id = "localsend",
        repo = "kaikozlov/localsend.koplugin",
        name = "LocalSend",
        author = "kaikozlov",
        aliases = { "localsend", "local send", "局域网传书", "传文件" },
        description = "在 KOReader 与手机/电脑的 LocalSend 客户端之间直接发送和接收文件。",
        category = "transfer_files",
        capabilities = { "transfer" },
        recommended = true,
        featured = true,
        featured_order = 6,
        recommendation = "设备间直接传文件",
        network_required = true,
        install_strategy = "architecture_assets",
        architecture_sensitive = true,
        supported_arches = { "armv7", "arm64", "arm_legacy" },
        asset_patterns = {
            armv7 = { "localsend-koplugin-armv7", "armv7" },
            arm64 = { "localsend-koplugin-arm64", "arm64" },
            arm_legacy = { "localsend-koplugin-arm-legacy", "arm-legacy" },
        },
        tested_platforms = { "Kindle", "Kobo", "reMarkable", "PocketBook" },
    },
    {
        id = "zotero",
        repo = "stelzch/zotero.koplugin",
        name = "Zotero",
        author = "stelzch",
        aliases = { "zotero", "文献" },
        description = "在 KOReader 中浏览 Zotero collections，通过 Web API 下载与打开文献。",
        category = "data_sync",
        capabilities = { "library", "sync" },
        recommended = true,
        recommendation = "论文与文献用户",
        dependencies = { "Zotero 账号 / API" },
        network_required = true,
        experimental = true,
        warning = "项目仍标注 Beta，建议先在非关键资料上验证。",
        install_strategy = "standard",
    },
    {
        id = "readeck",
        repo = "iceyear/readeck.koplugin",
        name = "Readeck",
        author = "iceyear",
        aliases = { "readeck", "稍后读" },
        description = "把自托管 Readeck 中的文章同步到 KOReader，并支持部分进度/高亮同步。",
        category = "data_sync",
        capabilities = { "library", "sync" },
        recommended = true,
        recommendation = "自托管稍后读",
        dependencies = { "自己的 Readeck 服务" },
        network_required = true,
        warning = "部分同步能力仍处于 Beta。",
        install_strategy = "standard",
    },
    {
        id = "highlightsync",
        repo = "gitalexcampos/highlightsync.koplugin",
        name = "HighlightSync",
        author = "gitalexcampos",
        aliases = { "highlightsync", "highlight sync", "批注同步", "高亮同步" },
        description = "通过 WebDAV / Dropbox 同步和合并 KOReader 高亮、笔记与书签。",
        category = "data_sync",
        capabilities = { "sync" },
        recommended = true,
        recommendation = "多设备批注同步",
        dependencies = { "WebDAV 或 Dropbox" },
        network_required = true,
        experimental = true,
        warning = "Beta：同步前请备份 KOReader 批注和设置，避免错误合并造成数据损失。",
        install_strategy = "standard",
    },
    {
        id = "kaou_market",
        name = "卡欧市场",
        author = "攒钱买大黑卡",
        aliases = { "卡欧", "卡欧市场", "kaou", "market" },
        description = "面向中文 KOReader 用户的插件市场，提供中文分类、中文说明与国内镜像等功能。",
        category = "plugin_market",
        capabilities = { "plugin_market" },
        recommended = true,
        recommendation = "中文 KOReader 插件市场",
        network_required = true,
        source_kind = "external",
        install_strategy = "external_manual",
        auto_install = false,
        experimental = true,
        warning = "卡欧市场目前没有可由觅阅验证并持续跟踪的公开官方 GitHub 仓库，因此 beta.2 不代替作者分发安装包，也不会猜测下载地址。请从作者的官方发布渠道获取。",
    },
    {
        id = "appstore",
        repo = "omer-faruq/appstore.koplugin",
        name = "App Store",
        author = "omer-faruq",
        aliases = { "app store", "appstore", "kostore", "插件商店" },
        description = "KOReader 社区插件与 User Patch 市场，支持发现、安装、更新和管理。",
        category = "plugin_market",
        capabilities = { "plugin_market" },
        recommended = true,
        recommendation = "插件与 User Patch 市场",
        min_koreader = "2024.12",
        network_required = true,
        install_strategy = "standard",
    },
    {
        id = "storefront",
        repo = "ultimatejimmy/storefront.koplugin",
        name = "Storefront",
        author = "ultimatejimmy",
        aliases = { "storefront", "store front", "插件市场", "字体市场", "屏保市场" },
        description = "综合 KOReader 资源市场：插件、补丁、字体、屏保/壁纸与版本管理。",
        category = "plugin_market",
        capabilities = { "plugin_market" },
        recommended = true,
        recommendation = "插件、补丁、字体与屏保",
        network_required = true,
        install_strategy = "standard",
    },

    -- Known full-interface replacements: searchable and installable, but never
    -- promoted in MiuRead recommendations because they overlap the MiuRead home.
    {
        id = "simpleui",
        repo = "doctorhetfield-cmd/simpleui.koplugin",
        name = "SimpleUI",
        aliases = { "simpleui", "simple ui" },
        description = "KOReader 完整主页与界面扩展。",
        category = "ui_replacement",
        capabilities = { "ui_replacement" },
        recommended = false,
        ui_conflict = true,
        install_strategy = "standard",
    },
    {
        id = "zenos",
        repo = "xZenLabs/zen-os",
        name = "ZenOS",
        aliases = { "zenos", "zen os", "zen ui", "zenui" },
        description = "KOReader 完整可定制界面层。",
        category = "ui_replacement",
        capabilities = { "ui_replacement" },
        recommended = false,
        ui_conflict = true,
        min_koreader = "2026.03",
        install_strategy = "standard",
    },
    {
        id = "kindleui",
        repo = "hhoangg/kindleui.koplugin",
        name = "KindleUI",
        aliases = { "kindleui", "kindle ui" },
        description = "面向 Kindle 风格的完整 KOReader UI。",
        category = "ui_replacement",
        capabilities = { "ui_replacement" },
        recommended = false,
        ui_conflict = true,
        auto_install = false,
        install_strategy = "external_manual",
        warning = "该项目包含插件目录之外的额外 patch 安装步骤，觅阅不会用普通 .koplugin 流程自动安装。",
    },
    {
        id = "cozyhome",
        repo = "thekimberleyann/cozyhome.koplugin",
        name = "Cozy Home",
        aliases = { "cozyhome", "cozy home" },
        description = "可定制 KOReader 欢迎页 / dashboard。",
        category = "ui_replacement",
        capabilities = { "ui_replacement" },
        recommended = false,
        ui_conflict = true,
        install_strategy = "standard",
    },
    {
        id = "bookshelf",
        repo = "AndyHazz/bookshelf.koplugin",
        name = "Bookshelf",
        aliases = { "bookshelf", "书架" },
        description = "KOReader 主页、书架、Collections 与 OPDS 扩展。",
        category = "ui_replacement",
        capabilities = { "ui_replacement", "library" },
        recommended = false,
        ui_conflict = true,
        install_strategy = "standard",
    },
}

local by_repo, by_id, category_map = {}, {}, {}
for _, category in ipairs(M.CATEGORIES) do category_map[category.key] = category end
for _, entry in ipairs(M.ENTRIES) do
    if entry.repo then by_repo[entry.repo] = entry end
    if entry.id then by_id[entry.id] = entry end
end

local function normalized_alias(value)
    return tostring(value or ""):lower():gsub("[%s%p_]+", "")
end

function M.known_repo(repo)
    return by_repo[tostring(repo or "")]
end

function M.by_id(id)
    return by_id[tostring(id or "")]
end

function M.category(key)
    return category_map[tostring(key or "")]
end

function M.category_label(key)
    local category = M.category(key)
    if category then return category.label end
    return M.CAPABILITY_LABELS[tostring(key or "")] or tostring(key or "")
end

function M.featured_entries()
    local out = {}
    for _, entry in ipairs(M.ENTRIES) do
        if entry.recommended == true and entry.featured == true then out[#out + 1] = entry end
    end
    table.sort(out, function(a, b)
        local ao, bo = tonumber(a.featured_order) or 999, tonumber(b.featured_order) or 999
        if ao ~= bo then return ao < bo end
        return tostring(a.name or a.id) < tostring(b.name or b.id)
    end)
    return out
end

function M.category_entries(key)
    local out = {}
    local category = M.category(key)
    if not category then return out end
    for _, entry in ipairs(M.ENTRIES) do
        local include = entry.recommended == true and entry.category == key
        if category.aggregate_experimental == true then
            include = entry.recommended == true and entry.experimental == true
        end
        if include then out[#out + 1] = entry end
    end
    return out
end

function M.alias_matches(query)
    local key = normalized_alias(query)
    if key == "" then return {} end
    local out = {}
    for _, entry in ipairs(M.ENTRIES) do
        if entry.repo then
            local matched = normalized_alias(entry.name):find(key, 1, true) ~= nil
                or normalized_alias(entry.repo):find(key, 1, true) ~= nil
            if not matched then
                for _, alias in ipairs(entry.aliases or {}) do
                    local alias_key = normalized_alias(alias)
                    if alias_key ~= "" and (alias_key:find(key, 1, true) ~= nil or key:find(alias_key, 1, true) ~= nil) then
                        matched = true
                        break
                    end
                end
            end
            if matched then out[#out + 1] = entry end
        end
    end
    return out
end

function M.capability_text(entry)
    local labels = {}
    for _, key in ipairs(type(entry) == "table" and entry.capabilities or {}) do
        labels[#labels + 1] = M.CAPABILITY_LABELS[key] or tostring(key)
    end
    return table.concat(labels, " / ")
end

return M
