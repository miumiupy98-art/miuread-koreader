# beta.13 本地检查结果

## 已通过
- Lua 5.4 语法解析：运行时 174 个 Lua 文件与 tools 中 106 个 Lua 文件均无语法错误。
- 修订的 `tools/test_beta17_sync_contract.lua`：通过（使用当前 Web 云端预检契约）。
- 修订的 `tools/test_beta17_fixed_paths.py`：5 项通过。
- 新增 `tools/test_beta13_pending_replay_behavior.lua`：8 个真实生产函数隔离执行场景通过。
- `tools/test_beta12_freeze_contract.py`：通过（包括冻结功能 SHA-256）。
- beta.9 阅读时间 Worker 归属、beta.10 Web 坐标验证及文本映射、beta.11 重试/恢复、beta.12 旧书定位补全等定向回归：通过。
- 运行时逐文件对照 beta.12：283 个文件清单一致，仅两个版本元数据文件不同。
- Beta 发布工作流与 beta.12（即 beta.5 原版）完全相同。
- 安装 ZIP 逐文件与源码一致，压缩包校验通过。

## 限制与未通过
- 旧的 `tools/test_beta12_sync_contract.lua` 写死 `VERSION = "5.9.0-beta.12"`，并检查该历史分支的代码形态；未纳入本版回归。
- `tools/test_beta9_sync_readtime.lua` 用到了 Lua 5.1 的 `loadstring`，在当前 Lua 5.4 本地运行器下未通过；该失败不能作为 Kindle 行为结论。
- 全部历史测试集未重新报告为 100% 通过，部分旧断言与现在的功能和版本冲突。
- Kindle 真机、实际微信读书接口、在线多设备及 GitHub Release/OTA 尚未执行。
