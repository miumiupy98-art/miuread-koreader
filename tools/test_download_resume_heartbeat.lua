-- Usage: luajit tools/test_download_resume_heartbeat.lua miuread.koplugin/miuread/downloader.lua
-- Reusing a long completed checkpoint must keep reporting progress, otherwise
-- the parent stall watchdog stops a healthy worker before new chapters start.
local f=assert(io.open(assert(arg[1]),'rb'));local source=f:read('*a'):gsub('\r\n','\n');f:close()
local a=assert(source:find('    local function process_one(',1,true))
local b=assert(source:find('    for index, chapter in ipairs(selected)',a,true))
local factory=assert(loadstring(source:sub(a,b-1)..' return process_one'))
local CHAPTERS,WATCHDOG=682,50 -- smallest foreground stall window (prepare/resume)
local now,last,emits=0,0,0
local env=setmetatable({opt={},Config={},self={},expected=CHAPTERS,
    requested_annotations=true,annotation_account_key='test',chapters_from_checkpoint=0,
    CONTENT_TRANSFORM_VERSION=2,IMAGE_TRANSFORM_VERSION=2,LEGACY_CONTENT_TRANSFORM_VERSION=1,
    failure_map={},restricted_map={},cache={manifest={chapters={}}},
    logger={info=function() end,warn=function() end},
    cache_save=function() end,cache_reset_entry=function() error('completed chapter was reset') end,
    -- 0.2 s of cache validation per chapter, as measured on a real 682-chapter book.
    respect_reader_priority=function() now=now+.2 end,
    cache_load_final_source=function() return 'verified.xhtml','' end,
    validate_cached_chapter=function() return true end,
    progress=function(stage,index,total)
        assert(stage=='resume' and index==emits+1 and total==CHAPTERS,'unexpected progress')
        assert(now-last<WATCHDOG,'stall watchdog would stop a live worker')
        last=now;emits=emits+1
    end,
},{__index=_G})
setfenv(factory,env)
local process=factory()
for i=1,CHAPTERS do
    local uid=tostring(i)
    env.cache.manifest.chapters[uid]={complete=true,title='chapter',word_count=4000,
        content_transform_version=2,image_transform_version=2,title_transform_version=2,
        annotation_transform_version=2,annotation_account_key='test',source_cache_done=true}
    assert(process({chapterUid=uid,title='chapter',wordCount=4000},i,0))
end
assert(emits==CHAPTERS,'reused chapters reported '..emits..' heartbeats')
assert(env.chapters_from_checkpoint==CHAPTERS)
env.opt.cancelled=function() return true end
local ok,err=pcall(process,{chapterUid='1'},1,0)
assert(not ok and tostring(err):find('download cancelled',1,true),'cancellation no longer checked')
print('DOWNLOAD_RESUME_HEARTBEAT_OK','chapters='..CHAPTERS,'heartbeats='..emits,
    string.format('simulated=%.1fs',now))
