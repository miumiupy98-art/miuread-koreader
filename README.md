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

## 微信读书书城

在觅阅菜单中选择“微信读书书城”，可浏览为你推荐、排行榜、分类及子分类，并搜索微信读书全库。主页推荐快捷栏默认显示“书城”；长按“书城”可直接搜索微信读书、我的书架或批注。“搜索”仍可单独启用，默认顺序紧挨“书城”；这两个入口均可配置到主页快捷栏，“书城”也可配置到下拉控制中心或 KOReader 手势。升级时仅将未自定义的旧推荐快捷栏中的“搜索”替换为“书城”，已有的自定义开关与排序保留；旧版自动追加在末尾的“书城”会移到“搜索”旁。

列表显示封面、作者、推荐值和推荐理由。每次获取一批书籍，使用“上一批 / 下一批”继续浏览；已获取的列表在当前会话中缓存，超过 15 分钟会标记为缓存，可点击“刷新”获取最新内容。排行榜和分类可直接联网浏览；个性化推荐、相似推荐与管理微信书架需要登录。

点击书籍后可查看详情、相似推荐、下载到本机或“加入微信书架”。已在微信书架的书籍显示“从微信书架移除”，也可在主页或微信书架中长按微信读书书籍找到此入口；移除前会确认，本机已下载的文件会保留。添加和移除均在回读云端确认后刷新书架；若请求中断或结果不明，后续操作只核对原操作的结果，需确认当前状态后才可再次提交。

首次移除可能需要单独授权书架管理：点击“微信扫码授权”，使用当前账号对应的微信扫描二维码。授权完成后再次选择移除；原有网页登录保持不变。

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
