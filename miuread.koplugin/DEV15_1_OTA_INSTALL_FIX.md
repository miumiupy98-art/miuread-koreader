# v0.1.0-dev.15.1 OTA 安装修复

- 修复 Kindle 自带 `unzip` 不支持 `unzip -Z1` 时被误判为“更新包为空”的问题。
- OTA 安装改为沿用旧版已验证流程：直接 `unzip -q` 到临时目录，再检查 `miuread.koplugin`。
- 下载增加 `curl -L` 后备路径，兼容 GitHub Release 多次重定向。
- 下载后继续进行 SHA-256 校验、安装前备份和失败回滚。
- 保留 v0.1.0-dev.15 的原生文件夹选择器修复。
