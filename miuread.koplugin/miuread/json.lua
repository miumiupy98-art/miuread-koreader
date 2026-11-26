local ok, engine = pcall(require, "json")
if not ok then ok, engine = pcall(require, "rapidjson") end
if not ok then error("MiuRead requires KOReader JSON support") end
local Json = {}
function Json.encode(value)
    if engine.encode then return engine.encode(value) end
    if engine.stringify then return engine.stringify(value) end
    error("JSON encoder unavailable")
end
function Json.decode(value)
    if engine.decode then return engine.decode(value) end
    if engine.parse then return engine.parse(value) end
    error("JSON decoder unavailable")
end
function Json.is_null(value)
    local null=engine.null or (engine.util and engine.util.null)
    return null~=nil and value==null
end
return Json
