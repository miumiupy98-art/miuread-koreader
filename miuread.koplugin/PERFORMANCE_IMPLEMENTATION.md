# 5.8.0-beta.6 / beta.7 性能实施矩阵

本文件对应 #86/#87/#90/#71 的性能重构方案。beta.6 先隔离主页回归；beta.7 在 beta.6 上累积 Reader/ReadReport/功耗修复。

## beta.6 已落地
- 统一数据层保留；`shelf/recent/account/mp` 使用按 section/page/signature 的快照缓存。
- Home rendered section 层限制为 3，旧 revision 同逻辑视图立即淘汰。
- section 切换首帧使用 `ui` waveform，静止后合并一次 `full` 清理刷新，不降低最终显示质量。
- Reader park 时释放非活动 Home 层，仅保留当前 HomeShell。
- Scheduler 增加无 timer 的 PARK/WAKE；memory/foreground/annotation 阻塞不再周期轮询。
- QuickPanel 使用同步摘要缓存，不在打开前扫描全部持久化 session/library。
- Wi-Fi 文案拆分 radio/connected/online，不再把 online probe 等待统一显示成“识别中”。
- local/shelf/stats/cover 延续原有异步 worker，并统一受 Scheduler/前台 barrier 控制；Reader/suspend 已有 hard cancel 路径保留。
- schema 不变；migration 改为内存串行、一次 atomic flush；已有 settings payload 校验+备份回滚继续保留。
- #71 的下载退出 quiesce、断点保留逻辑保持不变。

## beta.7 累积补齐
- Reader rebuild resume grace、Reader 生命周期/input hook generation 诊断。
- ReadReport stale identity fuse：停止过期 daemon/poll，不再每 10 秒输出 stale。
- Reader finalizer 更短硬期限；用户唤醒优先取消旧 finalizer（原 beta.5 已有，保留并验证）。
- RuntimePressure 在 Reader 下主动释放 Home 重层，并阻止新 Home 重任务。
- Reader open/close 文件指纹与阶段日志，辅助区分 CRE full render 与 MiuRead 延迟。
- 前台直接 `io.popen` 路径审计：QuickPanel 蓝牙保持 memory-only；metadata/扩展/维护命令只允许后台/用户显式路径。
- Broken pipe 不修改 KOReader 核心；新增 MiuRead input lifecycle 日志与旧 generation callback 防护，用于追到第一现场。

## beta.7 实际落点补充
- `miuread/background_scheduler.lua`: active worker event-driven release；RuntimePressure 下自动 PARK。
- `miuread/sync.lua`: stale identity 两次确认后 fuse poll，当前 job 激活时 reset。
- `main.lua`: Resume rebuild grace、HomeShell memory logging、InputLifecycle、EPUB size/mtime、跨章节 thought cache release。
- `miuread/thoughts.lua`: popup/group resident cache 16/24 -> 8/12。
- `miuread/bluetooth.lua`: timeout runner lazy resolve；模块 import/QuickPanel 不触发 shell probing。
- `miuread/config.lua`: finalizer hard deadline 12 秒。

### 已在 beta.5/既有代码中实现并在 beta.7 保留（不重复重写）
- 精确阅读进度计算公式不改；结束阅读先冻结本地位置/本地 pending，再做云上传。
- Kindle User Wake 已调用 reader-finalizer cancel/writer-barrier invalidation，优先级高于旧 finalizer。
- DownloadTask 的 pause reasons 已是共享集合，`thought_popup/page_transition/...` 只在 reason 0↔1 状态变化时生效并有 stale transient 恢复。
- Settings flush 已有 payload `loadstring` 校验、atomic_write、目标文件复验、previous/backup 回滚；beta.6 仅消除 migration 的重复 flush。
- #71 的 Exit/Restart download quiesce、强制停止后的 interrupted 状态、断点保留路径保持。
- CRE 本版不改 KOReader；MiuRead Reader-open 不写 EPUB，并记录 size/mtime 用于确认同一文件是否被改写。
- Broken pipe 本版不侵入 KOReader input core；MiuRead hook ownership/generation 可追踪，避免把未证明的核心问题强行“修复”。
