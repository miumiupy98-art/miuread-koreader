# 6.0.0 Stable Release - Verification

以下是发布验收标准。实际 CI 和真机验收结果以对应 Release PR 与发布记录为准，不因创建候选分支而自动视为通过。

## 发布门槛

1. 配置、元数据同为 `6.0.0`，Schema 136，默认 OTA 为 stable；Beta workflow 独立保留。
2. Lua 5.1 全目录语法检查，LuaJIT 与核心单元/契约回归测试通过。
3. 重点检验精确阅读进度、pending 恢复、书架增删、读完状态、两套登录授权、翻译和书摘复制。
4. 比对 `miuread.koplugin` 发布 ZIP 清单、大小、SHA-256、运行时库和跨平台 codec。
5. Kindle、Kobo、Android 至少覆盖可用设备的登录/下载/同步/更新冒烟测试；不把 CI 视为真机替代。
6. 审查变更和版本号后再合入 main，最后从 main 发布 `v6.0.0`。

# 6.0.0-beta.1 Verification

- `tools/verify_600_beta1.py`: validates 6.0.0-beta.1 identity, Schema 136, inherited progress/shelf/bookstore contracts, lean-package boundaries, same-account Native shelf-auth preservation, independent shelf-auth revocation, bookstore copy polish, and StorePerf log throttling.
- Historical contract tests for beta.19 mapping and 5.9.1-beta.1 progress recovery no longer pin the current release to an old version string; they continue to validate the retained behavior.
- Release workflow still installs Lua 5.1 and LuaJIT and runs the production regression set before packaging.
