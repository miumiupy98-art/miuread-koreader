-- One deterministic route per download run. Book content and services prefer E-Ink;
-- an ordinary Native failure pins the remaining run to Web. Rate limits,
-- cancellation and hibernation propagate without issuing a fallback request.
local U=require("miuread.util")
local Http=require("miuread.http")
local Protocol=require("miuread.protocol")
local Transport=require("miuread.api_transport")
local Log=require("miuread.diagnostic_log")
local M=setmetatable({},{__index=Transport}); M.__index=M
local FAILURE_STAGES={catalog=true,chapter_download=true,refresh=true,style=true,book=true,
    annotations=true,translation=true,client_download=true,decode=true,images=true}
local FAILURE_FILES={"eink_client.lua","eink_crypto.lua","eink_archive.lua","reader.lua"}
-- Classify fixed local failures without copying response data into logs.
local KNOWN_FAILURES={
    {"E-Ink 与 Web 目录版本不同","catalog_version","catalog"},
    {"E-Ink 未返回对应书籍目录","catalog_missing","catalog"},
    {"E-Ink 目录中不存在当前章节","chapter_missing","catalog"},
    {"E-Ink 目录未确认章节免费或已购买","chapter_access","catalog"},
    {"E-Ink 书籍格式暂不支持","book_format","catalog"},
    {"E-Ink 书籍版本缺失","book_version","catalog"},
    {"E-Ink 接口需要客户端授权","authorization","client_download"},
    {"E-Ink 未返回章节下载密钥","key_missing","chapter_download"},
    {"E-Ink 账号标识无效","account_invalid","decode"},
    {"E-Ink 解密组件不可用","crypto_unavailable","decode"},
    {"E-Ink 解压组件不可用","inflate_unavailable","decode"},
    {"E-Ink 下载密钥","key_decode","decode"},
    {"E-Ink ZIP 密码","zip_password","decode"},
    {"E-Ink ZIP","archive_invalid","decode"},
    {"E-Ink 章节包大小无效","archive_size","decode"},
    {"E-Ink 书籍样式未能获取","style_missing","style"},
    {"E-Ink 章节清单","chapter_manifest","decode"},
    {"E-Ink 未返回唯一章节正文","body_missing","decode"},
    {"E-Ink 章节正文为空","body_empty","decode"},
    {"无法读取 E-Ink 章节包","archive_read","decode"},
    {"E-Ink 图片格式无效","image_format","images"},
    {"无法保存 E-Ink 章节图片","image_save","images"},
    {"E-Ink 正文图片未完整获取","image_missing","images"},
    {"E-Ink 批注位置未能验证","annotation_alignment","annotations"},
    {"E-Ink 划线响应不完整","annotation_underlines","annotations"},
    {"E-Ink 想法响应不完整","annotation_reviews","annotations"},
    {"E-Ink 会员响应不完整","translation_member","translation"},
    {"E-Ink 译文模式未能开启","translation_mode","translation"},
    {"E-Ink 译文状态响应无效","translation_status","translation"},
    {"E-Ink 未返回译文正文","translation_body","chapter_download"},
    {"客户端续期返回了其他账号","refresh_account","refresh"},
    {"登录账号或凭据已变更","auth_changed","refresh"},
    {"客户端续期凭证未保存","refresh_save","refresh"},
    {"客户端授权未返回完整登录凭证","refresh_incomplete","refresh"},
}

function M.new(reader,options)
    local route=Transport.new(reader.store,options)
    route.reader=reader
    route.web_chapters,route.eink_chapters=0,0
    route.restart_annotations=true
    return setmetatable(route,M)
end
function M:native()
    local reader=self.reader
    reader._eink_client=reader._eink_client or require("miuread.eink_client").new(reader.http,reader.store,reader)
    reader._eink_client.keepalive=true
    reader._eink_client.before_request=function(stage)
        if type(self.checkpoint)=="function" then self.checkpoint(stage) end
    end
    return reader._eink_client
end
function M:use_web(value)
    self:note_eink_failure(value)
    self.selected,self.reason="web","eink_failed"
    self.fallback=true
    Log.record(self.store,{operation="download",channel="web",outcome="fallback",
        reason=self.failure.code,native_stage=self.failure.stage,status=self.failure.status,code=self.failure.error_code})
    self.reader:cleanup_transient_images()
    if type(self.on_fallback)=="function" then self.on_fallback() end
end
function M:service(api)
    return require("miuread.api").bind(api,self.reader,self)
end
function M:configure(format)
    if self.selected=="eink" and format and format~="epub" and format~="txt" then
        self.selected,self.reason="web","unsupported_format"
    end
end
function M:restore(prior)
    -- A partial download must not hammer a failed Native route after a worker
    -- restart. This cannot grant Native access or override explicit Web mode.
    if self.selected=="eink" and type(prior)=="table"
        and prior.selected=="web" and prior.reason=="eink_failed" then
        self.selected,self.reason="web","eink_failed"
        self.fallback=true
    end
end
function M:resume_state()
    if self.selected=="web" and self.fallback then return {selected="web",reason="eink_failed"} end
end
function M:activity(opt,channel)
    self.active_channel,self.active_phase=channel,"download"
    if type(opt.activity)=="function" then opt.activity("transport_download",{channel=channel}) end
end
function M:note_eink_failure(value)
    local text=tostring(value or "")
    local stage=text:match("native_stage=([%w_]+)")
    if not FAILURE_STAGES[stage] then stage=nil end
    local failure={code="unknown",stage=stage}
    for _,known in ipairs(KNOWN_FAILURES) do
        if text:find(known[1],1,true) then
            failure.code,failure.stage=known[2],known[3]
            break
        end
    end
    if failure.code=="unknown" then
        local status=tonumber(text:match("HTTP (%d%d%d)"))
        local code=tonumber(text:match("error_code=(%-?%d+)"))
        local lower=text:lower()
        if status then failure.code,failure.status="http_status",status
        elseif code then failure.code,failure.error_code="service_error",code
        elseif lower:find("network request failed",1,true) or lower:find("timed out",1,true)
            or lower:find("timeout",1,true) then failure.code="network" end
    end
    for _,file in ipairs(FAILURE_FILES) do
        local line=tonumber(text:match(file:gsub("%.","%%.")..":(%d+):"))
        if line then failure.file,failure.line=file,line; break end
    end
    self.failure=failure
end
function M:note_rate_limit(value)
    if not tostring(value):find("[MiuReadRateLimit]",1,true) then return end
    if not self.stopped then
        self.stopped_channel,self.stopped_phase=self.active_channel,self.active_phase or "download"
    end
    self.reason="rate_limited"
    local text=tostring(value)
    self.limit_code=tonumber(text:match("error_code=(%-?%d+)")) or tonumber(text:match("HTTP (%d+)"))
    self.wait_seconds=tonumber(text:match("wait_seconds=(%d+)"))
    self.local_cooldown=text:find("[MiuReadLocalCooldown]",1,true)~=nil
    self.native_stage=text:match("native_stage=([%w_]+)")
    self.stopped=true
end

function M:_chapter_once(book,chapter,format,opt)
    if Protocol.is_mp(tostring(book.bookId or book.book_id or "")) then self.selected,self.reason="web","mp" end
    local function web()
        self:activity(opt,"web")
        local read=self.reader.web_chapter or self.reader.chapter
        local a,b,c,d=read(self.reader,book,chapter,format,opt)
        self.web_chapters=self.web_chapters+1
        return a,b,c,d
    end
    return self:invoke("chapter",function()
        self:native()
        self:activity(opt,"eink")
        local a,b,c,d=self.reader:eink_chapter(book,chapter,format,opt)
        self.eink_chapters=self.eink_chapters+1
        return a,b,c,d
    end,web,{phase="download",web_only=opt.fresh_context==true})
end
function M:chapter(book,chapter,format,opt)
    local ok,a,b,c,d=pcall(self._chapter_once,self,book,chapter,format,opt or {})
    if not ok then self:note_rate_limit(a) end
    self.active_channel,self.active_phase=nil,nil
    if not ok then error(a,0) end
    return a,b,c,d
end
function M:result()
    return {mode=self.mode,selected=self.selected,reason=self.reason,
        web_chapters=self.web_chapters,eink_chapters=self.eink_chapters,
        stopped=self.stopped,stopped_channel=self.stopped_channel,
        stopped_phase=self.stopped_phase,limit_code=self.limit_code,
        wait_seconds=self.wait_seconds,local_cooldown=self.local_cooldown,
        native_stage=self.native_stage,failure=self.failure,api_counts=U.copy(self.api_counts)}
end
function M:log_result(outcome,elapsed)
    local counts=self.api_counts
    local failure=self.failure or {}
    Log.record(self.store,{operation="download",channel=self.stopped_channel or self.selected,outcome=outcome,
        reason=self.reason,elapsed_ms=math.floor(math.max(0,elapsed or 0)*1000),
        code=self.limit_code or failure.error_code,status=failure.status,
        wait_seconds=self.wait_seconds,local_cooldown=self.local_cooldown,
        native_stage=self.native_stage or failure.stage,native_chapters=self.eink_chapters,web_chapters=self.web_chapters,
        failure_file=failure.file,failure_line=failure.line,
        native_annotations=counts.eink.annotations or 0,web_annotations=counts.web.annotations or 0,
        native_translation=counts.eink.translation or 0,web_translation=counts.web.translation or 0})
end
return M
