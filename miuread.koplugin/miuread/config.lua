local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "5.0.0",
    SCHEMA = 119,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 当前安装包自身仍有 stable/beta 身份；用户选择的 OTA 通道独立保存。
    -- beta.20 起所有实时更新清单都由统一仓库 miuread-koreader 提供。
    UPDATE_CHANNEL = "stable",
    UPDATE_CHANNEL_LABEL = "正式通道",
    UPDATE_MANIFEST = "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
    UPDATE_MANIFESTS = {
        "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
    },
    UPDATE_CHANNELS = {
        stable = {
            label = "正式通道",
            manifest = "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
            manifests = {
                "https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json",
            },
        },
        beta = {
            label = "内测通道",
            manifest = "https://github.com/miumiupy98-art/miuread-koreader/releases/download/beta-channel/update-beta.json",
            manifests = {
                "https://github.com/miumiupy98-art/miuread-koreader/releases/download/beta-channel/update-beta.json",
            },
        },
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

    -- Manifest files are tiny. Fail over quickly between the official route and
    -- mirrors, while package downloads keep their existing generous timeout.
    UPDATE_MANIFEST_RETRIES = 0,
    UPDATE_MANIFEST_CONNECT_TIMEOUT = 4,
    UPDATE_MANIFEST_TOTAL_TIMEOUT = 8,

    -- Warm only a small number of current-chapter comment groups after the
    -- reader has been idle. This removes SQLite cold-open latency from taps
    -- without moving large comment layouts into the foreground.
    THOUGHT_PREWARM_DELAY = 2.8,
    THOUGHT_PREWARM_GROUPS = 6,

    -- Single-chapter reading may prepare exactly one following chapter after
    -- the reader has been stable for a while. It never wakes a sleeping device
    -- just to prefetch, and any explicit user download takes priority.
    CHAPTER_PREFETCH_DELAY = 30,
    -- Hidden next-chapter EPUBs are cache, not formal downloads. Keep them
    -- long enough for a short reading break but prune stale unused entries.
    CHAPTER_PREFETCH_TTL = 24 * 60 * 60,
    -- Failed automatic cover fetches must not restart on every home gesture.
    -- A manual refresh bypasses the runtime backoff once.
    COVER_RETRY_DELAYS = {30, 120, 600, 1800},

    READ_INTERVAL = 60,
    -- beta.24 never replays historical/suspend reading-time debt. Normal
    -- reports stay on the established one-minute cadence and every request is
    -- independently capped, avoiding burst uploads after reconnect/resume.
    READ_REPORT_MAX_ELAPSED_SECONDS = 60,
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
    -- Repeated measured lag enables a temporary UI protection window. In
    -- beta.26 this no longer throttles an already-running downloader; only a
    -- manual lightweight choice or real memory pressure is global.
    PERFORMANCE_AUTO_PROTECT_SECONDS = 10 * 60,
    PERFORMANCE_MEMORY_PROTECT_SECONDS = 30 * 60,

    -- Automatic home maintenance is serialized on memory-constrained Kindles.
    -- Soft pressure enables temporary lightweight behavior; critical pressure
    -- defers optional heavy work until memory becomes available again.
    BACKGROUND_MEMORY_SOFT_KB = 48 * 1024,
    BACKGROUND_MEMORY_CRITICAL_KB = 28 * 1024,
    BACKGROUND_MEMORY_CHECK_SECONDS = 3,
    BACKGROUND_SERIAL_GAP_SECONDS = 0.35,
    BACKGROUND_RETRY_SECONDS = 0.9,
    BACKGROUND_LEASE_TIMEOUT_SECONDS = 300,
    HOME_FOREGROUND_BARRIER_SECONDS = 0.9,
    HOME_POST_READER_BARRIER_SECONDS = 1.8,
    -- Old taps delayed by a real UI stall are discarded instead of being
    -- replayed against a different book after the screen catches up.
    HOME_STALE_TAP_MS = 1200,

    -- Reader discovery and stale-touch protection. The same MiuRead reader
    -- toolbar can be opened by the existing downward swipe or by a deliberate
    -- tap in the top-center band. Short-lived taps carried across the Home ->
    -- Reader transition are consumed before they can become KOReader corner
    -- actions (for example an unintended bookmark).
    READER_OPEN_GESTURE_GUARD_SECONDS = 0.75,
    READER_TOP_MENU_X_MIN = 0.25,
    READER_TOP_MENU_X_MAX = 0.75,
    READER_TOP_MENU_Y_MAX = 0.10,
    HOME_REMOTE_SHELF_TTL_SECONDS = 30 * 60,
    HOME_LOCAL_SHELF_TTL_SECONDS = 60 * 60,
    HOME_REMOTE_COVER_BATCH = 4,
    HOME_REMOTE_COVER_GAP_SECONDS = 0.45,
    HOME_DERIVATIVE_COVER_BATCH = 2,
    HOME_DERIVATIVE_COVER_GAP_SECONDS = 0.50,
    HOME_COVER_THUMB_OVERSAMPLE = 1.22,

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

    -- Lightweight mode does not disable features. Standard mode is faster in
    -- beta.26 now that Home only works on the visible page; lightweight mode
    -- keeps smaller cover batches and wider gaps as a fallback.
    LIGHTWEIGHT_HOME_REMOTE_TTL = 30 * 60,
    LIGHTWEIGHT_HOME_LOCAL_TTL = 60 * 60,
    LIGHTWEIGHT_HOME_IDLE_DELAY = 6,
    LIGHTWEIGHT_READER_IDLE_SECONDS = 1.5,
    LIGHTWEIGHT_LOCAL_METADATA_QUEUE = 3,
    LIGHTWEIGHT_REMOTE_COVER_QUEUE = 2,
    LIGHTWEIGHT_DERIVATIVE_COVER_QUEUE = 1,
    LIGHTWEIGHT_METADATA_GAP = 0.75,
    LIGHTWEIGHT_COVER_GAP = 1.0,
    LIGHTWEIGHT_DERIVATIVE_GAP = 1.1,

    -- Online features are verified by their real request. Renewal is recovery,
    -- never a prerequisite. Diagnostics never include account secrets.
    -- beta.11 restores explicit/manual cloud annotation writes after moving the
    -- coordinate basis to complete decrypted XHTML. Diagnostic export remains
    -- available separately and never performs cloud writes.
    ANNOTATION_COORD_DIAGNOSTIC_ONLY = false,

    AUTH_NOTICE_FAILURE_THRESHOLD = 2,
    DOWNLOAD_AUTO_RESTARTS = 2,
    DOWNLOAD_DIAGNOSTIC_KEEP = 3,

    -- beta.9 opens the task-level network recovery path after the first full
    -- chapter request has exhausted HTTP-level retries. Repeating the same
    -- failing request across several chapters only wastes lock-screen time.
    DOWNLOAD_NETWORK_FAILURE_BREAKER = 1,
    DOWNLOAD_NETWORK_RECOVERY_POLL_SECONDS = 6,
    DOWNLOAD_NETWORK_RECOVERY_MAX_POLL_SECONDS = 15,
    -- beta.9 makes the lock-screen lease follow the useful download lifetime.
    -- Healthy transfers keep Wi-Fi alive until completion. If the association
    -- is lost, recovery keeps probing without a fixed attempt cap; only a long
    -- ten-minute offline window (or low battery) gives the device back to deep
    -- sleep after preserving the chapter checkpoint.
    DOWNLOAD_NETWORK_GUARD_POLL_SECONDS = 8,
    -- beta.11 keeps downloads in an ACTIVE pseudo-lock state instead of
    -- asking Wi-Fi to survive a real system suspend. Kindle still reasserts
    -- ensureConnection at low cadence; Kobo leaves a healthy association alone
    -- because its normal pre-suspend Wi-Fi shutdown is bypassed until download
    -- completion.
    DOWNLOAD_LOCKSCREEN_LINK_GUARD_SECONDS = 5,
    DOWNLOAD_KINDLE_ENSURE_REFRESH_SECONDS = 30,
    DOWNLOAD_KINDLE_ENSURE_RETRY_SECONDS = 5,
    DOWNLOAD_NETWORK_RESTORE_COOLDOWN_SECONDS = 20,
    DOWNLOAD_NETWORK_RESTORE_MAX_ATTEMPTS = 0,
    DOWNLOAD_NETWORK_LOCK_MAX_SECONDS = 600,
    DOWNLOAD_NETWORK_HIBERNATE_SECONDS = 620,
    DOWNLOAD_LOCKSCREEN_MIN_BATTERY_PERCENT = 10,
    DOWNLOAD_BACKGROUND_KEEPALIVE_SECONDS = 12,
    DOWNLOAD_BACKGROUND_STALL_SLEEP_SECONDS = 300,

    -- beta.23 keeps the five-minute sleep policy for a genuinely offline book,
    -- but a worker that is still marked as active and produces no heartbeat is
    -- recovered much earlier from its on-disk chapter checkpoint. Streaming
    -- image transfers emit heartbeats, so large healthy archives are not
    -- mistaken for a stall.
    DOWNLOAD_STALL_RECOVERY_SECONDS = 120,
    -- beta.18 makes every stage that can keep a lock-screen download alive
    -- participate in the same health model. Expensive annotation/package
    -- stages get wider silence windows; any emitted progress heartbeat resets
    -- the timer, so a large but healthy book is never killed merely for being
    -- slow.
    DOWNLOAD_BACKGROUND_STALL_SECONDS = {
        prepare = 120, catalog = 120, resume = 120, content = 150, images = 180,
        underlines = 240, thoughts = 600, footnotes = 240,
        annotation_batch = 180, annotation_apply = 240, transform = 240, package = 300,
    },
    -- Foreground notices remain earlier than recovery. Heavy local stages still
    -- use generous bounds to avoid turning a large comment set into a false
    -- positive.
    DOWNLOAD_FOREGROUND_STALL_NOTICE_SECONDS = 25,
    DOWNLOAD_FOREGROUND_STALL_SECONDS = {
        prepare = 50, catalog = 60, resume = 50, content = 90, images = 120,
        underlines = 240, thoughts = 600, footnotes = 240,
        annotation_batch = 180, annotation_apply = 240, transform = 240, package = 300,
    },
    DOWNLOAD_CANCEL_FORCE_SECONDS = 4,
    DOWNLOAD_STALL_RESTART_GRACE_SECONDS = 3,
    DOWNLOAD_STALL_FAIL_OPEN_SECONDS = 12,
    DOWNLOAD_STALL_AUTO_RESTARTS = 1,
    DOWNLOAD_TRANSFER_HEARTBEAT_SECONDS = 3,
    DOWNLOAD_TRANSFER_HEARTBEAT_BYTES = 512 * 1024,
    DOWNLOAD_STREAM_CHUNK_BYTES = 128 * 1024,

    -- beta.19 heavy-resource arbitration. Ordinary background protection keeps
    -- the beta.16 48/28 MB thresholds; only Native/FileManager transitions use
    -- the higher guard because a resident download child plus FileManager can
    -- exhaust old Kindle memory well before the global critical threshold.
    HEAVY_NATIVE_HIBERNATE_KB = 96 * 1024,
    HEAVY_NATIVE_CRITICAL_KB = 64 * 1024,
    HEAVY_DOWNLOAD_RESUME_MIN_KB = 72 * 1024,

    -- beta.4 coalesces repeated typography taps into one KOReader reflow. On a
    -- low-memory/heavy-download overlap, let the downloader checkpoint first
    -- instead of stacking layout work until the native renderer crashes.
    TYPOGRAPHY_APPLY_DEBOUNCE_SECONDS = 0.42,
    TYPOGRAPHY_REBUILD_HINT_SECONDS = 12,
    TYPOGRAPHY_HIBERNATE_MEMORY_KB = 72 * 1024,
    TYPOGRAPHY_CRITICAL_MEMORY_KB = 48 * 1024,
    TYPOGRAPHY_HEAVY_WAIT_SECONDS = 8,
    TYPOGRAPHY_DOWNLOAD_RESUME_DELAY_SECONDS = 2.2,
    -- Remote cover fetching may coexist with a healthy download. It yields only
    -- when a heavy download stage and real memory pressure overlap.
    DOWNLOAD_COVER_COEXIST_MIN_KB = 80 * 1024,
    DOWNLOAD_HIBERNATE_WAIT_SECONDS = 8,
    DOWNLOAD_INTERACTION_RESUME_DELAY = 1.8,
    -- beta.21 foreground arbitration: ordinary UI interaction no longer hard-pauses
    -- the download worker. Heavy local stages yield behind a short absolute
    -- deadline instead, so a lost UI callback can never strand the task.
    DOWNLOAD_UI_YIELD_SECONDS = 2,
    DOWNLOAD_UI_HEAVY_YIELD_MAX_SECONDS = 4,
    DOWNLOAD_INTERACTION_STALE_SECONDS = 12,
    DOWNLOAD_TRANSITION_STALE_SECONDS = 60,
    HEAVY_WATCH_SECONDS = 10,

    -- beta.17 power lifecycle: short resumes are diagnosed but never forced
    -- back to sleep. Resume keeps optional background work quiet briefly.
    SHORT_WAKE_SECONDS = 5,
    POWER_RESUME_QUIET_SECONDS = 1.0,

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
}
return C
