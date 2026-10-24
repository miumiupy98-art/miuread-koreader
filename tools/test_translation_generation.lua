local TOOL_DIR=tostring(arg and arg[0] or ''):gsub('\\','/'):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=TOOL_DIR..'/?.lua;'..ROOT..'?.lua;'..package.path

local function copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local result={}; seen[value]=result
    for key,item in pairs(value) do result[copy(key,seen)]=copy(item,seen) end
    return result
end
local function encode(value)
    if type(value)=='string' then return '"'..value:gsub('[\\"%c]',function(c) return string.format('\\u%04x',c:byte()) end)..'"' end
    if type(value)=='number' or type(value)=='boolean' then return tostring(value) end
    if type(value)~='table' then return 'null' end
    local parts={}
    if #value>0 then
        for _,item in ipairs(value) do parts[#parts+1]=encode(item) end
        return '['..table.concat(parts,',')..']'
    end
    local keys={}; for key in pairs(value) do keys[#keys+1]=key end; table.sort(keys)
    for _,key in ipairs(keys) do parts[#parts+1]=encode(key)..':'..encode(value[key]) end
    return '{'..table.concat(parts,',')..'}' -- Deliberately encodes an empty table as {}.
end
local Util={copy=copy,first_line=function(s) return tostring(s):match('[^\n]*') end,
    file_exists=function() return true end,file_size=function() return 500 end}
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.util']=function() return Util end
package.preload['miuread.protocol']=function() return {reader_url=function(id) return 'https://weread.qq.com/web/reader/'..id end} end
package.preload['miuread.codec']=function() return {} end
package.preload['miuread.json']=function() return {encode=encode} end
package.preload['miuread.http']=function() return {is_auth_error=function(s) return tostring(s):find('-2012',1,true)~=nil end} end

local Api=require('miuread.api')
local Generation=require('miuread.translation_generation')
local Translation=require('miuread.translation')
local book_id='CB_test'

-- Exercise the actual HTTP adapter, including JSON backends that confuse []
-- with {}, bounded auth recovery, and errors that must never retry a job.
do
    local calls={}
    local http={}
    function http:get_json(url,opt)
        calls[#calls+1]={method='GET',url=url,opt=copy(opt)}
        return {data={isPaying=1},errCode=0}
    end
    function http:post_json(url,payload,opt)
        calls[#calls+1]={method='POST',url=url,payload=copy(payload),opt=copy(opt)}
        return {data={succ=true},errCode=0}
    end
    function http:json(opt)
        calls[#calls+1]={method=opt.method,url=opt.url,body=opt.body,opt=copy(opt)}
        return {data={stopPoll=true,curStatus={{uid=2,translateVersion=7}}},errCode=0}
    end
    local api=Api:new(http,{},nil)
    assert(api:translation_member_summary(book_id).isPaying==1)
    assert(api:toggle_translate(book_id,true).succ)
    assert(api:en_read(book_id,'2',{{uid='2',translateVersion=0},{uid='3',translateVersion=4}}).curStatus[1].translateVersion==7)
    assert(calls[1].url=='https://weread.qq.com/web/pay/memberCardSummary?pf=ios')
    assert(calls[2].url=='https://weread.qq.com/web/reader/toggleTranslate' and calls[2].payload.enabled==true)
    assert(calls[3].url=='https://weread.qq.com/web/book/enRead' and calls[3].method=='POST')
    assert(calls[3].body:find('"reference":{"uid":2,"texts":[]}',1,true),'official empty texts array was changed')
    assert(calls[3].body:find('"read":[{"translateVersion":0,"uid":2},{"translateVersion":4,"uid":3}]',1,true))
    assert(not calls[3].body:find('freeTrial',1,true),'request may not activate a trial')
    for _,call in ipairs(calls) do
        assert(call.opt.auth and call.opt.retries==0 and call.opt.rate_limit_retries==0)
        assert(call.opt.headers.Origin=='https://weread.qq.com' and call.opt.headers.Referer:find(book_id,1,true))
    end
    assert(not pcall(api.en_read,api,book_id,'2',{{uid=2},{uid=3},{uid=4}}) and #calls==3,'whole-book generation was allowed')
    assert(not pcall(api.en_read,api,book_id,'',{{uid=2}}) and #calls==3)
    -- beta.8: ordinary numeric WeRead books use the same official capability
    -- probe instead of being rejected locally because they are not CB_ uploads.
    assert(api:translation_member_summary('748277').isPaying==1 and #calls==4,'numeric book id was rejected before official service probe')
    assert(calls[4].opt.headers.Referer:find('748277',1,true),'numeric book id did not reach official reader context')
    assert(not pcall(api.translation_member_summary,api,'') and #calls==4,'empty translation book id reached network')
    local attempts,recoveries=0,0
    function http:get_json()
        attempts=attempts+1
        if attempts==1 then error('session expired -2012') end
        return {data={isPaying=true}}
    end
    api=Api.bind(api,{_recover_login_session=function() recoveries=recoveries+1; return true end})
    assert(api:translation_member_summary(book_id).isPaying and attempts==2 and recoveries==1)
    function http:json() attempts=attempts+1; error('paid member required') end
    attempts,recoveries=0,0
    assert(not pcall(api.en_read,api,book_id,2,{{uid=2}}) and attempts==1 and recoveries==0,'membership denial retried a generation')
end

local chapters={{chapterUid=1},{chapterUid=2},{chapterUid=3},{chapterUid=4}}
local function mock_api(summary,responses)
    local api={calls={},polls=0}
    function api:translation_member_summary(id) self.calls[#self.calls+1]='member'; assert(id==book_id); return copy(summary) end
    function api:toggle_translate(id,enabled) self.calls[#self.calls+1]='toggle'; assert(id==book_id and enabled) end
    function api:en_read(id,current,read)
        self.calls[#self.calls+1]='read'; self.polls=self.polls+1
        assert(id==book_id and tostring(current)=='2')
        self.read=copy(read)
        return copy(responses[math.min(self.polls,#responses)])
    end
    return api
end
local function options(overrides)
    local tick=0
    local opt={now=function() return tick end,wait=function(seconds) tick=tick+seconds end,timeout=6}
    for key,value in pairs(overrides or {}) do opt[key]=value end
    return opt
end
assert(Generation.friendly_error('translation not supported for this book'):find('暂不支持',1,true),
    'unsupported official capability is not translated into a safe user message')

for _,summary in ipairs({{isPaying=false},{isPaying=0},{isPaying='0'},{},{freeTrial=true}}) do
    local api=mock_api(summary,{})
    local ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and #api.calls==1 and api.polls==0,'unpaid or unknown account reached a generation endpoint')
    if summary.isPaying~=nil then assert(Generation.friendly_error(err):find('付费会员',1,true)) end
end
do
    local summary=assert(Generation.friendly_error('下载不完整，未生成新的 EPUB\n必需内容：230\n已完整获取：229\n'
        ..'• Triple Stores and SPARQL：plugins/miuread.koplugin/miuread/translation.lua:156: attempt to index a nil value'))
    assert(summary:find('229 / 230',1,true) and summary:find('Triple Stores and SPARQL',1,true)
        and not summary:find('translation.lua',1,true),'incomplete download hid the saved count or exposed an internal stack')
end
do
    local api=mock_api({isPaying=1},{{curStatus={{uid=2,translateVersion=0}}},
        {stopPoll=true,curStatus={{uid=2,translateVersion=7},{uid=3,translateVersion=8},{uid=4,translateVersion=9}}}})
    local progress=0
    local versions=Generation.prepare(api,book_id,chapters,'2',options({progress=function() progress=progress+1 end}))
    assert(versions['2']==7 and versions['3']==8 and versions['4']==nil and progress==1 and api.polls==2)
    assert(#api.read==2 and api.read[1].uid==2 and api.read[2].uid==3)
    assert(Generation.should_refresh(versions,'2'),'early metadata must not keep untranslated cached shards')
    assert(not Generation.should_refresh(versions,'1') and not Generation.should_refresh(nil,'2'))
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus={{uid=2,translateVersion=7}}}})
    versions=Generation.prepare(api,book_id,chapters,'2',options({include_next=false}))
    assert(#api.read==1 and versions['2']==7 and versions['3']==nil,'chapter-only EPUB requested an outside chapter')
end
do
    local api=mock_api({isPaying=true},{{curStatus={{uid=2,translateVersion=0}}}})
    local ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and api.polls==4 and Generation.friendly_error(err):find('稍后',1,true),'generation wait was not bounded')
    api=mock_api({isPaying=true},{{curStatus={},stopPoll=true,tips='仅限会员'}})
    ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and api.polls==1 and Generation.friendly_error(err):find('付费会员',1,true))
    api=mock_api({isPaying=true},{{data='unexpected'}})
    assert(not pcall(Generation.prepare,api,book_id,chapters,'2',options()) and api.polls==1)
    api=mock_api({isPaying=true},{{curStatus={}}})
    assert(not pcall(Generation.prepare,api,book_id,chapters,'missing',options()) and #api.calls==1)
    api=mock_api({isPaying=true},{{curStatus={}}})
    assert(not pcall(Generation.prepare,api,book_id,chapters,'2',options({cancelled=function() return #api.calls>0 end}))
        and #api.calls==1,'cancel during membership lookup reached toggleTranslate')
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus={{uid=2,translateVersion=7}}}})
    assert(not pcall(Generation.prepare,api,book_id,chapters,'2',options({cancelled=function() return api.polls>0 end}))
        and api.polls==1,'cancelled ready response was installed')
end
do
    local versioned=copy(chapters)
    versioned[2].translateVersion=5; versioned[2].hasTranslated=false
    local api=mock_api({isPaying=true},{{curStatus={{uid=2,translateVersion=5}}}})
    local ok,err=pcall(Generation.prepare,api,book_id,versioned,'2',options())
    assert(not ok and Generation.friendly_error(err) and api.polls==4,'unchanged non-zero catalog version was mistaken for a completed job')
    assert(api.read[1].translateVersion==5,'official generation request lost its catalog baseline')
    api=mock_api({isPaying=true},{{curStatus={{uid=2,translateVersion=5}}},{stopPoll=true,curStatus={{uid=2,translateVersion=6}}}})
    local versions=Generation.prepare(api,book_id,versioned,'2',options())
    assert(api.polls==2 and versions['2']==6,'generation did not wait for its new version')
    versioned[2].hasTranslated=true
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus={{uid=2,translateVersion=5}}}})
    versions=Generation.prepare(api,book_id,versioned,'2',options())
    assert(api.polls==1 and versions['2']==5,'previously translated server chapter could not be refreshed')
    versioned[3].translateVersion=9; versioned[3].hasTranslated=false
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus={{uid=2,translateVersion=5},{uid=3,translateVersion=9}}}})
    versions=Generation.prepare(api,book_id,versioned,'2',options())
    assert(versions['2']==5 and versions['3']==nil,'next chapter with an unchanged pending version was unnecessarily refreshed')
    assert(not Generation.content_ready('<p>Only the original.</p>'))
    assert(not Generation.content_ready('<p class="wr-translation">&#160;<br/></p>'))
    assert(Generation.content_ready('<p>Original.</p><p class="wr-translation">译文。</p>'))
end

-- The official frontend reads curStatus only when stopPoll is true. Waiting
-- responses may omit it or encode it as JSON null; interim versions must not
-- trigger a content download. Metadata outside a data envelope is allowed.
do
    local json_null=newproxy(true)
    local api=mock_api({isPaying=true},{
        {stopPoll=false},
        {data={stopPoll=false,curStatus=json_null},requestId='private-request-value'},
        {stopPoll=false,curStatus={{uid=2,translateVersion=7}}},
        {stopPoll=true,curStatus={false,'unexpected row',json_null,{uid=2,translateVersion=7}}},
    })
    local progress=0
    local versions=Generation.prepare(api,book_id,chapters,'2',options({
        include_next=false,progress=function() progress=progress+1 end,
    }))
    assert(versions['2']==7 and api.polls==4 and progress==3,'waiting response was rejected or an interim version was released')
    api=mock_api({isPaying=true},{
        {},{tips='Still processing'},
        {result={payload={stopPoll=true,curStatus={{uid=2,translateVersion=7}}}},traceId='private-trace-value'},
    })
    versions=Generation.prepare(api,book_id,chapters,'2',options())
    assert(versions['2']==7 and api.polls==3,'empty/tips-only waiting response or nested response failed')

    api=mock_api({isPaying=true},{{stopPoll=false,curStatus={{uid=2,translateVersion=7}}}})
    local ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and api.polls==4 and Generation.friendly_error(err),'positive version bypassed stopPoll or its timeout')
    api=mock_api({isPaying=true},{{stopPoll=true}})
    ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and api.polls==1 and tostring(err):find('尚未就绪',1,true),'stopped empty response was misclassified')

    local versioned=copy(chapters); versioned[2].translateVersion=5
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus=json_null}})
    versions=Generation.prepare(api,book_id,versioned,'2',options())
    assert(versions['2']==5 and Generation.should_refresh(versions,'2'),
        'completed unchanged chapter was not scheduled for guarded content refresh')
    api=mock_api({isPaying=true},{{stopPoll=true,curStatus={{uid=2,translateVersion=0}}}})
    assert(not pcall(Generation.prepare,api,book_id,versioned,'2',options()) and api.polls==1,
        'explicitly unavailable current chapter fell back to a stale catalog version')
    api=mock_api({isPaying=true},{{stopPoll=true,tips='仅限会员'}})
    ok,err=pcall(Generation.prepare,api,book_id,versioned,'2',options())
    assert(not ok and api.polls==1 and Generation.friendly_error(err):find('付费会员',1,true),
        'server membership denial was bypassed by a non-zero catalog version')

    local malformed={data='private-response-value',sessionToken='private-session-value'}
    api=mock_api({isPaying=true},{malformed})
    ok,err=pcall(Generation.prepare,api,book_id,chapters,'2',options())
    assert(not ok and api.polls==1 and tostring(err):find('暂时无法确认译文状态',1,true))
    for _,private in ipairs({'private-response-value','private-session-value','sessionToken'}) do
        assert(not tostring(err):find(private,1,true) and not Generation.describe_response(malformed):find(private,1,true),
            'response diagnostics exposed private fields or values')
    end
end

-- Rebase native annotations after translated siblings are inserted. Keep exact
-- original-language offsets, and remap only the reading cursor to the target
-- language. Exercise recovery across each side of the two-file transaction.
local function html(body,uid) return '<html><head/><body data-miuread-chapter="'..uid..'"><section>'..body..'</section></body></html>' end
local p1='<p id="p1">One.</p>'
local p2='<p id="p2">Two <em>words</em>.</p>'
local old_html=html(p1..p2,'2')
local new_html=html(p1..'<p id="p1" class="wr-translation">一。</p>'..p2..'<p id="p2" class="wr-translation">二。</p>','2')
local archives={old={html=old_html,meta={book_id=book_id,task_id='old',_file_size=1000,_chapter_count=1},uid='2'},
    new={html=new_html,meta={book_id=book_id,task_id='new',_file_size=1200,_chapter_count=1},uid='2'}}
local Installer={}
function Installer.inspect(path) return copy(archives[path].meta) end
function Installer.visit_chapter_text(path,callback)
    local item=assert(archives[path])
    local ok,err=callback(item.html,1,{uid=item.uid})
    if not ok then return nil,err end
    return true,copy(item.meta)
end
package.preload['miuread.epub_installer']=function() return Installer end
local base='/body/DocFragment[1]/body/section'
local settings={last_xpointer=base..'/p[2]/text().0',miuread_translation_mode='original',
    annotations={{page=base..'/p[2]/text().7',pos0=base..'/p[2]/em/text().1',pos1=base..'/p[2]/em/text().4',
        text='words',note='Keep this note',datetime='2026-09-30'}},bookmarks={{page=base..'/p[1]/text().0'}}}
local rebased=assert(Translation.rebase_settings('old','new',settings,'translation'))
assert(rebased.annotations[1].page==base..'[1]/p[3]/text().7')
assert(rebased.annotations[1].pos0==base..'[1]/p[3]/em[1]/text().1' and rebased.annotations[1].pos1==base..'[1]/p[3]/em[1]/text().4')
assert(rebased.last_xpointer==base..'[1]/p[4]' and rebased.miuread_translation_mode=='translation')
assert(rebased.annotations[1].note=='Keep this note' and rebased.annotations[1].datetime=='2026-09-30' and rebased.annotations_externally_modified)
assert(settings.annotations[1].page==base..'/p[2]/text().7' and settings.miuread_translation_mode=='original','source settings were mutated')
assert(Translation.recover_settings('old',rebased).annotations[1].page==settings.annotations[1].page)
assert(Translation.recover_settings('new',rebased).annotations[1].page==rebased.annotations[1].page)
assert(Translation.recover_settings('new',rebased).miuread_translation_pending_rebase==nil)
archives.bad=copy(archives.new); archives.bad.meta.task_id='unknown'
assert(Translation.recover_settings('bad',rebased)==nil,'an unrelated EPUB version consumed the recovery journal')
for _,bad in ipairs({
    {html=new_html:gsub('Two','Changed'),uid='2'},
    {html=new_html:gsub('</section>','<p id="p2">Duplicate</p><p id="p2">Again</p></section>'),uid='2'},
    {html=new_html,uid='different'},
}) do
    archives.bad={html=bad.html,uid=bad.uid,meta=copy(archives.new.meta)}
    assert(Translation.rebase_settings('old','bad',settings,'bilingual')==nil,'unverified annotation moved to a different block')
end
archives.bad=copy(archives.new); archives.bad.meta.book_id='CB_other'
assert(Translation.rebase_settings('old','bad',settings,'bilingual')==nil,'cross-book update accepted')
archives.cached=copy(archives.new); archives.cached.meta.task_id='cached'
local chinese={last_xpointer=base..'/p[4]/text().0',annotations={{pos0=base..'/p[4]/text().1',pos1=base..'/p[4]/text().2'}}}
local unchanged=assert(Translation.rebase_settings('new','cached',chinese,'translation'))
assert(unchanged.annotations[1].pos0==chinese.annotations[1].pos0 and unchanged.last_xpointer==chinese.last_xpointer,
    'unchanged translated chapters lost their Chinese annotations')
archives.no_id={html=html('<p>Unchanged without an id.</p>','2'),uid='2',meta=copy(archives.old.meta)}
assert(Translation.rebase_settings('no_id','no_id',{last_xpointer=base..'/p[1]/text().3'},'bilingual').last_xpointer
    ==base..'/p[1]/text().3','unchanged original chapter required an unnecessary id')

-- Native positions are about DOM text and children, not the source's ids,
-- class attributes or quote spelling. Verify the whole original paragraph
-- before retaining offsets within it; an isolated matching word is insufficient.
local bare='<p>First paragraph.</p><p>Keep <em>these words</em> &amp; offsets.</p>'
archives.bare={html=html(bare,'2'),uid='2',meta=copy(archives.old.meta)}
archives.bare_new={html=html('<p id="new-1" class="server">First paragraph.</p>'
    ..'<p id="new-1" class="wr-translation">第一段。</p>'
    ..'<p class="server" id="new-2">Keep <em data-server="1">these words</em> &#38; offsets.</p>'
    ..'<p id="new-2" class="wr-translation">保留文字。</p>','2'),uid='2',meta=copy(archives.new.meta)}
local bare_settings={last_xpointer=base..'/p[2]/text().2',annotations={{page=base..'/p[2]/text().2',
    pos0=base..'/p[2]/em/text().1',pos1=base..'/p[2]/em/text().5',text='these words',note='Keep'}}}
local bare_rebased=assert(Translation.rebase_settings('bare','bare_new',bare_settings,'bilingual'))
assert(bare_rebased.last_xpointer==base..'[1]/p[3]/text().2')
assert(bare_rebased.annotations[1].pos0==base..'[1]/p[3]/em[1]/text().1')
assert(bare_rebased.annotations[1].pos1==base..'[1]/p[3]/em[1]/text().5' and bare_rebased.annotations[1].note=='Keep')
archives.attrs=copy(archives.new)
archives.attrs.html=archives.attrs.html:gsub('<p id="p2">','<p class="server" id="p2" data-version="42">')
assert(Translation.rebase_settings('old','attrs',settings,'bilingual').annotations[1].page==base..'[1]/p[3]/text().7')
archives.renamed=copy(archives.attrs); archives.renamed.html=archives.renamed.html:gsub('id="p2"','id="new-p2"')
assert(Translation.rebase_settings('old','renamed',settings,'bilingual').annotations[1].page==base..'[1]/p[3]/text().7')
archives.bare_bad=copy(archives.bare_new)
archives.bare_bad.html=archives.bare_bad.html:gsub('Keep <em','Changed <em')
local em_only={annotations={{pos0=base..'/p[2]/em/text().1',pos1=base..'/p[2]/em/text().5'}}}
local rejected,reason=Translation.rebase_settings('bare','bare_bad',em_only,'bilingual')
assert(not rejected and reason:find('chapter=2 path=',1,true),'a matching word in changed source text moved a highlight')
archives.ambiguous=copy(archives.bare_new)
archives.ambiguous.html=html(bare..bare,'2')
assert(not Translation.rebase_settings('bare','ambiguous',bare_settings,'bilingual'),'duplicate idless paragraphs accepted')
archives.structure=copy(archives.bare_new)
archives.structure.html=archives.structure.html:gsub('<em data-server="1">','<strong>'):gsub('</em>','</strong>')
assert(not Translation.rebase_settings('bare','structure',bare_settings,'bilingual'),'different text-node structure retained native offsets')

-- Load the actual reader integration methods without starting KOReader. Test
-- generation routing, retained download scope, and rollback before replacing
-- an open book; annotations above test the independent migration algorithm.
local Plugin={}
local env=setmetatable({Plugin=Plugin,U=Util,EpubInstaller=Installer,
    logger=require('logger'),Event={new=function(_,name) return {name=name} end},
    BookIntegrity={repair_options=function(record) return {annotations=true,range_start_index=4,range_end_index=5} end}}, {__index=_G})
require('translation_test_support').load_plugin_methods(ROOT,
    {'_reader_translation_current_uid','_reader_translation_record','_reader_translation_context',
    '_request_reader_translation_mode','_show_reader_translation_only_help','_install_pending_record'},env)
local messages,notices,saved_mode,queued,download_options={},{},nil,nil,nil
local current={book={book_id=book_id,title='Test'},record={file='old',chapter_map={{uid='2'}}}}
local plugin=setmetatable({ui={rolling={xpointer=base..'/p[2]/text().0'},
    doc_settings={readSetting=function() end,saveSetting=function(_,_,mode) saved_mode=mode end},handleEvent=function() end},
    _reader_translation_profile=function() return {blocks=0,chapters={},separable=false} end,
    _current_book_record=function() return current end,
    info=function(_,message) messages[#messages+1]=message end,toast=function() end,
    status_toast=function(_,_,message) notices[#notices+1]=message end,
    _reader_queue_typography=function(_,key,mode) queued=mode; return true end,
    download=function(_,book,opt,open_after,done,background)
        assert(book.bookId==book_id and not open_after and background)
        download_options=copy(opt); done({pending_install=true},background); return true
    end}, {__index=Plugin})
assert(plugin:_request_reader_translation_mode('translation'))
assert(download_options.generate_translation_uid=='2' and download_options.translation_mode=='translation')
assert(download_options.translation_batch_size=='auto' and next(download_options.translation_cached_uids)==nil)
assert(download_options.annotations and download_options.range_start_index==4 and download_options.range_end_index==5)
assert(#messages==0 and notices[#notices]:find('应用',1,true),'background completion lost its quiet application hint')
plugin._reader_translation_profile=function() return {blocks=4,chapters={{chapter_uid='2',blocks=4}}} end
assert(plugin:_request_reader_translation_mode('bilingual') and queued=='bilingual','cached translations contacted generation')
plugin._reader_translation_profile=function() return nil end
assert(plugin:_request_reader_translation_mode('original') and saved_mode=='original')
plugin.download_task={busy=function() return true end}
download_options=nil
assert(plugin:_request_reader_translation_mode('translation')==false and download_options==nil,'generation raced an active download')

local sidecar,flushes,installed,removed,stored=copy(settings),{},0,0,nil
local flush_fail,install_fail=false,false
local docsettings={data=sidecar}
function docsettings:flush(data)
    flushes[#flushes+1]=copy(data or self.data)
    if flush_fail then return nil end
    sidecar=copy(data or self.data); return 'sidecar'
end
package.preload['docsettings']=function() return {open=function() docsettings.data=sidecar; return docsettings end} end
function Installer.install()
    installed=installed+1
    if install_fail then return false,'rename failed' end
    return true,'atomic'
end
plugin.store={save_variant=function(_,id,kind,record) stored=copy(record) end,
    remove_pending_install=function() removed=removed+1 end}
local record={file='old',pending_file='new',variant='notes',chapter_map={{uid='2'}},pending_install=true,
    translation_mode='translation',translation_refresh_versions={['2']=7}}
assert(plugin:_install_pending_record(book_id,'notes',nil,record))
assert(installed==1 and removed==1 and stored.pending_install==nil and stored.translation_mode==nil)
assert(flushes[1].miuread_translation_pending_rebase and not sidecar.miuread_translation_pending_rebase)
assert(sidecar.annotations[1].page==rebased.annotations[1].page and sidecar.miuread_translation_mode=='translation')
archives.unpaired=copy(archives.new)
archives.unpaired.html=archives.unpaired.html:gsub('<p id="p1" class','<p class'):gsub('<p id="p2" class','<p class')
sidecar=copy(settings); sidecar.miuread_translation_mode='translation'
local fallback_record=copy(record)
fallback_record.pending_file='unpaired'; fallback_record.translation_only_available=false
fallback_record.translation_follow_display=true
local fallback_ok,fallback_result=plugin:_install_pending_record(book_id,'notes',nil,fallback_record)
assert(fallback_ok and fallback_result.translation_display_fallback and sidecar.miuread_translation_mode=='bilingual',
    'unsupported downloaded translations were applied as an invisible translation-only mode')
assert(sidecar.annotations[1].page==rebased.annotations[1].page and sidecar.annotations[1].note=='Keep this note')
assert(stored.translation_only_available==nil)
sidecar=copy(settings); installed=0; install_fail=true
assert(not plugin:_install_pending_record(book_id,'notes',nil,record) and installed==1)
assert(sidecar.annotations[1].page==settings.annotations[1].page and sidecar.miuread_translation_mode=='original','failed EPUB install did not restore sidecar')
sidecar=copy(settings); installed=0; install_fail=false; flush_fail=true
assert(not plugin:_install_pending_record(book_id,'notes',nil,record) and installed==0,'failed sidecar write still replaced EPUB')
flush_fail=false; record.pending_file='bad'; installed=0
assert(not plugin:_install_pending_record(book_id,'notes',nil,record) and installed==0,'unverified migration still replaced EPUB')

-- A cached Sync record can predate the download result. Reuse the authoritative
-- pending variant on disk instead of generating the same translated chapter.
local pending_record=copy(record); pending_record.pending_file='new'
pending_record.variant='notes'; current.variant='notes'
plugin.download_task=nil; download_options=nil
plugin.store.variant=function() return pending_record end
assert(plugin:_request_reader_translation_mode('bilingual') and download_options==nil)
assert(stored.translation_mode=='bilingual' and stored.pending_file=='new')
assert(notices[#notices]:find('应用',1,true),'pending translation reuse lost its application hint')
pending_record.pending_file='unpaired'
plugin.ui.doc_settings.readSetting=function() return 'bilingual' end
assert(not plugin:_request_reader_translation_mode('translation') and saved_mode=='bilingual',
    'unsupported pending translation changed the existing reading choice')
assert(messages[#messages]:find('逐段对应',1,true))
pending_record.pending_file='new'
plugin.ui.doc_settings.readSetting=function() end
print('Translation generation: official requests, membership gate, bounded polling, selective refresh, native positions and install recovery passed')

-- Short chapters fill a bounded reading window; long chapters and missing
-- word counts cannot accidentally request a whole book. Catalog flags alone
-- never count as locally cached translations.
do
    local catalog={}
    for i=1,35 do catalog[i]={chapterUid=i,wordCount=400,title='Chapter '..i} end
    local plan=Generation.plan(catalog,'2')
    assert(#plan.chapters==20 and #plan.pending==20 and plan.words==8000)
    catalog[3].structural=true
    plan=Generation.plan(catalog,'2',{batch_size=5,cached_uids={['2']=true,['4']=true}})
    assert(#plan.chapters==5 and #plan.pending==3 and plan.chapters[2].chapterUid==4)
    for _,chapter in ipairs(catalog) do chapter.wordCount=5000 end
    assert(#Generation.plan(catalog,'2').chapters==3,'long chapters ignored the minimum window')
    for _,chapter in ipairs(catalog) do chapter.wordCount=nil end
    assert(#Generation.plan(catalog,'2').chapters==20,'missing word counts escaped the cap')
    assert(#Generation.plan(catalog,'2',{batch_size=1}).chapters==1)
    assert(#Generation.plan(catalog,'34').chapters==2,'end of book was not clamped')
    assert(not pcall(Generation.plan,catalog,'missing'))
    assert(Generation.normalize_batch_size(999)=='auto' and Generation.normalize_batch_size('10')==10)
    plan=Generation.plan(catalog,'25',{batch_size='all',cached_uids={['1']=true}})
    assert(#plan.chapters==34 and #plan.pending==33 and plan.chapters[1].chapterUid==1,
        'whole-file scope omitted earlier chapters or retained a directory page')
    assert(Generation.normalize_batch_size('all')=='all' and not pcall(Generation.plan,catalog,'missing',{batch_size='all'}))
    plan=Generation.plan({{chapterUid=1,structural=true},{chapterUid=2}},'1',{batch_size='all'})
    assert(plan.required_uid=='2' and #plan.chapters==1)
end

local function batch_api(responder)
    local api={members=0,toggles=0,requests={}}
    function api:translation_member_summary() self.members=self.members+1; return {isPaying=true} end
    function api:toggle_translate() self.toggles=self.toggles+1 end
    function api:en_read(_,current,read)
        self.requests[#self.requests+1]={current=current,read=copy(read)}
        assert(#read<=2,'batch changed the official request shape')
        return responder(self,current,read)
    end
    return api
end
do
    local catalog={{chapterUid=1},{chapterUid=2},{chapterUid=3},{chapterUid=4},{chapterUid=5},{chapterUid=6}}
    -- Each response completes only its current chapter, reproducing the
    -- original bug: next-chapter prefetch must not be mistaken for completion.
    local api=batch_api(function(_,current) return {stopPoll=true,curStatus={{uid=current,translateVersion=7}}} end)
    local versions,plan=Generation.prepare_batch(api,book_id,catalog,'2',options({batch_size=5}))
    assert(api.members==1 and api.toggles==1 and #api.requests==5)
    for i=2,6 do assert(versions[tostring(i)]==7) end
    assert(versions['1']==nil and #api.requests[5].read==1 and not plan.incomplete)

    -- A completed next chapter needs no second generation request. Ignore
    -- unsolicited versions, stay inside the local range, and skip cached text.
    api=batch_api(function(_,_,read)
        local status={{uid='outside',translateVersion=99}}
        for _,item in ipairs(read) do status[#status+1]={uid=item.uid,translateVersion=8} end
        return {stopPoll=true,curStatus=status}
    end)
    versions=Generation.prepare_batch(api,book_id,catalog,'2',options({batch_size=5,cached_uids={['3']=true}}))
    assert(#api.requests==3 and versions['3']==nil and versions.outside==nil)
    assert(#api.requests[1].read==1 and api.requests[2].current==4)
    local local_range={{chapterUid=20},{chapterUid=21},{chapterUid=22}}
    api=batch_api(function(_,current,read)
        for _,item in ipairs(read) do assert(item.uid>=21 and item.uid<=22) end
        return {stopPoll=true,curStatus={{uid=current,translateVersion=7}}}
    end)
    versions=Generation.prepare_batch(api,book_id,local_range,'21',options({batch_size=20}))
    assert(#api.requests==2 and versions['20']==nil and versions['21'] and versions['22'])
    api=batch_api(function() error('already translated chapters reached the network') end)
    versions=Generation.prepare_batch(api,book_id,{{chapterUid=2}},'2',options({cached_uids={['2']=true}}))
    assert(next(versions)==nil and api.members==0 and api.toggles==0)

    -- A next-chapter timeout preserves the completed current chapter. A
    -- timeout of the required current chapter and cancellation remain fatal.
    api=batch_api(function(_,current)
        return current==2 and {stopPoll=true,curStatus={{uid=2,translateVersion=7}}} or {stopPoll=false}
    end)
    versions,plan=Generation.prepare_batch(api,book_id,catalog,'2',options({batch_size=5}))
    assert(versions['2']==7 and versions['3']==nil and plan.incomplete)
    api=batch_api(function() return {stopPoll=false} end)
    local ok,err=pcall(Generation.prepare_batch,api,book_id,catalog,'2',options())
    assert(not ok and Generation.friendly_error(err),'current chapter timeout was swallowed')
    ok,err=pcall(Generation.prepare_batch,api,book_id,catalog,'2',options({cached_uids={['2']=true}}))
    assert(not ok and Generation.friendly_error(err),'zero new chapters still staged a replacement')
    api=batch_api(function(_,current) return {stopPoll=true,curStatus={{uid=current,translateVersion=7}}} end)
    ok,err=pcall(Generation.prepare_batch,api,book_id,catalog,'2',options({cancelled=function() return #api.requests>0 end}))
    assert(not ok and tostring(err):find('download cancelled',1,true) and #api.requests==1)
    api=batch_api(function(_,current)
        if current==2 then return {stopPoll=true,curStatus={{uid=2,translateVersion=7}}} end
        return {stopPoll=true,tips='仅限会员'}
    end)
    ok,err=pcall(Generation.prepare_batch,api,book_id,catalog,'2',options())
    assert(not ok and Generation.friendly_error(err):find('付费会员',1,true),
        'a service denial was swallowed as optional prefetch')
    api=batch_api(function() error('unpaid batch reached generation') end)
    function api:translation_member_summary() return {isPaying=false} end
    ok,err=pcall(Generation.prepare_batch,api,book_id,catalog,'2',options())
    assert(not ok and api.toggles==0 and #api.requests==0)

    -- The whole batch also has a five-minute budget even if each chapter
    -- individually completes within its own polling timeout.
    local tick=0
    api=batch_api(function(_,current)
        tick=tick+80
        return {stopPoll=true,curStatus={{uid=current,translateVersion=7}}}
    end)
    versions,plan=Generation.prepare_batch(api,book_id,catalog,'2',{
        batch_size=5,now=function() return tick end,wait=function() end})
    assert(#api.requests==4 and plan.incomplete and versions['5']==7 and versions['6']==nil)

    -- Whole-file jobs are explicitly requested and are allowed to run beyond
    -- the short batch budget. Prioritize the open chapter, include earlier
    -- chapters, retain catalog order, and skip only local or verified results.
    local large={}
    for i=1,30 do large[i]={chapterUid=i} end
    tick=0
    api=batch_api(function(_,current)
        tick=tick+80
        return {stopPoll=true,curStatus={{uid=current,translateVersion=7}}}
    end)
    local completed={}
    versions,plan=Generation.prepare_batch(api,book_id,large,'20',{
        batch_size='all',now=function() return tick end,wait=function() end,
        on_ready=function(ready) for id,version in pairs(ready) do completed[id]=version end end})
    assert(#api.requests==30 and not plan.incomplete and api.requests[1].current==20 and tick>300)
    assert(#plan.chapters==30 and large[1].chapterUid==1 and versions['1']==7 and versions['30']==7)
    for id,version in pairs(versions) do assert(completed[id]==version) end

    api=batch_api(function(_,current)
        return current==3 and {stopPoll=false} or {stopPoll=true,curStatus={{uid=current,translateVersion=7}}}
    end)
    versions,plan=Generation.prepare_batch(api,book_id,catalog,'2',options({batch_size='all'}))
    assert(plan.incomplete and versions['3']==nil and versions['1']==7 and versions['6']==7,
        'one later generation timeout stopped the whole-file job')

    catalog[4].translateVersion=9
    api=batch_api(function(_,current) return {stopPoll=true,curStatus={{uid=current,translateVersion=10}}} end)
    versions=Generation.prepare_batch(api,book_id,catalog,'2',options({batch_size='all',
        cached_uids={['1']=true},ready_versions={['2']=7,['3']=8,['4']=8,['5']=9,['6']=9,outside=99}}))
    assert(#api.requests==1 and api.requests[1].current==4 and versions['4']==10 and versions['2']==7,
        'resume forgot completed generation or reused an obsolete catalog version')
    assert(versions.outside==nil and versions['1']==nil)

    assert(Generation.can_reuse_content({translation_version=7},7,'<p class="wr-translation">译文</p>'))
    assert(not Generation.can_reuse_content({translation_version=6},7,'<p class="wr-translation">译文</p>'))
    assert(not Generation.can_reuse_content({translation_version=7},7,'<p>Original only</p>'))
    assert(not Generation.can_reuse_content({},7,'<p class="wr-translation">译文</p>'))
end

-- Even with the current chapter cached, the explicit ahead action must reach
-- the worker and carry both the selected window and known translated chapters.
do
    plugin.store=nil; plugin.download_task=nil; current.variant=nil
    current.record={file='old',chapter_map={{uid='2'},{uid='3'},{uid='4'}}}
    plugin._reader_translation_profile=function() return {blocks=4,chapters={{chapter_uid='2',blocks=4}}} end
    download_options=nil
    assert(plugin:_request_reader_translation_mode('bilingual',true) and download_options)
    assert(download_options.translation_cached_uids['2'] and download_options.translation_batch_size=='auto')
    download_options=nil
    assert(plugin:_request_reader_translation_mode('bilingual',true,1) and download_options==nil,
        'a fully cached window still downloaded and rebuilt the EPUB')
    local count=#messages
    download_options=nil
    assert(plugin:_request_reader_translation_mode('bilingual',true,'all') and download_options,
        'whole-file background action did not override the current-chapter setting')
    assert(download_options.translation_batch_size=='all' and #messages==count,
        'background completion interrupted reading with a modal message')
    download_options=nil
    assert(plugin:_request_reader_translation_mode('original',true,'all') and download_options,
        'offline downloading was coupled to changing the reading mode')
    assert(download_options.translation_mode=='original' and download_options.translation_follow_display)
    plugin._reader_translation_profile=function()
        return {blocks=1,chapters={{chapter_uid='2',blocks=1,pairs={}}},separable=false}
    end
    download_options=nil
    assert(not plugin:_request_reader_translation_mode('translation') and download_options==nil,
        'a direct mode request bypassed unavailable translation-only conditions')
    assert(messages[#messages]:find('逐段对应',1,true))
end
print('Translation batches: bounded reading windows, cached skips, completed polls, partial timeout, cancellation and reader ahead action passed')
