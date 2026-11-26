-- Verify beta.16 filesystem discovery and cleanup without a Kindle or account.
package.path="./miuread.koplugin/?.lua;"..package.path
local directories={["/books"]=1,["/books/Fiction"]=1,["/mnt/us/koreader/books"]=1}
local files={["/books/Fiction/one.epub"]=12,["/books/installed.epub"]=34,
    ["/books/5-online.epub"]=22}
local entries={["/books"]={"Fiction","installed.epub","5-online.epub"},["/books/Fiction"]={"one.epub"}}
local denied={}
package.loaded["libs/libkoreader-lfs"]={
    attributes=function(path, field)
        local row=directories[path] and {mode="directory",modification=directories[path]}
            or files[path] and {mode="file",size=files[path],modification=1}
        return row and (field and row[field] or row)
    end,
    dir=function(path)
        if denied[path] then error("unreadable") end
        local index=0
        return function() index=index+1; return (entries[path] or {})[index] end
    end,
}
package.loaded["document/documentregistry"]={hasProvider=function() return true end}
package.loaded["miuread.book_integrity"]={}
package.loaded["miuread.util"]={}
package.loaded.logger={warn=function() end}
package.loaded.docsettings={open=function() error("download removal must not open or delete sidecars") end}

local Library=require("miuread.local_library")
assert(Library.validate_root("/books"))
assert(not Library.validate_root("/mnt/us/koreader/books"))
local original=Library.list_tree("/books")
assert(#original.books==3 and not Library.snapshot_changed(original))
files["/books/Fiction/two.epub"]=18
entries["/books/Fiction"][2]="two.epub"
directories["/books/Fiction"]=2
assert(Library.snapshot_changed(original))
assert(#Library.list_tree("/books").books==4)
denied["/books/Fiction"]=true
local partial=Library.list_tree("/books")
assert(partial.partial and partial.unreadable_dirs[1]=="/books/Fiction")
denied["/books"]=true
assert(not Library.validate_root("/books"))
assert(Library.list_tree("/books").error)

local Service=require("miuread.book_delete_service")
local book={variants={clean={file="/books/installed.epub"}},chapters={
    ["5"]={clean={file="/books/Fiction/one.epub"},online={file="/books/5-online.epub",variant="online"}}
}}
local store={}
function store:variant(_,kind) return book.variants[kind] end
function store:book() return book end
function store:forget_variant(_,kind) book.variants[kind]=nil end
function store:forget_chapter(_,uid,kind) book.chapters[uid][kind]=nil end
local service=Service:new{store=store}
local variant=service:plan_variant("b","clean",true)
assert(variant.download_only and #variant.paths==1 and variant.paths[1]=="/books/installed.epub")
files[variant.paths[1]]=nil
service:commit(variant)
assert(service:verify(variant).ok)
local chapter=service:plan_chapter("b","5",true)
assert(#chapter.paths==1 and chapter.paths[1]=="/books/Fiction/one.epub")
files[chapter.paths[1]]=nil
service:commit(chapter)
assert(service:verify(chapter).ok and book.chapters["5"].online)
local zdir="/app/books/Z-Library"
local former=zdir.."/Legacy [110].epub"
local copied=zdir.."/Manual [120].epub"
directories[zdir]=1
entries[zdir]={"Legacy [110].epub"}
files[former]=29
package.loaded.datastorage={getDataDir=function() return "/app" end,getSettingsDir=function() return "/settings" end}
package.loaded.luasettings={}
package.loaded.pluginloader={getPluginInstance=function() end}
local unified=require("miuread.unified_library")
local old=unified.build({})
local legacy=assert(old.external_state.zlibrary.legacy_downloads)
assert(legacy[former] and unified.managed_source(old.files,former)=="zlibrary")
entries[zdir][2]="Manual [120].epub"
files[copied]=27
directories[zdir]=2
local next_scan=unified.build({local_rows={assert(Library.book_from_path(copied))},zlibrary_downloads=legacy})
assert(unified.managed_source(next_scan.files,former)=="zlibrary")
assert(unified.managed_source(next_scan.files,copied)==nil and #next_scan.device==1)
print("Directory change detection, mixed download provenance, and download-only cleanup passed")