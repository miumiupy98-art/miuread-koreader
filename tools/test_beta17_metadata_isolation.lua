-- Run from repository root with Lua 5.2+ interpreter.
package.preload["logger"] = function() return {warn=function()end} end
package.preload["miuread.util"] = function() return {utf8_truncate=function(v)return v end} end
package.path = "./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;" .. package.path
local Metadata=require("miuread.network_metadata")
local seen={}
local http={get_json=function(_,url,opt)
    seen[#seen+1]={url=url,scope=opt.rate_limit_scope,fail_fast=opt.rate_limit_fail_fast,
        rate_retries=opt.rate_limit_retries,auth=opt.auth,pacing=opt.pacing}
    if url:find("googleapis.com",1,true) then error("Google Books 429") end
    if url:find("openlibrary.org/isbn/",1,true) then
        return {title="Sample",description="A book",works={{key="/works/OL1W"}}}
    end
    if url:find("openlibrary.org/works/",1,true) then
        return {title="Sample",subjects={"Test"}}
    end
    error("unexpected URL "..url)
end}
local patch=Metadata.fetch(http,{title="Sample",isbn="9780123456789"})
assert(type(patch)=="table" and patch.metadata_source=="open_library")
assert(#seen==3, "Google 429 must not block Open Library edition/work fallback")
assert(seen[1].scope=="metadata-google" and seen[2].scope=="metadata-openlibrary" and seen[3].scope=="metadata-openlibrary")
for _,r in ipairs(seen) do
  assert(r.fail_fast==true and r.rate_retries==0 and r.auth==false and r.pacing==false,
     "third-party metadata must be isolated and nonblocking")
end
seen={}
http.get_json=function(_,url,opt)
    seen[#seen+1]={url=url,scope=opt.rate_limit_scope}
    if url:find("googleapis.com",1,true) then return {items={}} end
    if url:find("/isbn/",1,true) then return {title="Sample",works={{key="/works/OL1W"}}} end
    if url:find("/works/",1,true) then return {title="Sample",description="A book"} end
    error(url)
end
patch=Metadata.fetch(http,{isbn="9780123456789"})
assert(type(patch)=="table" and #seen==3)
assert(seen[2].scope=="metadata-openlibrary" and seen[3].scope=="metadata-openlibrary",
    "Open Library work and edition requests must share provider budget")
print("PASS beta17: Google Books and Open Library scopes isolated; Google 429 fallback; fail-fast; both Open Library requests scoped")
