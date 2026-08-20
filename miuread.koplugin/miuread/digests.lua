local Codec = require("miuread.codec")

local D = {}

function D.md5(input)
    return Codec.md5(input)
end

function D.sha256(input)
    return Codec.sha256(input)
end

return D
