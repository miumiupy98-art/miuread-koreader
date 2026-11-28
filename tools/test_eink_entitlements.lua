package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.json"]={}
local E=require("miuread.eink_entitlements")
local Result=require("miuread.download_result")

local now=os.time()
local combined=E.summary({remainTime=864000,payingRemainTime=604800,expiredTime=now+864000,
    expired=0,isPaying=1,remainCoupon=0},now)
assert(combined.paying and combined.paid_remaining==604800 and combined.trial_remaining==259200)
assert(combined.coupons==0 and not combined.expired and combined.expires==now+864000)
assert(E.summary({remainTime=0,expiredTime=now-10,expired=1},now).expired)
assert(E.summary({permanent=1},now).permanent)
assert(not E.purchase_url("bad id") and E.purchase_url("12345678901")==
    "https://weread.qq.com/web/redirect?type=memCard&memCardExpand=1&eink=1&vid=bfd32730775bcd15g011abd")

local book={bookId="1234",payType=4096+8192,title="Fixture"}
local chapter={chapterUid=7,price=10,title="第七章"}
local member={expired=1,expiredTime=0,remainTime=0,isPaying=0,remainCoupon=2}
local tips={bookId="1234",readAfterPay=1}
local trial_days,queries,actions=3,0,0
local buy_flag=nil
local client={}
function client:book(id,details) assert(id=="1234" and details);return book end
function client:membership_summary() return member end
function client:catalog(id) assert(id=="1234");return {updated={chapter}} end
function client:request(method,path,fields,stage,opts)
    assert(method=="GET")
    if path=="/reader/tips" then assert(fields.from=="reader");return tips end
    if path=="/feature" then assert(fields.synckey==0);return {feature={membership_show_buy=buy_flag}} end
    if path=="/act/recvinfinite" and fields.cmd=="query" then
        assert(fields.action=="get" and fields.from=="reader")
        queries=queries+1
        return {day=trial_days}
    end
    assert(opts and opts.single_dispatch and stage=="account")
    if path=="/coupon/buyChapter" then
        assert(fields.chapterIds=="7" and fields.bookId=="1234")
        member.remainCoupon=member.remainCoupon-1
        chapter.paid=1
        actions=actions+1
        return {remainCoupon=member.remainCoupon}
    end
    assert(path=="/act/recvinfinite" and fields.cmd=="recv" and fields.action=="get" and fields.from=="")
    actions=actions+1
    member.expired,member.remainTime,member.expiredTime=0,259200,now+259200
    return {day=3}
end
local state=E.locked_options(client,"1234","7")
assert(state.trial_days==3 and not state.can_use_coupon and not state.can_buy_member and queries==1)
assert(E.apply(client,"1234","7","trial").reopen and actions==1)
assert(not pcall(E.apply,client,"1234","7","trial") and actions==1)
member.expired,member.remainTime,member.expiredTime=1,0,0
trial_days=0
state=E.locked_options(client,"1234","7")
assert(state.can_use_coupon and not state.can_buy_member)
local used=E.apply(client,"1234","7","coupon")
assert(used.reopen and used.member.coupons==1 and actions==2)
assert(E.apply(client,"1234","7","coupon").reopen and actions==2)
chapter.paid=nil
member.remainCoupon=0
book.payType=1048576
assert(E.locked_options(client,"1234","7").can_buy_member)
buy_flag=false
assert(not E.locked_options(client,"1234","7").can_buy_member)
buy_flag=true
tips.readAfterPay=0
assert(not E.locked_options(client,"1234","7").can_buy_member)
tips.bookId="other"
assert(not pcall(E.locked_options,client,"1234","7") and actions==2)

assert(Result.chapter_access("[MiuReadChapterLocked]")=="locked")
assert(Result.chapter_access("微信读书未确认本章离线下载权限")=="unconfirmed")
assert(Result.chapter_access("download HTTP 401")==nil and Result.chapter_access("timeout")==nil)
local partial={restricted_chapter_count=2,readable_chapter_count=5,
    restricted_chapters={{title="后记"},{title="终章"}}}
assert(Result.state(partial)=="partial_access" and Result.state({})=="completed")
assert(Result.access_summary(partial):find("已下载 5 章，2 章未取得下载权限。",1,true))
assert(Result.access_summary(partial):find("后记、终章",1,true))

-- A write-shaped GET uses the same account and a single HTTP dispatch.
package.loaded["miuread.http"]={is_auth_error=function() return true end,
    is_rate_limit_error=function() return false end,rate_limit_details=function() end}
local Client=require("miuread.shelf_client")
local auth={login_session_id="A",account={vid="1234"},accessToken="fixture"}
Client.credentials=function(row) return row and row.accessToken and {vid=row.account.vid,accessToken=row.accessToken} end
local disk=auth
local store={auth=function() return auth end,read_persisted=function() return disk end}
local sent=0
local native=require("miuread.eink_client").new({get_json=function(_,url,opt)
    assert(url:find("/coupon/buyChapter?",1,true) and opt.retries==0 and opt.rate_limit_retries==0)
    if opt.before_dispatch()~=true then error("request dispatch refused",0) end
    sent=sent+1
    error("HTTP 401",0)
end},store)
Client.refresh=function() error("must not refresh and replay an account mutation",0) end
assert(not pcall(native.request,native,"GET","/coupon/buyChapter",{bookId="1234"},"account",{single_dispatch=true}) and sent==1)
disk={login_session_id="B",account={vid="9"},accessToken="another-fixture"}
assert(not pcall(native.request,native,"GET","/coupon/buyChapter",{bookId="1234"},"account",{single_dispatch=true}) and sent==1)
print("Original membership QR, chapter lock, eligible trials and coupons, guarded mutations and partial downloads passed")


-- Follow the account and download entries, then invoke the lock sheet's
-- action through the same chapter context used by the reader.
local plugin,rendered,dialog,sheet,resumed,submitted={},{},nil,nil,nil,0
local U=require("miuread.util")
local auth={login_session_id="layout-account"}
local ui_context={}
local view_valid=true
local env=setmetatable({
    Plugin=plugin,U=U,Http={is_auth_error=function() return false end},
    ActionSheet={show=function(options) sheet=options;return options end},
    ConfirmBox={new=function(_,options) return options end},
    ButtonDialog={new=function(_,options) return options end},
    UIManager={show=function(_,widget) dialog=widget end,close=function() end},
    DownloadResult=Result,
    reader_close_active=function() return false end,
    interactive_child_store=function() return {} end,
},{__index=_G})
local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local src=file:read("*a")
file:close()
local function load_functions(first,last)
    local start=assert(src:find("function Plugin:"..first.."(",1,true))
    local finish=assert(src:find("function Plugin:"..last.."(",start,true))
    setfenv(assert(loadstring(src:sub(start,finish-1))),env)()
end
load_functions("show_eink_account_overview","confirm_logout")
load_functions("show_account_status","on_auth_success")
load_functions("account_menu","_save_shelf_context")
load_functions("_show_weread_locked_chapter","_finish_online_read")
load_functions("_download_access_actions","show_download_status")

plugin.store={auth=function() return auth end}
function plugin:require_login() return true end
function plugin:logged_in() return self.signed_out~=true end
function plugin:_home_account_name() return "Fixture reader" end
function plugin:_native_mp_feed_entries() return {} end
function plugin:_interactive_network_context() return ui_context end
function plugin:_interactive_network_context_valid(ctx) return view_valid and ctx==ui_context end
function plugin:_show_miuread_menu(title,items,opts)
    rendered={title=title,items=items,opts=opts}
    return rendered
end
function plugin:_run_interactive_network(_,_,_,cb)
    cb({ok=true,value={overview={balance=1,gift_balance=0,permanent=true,coupons=2}}})
    return true
end
local purchase=plugin._show_weread_member_qr
function plugin:_show_weread_member_qr(refresh) assert(type(refresh)=="function"); self.qr_requested=true end
function plugin:info(message) self.message=message end

plugin:show_account_status()
assert(rendered.title=="账号状态" and rendered.items[1].text=="账号" and rendered.items[2].text=="基础登录")
assert(rendered.items[3].text=="账户资料" and rendered.items[4].text=="云端笔记"
    and rendered.items[5].text=="账号操作")
assert(not rendered.items[3].keep_menu_open)
rendered.items[3].callback()
assert(rendered.title=="账户资料" and rendered.items[3].text=="会员卡" and rendered.items[3].post_text=="终身会员")
assert(rendered.items[5].text=="章节券" and rendered.items[5].post_text=="2 张")
assert(rendered.items[6].text=="卡券有效期" and rendered.items[7].keep_menu_open)
local overview=rendered
overview.items[6].callback()
assert(rendered.title=="卡券有效期" and rendered.items[1].post_text=="终身会员")
overview.items[7].callback()
assert(plugin.qr_requested)
overview.opts.on_close()
assert(rendered.title=="账号状态")
plugin.signed_out=true
assert(plugin:account_menu()[4].text=="扫码登录")
plugin.signed_out=false

function plugin:_fetch_eink_display(key,_,_,args,on_ready,check_persisted_auth)
    assert(args[1]=="fixture" and args[2]=="17")
    if key:match("^locked%-chapter:") then
        on_ready({title="第十七章",can_use_coupon=true,coupons=2})
    else
        assert(args[3]=="coupon" and check_persisted_auth==true)
        submitted=submitted+1
        on_ready({reopen=true})
    end
    return true
end
function plugin:download(selected,options,open)
    resumed={book=selected,options=options,open=open}
    return true
end
local book_for_ui={bookId="fixture",title="Fixture EPUB"}
local runtime={book=book_for_ui,options={chapter_uid="17",chapter_continuous_open=true},
    login_session_id=auth.login_session_id,online_context=ui_context,open_after=true}
assert(plugin:_show_weread_locked_chapter(runtime))
assert(sheet.title=="当前章节需要阅读权限" and sheet.subtitle=="第十七章")
assert(#sheet.actions==2 and sheet.actions[1].label=="用券解锁本章" and sheet.actions[1].detail=="剩余 2 张")
assert(sheet.actions[2].label=="刷新权益并打开本章")
assert(sheet.footer_action.label=="返回")
sheet.actions[1].callback()
assert(type(dialog.ok_callback)=="function" and submitted==0)
dialog.ok_callback()
assert(submitted==1 and resumed.options.chapter_uid=="17" and resumed.options.rights_recheck)
view_valid=false
dialog.ok_callback()
assert(submitted==1)
view_valid=true

local real_exists=U.file_exists
U.file_exists=function(path) return path=="/fixture.epub" end
local partial_record={file="/fixture.epub",access_scope="preview",eink_content_mode="eink-offline",
    readable_chapter_count=3,restricted_chapter_count=1,restricted_chapters={{title="第十七章"}},online_chapter_uid="17"}
function plugin:open_file(path) self.opened=path end
function plugin:chapters(selected) self.directory=selected end
assert(plugin:_show_download_complete(partial_record,{},book_for_ui))
assert(dialog.title:find("《Fixture EPUB》",1,true) and dialog.title:find("第十七章",1,true))
assert(dialog.buttons[1][1].text=="阅读已下载部分" and dialog.buttons[2][1].text=="继续在线阅读")
dialog.buttons[1][1].callback()
assert(plugin.opened==partial_record.file)
dialog.buttons[2][1].callback()
assert(resumed.options.chapter_uid=="17" and resumed.options.read_online)
local variant={kind="preview_clean",label="部分章节",file="/fixture.epub",record=partial_record}
plugin.store={reload=function() end,prune_missing_files=function() end,book=function() return {title="Fixture EPUB"} end}
plugin.book_delete_service={summary=function() return {has_local=true,variants={variant}} end}
function plugin:list(title,items) rendered={title=title,items=items};return rendered end
require("miuread.book_local_files_dialog").open_variant(plugin,"fixture","preview_clean")
assert(rendered.items[2].text=="下载详情")
rendered.items[2].callback()
assert(dialog.title:find("部分章节可下载",1,true))
variant.record.readable_chapter_count=0
require("miuread.book_local_files_dialog").open_variant(plugin,"fixture","preview_clean")
assert(rendered.items[1].text=="下载详情")
U.file_exists=real_exists
plugin._show_weread_member_qr=purchase
print("Reference-style account navigation, lock actions, and shared download details passed")
