-- One business API, backed by E-Ink and Web implementations. Protocol-specific
-- payloads, auth and response parsing stay inside their respective backends.
local Web=require("miuread.api_web")
local Transport=require("miuread.api_transport")
local Protocol=require("miuread.protocol")
local Api={}; Api.__index=Api

local capabilities={
    shelf={phase="shelf"},shelf_stream={phase="shelf"},book_on_shelf={phase="shelf"},
    add_to_shelf={phase="shelf",write=true},remove_from_shelf={phase="shelf",write=true},
    book={phase="book"},chapters={phase="catalog"},catalog={phase="catalog"},
    search={phase="search"},recommend_books={phase="store"},similar_books={phase="store"},
    store_categories={phase="store"},category_books={phase="store"},reading_stats={phase="statistics"},
    notebooks={phase="annotations"},bookmark_list={phase="annotations"},review_list_mine={phase="annotations"},
    underlines={phase="annotations"},readreviews={phase="annotations"},review_single={phase="annotations"},
    add_bookmark={phase="annotations",write=true,coordinates=true},
    add_review={phase="annotations",write=true,coordinates=true},
    remove_bookmark={phase="annotations",write=true},remove_review={phase="annotations",write=true},
    like_review={phase="annotations",write=true},
    progress={phase="progress"},web_progress={phase="progress",web_only=true},
    progress_sources={phase="progress",web_only=true},
    book_read_info={phase="progress"},mark_book_finished={phase="progress",write=true},
    translation_member_summary={phase="translation"},toggle_translate={phase="translation"},en_read={phase="translation"},
    chapter={phase="download"},report_payload={phase="reading_report",web_only=true,write=true},
    mp_content={phase="articles",web_only=true},
}

function Api:new(http,store,reader)
    return setmetatable({http=http,store=store,reader=reader,web_backend=Web:new(http,store,reader)},self)
end
function Api.bind(api,reader,transport)
    reader=reader or api.reader
    local http,store=api.http or (reader and reader.http),api.store or (reader and reader.store)
    local web=api.web_backend or api
    if api.web_backend and web.reader~=reader then web=Web:new(http,store,reader) end
    return setmetatable({http=http,store=store,reader=reader,web_backend=web,_transport=transport},Api)
end
function Api:for_channel(channel)
    assert(channel=="web" or channel=="eink","invalid API channel")
    local view=Api.bind(self,self.reader)
    view.coordinate_source,view._channel=channel,channel
    return view
end
function Api:scope(options)
    if self._transport then return self end
    options=options or {}
    local route=Transport.new(self.store,{channel=self._channel or options.channel})
    local view=Api.bind(self,self.reader,route)
    view.coordinate_source,view._channel=self.coordinate_source,self._channel
    return view
end
function Api:_native(transport)
    if type(transport.native)=="function" then return transport:native() end
    return require("miuread.eink_client").new(self.http,self.store,self.reader)
end
function Api:_invoke(name,...)
    local policy={}; for key,value in pairs(capabilities[name]) do policy[key]=value end
    if policy.coordinates then
        if self.coordinate_source=="eink" then policy.native_only=true else policy.web_only=true end
    end
    local arguments={n=select("#",...),...}
    if policy.write and type(arguments[1])=="table" then arguments[1]=Web._sanitize(arguments[1]) end
    local request_options=name=="chapter" and arguments[4] or (name=="catalog" and arguments[2]) or {}
    if type(request_options)~="table" then request_options={} end
    if request_options.fresh_context==true then policy.web_only=true end
    if name=="chapter" and Protocol.is_mp(tostring((arguments[1] or {}).bookId or "")) then policy.web_only=true end
    if self._channel=="eink" and not policy.web_only then policy.native_only=true end
    local transport=self._transport or Transport.new(self.store,{channel=self._channel or request_options.channel,
        fresh_context=request_options.fresh_context})
    local function invoke(backend)
        local fn=backend[name]
        if type(fn)~="function" then error("unsupported API operation: "..name,0) end
        return fn(backend,unpack(arguments,1,arguments.n))
    end
    local native
    if not policy.web_only and type(require("miuread.eink_client")[name])=="function" then
        native=function() return invoke(self:_native(transport)) end
    end
    policy.restart_on_fallback=transport.restart_annotations and policy.phase=="annotations"
    local a,b,c,d=transport:invoke(name,native,function() return invoke(self.web_backend) end,policy)
    if type(a)=="table" then
        a._api_channel=transport.last_channel
        if policy.phase=="annotations" and a._annotation_source==nil then a._annotation_source=transport.last_channel end
    end
    return a,b,c,d
end
for name in pairs(capabilities) do
    local operation=name
    Api[operation]=function(self,...) return self:_invoke(operation,...) end
end
Api.review_batches=Web.review_batches
Api._scalar,Api._sanitize,Api._unique_candidates=Web._scalar,Web._sanitize,Web._unique_candidates
return Api
