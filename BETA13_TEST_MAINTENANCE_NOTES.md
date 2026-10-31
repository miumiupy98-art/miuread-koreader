# 6.5.0-beta.13 — 测试维护版（不改变同步运行逻辑）

基线：用户已交付并核实的 6.5.0-beta.12 完整源码。仅更新版本标识、非运行时测试和本说明。

## 已修正的旧断言
- `tools/test_beta17_sync_contract.lua`：不再要求 `force_write=true`、禁止 Web 云端预检或要求 Kindle 强制权威标记；改为检查当前 `Web-only` 预检、可信锚点、过期记录校验、同位置免重复提交以及云端回读验证。
- `tools/test_beta17_fixed_paths.py`：评论菜单断言与 beta.12 已合并的下载/更新入口一致；进度及阅读时间断言保留。
- `tools/test_beta12_freeze_contract.py`：版本元数据检查改为“config 与 _meta 版本一致”，不再硬编码 beta.12；冻结函数及关键模块的 SHA-256 校验不变。
- 新增 `tools/test_beta13_pending_replay_behavior.lua`：隔离调用真实 `_submit_saved_pending_progress` 实现、用模拟 Store 与 Web 返回测试八种安全场景，不改变主程序。

## 不变部分
- `main.lua`、`sync.lua`、阅读时间和坐标处理模块、下载和评论的全部运行时代码：逐字节保持 beta.12 原样。
- 只有 `miuread/config.lua` 与 `_meta.lua` 内版本从 beta.12 升至 beta.13。
- GitHub Beta Release 的 `.github/workflows/release-beta.yml`、`.github/scripts/sync_release_identity.py` 保持 beta.5 原版，Release 仍只产出插件安装 ZIP。
- 未执行 GitHub 发布或修改 GitHub 仓库。

## 使用限制
- 这是对过时测试与版本元数据的修订，**不是**新的进度算法修复，也不意味着真实微信读书 / Kindle 端到端测试已完成。
- 本地 Lua 测试在可用的 Lua 5.4 解释器兼容层运行，不等于 Kindle LuaJIT 和真实云端接口验证。
- 有些更早的历史测试绑定已废弃的版本号/菜单/发布行为，未作为本版发布标准。
