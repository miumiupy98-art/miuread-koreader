-- MiuRead native menu icons: one neutral SVG family across Home and Reader.
-- Only action/navigation labels get icons; status-only rows stay text-first.
local M={}
local EXACT={
    ["微信书架"]="library",["打开觅阅书架"]="library",["微信读书"]="book",["微信读书书城"]="library",["书城"]="library",
    ["搜索书籍"]="search",["搜索扩展"]="search",["公众号"]="newspaper",["公众号阅读"]="newspaper",["本地书库"]="folder",
    ["当前书籍"]="current-book",["目录"]="toc",["书签"]="bookmark",["阅读评论"]="comment",["评论与想法"]="comment",
    ["我的想法"]="thought",["评论显示"]="comment",["评论显示设置"]="comment",["在线评论点赞"]="check",
    ["同步"]="sync",["同步状态"]="sync",["同步设置"]="settings",["同步与下载"]="sync",["手动同步"]="sync",
    ["自动同步设置"]="settings",["重试失败项目"]="refresh",["同步离线待传时间"]="upload",
    ["阅读时长同步"]="history",["启用阅读时长同步"]="power",["同步方式"]="swap",
    ["当前时间通道"]="wifi",["E-Ink 客户端授权"]="shield-check",["E-Ink 授权"]="shield-check",
    ["扫码授权"]="qr-code",["重新扫码授权"]="qr-code",["检查授权状态"]="refresh",
    ["取消 E-Ink 客户端授权"]="power-off",["需要重新授权"]="shield-alert",
    ["阅读进度"]="progress",["上传方式"]="swap",["自动同步最新阅读位置"]="progress",
    ["首次阅读时间同步成功提醒"]="check",["批注"]="pencil",["批注同步失败"]="warning",
    ["下载"]="download",["下载管理"]="download",["下载任务"]="download",["插件下载任务"]="download",
    ["插件与扩展"]="puzzle",["已安装扩展"]="puzzle",["可更新扩展"]="refresh",["扩展更新"]="refresh",
    ["检查扩展更新"]="refresh",["觅阅推荐"]="check",["社区热门"]="library",["扩展下载源"]="download",["关于扩展中心"]="info",
    ["首页与界面"]="home",["阅读界面"]="book",["主页"]="home",["快捷入口"]="grid",
    ["主页顶栏显示"]="display",["主页阅读统计"]="progress",["页面布局"]="grid",["显示书架封面"]="image",
    ["网络补全图书信息"]="wifi",["字体与显示"]="font",["觅阅界面字体"]="font",["觅阅显示大小"]="display",
    ["时间与时区"]="history",["锁屏壁纸"]="sleep",["觅阅阅读工具栏"]="tools",
    ["阅读与书库"]="book",["运行与兼容"]="device",["运行模式"]="device",["性能与兼容性"]="tools",
    ["使用提醒"]="info",["恢复全部使用提醒"]="refresh",
    ["账号"]="user",["账号管理"]="user",["账号状态"]="user",["扫码登录"]="qr-code",
    ["重新扫码登录"]="qr-code",["退出登录"]="power-off",["基础登录"]="user",
    ["微信分组"]="folder",["接口通道"]="swap",["存储"]="file-manager",["存储管理"]="file-manager",
    ["运行与兼容"]="device",["系统维护"]="repair",["插件设置"]="settings",["觅阅设置"]="settings",
    ["更新与关于"]="info",["检查更新"]="refresh",["更新通道"]="swap",["自动检查更新"]="refresh",
    ["检查频率"]="history",["更新完成后"]="refresh",["关于觅阅"]="info",["第三方声明"]="info",
    ["日志与状态"]="diagnostics",["日志诊断"]="diagnostics",["诊断与修复"]="repair",["高级诊断"]="diagnostics",
    ["导出运行日志"]="file-manager",["时间诊断"]="diagnostics",["同步诊断"]="diagnostics",
    ["同步状态详情"]="info",["书库修复"]="repair",["刷新本地书库"]="refresh",
    ["更新缺失书籍资料"]="refresh",["重建封面"]="image",["重建书架索引"]="repair",
    ["检查下载完整性"]="check",["查看存储占用"]="file-manager",["清理可再生缓存"]="trash",
    ["KOReader 设置"]="settings",["KOReader 文件管理"]="file-manager",["返回 KOReader"]="return",
    ["返回文章列表"]="back",["上一篇"]="back",["下一篇"]="page-jump",["当前文章"]="book",
    ["外文翻译"]="book",["使用说明"]="info",["查看同步详情"]="info",
    ["检查账号与授权"]="shield-alert",["立即同步"]="upload",["重新检查"]="refresh",
    ["查看记录问题"]="warning",["核对云端位置并恢复补传"]="repair",
}
function M.key(label)
    label=tostring(label or "")
    if EXACT[label] then return EXACT[label] end
    if label:find("待同步",1,true) or label:find("待上传",1,true) then return "upload" end
    if label:find("待确认",1,true) then return "history" end
    if label:find("下载",1,true) and not label:find("提醒",1,true) then return "download" end
    if label:find("重新扫码",1,true) then return "qr-code" end
    if label:find("阅读时长同步",1,true) then return "history" end
    if label:find("同步",1,true) and not label:find("状态",1,true) then return "sync" end
    return nil
end
return M
