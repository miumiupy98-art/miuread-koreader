-- Native chapter packages use an account-derived AES-CBC envelope for the
-- traditional ZIP password. Keys stay in memory; no shell or password files.
local bit = require("bit")
local Codec = require("miuread.codec")
local M = {}

function M.password(envelope, vid)
    vid = tostring(vid or "")
    if not vid:match("^%d+$") then error("E-Ink 账号标识无效") end
    envelope = tostring(envelope or "")
    if #envelope > 1024 or envelope == "" or envelope:find("[^%w+/=]") then
        error("E-Ink 下载密钥无效")
    end
    local input = Codec.b64decode(envelope)
    if #input == 0 or #input % 16 ~= 0 then error("E-Ink 下载密钥长度无效") end
    -- E-Ink 2.1.2 ChapterResp.aesDecryptKey repeats the UTF-8 VID bytes,
    -- then takes bytes 1..16 as key and 17..32 as IV. Its Java AES path
    -- does NOT call the phone client's nativeDecryptHeaderKey remap table.
    local material = vid:rep(math.ceil(32/#vid)):sub(1,32)
    local ffi = require("ffi")
    local available,crypto = pcall(require,"ffi/crypto")
    if not available or type(crypto)~="table" or type(crypto.evp_decrypt)~="function" or type(crypto.get_aes_ecb_cipher)~="function" then
        error("E-Ink 解密组件不可用",0)
    end
    local output, length = crypto.evp_decrypt(crypto.get_aes_ecb_cipher(16), input, material:sub(1,16))
    if not output or tonumber(length) ~= #input then error("E-Ink 下载密钥解码失败") end
    output = ffi.string(output, length)
    local plain, previous = {}, material:sub(17)
    for offset = 1, #input, 16 do
        for i = 0, 15 do plain[#plain+1] = string.char(bit.bxor(output:byte(offset+i), previous:byte(i+1))) end
        previous = input:sub(offset, offset+15)
    end
    plain = table.concat(plain)
    local padding = plain:byte(-1)
    if not padding or padding < 1 or padding > 16 or plain:sub(-padding) ~= string.rep(string.char(padding), padding) then
        error("E-Ink 下载密钥校验失败")
    end
    plain = plain:sub(1, -padding-1)
    if plain == "" then error("E-Ink 下载密钥为空") end
    return plain
end

function M.inflate(input, size)
    local ffi = require("ffi")
    -- Unique struct name avoids colliding with other zlib bindings in KOReader.
    if not pcall(ffi.typeof,"miuread_eink_zstream") then ffi.cdef[[
        typedef struct {
            const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
            unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
            const char *msg; void *state;
            void *(*zalloc)(void *, unsigned int, unsigned int);
            void (*zfree)(void *, void *); void *opaque;
            int data_type; unsigned long adler; unsigned long reserved;
        } miuread_eink_zstream;
        const char *zlibVersion(void);
        int inflateInit2_(void *, int, const char *, int);
        int inflate(void *, int);
        int inflateEnd(void *);
    ]] end
    -- Keep declarations once even when many chapter entries are decompressed.
    local inflate_impl
    local loaded,lib = pcall(ffi.loadlib,"z",1)
    if not loaded then error("E-Ink 解压组件不可用",0) end
    inflate_impl = function(data, expected)
        local stream = ffi.new("miuread_eink_zstream[1]")
        local buffer = ffi.new("unsigned char[?]", math.max(1, expected))
        stream[0].next_in = data; stream[0].avail_in = #data
        stream[0].next_out = buffer; stream[0].avail_out = math.max(1, expected)
        if lib.inflateInit2_(stream, -15, lib.zlibVersion(), ffi.sizeof(stream[0])) ~= 0 then error("E-Ink ZIP 解压初始化失败") end
        local status = lib.inflate(stream, 4)
        local actual, consumed = tonumber(stream[0].total_out), tonumber(stream[0].total_in)
        lib.inflateEnd(stream)
        if status ~= 1 or actual ~= expected or consumed ~= #data then error("E-Ink ZIP 解压校验失败") end
        return ffi.string(buffer, actual)
    end
    M.inflate = inflate_impl
    return inflate_impl(input, size)
end

return M
