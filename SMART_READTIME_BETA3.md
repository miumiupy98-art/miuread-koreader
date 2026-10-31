# 6.5.0-beta.3 — 智能阅读时间稳定性修复（源码候选）

本包以 `v6.5.0-beta.2` 对应的 `beta` 源码为基础，仅变更以下文件：

- `miuread.koplugin/miuread/store.lua`：新增独立 Web 计时认证修订号 `web_auth_revision`，旧存档自动兼容；继续保留全局 `auth_revision` 进行 CAS 保护。
- `miuread.koplugin/miuread/sync.lua`：Web 后台服务使用 Web 身份修订号校验；同账号 Web 凭据更新时尝试复用原单进程、同计时段重绑定；选中 Web 却已失活时按限流恢复新的计时段；真正切换账号依旧隔离。
- `miuread.koplugin/main.lua`：恢复未完成前显示 `Web · 正在恢复` / `Web · 等待服务确认`。
- `tools/test_650_smart_time_recovery.lua`：新增针对原生产方法的实际 Lua 行为测试，覆盖同账号 E-Ink Token 续期、Web 凭据变化、全局 CAS、防重复恢复、真正账号切换隔离。

## 关于版本号

该项目当前 Beta 发布工作流是 **无源代码版本提交** 模式。不要为了发布 Beta 把 `miuread.koplugin/_meta.lua` / `miuread.koplugin/miuread/config.lua` / `CHANGELOG.md` 里的历史开发版本号直接提交回 `beta`，否则可能重新引入 `beta → main` 合并冲突。

使用浏览器将本源码提交到 `beta` 后，在 GitHub Actions 的 **Release beta full package** 手动运行，选 **beta** 分支，在 `version` 中填 **`6.5.0-beta.3`**。工作流在 runner 中生成版本身份、变更日志、Git tag、安装包、Beta OTA 清单，不修改 `beta` 源码分支。

**此 ZIP 是完整源码，不是可直接放进 KOReader 的安装包。** 需要经项目的 Release 工作流打包；请勿直接将整个源码 ZIP 当成插件安装包。

## 已执行的本地检查

- Lua 5.4 静态语法分析：275 个 Lua 源码文件，0 错误。
- `tools/test_650_smart_time_recovery.lua`：通过（生产方法片段的实际 Lua 行为测试）。
- `tools/test_637_handoff.lua`：通过（Web→E-Ink 交接屏障、快速重新联网）。
- `tools/test_readtime_live_dispatch.lua`：通过。
- `tools/test_620_readtime_clock.lua`：通过（15/60 秒与关书结算）。
- `tools/test_637_menu_icons_and_handoff.py`：9 项通过。
- `tools/test_632_new_readtime_comment_preload.py`：4 项通过。

当前环境没有可直接用于真实 Kindle 的 KOReader 运行环境，**尚未进行真机上报及服务端数据核对**。部分旧测试依赖 LuaJIT/Lupa（当前环境缺失）；`test_620_readtime_contract.py` 有与旧发布工作流断言相关的失败，未作为本次计时回归通过的证据。

## 需要的 Beta 设备验证

1. 智能模式联网阅读至少 3 分钟，确认 15 秒、约 60 秒周期回执持续成功。
2. 阅读期间刷新 E-Ink 授权或触发 E-Ink 评论读取，确认不会出现 `identity_stale`。
3. 同一本书断网后继续阅读，确认进入 E-Ink 本地计时；重新联网后自动交接。
4. 关书后验证 E-Ink 记录是否自动进入补传流程；核对没有跨段或重复时长。
5. 切换账号或登出时旧服务停止、旧时间不归入新账号。

**限制：** 服务器接收但客户端丢失回执的时间无法在没有幂等凭证的情况下自动安全重发；本版继续采取不重发不确定时间的策略，以避免重复累计。全自动离线采集仍需要 KOReader 阅读统计已开启以及 E-Ink 客户端合法授权。
