local Protocol=require("miuread.protocol")
local Codec=require("miuread.codec")
local U=require("miuread.util")
local DownloadResult=require("miuread.download_result")
local logger=require("logger")
local Library={}; Library.__index=Library
function Library:new(api,http,store)
    return setmetatable({api=api,http=http,store=store,_sort_cache={}},self)
end

local COVER_MAX_BYTES=12*1024*1024
local COVER_EXTENSIONS={
    [".png"]=true,[".jpg"]=true,[".gif"]=true,[".webp"]=true,
    [".svg"]=true,
}

local function cover_download_url(url)
    url=tostring(url or "")
    if url=="" then return url end
    -- WeRead CDN cover URLs encode image size in the /tN_ token. t9 keeps a
    -- noticeably cleaner source for e-ink downscaling without downloading
    -- full-resolution artwork. Non-WeRead URLs are left untouched.
    return url:gsub("/t%d+_", "/t9_")
end

local function truthy(value)
    if value==true then return true end
    if tonumber(value)==1 then return true end
    local text=tostring(value or ""):lower()
    return text=="true" or text=="yes"
end

local function first_number(...)
    for i=1,select("#",...) do
        local value=tonumber(select(i,...))
        if value~=nil then return value end
    end
    return nil
end

local function archive_source_present(data)
    data=type(data)=="table" and data or {}
    return data.archive~=nil or data.archives~=nil or data.bookArchives~=nil or data.archiveList~=nil
end

local function archive_entries(data)
    local source=data.archive or data.archives or data.bookArchives or data.archiveList or {}
    if type(source)~="table" then return {} end
    if source[1] then return source end
    if source.bookIds or source.bookIdList or source.books or source.items then return {source} end
    local out={}
    for _,row in pairs(source) do
        if type(row)=="table" then out[#out+1]=row end
    end
    table.sort(out,function(a,b)
        local ao=first_number(a.order,a.sort,a.index,a.archiveIndex) or 1000000000
        local bo=first_number(b.order,b.sort,b.index,b.archiveIndex) or 1000000000
        if ao~=bo then return ao<bo end
        return tostring(a.name or a.title or "")<tostring(b.name or b.title or "")
    end)
    return out
end

local function archive_stable_id(archive)
    archive=type(archive)=="table" and archive or {}
    for _,field in ipairs({"archiveId","archive_id","groupId","group_id","id"}) do
        local value=archive[field]
        if value~=nil and tostring(value)~="" then return tostring(value) end
    end
    return nil
end

local function archive_identity(archive,index)
    local name=U.trim(tostring(archive.name or archive.title or archive.archiveName or "分组"))
    if name=="" then name="分组 "..tostring(index or "") end
    local stable_id=archive_stable_id(archive)
    return stable_id and ("id:"..stable_id) or ("name:"..name),name,stable_id~=nil
end

local function archive_ids(archive)
    local ids=archive.bookIds or archive.bookIdList or archive.books or archive.items or {}
    if type(ids)=="string" then
        local parsed={}
        for id in ids:gmatch("[^,%s]+") do parsed[#parsed+1]=id end
        ids=parsed
    end
    return type(ids)=="table" and ids or {}
end

local function build_archive_snapshot(data)
    local map={}
    local groups={updated_at=os.time(),authoritative=archive_source_present(data),list={},book_groups={}}
    for archive_index,archive in ipairs(archive_entries(data or {})) do
        local group_key,archive_name,stable=archive_identity(archive,archive_index)
        local member_count=0
        for item_index,item in ipairs(archive_ids(archive)) do
            local id=type(item)=="table" and (item.bookId or item.book_id or item.id) or item
            id=tostring(id or "")
            if id~="" then
                member_count=member_count+1
                local current=map[id]
                if not current then
                    current={archiveIndex=archive_index,archiveItemOrder=item_index,archiveName=archive_name,
                        archiveNames={},archiveKeys={}}
                    map[id]=current
                end
                current.archiveNames[#current.archiveNames+1]=archive_name
                current.archiveKeys[#current.archiveKeys+1]=group_key
                local relation=groups.book_groups[id]
                if not relation then relation={names={},keys={}}; groups.book_groups[id]=relation end
                relation.names[#relation.names+1]=archive_name
                relation.keys[#relation.keys+1]=group_key
            end
        end
        groups.list[#groups.list+1]={key=group_key,name=archive_name,stable=stable,member_count=member_count}
    end
    for _,row in pairs(map) do row.archiveNamesText=table.concat(row.archiveNames,"、") end
    return map,groups
end

local function book(row,raw_index,archive_map)
    row=type(row)=="table" and row or {}
    local b=type(row.bookInfo)=="table" and row.bookInfo or (type(row.book)=="table" and row.book or row)
    local id=tostring(b.bookId or row.bookId or b.book_id or row.book_id or "")
    local archive=archive_map and archive_map[id] or nil
    local top_value=row.isTop
    if top_value==nil then top_value=b.isTop end
    local explicit_order=first_number(
        row.shelfOrder,row.shelfIndex,row.bookOrder,row.sortOrder,row.displayOrder,
        b.shelfOrder,b.shelfIndex,b.bookOrder,b.sortOrder,b.displayOrder
    )
    return {
        bookId=id,
        title=b.title or row.title or "未命名",
        author=b.author or row.author or "",
        cover=b.cover or b.coverUrl or row.cover,
        category=b.category or row.category,
        description=b.intro or b.description or b.summary or row.intro or row.description or row.summary,
        publisher=b.publisher or row.publisher,
        version=tonumber(b.version or b.bookVersion or b.book_version
            or row.version or row.bookVersion or row.book_version),
        updateTime=tonumber(row.updateTime or b.updateTime or row.bookUpdateTime or 0) or 0,
        progress=tonumber(row.progress or row.readingProgress or b.progress or 0) or 0,
        finished=(row.finished==true or tonumber(row.progress or row.readingProgress or 0)>=100),
        isTop=truthy(top_value),
        rawIndex=tonumber(raw_index) or 0,
        explicitOrder=explicit_order,
        cloudOrder=tonumber(row.cloudOrder or row.cloud_order),
        readUpdateTime=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        cloudUpdatedAt=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        archiveIndex=archive and archive.archiveIndex or nil,
        archiveItemOrder=archive and archive.archiveItemOrder or nil,
        archiveName=archive and archive.archiveName or nil,
        archiveNames=archive and archive.archiveNamesText or nil,
        archiveNamesList=archive and U.copy(archive.archiveNames) or {},
        archiveKeys=archive and U.copy(archive.archiveKeys) or {},
        inArchive=archive~=nil,
    }
end

local function official_shelf_less(a,b)
    if a.isTop~=b.isTop then return a.isTop==true end
    local ar,br=tonumber(a.readUpdateTime or 0) or 0,tonumber(b.readUpdateTime or 0) or 0
    if ar>0 and br>0 and ar~=br then return ar>br end
    local ao,bo=tonumber(a.explicitOrder),tonumber(b.explicitOrder)
    if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
    local ai,bi=tonumber(a.rawIndex) or 1000000000,tonumber(b.rawIndex) or 1000000000
    if ai~=bi then return ai<bi end
    return tostring(a.bookId or "")<tostring(b.bookId or "")
end

local function shelf_order_plan(rows)
    local count=#(rows or {})
    local read_fields,explicit_fields,top_count=0,0,0
    for _,row in ipairs(rows or {}) do
        if (tonumber(row.readUpdateTime or 0) or 0)>0 then read_fields=read_fields+1 end
        if tonumber(row.explicitOrder)~=nil then explicit_fields=explicit_fields+1 end
        if row.isTop==true then top_count=top_count+1 end
    end
    local threshold=math.max(2,math.ceil(count*0.60))
    local mode="api"
    if count>=2 and read_fields>=threshold then mode="read_time"
    elseif count>=2 and explicit_fields>=threshold then mode="explicit" end
    return {mode=mode,count=count,read_fields=read_fields,explicit_fields=explicit_fields,top_count=top_count}
end

local function planned_shelf_less(mode,a,b)
    if a.isTop~=b.isTop then return a.isTop==true end
    if mode=="read_time" then
        local ar,br=tonumber(a.readUpdateTime or 0) or 0,tonumber(b.readUpdateTime or 0) or 0
        if (ar>0)~=(br>0) then return ar>0 end
        if ar~=br then return ar>br end
    elseif mode=="explicit" then
        local ao,bo=tonumber(a.explicitOrder),tonumber(b.explicitOrder)
        if (ao~=nil)~=(bo~=nil) then return ao~=nil end
        if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
    end
    local ai,bi=tonumber(a.rawIndex) or 1000000000,tonumber(b.rawIndex) or 1000000000
    if ai~=bi then return ai<bi end
    return tostring(a.bookId or "")<tostring(b.bookId or "")
end

local function order_cloud_rows(rows)
    rows=rows or {}
    local plan=shelf_order_plan(rows)
    table.sort(rows,function(a,b) return planned_shelf_less(plan.mode,a,b) end)
    for index,row in ipairs(rows) do
        row.cloudOrder=index
        row.shelfOrderMode=plan.mode
    end
    logger.info("[MiuRead][ShelfOrder] resolved",
        "mode=",plan.mode,"count=",tostring(plan.count),
        "read_fields=",tostring(plan.read_fields),
        "explicit_fields=",tostring(plan.explicit_fields),
        "top=",tostring(plan.top_count))
    return rows
end

local function table_keys_sorted(t)
    local out={}
    for key,value in pairs(type(t)=="table" and t or {}) do
        if value==true then out[#out+1]=tostring(key) end
    end
    table.sort(out)
    return out
end

local function current_filter(store)
    local prefs=store and store.preferences and store:preferences() or {}
    local filter=type(prefs.shelf_filter)=="table" and prefs.shelf_filter or {}
    return {
        enabled=filter.enabled==true,
        archives=type(filter.archives)=="table" and filter.archives or {},
        archive_keys=type(filter.archive_keys)=="table" and filter.archive_keys or {},
    },prefs
end

local function filter_fingerprint(filter)
    if filter.enabled~=true then return "all" end
    return "selected|"..table.concat(table_keys_sorted(filter.archive_keys),",").."|"..table.concat(table_keys_sorted(filter.archives),",")
end

local function row_group_names(row)
    local out={}
    if type(row.archiveNamesList)=="table" then
        for _,name in ipairs(row.archiveNamesList) do if tostring(name or "")~="" then out[#out+1]=tostring(name) end end
    elseif tostring(row.archiveNames or "")~="" then
        for name in tostring(row.archiveNames):gmatch("[^、]+") do if name~="" then out[#out+1]=name end end
    elseif tostring(row.archiveName or "")~="" then out[#out+1]=tostring(row.archiveName) end
    return out
end

local function row_group_keys(row)
    local out={}
    if type(row.archiveKeys)=="table" then for _,key in ipairs(row.archiveKeys) do if tostring(key or "")~="" then out[#out+1]=tostring(key) end end end
    return out
end

local function row_allowed(filter,row)
    if filter.enabled~=true then return true end
    for _,key in ipairs(row_group_keys(row)) do if filter.archive_keys[key]==true then return true end end
    for _,name in ipairs(row_group_names(row)) do if filter.archives[name]==true then return true end end
    return false
end

local function apply_filter(filter,rows)
    if filter.enabled~=true then return U.copy(rows or {}),0 end
    local out,filtered={},0
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        if row_allowed(filter,row) then out[#out+1]=U.copy(row) else filtered=filtered+1 end
    end
    return out,filtered
end

local function group_member_sets(groups)
    groups=type(groups)=="table" and groups or {}
    local by_key={}
    for _,group in ipairs(type(groups.list)=="table" and groups.list or {}) do
        by_key[tostring(group.key or "")]={}
    end
    for book_id,relation in pairs(type(groups.book_groups)=="table" and groups.book_groups or {}) do
        relation=type(relation)=="table" and relation or {}
        for _,key in ipairs(type(relation.keys)=="table" and relation.keys or {}) do
            key=tostring(key or "")
            if key~="" then
                by_key[key]=by_key[key] or {}
                by_key[key][tostring(book_id)]=true
            end
        end
        -- Legacy/name-only snapshots may not carry keys. Reconstruct them
        -- conservatively from the display name.
        for _,name in ipairs(type(relation.names)=="table" and relation.names or {}) do
            name=tostring(name or "")
            local key="name:"..name
            if name~="" and by_key[key]~=nil then by_key[key][tostring(book_id)]=true end
        end
    end
    return by_key
end

local function set_similarity(a,b)
    a=type(a)=="table" and a or {}; b=type(b)=="table" and b or {}
    local intersection,union=0,0
    local seen={}
    for id in pairs(a) do
        seen[id]=true; union=union+1
        if b[id] then intersection=intersection+1 end
    end
    for id in pairs(b) do if not seen[id] then union=union+1 end end
    if union==0 then return 0,intersection,union end
    return intersection/union,intersection,union
end

function Library:_reconcile_group_preferences(groups)
    groups=type(groups)=="table" and groups or {}
    if groups.authoritative~=true or not self.store then return false end
    local filter,prefs=current_filter(self.store)
    prefs.shelf_filter=type(prefs.shelf_filter)=="table" and prefs.shelf_filter or {}
    prefs.shelf_filter.archives=type(prefs.shelf_filter.archives)=="table" and prefs.shelf_filter.archives or {}
    prefs.shelf_filter.archive_keys=type(prefs.shelf_filter.archive_keys)=="table" and prefs.shelf_filter.archive_keys or {}
    local by_name,by_key={},{}
    for _,group in ipairs(groups.list or {}) do
        by_name[tostring(group.name or "")]=group
        by_key[tostring(group.key or "")]=group
    end
    local new_names,new_keys={},{}
    if filter.enabled==true then
        -- Stable keys survive a rename directly. Name-only groups are migrated
        -- only when one disappeared selected group has exactly one highly
        -- overlapping new candidate; ambiguous cases remain fail-closed.
        for key,value in pairs(filter.archive_keys) do
            if value==true and by_key[tostring(key)] then
                local group=by_key[tostring(key)]
                new_keys[tostring(group.key)]=true
                new_names[tostring(group.name)]=true
            end
        end
        local unresolved={}
        for name,value in pairs(filter.archives) do
            if value==true and by_name[tostring(name)] then
                local group=by_name[tostring(name)]
                new_names[tostring(group.name)]=true
                new_keys[tostring(group.key)]=true
            elseif value==true then
                unresolved[#unresolved+1]=tostring(name)
            end
        end

        if #unresolved>0 then
            local previous_cache=self.store:shelf_cache()
            local previous=type(previous_cache.groups)=="table" and previous_cache.groups or {}
            local old_by_name={}
            for _,group in ipairs(type(previous.list)=="table" and previous.list or {}) do
                old_by_name[tostring(group.name or "")]=group
            end
            local old_members,new_members=group_member_sets(previous),group_member_sets(groups)
            local claimed={}
            for _,old_name in ipairs(unresolved) do
                local old_group=old_by_name[old_name]
                -- Stable IDs that disappeared are deletions, not rename guesses.
                if old_group and old_group.stable~=true then
                    local old_key=tostring(old_group.key or ("name:"..old_name))
                    local candidates={}
                    for _,candidate in ipairs(groups.list or {}) do
                        local candidate_key=tostring(candidate.key or "")
                        local candidate_name=tostring(candidate.name or "")
                        if candidate.stable~=true and not claimed[candidate_key]
                            and not old_by_name[candidate_name] then
                            local score,common=set_similarity(old_members[old_key],new_members[candidate_key])
                            if common>=2 and score>=0.80 then
                                candidates[#candidates+1]={group=candidate,score=score}
                            end
                        end
                    end
                    table.sort(candidates,function(a,b) return a.score>b.score end)
                    if #candidates==1 or (#candidates>1 and candidates[1].score>candidates[2].score+0.10) then
                        local chosen=candidates[1] and candidates[1].group or nil
                        if chosen then
                            local chosen_key,chosen_name=tostring(chosen.key or ""),tostring(chosen.name or "")
                            claimed[chosen_key]=true
                            new_keys[chosen_key]=true
                            new_names[chosen_name]=true
                            logger.info("[MiuRead][ShelfGroups] conservative rename inferred",
                                "from=",old_name,"to=",chosen_name,"score=",string.format("%.2f",candidates[1].score))
                        end
                    end
                end
            end
        end
    end
    local changed=filter_fingerprint(filter)~=filter_fingerprint{enabled=filter.enabled,archives=new_names,archive_keys=new_keys}
    if changed then
        prefs.shelf_filter.archives=new_names
        prefs.shelf_filter.archive_keys=new_keys
        self.store:save_preferences(prefs)
        logger.info("[MiuRead][ShelfGroups] selection reconciled",
            "enabled=",tostring(filter.enabled==true),"groups=",tostring(#table_keys_sorted(new_names)))
    end
    return changed
end

function Library:_normalize_full(data)
    data=type(data)=="table" and data or {}
    local books,mp={},{}
    local seen_books,seen_mp={},{}
    local archive_map,groups=build_archive_snapshot(data)
    local src=data.books or data.bookList or data.updated or {}
    if type(src)~="table" then src={} end
    local raw_index=0
    for _,r in ipairs(src) do
        raw_index=raw_index+1
        local b=book(r,raw_index,archive_map)
        if b.bookId~="" then
            if Protocol.is_mp_account(b.bookId) then
                if not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            elseif not Protocol.is_mp(b.bookId) and not seen_books[b.bookId] then
                books[#books+1]=b; seen_books[b.bookId]=true
            end
        end
    end
    for _,x in ipairs({data.mp,data.mpBook,data.officialAccounts}) do
        if type(x)=="table" then
            local rows=x[1] and x or {x}
            for _,r in ipairs(rows) do
                raw_index=raw_index+1
                local b=book(r,raw_index,archive_map)
                if Protocol.is_mp_account(b.bookId) and not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            end
        end
    end
    order_cloud_rows(books); order_cloud_rows(mp)
    return books,mp,groups
end

function Library:normalize(data)
    local raw_books,mp,groups=self:_normalize_full(data)
    self:_reconcile_group_preferences(groups)
    local filter=current_filter(self.store)
    local books,filtered=apply_filter(filter,raw_books)
    if filter.enabled==true then
        self.last_shelf_filter={kept=#books,filtered=filtered}
        logger.info("[MiuRead][ShelfFilter] applied","kept=",tostring(#books),"filtered=",tostring(filtered))
    else self.last_shelf_filter=nil end
    return books,mp
end

local function fallback_groups(cache,store)
    local list,seen,book_groups={}, {}, {}
    local function add_group(name,key)
        name=U.trim(tostring(name or "")); if name=="" then return end
        key=tostring(key or ("name:"..name))
        if not seen[key] then seen[key]=true; list[#list+1]={key=key,name=name,stable=key:sub(1,3)=="id:",member_count=0} end
    end
    for _,name in ipairs(store and store.get and store:get("shelf_archive_names",{}) or {}) do add_group(name) end
    for _,row in ipairs(type(cache.raw_books)=="table" and cache.raw_books or (cache.books or {})) do
        local id=tostring(row.bookId or row.book_id or "")
        local names,keys=row_group_names(row),row_group_keys(row)
        if id~="" and (#names>0 or #keys>0) then book_groups[id]={names=U.copy(names),keys=U.copy(keys)} end
        for i,name in ipairs(names) do add_group(name,keys[i]) end
    end
    table.sort(list,function(a,b) return tostring(a.name)<tostring(b.name) end)
    return {updated_at=tonumber(cache.updated_at) or 0,authoritative=false,list=list,book_groups=book_groups}
end

function Library:group_snapshot()
    local cache=self.store:shelf_cache()
    local groups=type(cache.groups)=="table" and cache.groups or nil
    if groups and type(groups.list)=="table" and (#groups.list>0 or groups.authoritative==true) then return U.copy(groups) end
    return fallback_groups(cache,self.store)
end

local function attach_group_snapshot(rows,groups)
    groups=type(groups)=="table" and groups or {}
    local relations=type(groups.book_groups)=="table" and groups.book_groups or {}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        local id=tostring(row.bookId or row.book_id or "")
        local relation=type(relations[id])=="table" and relations[id] or nil
        if relation then
            row.archiveNamesList=U.copy(type(relation.names)=="table" and relation.names or {})
            row.archiveKeys=U.copy(type(relation.keys)=="table" and relation.keys or {})
            row.archiveName=row.archiveNamesList[1]
            row.archiveNames=#row.archiveNamesList>0 and table.concat(row.archiveNamesList,"、") or nil
            row.inArchive=#row.archiveNamesList>0 or #row.archiveKeys>0
        end
    end
    return rows
end

function Library:_apply_stream_response(data)
    data=type(data)=="table" and data or {}
    local stream=type(data._miuread_stream)=="table" and data._miuread_stream or nil
    -- beta.4 makes Home navigation fully local. A streamed/partial response can
    -- no longer replace the authoritative shelf snapshot; retain the last valid
    -- cache and wait for the next full refresh instead.
    if stream and (stream.keep_cache==true or stream.enabled==true) then
        local books,mp=self:cached()
        logger.info("[MiuRead][ShelfStream] partial response ignored",
            "reason=",tostring(stream.reason or "local_navigation_policy"),
            "books=",tostring(#books),"mp=",tostring(#mp))
        return books,mp,false,true
    end
    local raw_books,mp,groups=self:_normalize_full(data)
    local filter=current_filter(self.store)
    if groups.authoritative~=true then
        local previous_cache=self.store:shelf_cache()
        local previous_groups=type(previous_cache.groups)=="table" and previous_cache.groups or nil
        if filter.enabled==true then
            -- A successful book response without archive metadata is not a
            -- successful group refresh. Keep the last valid scoped snapshot.
            local books,cached_mp=self:cached()
            logger.warn("[MiuRead][ShelfGroups] incomplete group response retained cache",
                "books=",tostring(#books),"mp=",tostring(#cached_mp))
            return books,cached_mp,false,true
        end
        -- Full-account mode may accept fresh book metadata while keeping the
        -- last known group relations for future local selected-group switches.
        if previous_groups and type(previous_groups.list)=="table"
            and (#previous_groups.list>0 or previous_groups.authoritative==true) then
            groups=U.copy(previous_groups)
            attach_group_snapshot(raw_books,groups)
        end
    end
    self:_reconcile_group_preferences(groups)
    filter=current_filter(self.store)
    local books,filtered=apply_filter(filter,raw_books)
    self.last_shelf_filter=filter.enabled==true and {kept=#books,filtered=filtered} or nil
    self.store:save_shelf_cache({
        raw_books=raw_books,raw_mp=U.copy(mp),books=books,mp=mp,groups=groups,updated_at=os.time(),
        effective_scope={mode=filter.enabled and "selected" or "all",fingerprint=filter_fingerprint(filter),updated_at=os.time()},
        stream={enabled=false,ids={},hydrated_ids={},total=#raw_books+#mp,source="full",updated_at=os.time()},
    })
    logger.info("[MiuRead][ShelfGroups] full snapshot saved",
        "raw=",tostring(#raw_books),"effective=",tostring(#books),"groups=",tostring(#(groups.list or {})),
        "authoritative=",tostring(groups.authoritative==true))
    return books,mp,false,false
end

function Library:merge_stream_batch(data,requested_ids)
    logger.info("[MiuRead][ShelfStream] page hydration disabled","requested=",tostring(#(requested_ids or {})))
    return false
end

function Library:stream_missing(first,last) return {} end

function Library:refresh(options)
    options=options or {}
    local data=self.api:shelf(options)
    local books,mp=self:_apply_stream_response(data)
    return books,mp
end

function Library:cached()
    local c=self.store:shelf_cache()
    local filter=current_filter(self.store)
    if filter.enabled~=true then
        local rows=type(c.raw_books)=="table" and #c.raw_books>0 and c.raw_books or (c.books or {})
        local clean={}
        for _,row in ipairs(rows) do if type(row)=="table" and row._stream_placeholder~=true then clean[#clean+1]=row end end
        return clean,c.mp or c.raw_mp or {},c.updated_at
    end
    local raw=type(c.raw_books)=="table" and #c.raw_books>0 and c.raw_books or nil
    if raw then
        local rows=apply_filter(filter,raw)
        return rows,c.mp or c.raw_mp or {},c.updated_at
    end
    local scope=type(c.effective_scope)=="table" and c.effective_scope or {}
    if tostring(scope.fingerprint or "")==filter_fingerprint(filter) then return c.books or {},c.mp or {},c.updated_at end
    -- Legacy cache with unknown scope: only rows whose group membership can be
    -- proven are allowed through. Failing closed prevents an upgrade/offline
    -- path from expanding a selected shelf to the entire account.
    local rows=apply_filter(filter,c.books or {})
    return rows,c.mp or {},c.updated_at
end
function Library:rebuild_effective_cache()
    local cache=self.store:shelf_cache()
    local filter=current_filter(self.store)
    local source=(type(cache.raw_books)=="table" and #cache.raw_books>0) and cache.raw_books or (cache.books or {})
    local books=apply_filter(filter,source)
    cache.books=books
    cache.effective_scope={mode=filter.enabled and "selected" or "all",fingerprint=filter_fingerprint(filter),updated_at=os.time()}
    self.store:save_shelf_cache(cache)
    logger.info("[MiuRead][ShelfFilter] effective cache rebuilt","books=",tostring(#books),"mode=",filter.enabled and "selected" or "all")
    return books
end

function Library:cached_stream() return {enabled=false,ids={},hydrated_ids={},total=0,source="disabled_beta4"} end

local function record_state(row)
    local downloaded=false
    local partial_downloaded=false
    local has_record=false
    local latest_download=0
    local filenames={}
    local total_size=0
    local has_clean=false
    local has_notes=false
    local annotation_pending=false
    local annotation_fallback=false
    local content_type=nil
    local function scan(record,kind,is_final)
        if type(record)~="table" then return end
        local file=tostring(record.file or "")
        if file~="" then
            has_record=true
            latest_download=math.max(latest_download,tonumber(record.downloaded_at or 0) or 0)
            filenames[#filenames+1]=file:match("([^/]+)$") or file
            if U.file_exists(file) then
                if is_final then
                    downloaded=true
                    total_size=total_size+(tonumber(U.file_size(file)) or 0)
                    content_type=record.content_type or content_type
                    if kind=="clean" or kind=="range_clean" or kind=="preview_clean" then has_clean=true end
                    if kind=="notes" or kind=="range_notes" or kind=="preview_notes" then
                        has_notes=true
                        if DownloadResult.annotation_pending(record) then annotation_pending=true end
                        if record.annotation_fallback==true then annotation_fallback=true end
                    end
                else
                    partial_downloaded=true
                end
            end
        end
    end
    for kind,record in pairs((row and row.variants) or {}) do scan(record,tostring(kind),true) end
    for _,chapter in pairs((row and row.chapters) or {}) do
        for kind,record in pairs(chapter or {}) do scan(record,tostring(kind),false) end
    end
    return {
        has_record=has_record,
        downloaded=downloaded,
        partial_downloaded=partial_downloaded,
        file_missing=has_record and not downloaded and not partial_downloaded,
        downloaded_at=latest_download,
        filenames=table.concat(filenames," "),
        file_size=total_size,
        has_clean=has_clean,
        has_notes=has_notes,
        annotation_pending=annotation_pending,
        annotation_fallback=annotation_fallback,
        content_type=content_type,
    }
end

local function local_progress(session,row)
    session=type(session)=="table" and session or {}
    local pending=type(session.pending)=="table" and session.pending or {}
    return tonumber(pending.percent or session.progress_local_percent or session.verified_local_percent or row.progress or 0) or 0
end

function Library:is_downloaded(id, library_snapshot)
    local source=library_snapshot or self.store:library()
    local b=source and source[tostring(id)]
    return b and record_state(b).downloaded or false
end

local function local_book_from_row(id,row,session)
    if type(row)~="table" then return nil end
    local state=record_state(row)
    if not state.downloaded then return nil end
    session=type(session)=="table" and session or {}
    local b={
        bookId=tostring(row.book_id or id or ""),
        title=row.title or "未命名",
        author=row.author or "",
        cover=row.cover,
        category=row.category,
        updateTime=tonumber(row.updated_at or row.downloaded_at or 0) or 0,
        progress=local_progress(session,row),
        local_only=true,
        downloaded=true,
        file_missing=false,
        downloadedAt=state.downloaded_at,
        lastReadTime=tonumber(session.last_read_at or 0) or 0,
        filename_search=state.filenames,
        fileSize=state.file_size,
        hasClean=state.has_clean,
        hasNotes=state.has_notes,
        annotation_pending=state.annotation_pending,
        annotation_fallback=state.annotation_fallback,
        access=U.copy(row.access or {}),
        content_type=state.content_type or row.content_type,
        local_record=row,
    }
    return b.bookId~="" and b or nil
end

function Library:local_book(id,library_snapshot,sessions_snapshot)
    id=tostring(id or "")
    if id=="" then return nil end
    local source=library_snapshot or self.store:library()
    local row=source and source[id] or nil
    if type(row)~="table" then return nil end
    local sessions=sessions_snapshot or self.store:get("sessions",{})
    return local_book_from_row(id,row,sessions[id] or {})
end

function Library:local_books(library_snapshot,sessions_snapshot)
    local source=library_snapshot or self.store:library()
    local sessions=sessions_snapshot or self.store:get("sessions",{})
    local books,mp={},{}
    for id,row in pairs(source or {}) do
        local b=local_book_from_row(id,row,sessions[tostring(id)] or {})
        if b then
            if Protocol.is_mp_account(b.bookId) then
                mp[#mp+1]=b
            elseif not Protocol.is_mp(b.bookId) then
                books[#books+1]=b
            end
        end
    end
    return books,mp
end

local function local_index(local_rows)
    local index={}
    for _,row in ipairs(local_rows or {}) do
        local id=tostring(row.bookId or row.book_id or "")
        if id~="" then index[id]=row end
    end
    return index
end

local function merge_local_metadata(remote,local_book)
    remote.title=remote.title or local_book.title
    remote.author=remote.author or local_book.author
    remote.cover=remote.cover or local_book.cover
    remote.downloaded=local_book.downloaded==true
    remote.file_missing=local_book.file_missing==true
    remote.downloadedAt=tonumber(local_book.downloadedAt or 0) or 0
    remote.lastReadTime=tonumber(local_book.lastReadTime or 0) or 0
    remote.filename_search=local_book.filename_search
    remote.fileSize=tonumber(local_book.fileSize or 0) or 0
    remote.hasClean=local_book.hasClean==true
    remote.hasNotes=local_book.hasNotes==true
    remote.annotation_pending=local_book.annotation_pending==true
    remote.annotation_fallback=local_book.annotation_fallback==true
    remote.access=U.copy(local_book.access or {})
    remote.content_type=remote.content_type or local_book.content_type
    remote.local_record=local_book.local_record
    if (tonumber(remote.progress or 0) or 0)<=0 then remote.progress=local_book.progress end
    return remote
end

function Library:account_row(remote,local_book)
    if type(remote)~="table" then return nil end
    local b=U.copy(remote)
    local id=tostring(b.bookId or b.book_id or "")
    if id=="" then return nil end
    b.bookId=id
    b.local_only=false
    b.in_account_shelf=true
    b.remote_status_known=true
    if local_book then merge_local_metadata(b,local_book) else b.downloaded=false end
    return b
end

function Library:account_rows(remote_rows,local_rows)
    local local_by_id=local_index(local_rows)
    local out={}
    for _,remote in ipairs(remote_rows or {}) do
        local id=tostring(type(remote)=="table" and (remote.bookId or remote.book_id) or "")
        local b=self:account_row(remote,local_by_id[id])
        if b then out[#out+1]=b end
    end
    return out
end

function Library:generated_rows(remote_books,remote_mp,local_books,local_mp,remote_status_known)
    local remote_index={}
    for _,row in ipairs(remote_books or {}) do remote_index[tostring(row.bookId or "")]=row end
    for _,row in ipairs(remote_mp or {}) do remote_index[tostring(row.bookId or "")]=row end
    local out={}
    local function append(local_rows)
        for _,local_book in ipairs(local_rows or {}) do
            local b=U.copy(local_book)
            local id=tostring(b.bookId or "")
            local remote=remote_index[id]
            b.remote_status_known=remote_status_known==true
            b.in_account_shelf=remote~=nil
            b.local_only=remote==nil
            if remote then
                b.isTop=remote.isTop==true
                b.archiveName=remote.archiveName
                b.archiveNames=remote.archiveNames
                b.inArchive=remote.inArchive==true
                b.cloudOrder=remote.cloudOrder
                if (tonumber(b.progress or 0) or 0)<=0 then b.progress=remote.progress end
            end
            out[#out+1]=b
        end
    end
    append(local_books)
    append(local_mp)
    return out
end

-- Kept for older call sites and saved data. New shelf pages use account_rows and
-- generated_rows so cloud-only and generated files are never silently mixed.
function Library:merge_books(remote_rows,local_rows)
    local out=self:account_rows(remote_rows,local_rows)
    local seen={}
    for _,row in ipairs(out) do seen[tostring(row.bookId)]=true end
    for _,local_book in ipairs(local_rows or {}) do
        local id=tostring(local_book.bookId or "")
        if id~="" and not seen[id] then
            local copy=U.copy(local_book)
            copy.cloudOrder=copy.cloudOrder or (1000000+#out+1)
            out[#out+1]=copy
        end
    end
    return out
end

function Library:combined(remote_books,remote_mp,library_snapshot,sessions_snapshot)
    local local_books,local_mp=self:local_books(library_snapshot,sessions_snapshot)
    return self:merge_books(remote_books,local_books),self:merge_books(remote_mp,local_mp)
end

local function shelf_rows_fingerprint(rows,section)
    local parts={tostring(section or ""), tostring(#(rows or {}))}
    for index,row in ipairs(rows or {}) do
        parts[#parts+1]=table.concat({
            tostring(index), tostring(row.bookId or row.file or row.title or ""),
            tostring(row.title or ""), tostring(row.author or ""),
            tostring(row.file or ""), tostring(row.cover_path or row.cover or ""),
            tostring(row.cloudOrder or ""), tostring(row.readUpdateTime or ""),
            tostring(row.explicitOrder or ""), tostring(row.rawIndex or ""),
            tostring(row.downloadedAt or row.downloaded_at or ""),
            tostring(row.progress or ""), tostring(row.status_text or row.download_status or ""),
            row.isTop==true and "1" or "0",
            row.in_account_shelf==true and "1" or "0",
            row.generated==true and "1" or "0",
            row.downloaded==true and "1" or "0",
        },":")
    end
    return table.concat(parts,"|")
end

function Library:sort_filter(rows,options)
    options=options or {}
    local section=tostring(options.section or "account")
    self._sort_cache=type(self._sort_cache)=="table" and self._sort_cache or {}
    local fingerprint=shelf_rows_fingerprint(rows,section)
    local cached=self._sort_cache[section]
    if cached and cached.fingerprint==fingerprint and type(cached.rows)=="table" then
        return U.copy(cached.rows)
    end
    local out=U.copy(rows or {})
    if section=="account" then
        -- normalize() already selected the best available server ordering.
        -- Preserve that decision instead of guessing again when fields are
        -- missing on most rows.
        table.sort(out,function(a,b)
            local ao,bo=tonumber(a.cloudOrder),tonumber(b.cloudOrder)
            if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
            return official_shelf_less(a,b)
        end)
    elseif section=="generated" then
        table.sort(out,function(a,b)
            local ai=a.in_account_shelf==true
            local bi=b.in_account_shelf==true
            if ai~=bi then return ai end
            if ai then
                local ao=tonumber(a.cloudOrder) or 1000000000
                local bo=tonumber(b.cloudOrder) or 1000000000
                if ao~=bo then return ao<bo end
                return official_shelf_less(a,b)
            else
                local ad=tonumber(a.downloadedAt or 0) or 0
                local bd=tonumber(b.downloadedAt or 0) or 0
                if ad~=bd then return ad>bd end
            end
            return tostring(a.bookId or "")<tostring(b.bookId or "")
        end)
    end
    self._sort_cache[section]={fingerprint=fingerprint,rows=U.copy(out)}
    logger.info("[MiuRead][ShelfOrder] prepared","count=",tostring(#out),"section=",section)
    return out
end

local function searchable(value)
    return U.trim(tostring(value or "")):lower():gsub("%s+"," ")
end

function Library:search(rows,query)
    local q=searchable(query)
    if q=="" then return U.copy(rows or {}) end
    local terms={}
    for term in q:gmatch("%S+") do terms[#terms+1]=term end
    local out={}
    for _,b in ipairs(rows or {}) do
        local hay=searchable(table.concat({b.title or "",b.author or "",b.filename_search or ""}," "))
        local pass=true
        for _,term in ipairs(terms) do
            if not hay:find(term,1,true) then pass=false; break end
        end
        if pass then out[#out+1]=b end
    end
    return out
end

local function cover_header(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read(1024) or ""
    f:close()
    return data
end

function Library:_valid_cover_path(path)
    path=tostring(path or "")
    if path=="" or not U.file_exists(path) then return false,"missing" end
    local size=tonumber(U.file_size(path) or 0) or 0
    if size<=0 then return false,"empty" end
    if size>COVER_MAX_BYTES then return false,"too_large" end
    local ext=select(1,Codec.media(cover_header(path) or ""))
    if not COVER_EXTENSIONS[ext] then return false,"unsupported" end
    return true,nil,size,ext
end

function Library:cached_cover_path(id,cover_index)
    local own_index=cover_index==nil
    local index=cover_index or self.store:get("cover_index",{})
    local key=tostring(id)
    local path=index[key]
    if not path then return nil,false end
    local valid,reason=self:_valid_cover_path(path)
    if valid then return path,false end
    logger.warn("[MiuRead][Cover] removed invalid cache","book_id=",key,"reason=",tostring(reason),"path=",tostring(path))
    os.remove(path)
    index[key]=nil
    if own_index then self.store:set("cover_index",index) end
    return nil,true
end

function Library:cache_cover(b,options)
    if not b or not b.cover or b.cover=="" then return nil end
    options=options or {}
    local persist_index=options.persist_index~=false
    local index={}
    if options.skip_index_lookup~=true then
        index=self.store:get("cover_index",{})
        local cached,removed=self:cached_cover_path(b.bookId,index)
        if cached then return cached end
        if removed and persist_index then self.store:set("cover_index",index) end
    end
    local download_url=cover_download_url(b.cover)
    local data=self.http:download(download_url,{
        auth=false,
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {8,15},
    })
    if not data or #data==0 then return nil end
    if #data>COVER_MAX_BYTES then
        logger.warn("[MiuRead][Cover] skipped oversized image","book_id=",tostring(b.bookId),"bytes=",tostring(#data))
        return nil
    end
    local ext,mime=Codec.media(data)
    if not COVER_EXTENSIONS[ext] then
        logger.warn("[MiuRead][Cover] skipped unsupported response","book_id=",tostring(b.bookId),"type=",tostring(mime),"bytes=",tostring(#data))
        return nil
    end

    local base=self.store.covers_dir.."/"..U.id_name(b.bookId)
    local suffix=tostring(options.cache_suffix or ""):gsub("[^%w_%-]","")
    if suffix~="" then base=base.."-"..suffix end
    local path=base..ext
    local written,write_error=U.atomic_write(path,data,true)
    if not written then error("cover write failed: "..tostring(write_error or "unknown")) end
    local valid,reason=self:_valid_cover_path(path)
    if not valid then
        os.remove(path)
        logger.warn("[MiuRead][Cover] downloaded image failed validation","book_id=",tostring(b.bookId),"reason=",tostring(reason))
        return nil
    end
    for old_ext in pairs(COVER_EXTENSIONS) do
        local old=base..old_ext
        if old~=path then os.remove(old) end
    end
    index[tostring(b.bookId)]=path
    if persist_index then self.store:set("cover_index",index) end
    logger.info("[MiuRead][Cover] cached","book_id=",tostring(b.bookId),"bytes=",tostring(#data),"type=",tostring(mime))
    return path
end
function Library:clear_covers() U.remove_tree(self.store.covers_dir); U.mkdir(self.store.covers_dir); self.store:set("cover_index",{}) end
function Library:reader_link(url)
    local id=tostring(url or ""):match("/web/reader/([^/?#]+)") or tostring(url or ""):match("bookId=([^&#]+)")
    if not id then return nil end
    if id:match("^%d+$") or Protocol.is_mp_account(id) then return id end
    return nil
end
return Library
