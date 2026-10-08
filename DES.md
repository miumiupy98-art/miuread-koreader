# 5.9.1-beta.1

本版不重写 5.9 的进度同步协议，而是针对真机 crash 暴露的 ReadingEnd / pending recovery 边缘状态做收口。

最明确的根因来自 beta.19 的被动精确缓存：缓存已经保存原生 `chapterUid + wr_data_co`、`native_offset=true` 与整书进度，但行记录遗漏 `safe=true / coordinate_safe=true / precise=true`。因此退出阅读时它可以先被记录为 `final_position_captured`，进入 detached upload 后又被安全校验拒绝为 `position_unavailable`；Home 随后虽然看见一条 pending，却可能没有 send / verify / resubmit / coordinate 动作。5.9.1-beta.1 统一原生 exact snapshot 的安全语义，并对已存在的 beta.19 精确 pending 做一次性迁移修复。

对于真正无法在退出瞬间完成 source mapping 的情况，本版新增 `Progress Recovery Capsule`。Reader 仍存活时捕获的 immutable source anchor、XPointer、显示进度和 progress sequence/epoch 会写入 `pending_unresolved_position`。回到 Home 后，恢复流程先利用持久化锚点尝试本地 exact source，再在允许联网时 fresh 获取对应 Web Reader source；恢复出 native chapter/co 后仍须 fresh GET 云端并通过现有 freshness resolver 决定是否发送，已提交事务仍只做 readback verify。

进度失败列表现在能区分“保存了退出锚点、可后台恢复”和“旧记录确实缺少恢复材料”。前者可直接在 Home 选择“恢复精确位置”，并被自动恢复流程优先处理；后者明确显示为失效记录，可由用户清除，不再留下无动作的模糊 pending。

ReadReport 也收紧了生命周期日志：ReadingEnd 或 progress-priority 主动停止 worker 后的正常退出不再标记为 `unexpected`，且不会为了已请求停止的 worker 重新拉起；阅读期间真实异常退出仍保留一次自动重启。

本版不放宽精确性要求：不会用百分比近似替代 native `wr_data_co`，不会因为网络暂不可用而假定本机更新，也不修改 30 秒时钟偏差保护。beta.19 多锚点、beta.18 fresh context、progress epoch、remote-wire fresh GET、ProgressFence、rollback 与 exact cloud readback 全部保留。
