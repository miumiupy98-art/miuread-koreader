local Text = {}
local lang = (os.getenv("LANG") or ""):lower()
local zh = lang:find("zh", 1, true) ~= nil or lang == ""
local M = {
["MiuRead"]="觅阅 · 微信读书助手",["Independent WeRead client for KOReader."]="独立实现的 KOReader 微信读书客户端。",
["Account"]="账户",["QR login"]="扫码登录",["Manual credentials"]="手动导入凭据",["Account status"]="账户状态",["Clear account data"]="清除账号数据",["Logout"]="退出登录",
["My bookshelf"]="我的书架",["Books"]="书籍",["Official accounts"]="公众号",["Search books"]="搜索书籍",["Paste reader link"]="粘贴阅读链接",
["Reading sync"]="阅读同步",["Sync current book position"]="同步当前书籍位置",["Reading time sync"]="阅读时间同步",["Sync status"]="查看同步状态",["Automatic detection"]="自动检测设置",["Advanced"]="高级功能",
["Downloads and cache"]="下载管理",["Settings"]="设置",["Check update"]="检查更新",["About"]="关于",
["Not logged in"]="尚未登录",["Logged in"]="已登录",["Loading..."]="加载中……",["No items"]="没有内容",["No downloaded books"]="没有已下载内容",
["Book details"]="书籍详情",["Chapter list"]="章节列表",["Open"]="打开",["Delete"]="删除",["Download"]="下载",["Redownload"]="重新下载",["View cover"]="查看封面",
["Download full book"]="下载整本",["Read first chapter"]="阅读第一章",["Clean version"]="纯净版",["Notes version"]="划线与想法版",["Both versions"]="两个版本",["Downloaded"]="下载完成",
["Open clean version"]="打开纯净版",["Open notes version"]="打开划线与想法版",["Delete clean version"]="删除纯净版",["Delete notes version"]="删除划线与想法版",
["Download chapter"]="下载本章",["Delete chapter cache"]="删除本章缓存",["Cached"]="已缓存",["Partial"]="部分完成",["Failed chapters"]="失败章节",
["Sort"]="排序",["Filter"]="筛选",["Recently updated"]="最近更新",["Title"]="书名",["Author"]="作者",["Reading progress"]="阅读进度",["Only downloaded"]="仅显示已下载",["Only unread"]="仅显示未读",["Only reading"]="仅显示在读",["Only finished"]="仅显示读完",["Clear filters"]="清除筛选",
["Images"]="下载原书图片",["Official account images"]="下载公众号图片",["Show shelf covers"]="书架缓存封面",["Show annotations"]="显示划线与想法",["Low resource mode"]="低资源模式",
["Stable"]="正式通道",["Beta"]="内测通道",["Update channel"]="更新通道",["Manifest URL"]="更新清单地址",["Install update"]="安装更新",["Restart required"]="需要重启 KOReader",
["Clear all cache"]="清除全部缓存",["Clear book cache"]="清除本书缓存",["Clear covers"]="清除封面缓存",["Cache cleared"]="缓存已清理",["Change download directory"]="修改下载目录",
["Confirm"]="确认",["Cancel"]="取消",["Close"]="关闭",["Search"]="搜索",["Enter keyword"]="输入关键词",["Enter URL"]="输入链接",["Enter API key"]="输入 API Key",["Enter Cookie header"]="输入 Cookie 请求头",
["Verification code"]="验证码",["Enter the four-digit code shown on your phone."]="输入手机上显示的四位验证码。",["Login cancelled"]="登录已取消",["QR code expired"]="二维码已过期",
["Network unavailable"]="网络不可用",["Operation failed"]="操作失败",["No readable chapter found"]="没有可阅读章节",["No cached file"]="没有缓存文件",
["Current device"]="本机",["Other device"]="其他设备",["Unknown"]="未知",["Upload local position"]="上传本机位置",["Use other device position"]="使用其他设备位置",["Refresh remote position"]="刷新其他设备位置",["Enter percentage"]="输入百分比跳转",
["Conflict"]="位置冲突",["Automatic upload paused"]="自动上传已暂停",["Progress uploaded"]="位置已上传",["Jump requested"]="已请求跳转",["No matching MiuRead book is open."]="当前未打开可识别的觅阅书籍。",
["Enabled"]="已开启",["Disabled"]="已关闭",["Running"]="运行中",["Waiting"]="等待中",["Paused"]="已暂停",["Offline"]="离线",["Last upload"]="最近上传",["Session uploads"]="本次会话上传次数",
["Open-time remote check"]="打开书籍时检测其他设备位置",["Resume remote check"]="长时间唤醒后重新检测",["Protected automatic upload"]="受保护的自动上传",["Require verified remote position"]="上传前验证其他设备位置",
["Clear current sync state"]="清除当前书籍同步状态",["Detailed sync information"]="查看详细同步信息",["Return to MiuRead bookshelf"]="返回觅阅书架",["Redownload current book"]="重新下载当前书",["More settings"]="更多设置",
["Source code is independently implemented."]="本项目代码为独立重新实现。",["Unofficial client"]="非官方客户端",["Feature-complete beta"]="功能完整测试版",
["This build has not been verified with every Kindle model or every WeRead book."]="本版本尚未覆盖所有 Kindle 型号与所有微信读书书籍的实机验证。",
["Update package downloaded"]="更新包已下载",["Update installed"]="更新已安装",["Already current"]="已是最新版本",["Invalid update package"]="更新包无效",
["Download cancelled"]="下载已取消",["Some chapters failed"]="部分章节下载失败",["No personal annotations"]="没有可用的个人划线或想法",["Original notes"]="原书注释",["Personal highlights and thoughts"]="个人划线与想法",
}
function Text.tr(s) if zh and M[s] then return M[s] end return s end
return Text
