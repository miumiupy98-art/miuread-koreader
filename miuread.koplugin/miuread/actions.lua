local Dispatcher=require("dispatcher")

local Actions={}
local registered=false

local general_actions={
    {"miuread_show","ShowMiuRead","觅阅：打开觅阅书架"},
    {"miuread_return_home","MiuReadReturnHome","觅阅：退出阅读并返回觅阅"},
    {"miuread_toggle_progress_sync","ToggleMiuReadProgressSync","觅阅：开关自动同步进度"},
    {"miuread_toggle_time_sync","ToggleMiuReadTimeSync","觅阅：开关自动同步时间"},
    {"miuread_downloads","ShowMiuReadDownloads","觅阅：下载管理"},
    {"miuread_sync_status","ShowMiuReadSyncStatus","觅阅：同步状态"},
    {"miuread_qr_login","MiuReadQRLogin","觅阅：扫码登录"},
    {"miuread_logout","MiuReadLogout","觅阅：退出登录"},
}

local reader_actions={
    {"miuread_reader_panel","MiuReadReaderPanel","觅阅：打开阅读控制中心"},
    {"miuread_reader_font","MiuReadReaderFont","觅阅：字体与字号"},
    {"miuread_reader_typeset","MiuReadReaderTypeset","觅阅：完整排版面板"},
    {"miuread_reader_progress","MiuReadReaderProgress","觅阅：阅读进度"},
    {"miuread_upload_progress","MiuReadUploadProgress","觅阅：上传当前进度"},
    {"miuread_pull_progress","MiuReadPullProgress","觅阅：读取云端进度"},
    {"miuread_current_book","MiuReadCurrentBook","觅阅：当前书籍"},
}

function Actions.register()
    if registered then return end
    registered=true
    for _,row in ipairs(general_actions) do
        Dispatcher:registerAction(row[1],{
            category="none",event=row[2],title=row[3],general=true,
        })
    end
    for _,row in ipairs(reader_actions) do
        Dispatcher:registerAction(row[1],{
            category="none",event=row[2],title=row[3],reader=true,
        })
    end
    Dispatcher:registerAction("miuread_close_book",{
        category="none",event="MiuReadCloseBook",title="觅阅：退出阅读并返回书架",reader=true,
    })
end

return Actions
