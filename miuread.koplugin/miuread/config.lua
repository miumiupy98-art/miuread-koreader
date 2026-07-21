local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "1.1.27",
    SCHEMA = 26,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 更新清单固定保存在仓库根目录；清单中的下载地址指向
    -- GitHub Release 全量包。旧版本仍可通过备用地址升级到本版本。
    UPDATE_MANIFEST = "https://raw.githubusercontent.com/miumiupy98-art/miuread-koreader/main/update.json",
    UPDATE_MANIFESTS = {
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
