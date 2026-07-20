local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "1.1.16",
    SCHEMA = 25,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 更新清单由 GitHub Actions 自动生成。旧版本和当前版本均可
    -- 通过 Release 全量包直接升级，用户数据保存在插件目录之外。
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
