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
    { key = "device_beauty", label = "设备美化", detail = "主题、界面与休眠壁纸" },
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
    appearance = "界面美化",
    screensaver = "休眠壁纸",
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
        package = {
            type = "release_asset", version = "v1.4.0",
            artifact = { name = "weread.koplugin-v1.4.0.zip", url = "https://github.com/finlater/weread.koplugin/releases/download/v1.4.0/weread.koplugin-v1.4.0.zip", size = 876092, sha256 = "d9270eda83e41e0cd7cc62739c68db23950d86bdb10f4708ca23e64823ab3514" },
            install = { dirname = "weread.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset",
            version = "v2.2.1",
            artifact = {
                name = "fanqie.koplugin.zip",
                url = "https://github.com/hesan1232/fanqie.koplugin/releases/download/v2.2.1/fanqie.koplugin.zip",
                size = 126623,
                sha256 = "21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b",
            },
            install = { dirname = "fanqie.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "1.1.7",
            artifact = { name = "legado_plugin_update.zip", url = "https://github.com/pengcw/legado.koplugin/releases/download/1.1.7/legado_plugin_update.zip", size = 296251, sha256 = "204c3d537c38f2094b387ab234a8755cf5d3193866b951630dae7d73b720e7b4" },
            install = { dirname = "legado.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v1.16",
            artifact = { name = "assistant.koplugin-v1.16.zip", url = "https://github.com/omer-faruq/assistant.koplugin/releases/download/v1.16/assistant.koplugin-v1.16.zip", size = 1185025, sha256 = "3a0b7227ffd9ff4d2140e6989fc20c383c19a7053b750a710725a67c27d27fc6" },
            install = { dirname = "assistant.koplugin", layout = "name-koplugin" },
        },
        install_strategy = "standard",
    },
    {
        id = "inkstain",
        repo = "Estela-Zelin84/inkstain.koplugin",
        repo_aliases = { "miumiupy98-art/inkstain.koplugin" },
        install_dirname = "inkstain.koplugin",
        name = "墨痕壁纸",
        author = "Estela-Zelin84",
        aliases = { "墨痕", "墨痕壁纸", "inkstain", "ink stain", "账单壁纸", "休眠壁纸" },
        description = "根据 KOReader 阅读统计或觅阅书架数据生成墨痕账单风格休眠壁纸，支持阅读时长、Top 书单与每日趋势。",
        category = "device_beauty",
        capabilities = { "screensaver", "ui_extension" },
        lockscreen_provider = "inkstain",
        recommended = true,
        featured = true,
        featured_order = 7,
        recommendation = "阅读统计与休眠壁纸",
        platforms = { "kindle", "kobo", "android", "desktop", "other" },
        tested_platforms = { "Kindle Paperwhite 4" },
        network_required = false,
        package = {
            type = "release_asset",
            -- Verified fallback only. beta.17 resolves the newest installable official
            -- Release at runtime; this record is never treated as the remote latest.
            version = "v3.9.0",
            artifact = {
                name = "inkstain.koplugin-v3.9.0.zip",
                url = "https://github.com/Estela-Zelin84/inkstain.koplugin/releases/download/v3.9.0/inkstain.koplugin-v3.9.0.zip",
                size = 10294040,
                sha256 = "e43b33022a91d56590e78c52f8f845f0c869b6ab5a65a464f80942fe7787f080",
            },
            install = { dirname = "inkstain.koplugin", layout = "name-koplugin" },
        },
        install_strategy = "standard",
        warning = "当前作者仅在 Kindle Paperwhite 4 上完成真机测试；其他设备首次启用前建议备份 KOReader 屏保与设置。",
    },
    {
        id = "dashwallpaper",
        repo = "RC-APC/DashWallpaper.koplugin",
        install_dirname = "DashWallpaper.koplugin",
        name = "DashWallpaper 看板壁纸",
        author = "RC-APC",
        aliases = { "dashwallpaper", "dash wallpaper", "看板壁纸", "动态壁纸", "天气壁纸", "榜单壁纸" },
        description = "把天气、榜单、资讯等看板自动下载为 KOReader 休眠壁纸，支持每日自动更新、城市天气和自定义壁纸源。",
        category = "device_beauty",
        capabilities = { "screensaver", "ui_extension" },
        lockscreen_provider = "dashwallpaper",
        recommended = true,
        featured = true,
        featured_order = 8,
        recommendation = "天气、榜单与资讯看板壁纸",
        platforms = { "kindle", "kobo", "android", "desktop", "other" },
        network_required = true,
        install_strategy = "standard",
        warning = "新插件：首次使用前建议确认 KOReader 的休眠屏幕设置。觅阅切换为 DashWallpaper 时会先生成壁纸，成功后才改变当前锁屏来源。",
    },
    {
        id = "appearance",
        repo = "Euphoriyy/appearance.koplugin",
        install_dirname = "appearance.koplugin",
        name = "Appearance",
        author = "Euphoriyy",
        aliases = { "appearance", "主题", "配色", "外观", "界面美化" },
        description = "自定义 KOReader 界面与书籍配色、主题、字体、背景图片、进度条和标注样式。",
        category = "device_beauty",
        capabilities = { "appearance", "ui_extension" },
        recommended = true,
        recommendation = "主题、配色与界面外观",
        install_strategy = "standard",
    },
    {
        id = "coverprogress",
        repo = "joemk88/koreader-coverprogress",
        install_dirname = "coverprogress.koplugin",
        name = "CoverProgress",
        author = "joemk88",
        aliases = { "coverprogress", "cover progress", "封面进度", "进度壁纸" },
        description = "把当前阅读书籍封面与阅读进度写成固定屏保图片。",
        category = "device_beauty",
        capabilities = { "screensaver" },
        recommended = true,
        recommendation = "书籍封面 + 阅读进度屏保",
        install_strategy = "standard",
        warning = "beta.18 先作为推荐扩展提供安装与更新，不接入觅阅统一锁屏来源；真机验证稳定后再考虑直接接管。",
    },
    {
        id = "highlightsscreensaver",
        repo = "k-nacion/highlightsscreensaver.koplugin",
        install_dirname = "highlightsscreensaver.koplugin",
        name = "Highlights Screensaver",
        author = "k-nacion",
        aliases = { "highlightsscreensaver", "highlights screensaver", "摘录屏保", "划线屏保", "随机摘录" },
        description = "休眠时随机显示 KOReader 中的划线与摘录，让屏保展示正在积累的阅读内容。",
        category = "device_beauty",
        capabilities = { "screensaver", "reading_tool" },
        recommended = true,
        recommendation = "随机显示书中摘录作为屏保",
        install_strategy = "standard",
        warning = "beta.18 先作为推荐扩展提供安装与更新，不直接加入觅阅统一锁屏来源。",
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
        package = {
            type = "release_asset", version = "v1.2.0",
            artifact = { name = "opds_plus.koplugin.zip", url = "https://github.com/greywolf1499/opds_plus.koplugin/releases/download/v1.2.0/opds_plus.koplugin.zip", size = 107464, sha256 = "1f5a658752bd8cf663041bceb8ed6e1d6773eee811eb4d63627b98fc5a3d271c" },
            install = { dirname = "opds_plus.koplugin", layout = "name-koplugin" },
        },
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
        estimated_unpacked_bytes = 180 * 1024 * 1024,
        max_plugin_bytes = 256 * 1024 * 1024,
        -- Curated packages are resolved before any GitHub probing. Pinyin IME
        -- is intentionally pinned because its repository source archive is not
        -- an installable KOReader plugin; only the Release asset is valid.
        package = {
            type = "release_asset",
            version = "v1.2.0",
            artifact = {
                name = "pinyinime.koplugin-v1.2.0.zip",
                url = "https://github.com/Merpyzf/pinyinime.koplugin/releases/download/v1.2.0/pinyinime.koplugin-v1.2.0.zip",
                size = 63312207,
                sha256 = "14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb",
            },
            install = { dirname = "pinyinime.koplugin", layout = "name-koplugin" },
            compatibility = { min_koreader = "2025.10" },
        },
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
        package = {
            type = "release_asset", version = "v1.5.3",
            artifact = { name = "pinyin_enhancement.koplugin.zip", url = "https://github.com/gytwo/pinyin_enhancement.koplugin/releases/download/v1.5.3/pinyin_enhancement.koplugin.zip", size = 989119, sha256 = "1e4fdc46ebb15d2b1ca6850df46f7001fe57278e90f143a2352106bc7c356e92" },
            install = { dirname = "pinyin_enhancement.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "1.3.0",
            artifact = { name = "filebrowserplus.koplugin-v1.3.0-linux-armv7.zip", url = "https://github.com/patelneeraj/filebrowserplus.koplugin/releases/download/1.3.0/filebrowserplus.koplugin-v1.3.0-linux-armv7.zip", size = 9386518, sha256 = "38af5beab9aeb504bb698f5db2629967cf64e4408e774b58daf9b02a2565238b" },
            install = { dirname = "filebrowserplus.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v1.4.5",
            variants = {
                armv7 = { name = "localsend-koplugin-armv7.zip", url = "https://github.com/kaikozlov/localsend.koplugin/releases/download/v1.4.5/localsend-koplugin-armv7.zip", size = 7391257, sha256 = "baf8f20cc54274a418b51b96a58fbbe6e8447d98b8cb909dbe2634826a0eaa9d" },
                arm64 = { name = "localsend-koplugin-arm64.zip", url = "https://github.com/kaikozlov/localsend.koplugin/releases/download/v1.4.5/localsend-koplugin-arm64.zip", size = 7114066, sha256 = "4dd216654cd16e8270fe18b3225aa2dfa79bd1c60f8fc3ae17e33ac688877e90" },
                arm_legacy = { name = "localsend-koplugin-arm-legacy.zip", url = "https://github.com/kaikozlov/localsend.koplugin/releases/download/v1.4.5/localsend-koplugin-arm-legacy.zip", size = 7419991, sha256 = "a224927775123c67e6825ad04e91e506250f78391361bf3dfcd1bb5772b820bc" },
            },
            install = { dirname = "localsend.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v0.1.1",
            artifact = { name = "readeck.koplugin-v0.1.1.zip", url = "https://github.com/iceyear/readeck.koplugin/releases/download/v0.1.1/readeck.koplugin-v0.1.1.zip", size = 64106, sha256 = "09b67ee28e36fc5d43e317f73f403581c7ef92eddb1483a8896cc967c71d4b61" },
            install = { dirname = "readeck.koplugin", layout = "name-koplugin" },
        },
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
        warning = "卡欧市场目前没有可由觅阅验证并持续跟踪的公开官方 GitHub 仓库，因此觅阅不代替作者分发安装包，也不会猜测下载地址。请从作者的官方发布渠道获取。",
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
        package = {
            type = "release_asset", version = "v1.13.0",
            artifact = { name = "appstore.koplugin.zip", url = "https://github.com/omer-faruq/appstore.koplugin/releases/download/v1.13.0/appstore.koplugin.zip", size = 273795, sha256 = "dde0fcb3d8254a3c573ab8c46e7e5f35b688fb4f4177909211aeae7ed7d76449" },
            install = { dirname = "appstore.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "26.9.3",
            artifact = { name = "storefront.koplugin.zip", url = "https://github.com/ultimatejimmy/storefront.koplugin/releases/download/26.9.3/storefront.koplugin.zip", size = 4840170, sha256 = "5034a5fcd27fbd7516aaee6ed2a1a0fe7a5a2a434c2d40df4b0c55c82f4d3df8" },
            install = { dirname = "storefront.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "2.7.0",
            artifact = { name = "simpleui.koplugin.zip", url = "https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/download/2.7.0/simpleui.koplugin.zip", size = 1638529, sha256 = "dbc296f6c6bb7034d0aab9184752aadcdf9060c782caccb058a6aef4c42171cf" },
            install = { dirname = "simpleui.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v3.2.2",
            artifact = { name = "zenos.koplugin.zip", url = "https://github.com/xZenLabs/zen-os/releases/download/v3.2.2/zenos.koplugin.zip", size = 2258068, sha256 = "9af1ff72ec058d9ed113381aeca6d56b1a11ccfa314beaaa35635eab21aead23" },
            install = { dirname = "zenos.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v1.2.0",
            artifact = { name = "cozyhome.koplugin-v1.2.0.zip", url = "https://github.com/thekimberleyann/cozyhome.koplugin/releases/download/v1.2.0/cozyhome.koplugin-v1.2.0.zip", size = 130832, sha256 = "d84a9649fc9aa7b8b79c1b5688f145a89d518b298f80561bee392153bbe42762" },
            install = { dirname = "cozyhome.koplugin", layout = "name-koplugin" },
        },
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
        package = {
            type = "release_asset", version = "v4.5.1",
            artifact = { name = "bookshelf.koplugin.zip", url = "https://github.com/AndyHazz/bookshelf.koplugin/releases/download/v4.5.1/bookshelf.koplugin.zip", size = 3124627, sha256 = "51fbeb5a5f49183fce607e556bc0aa60d6890314fda8b9f393cf1ce418cda8f9" },
            install = { dirname = "bookshelf.koplugin", layout = "name-koplugin" },
        },
        install_strategy = "standard",
    },
}

local by_repo, by_id, category_map = {}, {}, {}
for _, category in ipairs(M.CATEGORIES) do category_map[category.key] = category end
for _, entry in ipairs(M.ENTRIES) do
    if entry.repo then by_repo[entry.repo] = entry end
    for _, alias in ipairs(type(entry.repo_aliases)=="table" and entry.repo_aliases or {}) do
        if tostring(alias or "")~="" then by_repo[tostring(alias)] = entry end
    end
    if entry.id then by_id[entry.id] = entry end
end

local function normalized_alias(value)
    return tostring(value or ""):lower():gsub("[%s%p_]+", "")
end

function M.known_repo(repo)
    return by_repo[tostring(repo or "")]
end

function M.canonical_repo(repo)
    local entry=M.known_repo(repo)
    return entry and tostring(entry.repo or repo or "") or tostring(repo or "")
end

function M.install_dirname(entry)
    entry=type(entry)=="table" and entry or {}
    local package=type(entry.package)=="table" and entry.package or {}
    local install=type(package.install)=="table" and package.install or {}
    local dirname=tostring(entry.install_dirname or install.dirname or "")
    if dirname=="" then dirname=tostring(entry.repo or ""):match("([^/]+)$") or "" end
    return dirname
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

function M.package_source(entry, arch)
    entry=type(entry)=="table" and entry or {}
    local package=type(entry.package)=="table" and entry.package or nil
    if not package then return nil,"此扩展尚未收录确定的一键安装包" end
    local artifact
    if type(package.variants)=="table" and tostring(arch or "")~="" then
        local variant=package.variants[tostring(arch)]
        if type(variant)=="table" then artifact=type(variant.artifact)=="table" and variant.artifact or variant end
    end
    artifact=artifact or (type(package.artifact)=="table" and package.artifact or package)
    local url=tostring(artifact.url or "")
    local size=tonumber(artifact.size or 0) or 0
    local sha256=tostring(artifact.sha256 or ""):lower():gsub("[^0-9a-f]","")
    local install=type(package.install)=="table" and package.install or {}
    local dirname=tostring(install.dirname or package.install_dirname or M.install_dirname(entry) or "")
    if not url:match("^https://") then return nil,"目录安装包地址无效" end
    if size<=0 then return nil,"目录安装包缺少精确文件大小" end
    if #sha256~=64 then return nil,"目录安装包缺少有效 SHA-256" end
    if not dirname:match("^[%w%._%-]+%.koplugin$") or dirname=="miuread.koplugin" then
        return nil,"目录安装包缺少有效插件目录"
    end
    local version=tostring(package.version or artifact.version or "")
    return {
        url=url,size=size,sha256=sha256,version=version,expected_dir=dirname,
        asset_name=tostring(artifact.name or url:match("/([^/?#]+)$") or "package.zip"),
        source="catalog-package",channel="catalog",remote_ref="catalog:"..tostring(entry.id or entry.repo or dirname)..":"..version,
        deterministic=true,layout=tostring(install.layout or ""),
    }
end

local function release_asset_sha(value)
    local sha=tostring(value or ""):lower():match("^sha256:([0-9a-f]+)$")
        or tostring(value or ""):lower():match("^([0-9a-f]+)$")
    return sha and #sha==64 and sha or ""
end

local function release_asset_score(entry,asset,arch)
    local name=tostring(asset and asset.name or "")
    local lower=name:lower()
    if name=="" or tostring(asset.browser_download_url or "")=="" or (tonumber(asset.size) or 0)<=0 then return nil end
    if not lower:match("%.zip$") then return nil end
    local source_archive=lower:match("^source%s+code") or lower:match("^source[%._%-]")
        or lower:match("[%._%-]source[%._%-]") or lower:match("^sources?%.zip$")
        or lower:match("[%._%-]sources?%.zip$")
    if lower:find("sha256",1,true) or lower:find("checksum",1,true) or lower:find("symbols",1,true)
        or lower:find("debug",1,true) or source_archive then return nil end
    local score=0
    if lower:find(".koplugin",1,true) then score=score+120 end
    local repo_name=tostring(entry and entry.repo or ""):match("([^/]+)$") or ""
    local bare=repo_name:lower():gsub("%.koplugin$","")
    if bare~="" and lower:find(bare,1,true) then score=score+55 end
    if tostring(asset.content_type or ""):lower():find("zip",1,true) then score=score+8 end
    if type(entry and entry.asset_patterns)=="table" and tostring(arch or "")~="" then
        local patterns=entry.asset_patterns[tostring(arch)]
        if type(patterns)=="table" and #patterns>0 then
            local matched=false
            for _,pattern in ipairs(patterns) do
                pattern=tostring(pattern or ""):lower()
                if pattern~="" and lower:find(pattern,1,true) then matched=true; score=score+80; break end
            end
            if entry.architecture_sensitive==true and not matched then return nil end
        end
    end
    -- Unknown community repositories do not have per-plugin architecture
    -- metadata. Prefer a package whose filename explicitly matches this CPU and
    -- reject explicit packages for another CPU. Final ELF validation still runs
    -- after extraction, so filenames are only a selection hint, not trust.
    local current=tostring(arch or "")
    if current~="" and current~="unknown" then
        local explicit={
            arm64={"arm64","aarch64"}, armv7={"armv7","armhf"}, arm_legacy={"arm-legacy","arm_legacy","armv6","armv5"},
            x86_64={"x86_64","amd64"}, x86={"i386","i686","x86"}, mips={"mips"},
        }
        local seen_arch,matched=false,false
        for key,tokens in pairs(explicit) do
            for _,token in ipairs(tokens) do
                if lower:find(token,1,true) then
                    seen_arch=true
                    if key==current then matched=true end
                end
            end
        end
        if seen_arch and not matched then return nil end
        if matched then score=score+70 end
    end
    return score
end

local function inferred_asset_dirname(asset_name)
    asset_name=tostring(asset_name or "")
    local seen,dirs={},{}
    for name in asset_name:gmatch("([%w%._%-]-%.koplugin)") do
        name=name:gsub("^[%._%-]+","")
        if name~="" and name~="miuread.koplugin" and not seen[name] then
            seen[name]=true
            dirs[#dirs+1]=name
        end
    end
    if #dirs==1 then return dirs[1] end
    return ""
end

local function release_source_from_asset(entry,release,asset)
    local repo=tostring(entry.repo or "")
    local dirname=M.install_dirname(entry)
    local asset_name=tostring(asset and asset.name or "")
    if not dirname:match("^[%w%._%-]+%.koplugin$") then
        dirname=inferred_asset_dirname(asset_name)
    end
    if not dirname:match("^[%w%._%-]+%.koplugin$") or dirname=="miuread.koplugin" then
        return nil,"无法从仓库或安装包名确定唯一插件目录"
    end
    local sha=release_asset_sha(asset and asset.digest)
    local version=tostring(release.tag_name or release.name or "")
    return {
        url=tostring(asset and asset.browser_download_url or ""),size=tonumber(asset and asset.size) or 0,sha256=sha,
        version=version,expected_dir=dirname,asset_name=tostring(asset and asset.name or "package.zip"),
        source="github-release-asset",channel="release",remote_ref="release:"..version,
        deterministic=true,layout="release-auto",allow_missing_sha=sha=="",official_release_asset=true,
    }
end

-- Return all plausible official Release assets in deterministic score order.
-- This is intentionally separate from selection so the UI can ask the user if
-- two equally good artifacts remain instead of silently guessing one.
function M.release_package_candidates(entry, release, arch)
    entry=type(entry)=="table" and entry or {}
    release=type(release)=="table" and release or {}
    local ranked={}
    for _,asset in ipairs(type(release.assets)=="table" and release.assets or {}) do
        local score=release_asset_score(entry,asset,arch)
        if score then
            local source=release_source_from_asset(entry,release,asset)
            if source then ranked[#ranked+1]={source=source,score=score} end
        end
    end
    table.sort(ranked,function(a,b)
        if a.score~=b.score then return a.score>b.score end
        return tostring(a.source.asset_name)<tostring(b.source.asset_name)
    end)
    local out={}
    for _,item in ipairs(ranked) do
        item.source._asset_score=item.score
        out[#out+1]=item.source
    end
    return out
end

-- beta.17: an official stable Release decides the package identity. GitHub's
-- `/releases/latest` is not trusted because it may point at a channel/manifest
-- release. Mirrors only transport those exact official bytes. If two top
-- candidates tie, return the candidate list so the caller can ask instead of guessing.
function M.release_package_source(entry, release, arch)
    local candidates=M.release_package_candidates(entry,release,arch)
    if #candidates==0 then return nil,"最新 Release 没有可识别的插件 ZIP",candidates end
    if #candidates>1 and tonumber(candidates[1]._asset_score)==tonumber(candidates[2]._asset_score) then
        return nil,"最新 Release 有多个同等候选安装包，需要选择",candidates
    end
    local source=candidates[1]
    source._asset_score=nil
    return source,nil,candidates
end

function M.release_is_stable(release)
    release=type(release)=="table" and release or {}
    return release.draft~=true and release.prerelease~=true
end

-- GitHub /releases/latest can point at a channel/manifest Release rather than a
-- plugin ZIP. Walk recent stable releases in GitHub order and stop at the newest
-- release that actually exposes an installable asset. An ambiguous newest
-- release is surfaced for user choice instead of silently falling back older.
function M.best_release_source(entry,releases,arch)
    for _,release in ipairs(type(releases)=="table" and releases or {}) do
        if M.release_is_stable(release) then
            local source,err,candidates=M.release_package_source(entry,release,arch)
            if source then return release,source,nil,candidates end
            if type(candidates)=="table" and #candidates>0 then
                return release,nil,err,candidates
            end
        end
    end
    return nil,nil,"近期正式 Release 没有可识别的插件 ZIP",{}
end

-- Source archives are allowed only after the GitHub Contents API has proved the
-- repository itself is a complete KOReader plugin (main.lua + _meta.lua at the
-- root or in one unambiguous *.koplugin directory). This keeps source fallback
-- generic; no per-plugin source allow-list is needed.
function M.source_package_source(entry, repo_info, source_probe)
    entry=type(entry)=="table" and entry or {}
    repo_info=type(repo_info)=="table" and repo_info or {}
    source_probe=type(source_probe)=="table" and source_probe or repo_info.source_probe
    if type(source_probe)~="table" or source_probe.installable~=true then
        return nil,"GitHub 源码结构尚未确认可直接安装"
    end
    local repo=tostring(entry.repo or "")
    local dirname=tostring(source_probe.expected_dir or M.install_dirname(entry) or "")
    if not repo:match("^[%w%._%-]+/[%w%._%-]+$") then return nil,"源码仓库地址无效" end
    if not dirname:match("^[%w%._%-]+%.koplugin$") or dirname=="miuread.koplugin" then
        return nil,"源码安装目录无效"
    end
    local branch=tostring(source_probe.branch or repo_info.default_branch or "main")
    if branch=="" or branch:find("[^%w%._%-%/]") then return nil,"源码分支无效" end
    local url="https://github.com/"..repo.."/archive/refs/heads/"..branch..".zip"
    return {
        url=url,size=0,sha256="",version="source:"..branch,expected_dir=dirname,
        asset_name=(repo:match("([^/]+)$") or "plugin").."-"..branch:gsub("/","-")..".zip",
        source="github-source-verified",channel="source",remote_ref="source:"..branch,
        deterministic=true,layout=tostring(source_probe.path or "source-root"),allow_missing_sha=true,
        verified_source=true,source_probe_path=tostring(source_probe.path or ""),
    }
end

function M.has_installable_package(entry, arch)
    return M.package_source(entry,arch)~=nil
end

return M
