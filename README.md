# MiuRead

> **6.0.0 · Stable Release**

觅阅（MiuRead）是面向 KOReader 的非官方微信读书客户端。

6.0.0 正式版基于 `6.0.0-beta.1` 收口，Schema 为 `136`。发布必须通过回归与真机验证，Git 合并无冲突本身并不构成发布验收。

## 版本与更新通道

- `main`：正式版代码分支
- `beta`：独立内测通道，6.0.0 的内测基线为 `6.0.0-beta.1`
- 正式 OTA：`stable-channel/update.json`
- 内测 OTA：`beta-channel/update-beta.json`

## 6.0.0 主要功能

- 5.9 精确进度同步、云端/本地可信锚点判断、失败恢复与旧位置写入保护。
- 微信读书书城、书籍详情/推荐、书架管理、阅读百分比和“已读完”状态同步。
- 登录与书架管理授权仍为两套独立凭证；这是已知功能边界，不是单扫码统一。
- 外文翻译三态、EPUB 安全替换、下载连接复用与插件更新/扩展中心。
- 6.0 内测已进行安装包减重、UI 与日志整理；正式发布前必须检查完整安装包和设备兼容性。

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

## 书架阅读状态

桌面模式刷新微信书架会同步手机端的“已读完”标记，并在后台更新当前页的阅读百分比，无需先下载书籍。手动点击书架的“刷新”也会触发更新；翻页后会补齐该页的进度。离线时保留缓存，Kindle 上尚未上传的阅读进度优先显示。

长按微信书架中的书籍，或在阅读菜单的“当前书籍”中，可标记或取消“已读完”，无需先下载。操作保留阅读位置，并在微信读书回读确认后更新状态。离线操作会保存；联网刷新书架或唤醒后继续同步。未确认的操作可从同一菜单重试或更改。

精确阅读位置在打开书籍时检查云端、在关闭或休眠时上传（选择手动上传模式时需手动操作）。离线补传也会先检查云端，按已确认的共同位置和阅读事件时间判断新旧；无法可靠判断时，保留本机位置等待选择。

## Release Process

- Stable tag：`vX.Y.Z`
- Beta tag：`vX.Y.Z-beta.N`
- 正式版发布到 `stable-channel`
- 内测版发布到 `beta-channel`
- 正式版工作流会核对并同步正式发布身份；内测版必须预先提交匹配的版本号与 CHANGELOG，才能发布 Beta Tag。
- Beta Tag 必须创建在 `beta` 最新提交；Stable Tag 必须创建在 `main` 最新提交。
- 最终分支源码、Tag 源码、Release 安装包与 OTA 清单保持同一版本。

仓库根目录 `update.json` 仅保留为旧正式版 OTA 桥接入口，不作为当前正式版实时更新清单。

## Origin and License

MiuRead originated as a modified version of `finlater/weread.koplugin` v0.1.1 and has since undergone substantial restructuring, modification, and extension.

MiuRead is an unofficial community project and is not affiliated with or endorsed by WeRead, Tencent, KOReader, or their maintainers.

This project is distributed under the GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES` for details.
