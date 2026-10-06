# MiuRead

> **5.9.0-beta.19 · Robust Local Mapping & Quiet Position Sync**

5.9.0 开始把“本机/云端冲突需要用户判断”改为无感云端镜像：打开书籍时自动按同步因果和更新时间选择最新阅读状态，在定位完成前短暂保护翻页；精确 `chapter_uid + co` 仍是最终验收依据。账号书架默认使用微信云端顺序，已读完状态与当前位置分离解析，自动云端跳转可以短时撤回。

本仓库同时维护正式版与内测版：

- `main`：正式版
- `beta`：内测版
- 正式 OTA：`stable-channel/update.json`
- 内测 OTA：`beta-channel/update-beta.json`

## Versions

- 正式版：以 GitHub Releases 中最新的非 Pre-release 为准。
- 内测版：以 GitHub Releases 中最新的 Pre-release 为准。

完整版本记录见 [`CHANGELOG.md`](CHANGELOG.md)。

当前 beta 开发基线：`5.9.0-beta.19`。本版本以 5.8.0-beta.26 为兼容基线，Schema 升至 136；5.9 beta 阶段对新的 `position_state` 与旧进度字段双写，以便继续验证多设备 latest-wins 而不牺牲回退能力。


## 5.9 beta.5 highlights

- 开书立即恢复本机页面，云端 position metadata 在后台确认；已有精确本地快照时先走轻量 freshness 判断，remote 确认更新后才启动重型定位。
- 删除“用户已经翻页 → local wins”的旧语义；以可信 verified anchor + 真实阅读事件时间统一判断 `LOCAL_NEWER / REMOTE_NEWER / ALIGNED / CONFLICT`。
- 新增 progress write fence：remote 未确认、remote newer 或 conflict 时禁止自动本机写回，避免旧 Kindle 位置覆盖更新云端。
- `raw_percent` 仅保留为诊断字段；canonical progress、finished、CloudAnchor 与 ReadReport 均以精确位置状态为准。
- exact-co 定位加入已验证 XPointer 缓存和 text-anchor rescue，percent correction 最多一次 bounded fallback。
- 阅读时间改为 best-effort：运行期最多两次尝试，仍失败静默丢弃，不再跨重启持久 pending 或污染主页总体同步状态。
- Schema 136 与 beta.4 的 position-state stack overflow StoreRepair 保持不变。

## Installation

1. 在 GitHub Releases 下载需要的版本。
2. 解压后将完整的 `miuread.koplugin` 目录放入 KOReader 的插件目录。
3. 完整重启 KOReader。
4. 支持双更新通道的版本可在“觅阅设置 → 更新与关于 → 更新通道”中选择正式通道或内测通道。

## 书架阅读状态

桌面模式刷新微信书架会同步手机端的“已读完”标记，并在后台更新当前页的阅读百分比，无需先下载书籍。手动点击书架的“刷新”也会触发更新；翻页后会补齐该页的进度。离线时保留缓存，Kindle 上尚未上传的阅读进度优先显示。

长按微信书架中的书籍，或在阅读菜单的“当前书籍”中，可标记或取消“已读完”，无需先下载。操作保留阅读位置，并在微信读书回读确认后更新状态。离线操作会保存；联网刷新书架或唤醒后继续同步。未确认的操作可从同一菜单重试或更改。

精确阅读位置在打开书籍时检查云端、在关闭或休眠时上传（选择手动上传模式时需手动操作）。离线补传也会先检查云端，按已确认的共同位置和阅读事件时间判断新旧；无法可靠判断时，保留本机位置等待选择。

## Release Process

- Stable tag：`vX.Y.Z`
- Beta tag：`vX.Y.Z-beta.N`
- 正式版发布到 `stable-channel`
- 内测版发布到 `beta-channel`
- 创建 Tag 后，发布工作流会自动同步分支源码中的版本号、发布通道与 `CHANGELOG.md`，再把 Tag 指向同步后的提交。
- Beta Tag 必须创建在 `beta` 最新提交；Stable Tag 必须创建在 `main` 最新提交。
- 最终分支源码、Tag 源码、Release 安装包与 OTA 清单保持同一版本。

仓库根目录 `update.json` 仅保留为旧正式版 OTA 桥接入口，不作为当前正式版实时更新清单。

## Origin and License

MiuRead originated as a modified version of `finlater/weread.koplugin` v0.1.1 and has since undergone substantial restructuring, modification, and extension.

MiuRead is an unofficial community project and is not affiliated with or endorsed by WeRead, Tencent, KOReader, or their maintainers.

This project is distributed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES` for details.
