local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "4.3.2",
    SCHEMA = 112,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 正式版更新清单由 tag 发布流程生成，并作为固定 stable-channel Release
    -- 资源提供。main/update.json 仅用于把 4.1.2 等旧正式版桥接到 4.3.0；
    -- 4.3.0 起插件自身只读取 stable-channel，避免旧桥接清单参与后续判断。
    UPDATE_CHANNEL = "stable",
    UPDATE_CHANNEL_LABEL = "正式通道",
    UPDATE_MANIFEST = "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
    UPDATE_MANIFESTS = {
        "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    AUTO_UPDATE_INTERVAL = 24 * 60 * 60,
    AUTO_UPDATE_RETRY_INTERVAL = 6 * 60 * 60,

    READ_INTERVAL = 60,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,

    -- Coalesce page-turn control snapshots. Reading position stays in memory
    -- and is written at most once per window; suspend/close still flushes now.
    CONTROL_WRITE_DELAY = 60,

    LOW_MEMORY_SETTING = "DGLOBAL_CACHE_FREE_PROPORTION",
    LOW_MEMORY_RATIO = 0.15,

    -- Runtime performance protection is based on measured UI latency, not on
    -- device model or firmware. The lightweight flag is shared with the
    -- download subprocess so an already-running job can adapt immediately.
    LIGHTWEIGHT_MODE_FLAG = "/tmp/miuread-lightweight-mode.flag",
    PERFORMANCE_SLOW_MS = 1200,
    PERFORMANCE_EXTREME_MS = 2500,
    PERFORMANCE_WINDOW_SECONDS = 10 * 60,
    PERFORMANCE_REPEAT_COUNT = 2,
    PERFORMANCE_PROMPT_COOLDOWN = 7 * 24 * 60 * 60,

    -- Different user-visible operations have different normal costs.
    -- Only repeated slow samples of the SAME kind are combined. A single
    -- extreme Reader->Home delay may prompt because it is already severe.
    PERFORMANCE_RULES = {
        default = {slow_ms = 1200, extreme_ms = 2500, repeat_count = 2},
        home_panel = {slow_ms = 1000, extreme_ms = 2000, repeat_count = 2},
        reader_toolbar = {slow_ms = 800, extreme_ms = 1800, repeat_count = 2},
        thought_popup = {slow_ms = 1200, extreme_ms = 2500, repeat_count = 2},
        reader_open = {slow_ms = 3000, extreme_ms = 6000, repeat_count = 2},
        reader_home = {slow_ms = 4000, extreme_ms = 8000, repeat_count = 2, single_extreme = true},
    },

    -- Lightweight mode does not disable features. It gives the foreground
    -- longer quiet windows, refreshes automatic sources less often, and
    -- processes metadata/covers in smaller batches with wider gaps.
    LIGHTWEIGHT_HOME_REMOTE_TTL = 30 * 60,
    LIGHTWEIGHT_HOME_LOCAL_TTL = 60 * 60,
    LIGHTWEIGHT_HOME_IDLE_DELAY = 6,
    LIGHTWEIGHT_READER_IDLE_SECONDS = 1.5,
    LIGHTWEIGHT_LOCAL_METADATA_QUEUE = 3,
    LIGHTWEIGHT_REMOTE_COVER_QUEUE = 4,
    LIGHTWEIGHT_DERIVATIVE_COVER_QUEUE = 1,
    LIGHTWEIGHT_METADATA_GAP = 0.75,
    LIGHTWEIGHT_COVER_GAP = 0.65,
    LIGHTWEIGHT_DERIVATIVE_GAP = 1.0,

    -- Online features are verified by their real request. Renewal is recovery,
    -- never a prerequisite. Diagnostics never include account secrets.
    -- beta.11 restores explicit/manual cloud annotation writes after moving the
    -- coordinate basis to complete decrypted XHTML. Diagnostic export remains
    -- available separately and never performs cloud writes.
    ANNOTATION_COORD_DIAGNOSTIC_ONLY = false,

    AUTH_NOTICE_FAILURE_THRESHOLD = 2,
    DOWNLOAD_AUTO_RESTARTS = 2,
    DOWNLOAD_DIAGNOSTIC_KEEP = 3,

    -- Download networking stays automatic by default. A compatibility prompt
    -- is considered only after several genuinely slow responses, then confirmed
    -- with paired automatic/IPv4 probes against the same host.
    DOWNLOAD_NETWORK_IGNORE_INITIAL_REQUESTS = 1,
    DOWNLOAD_NETWORK_SAMPLE_WINDOW = 4,
    DOWNLOAD_NETWORK_SLOW_REQUIRED = 3,
    DOWNLOAD_NETWORK_SLOW_RESPONSE_SECONDS = 3,
    DOWNLOAD_NETWORK_PROBE_BLOCK_TIMEOUT = 4,
    DOWNLOAD_NETWORK_PROBE_TOTAL_TIMEOUT = 6,
    DOWNLOAD_NETWORK_PROBE_AUTO_MIN_SECONDS = 2,
    DOWNLOAD_NETWORK_IPV4_MAX_RATIO = 0.50,
    DOWNLOAD_NETWORK_IPV4_MIN_GAIN_SECONDS = 1,
    READ_REPORT_AUTH_RETRY_DELAYS = {120, 300, 900, 1800},
    READ_REPORT_CONTEXT_RETRY_DELAYS = {60, 120, 300, 900},

    -- Stream reading: one chapter at a time, rebuilt EPUB in temp only.
    STREAM_READING = true,
    STREAM_TMP_DIR = "/tmp/miuread-stream",
    -- Offline book download removed; only stream chapter EPUB build remains.
}
return C
