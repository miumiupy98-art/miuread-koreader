# MiuRead · WeRead Assistant

MiuRead（觅阅 · 微信读书助手）是面向 KOReader 的非官方微信读书客户端。

本仓库同时维护正式版与内测版：

- `main`：正式版
- `beta`：内测版
- 正式 OTA：`stable-channel/update.json`
- 内测 OTA：`beta-channel/update-beta.json`

## Versions

- 正式版：以 GitHub Releases 中最新的非 Pre-release 为准。
- 内测版：以 GitHub Releases 中最新的 Pre-release 为准。

完整版本记录见 [`CHANGELOG.md`](CHANGELOG.md)。

## Installation

1. 在 GitHub Releases 下载需要的版本。
2. 解压后将完整的 `miuread.koplugin` 目录放入 KOReader 的插件目录。
3. 完整重启 KOReader。
4. 支持双更新通道的版本可在“觅阅设置 → 更新与关于 → 更新通道”中选择正式通道或内测通道。

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
