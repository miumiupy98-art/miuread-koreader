local U = require("miuread.util")

local R = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function strip_quotes(value)
    local out = trim(value)
    local first, last = out:sub(1, 1), out:sub(-1)
    if #out >= 2 and ((first == "'" and last == "'") or (first == '"' and last == '"')) then
        out = trim(out:sub(2, -2))
    end
    return out
end

local function decode_entities(value)
    return tostring(value or "")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&#39;", "'")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
end

local function url_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function normalize_path(path)
    path = url_decode(decode_entities(path)):gsub("\\", "/")
    path = path:gsub("[?#].*$", "")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]*$") or ""
end

function R.resolve(base_file, reference)
    local ref = strip_quotes(reference)
    local lower = ref:lower()
    if ref == "" or ref:sub(1, 1) == "#" then return nil, "ignored" end
    if lower:match("^data:") then return nil, "embedded" end
    if lower:match("^javascript:") then return nil, "ignored" end
    if lower:match("^https?://") or ref:match("^//") then return nil, "external" end
    if ref:sub(1, 1) == "/" then return normalize_path(ref:sub(2)), "local" end
    return normalize_path(dirname(base_file) .. "/" .. ref), "local"
end

function R.looks_like_image(reference)
    local ref = strip_quotes(reference):lower():gsub("[?#].*$", "")
    if ref:match("%.jpe?g$") or ref:match("%.png$") or ref:match("%.gif$")
        or ref:match("%.webp$") or ref:match("%.svg$") or ref:match("%.avif$")
        or ref:match("%.bmp$") then return true end
    return false
end

local function add_reference(out, reference, kind)
    local value = trim(reference)
    if value ~= "" then out[#out + 1] = {value=value, kind=kind or "image"} end
end

local function collect_srcset(out, value, kind)
    for item in tostring(value or ""):gmatch("[^,]+") do
        add_reference(out, item:match("^%s*([^%s]+)"), kind)
    end
end

local function collect_css_urls(out, text)
    text = tostring(text or "")
    for ref in text:gmatch('[uU][rR][lL]%s*%(%s*"([^"]+)"%s*%)') do add_reference(out, ref, "css") end
    for ref in text:gmatch("[uU][rR][lL]%s*%(%s*'([^']+)'%s*%)") do add_reference(out, ref, "css") end
    for ref in text:gmatch("[uU][rR][lL]%s*%(%s*([^%s%)\"']+)%s*%)") do add_reference(out, ref, "css") end
end

-- Shared E-Ink styles may refer to images from other chapters' body classes.
-- Only remove a top-level rule when its single body class cannot match.
function R.prune_online_chapter_style(css,xhtml)
    css=tostring(css or "")
    local body=tostring(xhtml or ""):match("<[bB][oO][dD][yY]%s+([^>]*)>") or ""
    body=" "..body
    local _,classes=body:match("%s[cC][lL][aA][sS][sS]%s*=%s*(['\"])(.-)%1")
    classes=classes or body:match("%s[cC][lL][aA][sS][sS]%s*=%s*([^%s'\"]+)")
    local active={}
    for class in tostring(classes or ""):gmatch("%S+") do active[class]=true end

    local output,removed={},{}
    local start,pos,depth,parens=1,1,0,0
    local selector
    local function finish(at,drop)
        local rule=css:sub(start,at)
        if drop then
            for key in rule:gmatch("#miuread%-image%-(%d+)#") do removed[key]=(removed[key] or 0)+1 end
        else
            output[#output+1]=rule
        end
        start=at+1
    end
    while pos<=#css do
        local at=css:find("[\"'\\/;{}()]",pos)
        if not at then break end
        local char=css:sub(at,at)
        pos=at+1
        if char=="'" or char=='"' then
            while pos<=#css do
                local next_char=css:sub(pos,pos)
                pos=pos+1
                if next_char==char then break end
                if next_char=="\\" then pos=pos+1 end
            end
        elseif char=="/" and css:sub(pos,pos)=="*" then
            local last=css:find("*/",pos+1,true)
            pos=last and (last+2) or (#css+1)
        elseif char=="\\" then
            pos=pos+1
        elseif char=="(" then
            parens=parens+1
        elseif char==")" then
            parens=math.max(0,parens-1)
        elseif parens==0 then
            if char=="{" then
                if depth==0 then selector=trim((css:sub(start,at-1):gsub("/%*.-%*/",""))) end
                depth=depth+1
            elseif char=="}" and depth>0 then
                depth=depth-1
                if depth==0 then
                    local class=selector and selector:match("^[bB][oO][dD][yY]%.([%w_%-]+)$")
                    finish(at,class and not active[class] and css:sub(start,at):lower():find("url%s*%(")~=nil)
                end
            elseif char==";" and depth==0 then
                local statement=trim((css:sub(start,at):gsub("/%*.-%*/","")))
                local urls={}
                if statement:lower():match("^@import%s") then collect_css_urls(urls,statement) end
                local source=urls[1] and urls[1].value:lower():gsub("[?#].*$", "") or ""
                local basename=source:match("([^/]+)$")
                finish(at,basename=="fonts.css" or source:match("^data:image/"))
            end
        end
    end
    output[#output+1]=css:sub(start)
    return table.concat(output),removed
end

function R.collect(text, opt)
    local refs = {}
    text = tostring(text or "")

    for tag in text:gmatch("<[iI][mM][gG][^>]*>") do
        local src = tag:match('[sS][rR][cC]%s*=%s*"([^"]+)"')
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            or tag:match("[sS][rR][cC]%s*=%s*([^%s>\"']+)")
        add_reference(refs, src, "image")
        local srcset = tag:match('[sS][rR][cC][sS][eE][tT]%s*=%s*"([^"]+)"')
            or tag:match("[sS][rR][cC][sS][eE][tT]%s*=%s*'([^']+)'")
        if srcset then collect_srcset(refs, srcset, "image") end
    end

    for tag in text:gmatch("<[sS][oO][uU][rR][cC][eE][^>]*>") do
        local srcset = tag:match('[sS][rR][cC][sS][eE][tT]%s*=%s*"([^"]+)"')
            or tag:match("[sS][rR][cC][sS][eE][tT]%s*=%s*'([^']+)'")
        if srcset then collect_srcset(refs, srcset, "image") end
    end

    for tag in text:gmatch("<[iI][mM][aA][gG][eE][^>]*>") do
        local href = tag:match('[xX][lL][iI][nN][kK]:[hH][rR][eE][fF]%s*=%s*"([^"]+)"')
            or tag:match("[xX][lL][iI][nN][kK]:[hH][rR][eE][fF]%s*=%s*'([^']+)'")
            or tag:match('[hH][rR][eE][fF]%s*=%s*"([^"]+)"')
            or tag:match("[hH][rR][eE][fF]%s*=%s*'([^']+)'")
        add_reference(refs, href, "image")
    end

    if opt and opt.css == true then
        collect_css_urls(refs, text)
    else
        for style in text:gmatch('[sS][tT][yY][lL][eE]%s*=%s*"([^"]*)"') do collect_css_urls(refs, style) end
        for style in text:gmatch("[sS][tT][yY][lL][eE]%s*=%s*'([^']*)'") do collect_css_urls(refs, style) end
        for block in text:gmatch("<[sS][tT][yY][lL][eE][^>]*>(.-)</[sS][tT][yY][lL][eE]%s*>") do
            collect_css_urls(refs, block)
        end
    end
    return refs
end

local function asset_href(item)
    local href = normalize_path(tostring(item and item.href or ""))
    return href:gsub("^OEBPS/", "")
end

local read_chapter

local TRANSPARENT_IMAGE = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

local function tag_attr(tag, name)
    tag = tostring(tag or "")
    local escaped = tostring(name or ""):gsub("([^%w])", "%%%1")
    return tag:match(escaped .. '%s*=%s*"([^"]*)"')
        or tag:match(escaped .. "%s*=%s*'([^']*)'")
        or tag:match(escaped .. "%s*=%s*([^%s>\"']+)")
end

local function optional_image_tag(tag, reference)
    local lower = tostring(tag or ""):lower()
    for _, token in ipairs({"qqreader-footnote", "footnote-icon", "footnote-ref", "note-ref"}) do
        if lower:find(token, 1, true) then return true end
    end
    -- Never classify by filename alone. A real正文 image is allowed to be named
    -- note.png; only explicit footnote/helper markup is optional before repair.
    return false
end

local function xml_escape(value)
    return tostring(value or "")
        :gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

local function build_asset_set(assets)
    local set = {}
    for _, item in ipairs(assets or {}) do
        local href = asset_href(item)
        if href ~= "" then set[href] = true end
    end
    return set
end

local function clean_allowed_reference(reference, base_file, asset_set, allowed)
    local target, kind = R.resolve(base_file, reference)
    if kind ~= "local" or not target then return nil end
    local href = tostring(target):gsub("^OEBPS/", "")
    if asset_set[href] or (allowed and not allowed[href]) then return nil end
    return href
end

--- Remove final local image references that are proven safe to drop.
-- `allowed` is normally the exact missing set from a completed preflight. With
-- `allow_orphan=false`, only known footnote/annotation helper images are
-- removed. With `allow_orphan=true`, every still-missing local reference in the
-- supplied allowed set is considered a stable orphan after a repair attempt.
-- External URLs are never touched here.
function R.cleanup_missing_local(chapters, css, assets, opt)
    opt = opt or {}
    local asset_set = build_asset_set(assets)
    local allowed = type(opt.allowed) == "table" and opt.allowed or nil
    local allow_orphan = opt.allow_orphan == true
    local stats = {removed=0, optional=0, orphan=0, chapters=0, css=0, samples={}}

    local function record(href, optional)
        stats.removed = stats.removed + 1
        if optional then stats.optional = stats.optional + 1 else stats.orphan = stats.orphan + 1 end
        if #stats.samples < 8 then stats.samples[#stats.samples + 1] = href end
    end

    local function replacement_for_tag(tag, reference, base_file, svg)
        local href = clean_allowed_reference(reference, base_file, asset_set, allowed)
        if not href then return nil end
        local optional = optional_image_tag(tag, reference)
        if not optional and not allow_orphan then return nil end
        record(href, optional)
        if svg then return "" end
        local alt = tag_attr(tag, "alt") or ""
        alt = trim(alt)
        return alt ~= "" and ('<span class="miu-image-alt">' .. xml_escape(alt) .. '</span>') or ""
    end

    local function clean_css_urls(text, base_file)
        local changed = 0
        local function replace_ref(prefix, ref, suffix, quote)
            local href = clean_allowed_reference(ref, base_file, asset_set, allowed)
            if href and allow_orphan then
                changed = changed + 1
                record(href, false)
                return prefix .. "'" .. TRANSPARENT_IMAGE .. "'" .. suffix
            end
            return prefix .. tostring(quote or "") .. ref .. tostring(quote or "") .. suffix
        end
        local out = tostring(text or "")
        out = out:gsub('([uU][rR][lL]%s*%(%s*)"([^"]+)"(%s*%))', function(prefix,ref,suffix)
            return replace_ref(prefix,ref,suffix,'"')
        end)
        out = out:gsub("([uU][rR][lL]%s*%(%s*)'([^']+)'(%s*%))", function(prefix,ref,suffix)
            return replace_ref(prefix,ref,suffix,"'")
        end)
        out = out:gsub("([uU][rR][lL]%s*%(%s*)([^%s%)\"']+)(%s*%))", function(prefix,ref,suffix)
            return replace_ref(prefix,ref,suffix,"")
        end)
        return out, changed
    end

    for index, chapter in ipairs(chapters or {}) do
        local raw, err = read_chapter(chapter)
        if type(raw) ~= "string" then return nil, nil, "无法读取待清理章节资源：" .. tostring(err or index) end
        local base_file = string.format("OEBPS/text/chapter-%04d.xhtml", index)
        local changed = 0
        local body = raw:gsub("<[iI][mM][gG][^>]*>", function(tag)
            local ref = tag_attr(tag, "src")
            if not ref or ref == "" then return tag end
            local replacement = replacement_for_tag(tag, ref, base_file, false)
            if replacement ~= nil then changed = changed + 1; return replacement end
            return tag
        end)
        body = body:gsub("<[iI][mM][aA][gG][eE][^>]*>", function(tag)
            local ref = tag_attr(tag, "xlink:href") or tag_attr(tag, "href")
            if not ref or ref == "" then return tag end
            local replacement = replacement_for_tag(tag, ref, base_file, true)
            if replacement ~= nil then changed = changed + 1; return replacement end
            return tag
        end)
        body = body:gsub("<[sS][oO][uU][rR][cC][eE][^>]*>", function(tag)
            local srcset = tag_attr(tag, "srcset")
            local ref = srcset and (srcset:match("^%s*([^,%s]+)")) or nil
            if not ref then return tag end
            local href = clean_allowed_reference(ref, base_file, asset_set, allowed)
            if href and allow_orphan then changed = changed + 1; record(href, false); return "" end
            return tag
        end)
        local css_changed
        body, css_changed = clean_css_urls(body, base_file)
        changed = changed + css_changed
        if changed > 0 then
            stats.chapters = stats.chapters + 1
            if chapter.body_path then
                local ok, write_error = U.atomic_write(chapter.body_path, body, true)
                if not ok then return nil, nil, "无法保存清理后的章节：" .. tostring(write_error or index) end
            else
                chapter.body = body
            end
        end
    end

    local cleaned_css, css_changed = clean_css_urls(css or "", "OEBPS/style.css")
    stats.css = css_changed
    return cleaned_css, stats
end


read_chapter = function(chapter)
    if type(chapter) ~= "table" then return "" end
    if chapter.body_path then return U.read_file(chapter.body_path, true) end
    return tostring(chapter.body or "")
end

function R.prepare_online_chapter_style(css,chapter,summary,repair)
    -- The packager wraps the chapter fragment in a body with no class.
    local cleaned,removed=R.prune_online_chapter_style(css)
    if not next(removed) then return cleaned,summary,repair end

    local count=0
    for _,references in pairs(removed) do count=count+references end
    summary=U.copy(summary or {})
    for _,field in ipairs({"missing","required_missing","required_discovered","discovered"}) do
        summary[field]=math.max(0,(tonumber(summary[field]) or 0)-count)
    end
    if repair then
        local body=read_chapter(chapter) or ""
        local pending={}
        for _,item in ipairs(repair.items or {}) do
            local marker="#miuread-image-"..item.key.."#"
            if not removed[item.key] or cleaned:find(marker,1,true) or body:find(marker,1,true) then
                pending[#pending+1]=item
            end
        end
        repair=#pending>0 and U.copy(repair) or nil
        if repair then repair.items=pending end
    end
    return cleaned,summary,repair
end

function R.scan(chapters, css, assets)
    local asset_set = {}
    for _, item in ipairs(assets or {}) do
        local href = asset_href(item)
        if href ~= "" then asset_set[href] = true end
    end

    local referenced, missing = {}, {}
    local external, embedded = {}, 0
    local missing_chapters, external_chapters = {}, {}
    local missing_details, external_details = {}, {}
    local function chapter_uid(chapter)
        return tostring(chapter and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
    end
    local function inspect(text, base_file, is_css, chapter)
        local uid = chapter_uid(chapter)
        for _, item in ipairs(R.collect(text, {css=is_css == true})) do
            local target, kind = R.resolve(base_file, item.value)
            if kind == "embedded" then
                embedded = embedded + 1
            elseif kind == "external" then
                if item.kind == "image" or R.looks_like_image(item.value) then
                    external[#external + 1] = tostring(item.value)
                    if uid ~= "" then external_chapters[uid] = true end
                    if #external_details < 12 then
                        external_details[#external_details + 1] = {
                            uid=uid, title=chapter and chapter.title or nil,
                            reference=tostring(item.value), base_file=base_file,
                        }
                    end
                end
            elseif target then
                local href = tostring(target):gsub("^OEBPS/", "")
                local relevant = item.kind == "image" or asset_set[href] or R.looks_like_image(item.value)
                if relevant then
                    referenced[href] = true
                    if not asset_set[href] then
                        missing[href] = true
                        if uid ~= "" then missing_chapters[uid] = true end
                        if #missing_details < 12 then
                            missing_details[#missing_details + 1] = {
                                uid=uid, title=chapter and chapter.title or nil,
                                reference=tostring(item.value), href=href, base_file=base_file,
                            }
                        end
                    end
                end
            end
        end
    end

    for index, chapter in ipairs(chapters or {}) do
        local raw, err = read_chapter(chapter)
        if type(raw) ~= "string" then return nil, "无法读取最终章节资源：" .. tostring(err or index) end
        inspect(raw, string.format("OEBPS/text/chapter-%04d.xhtml", index), false, chapter)
        if tostring(chapter.style or "") ~= "" then
            inspect(chapter.style, "OEBPS/style.css", true, chapter)
        end
    end
    inspect(css or "", "OEBPS/style.css", true, nil)

    return {
        referenced=referenced,
        missing=missing,
        external=external,
        embedded=embedded,
        missing_chapters=missing_chapters,
        external_chapters=external_chapters,
        missing_details=missing_details,
        external_details=external_details,
    }
end

local function set_count(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function set_samples(value, limit)
    local out = {}
    for key in pairs(value or {}) do out[#out + 1] = key end
    table.sort(out)
    while #out > (limit or 6) do table.remove(out) end
    return out
end

function R.prune(chapters, css, assets)
    local scan, scan_error = R.scan(chapters, css, assets)
    if not scan then return nil, nil, scan_error end
    local kept, pruned, seen = {}, {}, {}
    for _, item in ipairs(assets or {}) do
        local href = asset_href(item)
        if href ~= "" and scan.referenced[href] and not seen[href] then
            kept[#kept + 1] = item
            seen[href] = true
        elseif href ~= "" then
            pruned[href] = true
        end
    end
    local stats = {
        references=set_count(scan.referenced),
        kept=#kept,
        pruned=set_count(pruned),
        missing=set_count(scan.missing),
        external=#scan.external,
        embedded=scan.embedded,
        pruned_samples=set_samples(pruned, 6),
        missing_samples=set_samples(scan.missing, 6),
        external_samples={},
        missing_chapters=scan.missing_chapters or {},
        external_chapters=scan.external_chapters or {},
        missing_details=scan.missing_details or {},
        external_details=scan.external_details or {},
    }
    for index=1,math.min(6,#scan.external) do stats.external_samples[index]=scan.external[index] end
    return kept, stats
end

R._normalize_path = normalize_path
R._asset_href = asset_href

return R
