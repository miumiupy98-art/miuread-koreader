local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "1.1.13",
    SCHEMA = 25,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 1.1.13 是更新架构过渡版：
    -- 旧版仍可通过 main/update.json 升级到本版；本版以后优先读取
    -- GitHub Release 中由 Actions 自动生成的 update.json。
    UPDATE_MANIFEST = "https://github.com/miumiupy98-art/miuread-koreader/releases/latest/download/update.json",
    UPDATE_MANIFESTS = {
        "https://github.com/miumiupy98-art/miuread-koreader/releases/latest/download/update.json",
        "https://raw.githubusercontent.com/miumiupy98-art/miuread-koreader/main/update.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,
}
return C
