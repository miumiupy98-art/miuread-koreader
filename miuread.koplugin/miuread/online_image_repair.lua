local Resources=require("miuread.eink_resources")
local Installer=require("miuread.epub_installer")
local Codec=require("miuread.codec")
local U=require("miuread.util")

local M={}
local MARKER="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==#miuread%-image%-(%d+)#"
local DIRECT_IMAGE_BUDGET=16*1024*1024

function M.prepare(client,book,uid,record,root)
    local plan=record.image_repair
    local ok,grant=pcall(client.online_chapter_access,client,book,uid)
    if not ok then return nil,"access_check_failed" end
    if not grant or grant.durable~=true or tostring(grant.version)~=plan.version then
        return nil,"access_or_version_changed"
    end

    U.mkdir(root)
    local deadline=os.time()+12
    local assets,archive_names,index={},{},{}
    local archive_available=false
    for _,item in ipairs(plan.items) do
        if item.archive_name then archive_names[item.archive_name]=true end
    end
    if type(grant.archive)=="string" and grant.archive~="" and next(archive_names) then
        local path=root.."/images.archive"
        local loaded,result=pcall(function()
            Resources.download(client,grant.archive,path,{image_deadline=deadline})
            return Resources.read(path,root,{image_names=archive_names,image_deadline=deadline})
        end)
        os.remove(path)
        if loaded then
            archive_available=true
            for _,asset in ipairs(result) do Resources.index_asset(index,asset.source,asset) end
        end
    end

    local direct_bytes=0
    local stats={archive_name_ambiguous=0,archive_name_missing=0,archive_unavailable=0,
        direct_image_failed=0,image_budget_exhausted=0}
    for _,item in ipairs(plan.items) do
        if type(item.key)=="string" and item.key:match("^%d+$") then
            local asset
            if item.archive_name then
                asset=index[item.archive_name]
                if not asset then
                    local reason=asset==false and "archive_name_ambiguous"
                        or (archive_available and "archive_name_missing" or "archive_unavailable")
                    stats[reason]=stats[reason]+1
                end
            elseif item.url then
                if os.time()<deadline and direct_bytes<DIRECT_IMAGE_BUDGET then
                    local url=Resources.image_url(item.url)
                    local target=root.."/direct-"..item.key..".bin"
                    if url then
                        local fetched=pcall(Resources.download,client,url,target,{anonymous=true,image_deadline=deadline})
                        if fetched then
                            local ext,mime=Codec.media_file(target,url)
                            local size=U.file_size(target) or 0
                            if tostring(mime):match("^image/") and size>0 and size<=DIRECT_IMAGE_BUDGET-direct_bytes then
                                asset={href="image"..ext,mime=mime,data_path=target}
                                direct_bytes=direct_bytes+size
                            end
                        end
                    end
                    if not asset then os.remove(target); stats.direct_image_failed=stats.direct_image_failed+1 end
                else
                    stats.image_budget_exhausted=stats.image_budget_exhausted+1
                end
            end
            if asset then
                local ext=asset.href:match("%.[a-z0-9]+$")
                if ext then assets[item.key]={href="images/eink-repair-"..item.key..ext,mime=asset.mime,data_path=asset.data_path} end
            end
        end
    end
    if not next(assets) then return nil,"no_missing_images_recovered",stats end

    local repaired,reason=Installer.repair_online_images(record.file,root.."/repaired.epub",{
        book_id=book.bookId or book.book_id,uid=uid,task_id=record.task_id,assets=assets,marker_pattern=MARKER,
    })
    return repaired,repaired and "images_recovered" or reason,stats
end

return M
