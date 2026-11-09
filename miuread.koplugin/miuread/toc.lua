-- EPUB 3 and NCX navigation from verified WeRead catalog structure.
-- Navigation-only parents and chapter-local anchors never become spine chapters,
-- and therefore cannot change UID, chapterIdx or reading-position mappings.
local M = {}
local MAX_DEPTH = 12
local MAX_ANCHORS_PER_CHAPTER = 64
local MAX_ANCHOR_ID = 128
local READ_CHUNK = 32768

local function level_of(chapter)
    local value = chapter.toc_level or chapter.level or chapter.chapterLevel
        or chapter.chapter_level or chapter.depth
    local level = tonumber(value)
    if not level or level < 0 or level ~= math.floor(level) then return nil end
    return level
end

local function parent_uid_of(chapter)
    local uid = tostring(chapter.toc_parent_uid or chapter.parentChapterUid or chapter.parentUid
        or chapter.parent_chapter_uid or chapter.parentChapterId or chapter.parentId or "")
    return uid ~= "" and uid ~= "0" and uid or nil
end

local function anchor_id(value)
    if type(value) ~= "table" then return nil end
    local fragment = value.fragment or value.anchorId or value.anchor_id or value.id
    if fragment == nil and type(value.href) == "string" then
        fragment = value.href:match("^#(.+)$")
    end
    fragment = tostring(fragment or ""):gsub("^#", "")
    -- Do not interpolate remote offsets, paths, whitespace or special URL
    -- characters as document fragments. Only literal verified XHTML IDs work.
    if #fragment == 0 or #fragment > MAX_ANCHOR_ID
        or not fragment:match("^[%w_%.:%-]+$") then return nil end
    return fragment
end

local function anchor_title(value)
    if type(value) ~= "table" then return nil end
    local title = value.title or value.name or value.label or value.heading
    if type(title) ~= "string" then return nil end
    title = title:match("^%s*(.-)%s*$")
    if title == "" or #title > 240 then return nil end
    return title
end

local function find_existing_ids(chapter, wanted)
    local found = {}
    if next(wanted) == nil then return found end
    local function scan(data)
        -- Scan *tags*, not arbitrary occurrences of 'id=' in chapter prose.
        -- The rolling tail handles an attribute crossing a read boundary.
        for tag in data:gmatch("<[^>]+>") do
            local cursor=1
            -- Consume each complete quoted attribute; this prevents a string
            -- such as title=' id="ghost"' from fabricating a navigation ID.
            while true do
                local first,last,key,quote,value=tag:find("([%w:_%-]+)%s*=%s*(['\"])(.-)%2",cursor)
                if not first then break end
                if (key=="id" or key=="name") and wanted[value] then found[value]=true end
                cursor=last+1
            end
        end
    end
    if type(chapter.body_path) == "string" then
        local file = io.open(chapter.body_path, "rb")
        if not file then return found end
        local rest = ""
        while true do
            local block = file:read(READ_CHUNK)
            if not block then break end
            local data = rest .. block
            -- Retain an unfinished trailing tag, never a whole HTML body.
            local last_open = data:match(".*()<")
            local last_close = data:match(".*()>") or 0
            if last_open and last_open > last_close and #data-last_open <= 2048 then
                scan(data:sub(1,last_open-1))
                rest = data:sub(last_open)
            else
                scan(data)
                rest = ""
            end
        end
        if rest~="" then scan(rest) end
        file:close()
    else
        scan(tostring(chapter.body or ""))
    end
    return found
end

local function verified_anchors(chapter)
    local candidates = type(chapter.toc_anchors) == "table" and chapter.toc_anchors or {}
    local selected, wanted, seen = {}, {}, {}
    for _, value in ipairs(candidates) do
        if #selected >= MAX_ANCHORS_PER_CHAPTER then break end
        local id, title = anchor_id(value), anchor_title(value)
        if id and title and not seen[id] then
            seen[id] = true
            wanted[id] = true
            selected[#selected + 1] = {id=id, title=title}
        end
    end
    if #selected == 0 then return {} end
    local found = find_existing_ids(chapter, wanted)
    local out = {}
    for _, item in ipairs(selected) do
        if found[item.id] then out[#out+1] = item end
    end
    return out
end

local function new_tree(chapters, catalog)
    local root = {children={}}
    local active = {}
    local selected = {}
    for index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.uid or chapter.chapterUid or "")
        if uid ~= "" then selected[uid] = {chapter=chapter,index=index} end
    end
    local emitted = {}
    local function add(node)
        local parent_position = 0
        if node.parent_uid then
            for pos=#active,1,-1 do
                if active[pos].uid == node.parent_uid then parent_position=pos; break end
            end
        end
        if parent_position == 0 and node.level ~= nil then
            for pos=#active,1,-1 do
                if active[pos].level ~= nil and active[pos].level < node.level then
                    parent_position=pos;break
                end
            end
        end
        if parent_position >= MAX_DEPTH then parent_position=MAX_DEPTH-1 end
        local parent=parent_position>0 and active[parent_position] or root
        parent.children[#parent.children+1]=node
        for pos=#active,parent_position+1,-1 do active[pos]=nil end
        active[parent_position+1]=node
    end
    local input = type(catalog)=="table" and #catalog>0 and catalog or chapters
    for _, raw in ipairs(input) do
        if type(raw)=="table" then
            local uid=tostring(raw.uid or raw.chapterUid or "")
            local match=selected[uid]
            local heading = uid=="" or raw.structural_heading==true
            if match or heading then
                local title=match and match.chapter.title or raw.title
                title=tostring(title or "")
                if title~="" then
                    local node={uid=uid,level=level_of(raw),parent_uid=parent_uid_of(raw),
                        title=title,index=match and match.index or nil,children={},
                        anchor_nodes=match and verified_anchors(match.chapter) or {},
                        structural_heading=heading}
                    add(node)
                    if match then emitted[match.index]=true end
                end
            else
                -- Preserve ancestry for selected descendants even when a
                -- catalog parent is outside a partial download's spine.
                local node={uid=uid,level=level_of(raw),parent_uid=parent_uid_of(raw),
                    title=tostring(raw.title or ""),children={},structural_heading=false}
                add(node)
            end
        end
    end
    -- e.g. a preview information page, absent from WeRead catalog.
    for index,chapter in ipairs(chapters or {}) do
        if not emitted[index] then
            active={}
            local node={uid=tostring(chapter.uid or ""),title=tostring(chapter.title or "Chapter "..index),
                level=nil,index=index,children={},anchor_nodes=verified_anchors(chapter)}
            add(node)
        end
    end
    return root.children
end

local function prune(nodes)
    local out={}
    for _,node in ipairs(nodes or {}) do
        node.children=prune(node.children)
        if node.index then
            out[#out+1]=node
        elseif #node.children>0 and node.title~="" and node.structural_heading then
            -- A heading has no own XHTML; link to the first included descendant.
            local first=node.children[1]
            while first and not first.index do first=first.children[1] end
            if first then node.index=first.index;out[#out+1]=node end
        else
            -- No downloadable body / no reliable navigation heading: flatten.
            for _,child in ipairs(node.children) do out[#out+1]=child end
        end
    end
    return out
end

local function render(nodes,escape,nav,ncx,state,depth)
    for _,node in ipairs(nodes) do
        local href=string.format("text/chapter-%04d.xhtml",node.index)
        local title=escape(node.title)
        state.count=state.count+1
        local id="n"..state.count
        local order=state.count
        nav[#nav+1]='<li><a href="'..href..'">'..title..'</a>'
        ncx[#ncx+1]='<navPoint id="'..id..'" playOrder="'..order
            ..'"><navLabel><text>'..title..'</text></navLabel><content src="'..href..'"/>'
        local subnav,subncx={},{}
        -- Anchors belong to the current XHTML, before later spine chapters.
        for _,a in ipairs(node.anchor_nodes or {}) do
            local child_href=href.."#"..a.id
            local label=escape(a.title)
            state.count=state.count+1
            local child_id="n"..state.count
            subnav[#subnav+1]='<li><a href="'..child_href..'">'..label..'</a></li>'
            subncx[#subncx+1]='<navPoint id="'..child_id..'" playOrder="'..state.count
                ..'"><navLabel><text>'..label..'</text></navLabel><content src="'..child_href..'"/></navPoint>'
            state.depth=math.max(state.depth,depth+1)
        end
        render(node.children,escape,subnav,subncx,state,depth+1)
        if #subnav>0 then
            nav[#nav+1]='<ol>'..table.concat(subnav)..'</ol>'
            ncx[#ncx+1]=table.concat(subncx)
            state.depth=math.max(state.depth,depth+1)
        end
        nav[#nav+1]='</li>'
        ncx[#ncx+1]='</navPoint>'
        state.depth=math.max(state.depth,depth)
    end
end

function M.build(chapters,escape,catalog)
    chapters=type(chapters)=="table" and chapters or {}
    escape=type(escape)=="function" and escape or tostring
    local roots=prune(new_tree(chapters,catalog))
    local nav,ncx={},{}
    local state={count=0,depth=0}
    render(roots,escape,nav,ncx,state,1)
    return table.concat(nav),table.concat(ncx),math.max(1,state.depth)
end

return M
