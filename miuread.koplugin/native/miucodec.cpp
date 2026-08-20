#include "miucodec.h"
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

// ── helpers ──────────────────────────────────────────────────────────

static char* dup_str(const std::string& s, int* out_len) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (!p) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = '\0';
    if (out_len) *out_len = static_cast<int>(s.size());
    return p;
}

static char* dup_hex(const std::string& hex) {
    char* p = static_cast<char*>(std::malloc(hex.size() + 1));
    if (!p) return nullptr;
    std::memcpy(p, hex.data(), hex.size());
    p[hex.size()] = '\0';
    return p;
}

// ── base64 ───────────────────────────────────────────────────────────

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int b64val(unsigned char ch) {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+' || ch == '-') return 62;
    if (ch == '/' || ch == '_') return 63;
    return 0;
}

static std::string b64_decode(const char* src, int len) {
    std::string clean;
    clean.reserve(len);
    for (int i = 0; i < len; ++i) {
        unsigned char c = static_cast<unsigned char>(src[i]);
        if (c == '-') c = '+';
        else if (c == '_') c = '/';
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')
            clean.push_back(static_cast<char>(c));
    }
    while (clean.size() % 4 != 0) clean.push_back('=');
    std::string out;
    out.reserve(clean.size() * 3 / 4);
    for (size_t i = 0; i + 3 < clean.size(); i += 4) {
        int c1 = b64val(clean[i]);
        int c2 = b64val(clean[i + 1]);
        int c3 = (clean[i + 2] == '=') ? 0 : b64val(clean[i + 2]);
        int c4 = (clean[i + 3] == '=') ? 0 : b64val(clean[i + 3]);
        int n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4;
        out.push_back(static_cast<char>((n >> 16) & 0xFF));
        if (clean[i + 2] != '=') out.push_back(static_cast<char>((n >> 8) & 0xFF));
        if (clean[i + 3] != '=') out.push_back(static_cast<char>(n & 0xFF));
    }
    return out;
}

static std::string b64_encode(const char* src, int len) {
    std::string out;
    out.reserve((len + 2) / 3 * 4);
    for (int i = 0; i < len; i += 3) {
        unsigned a = static_cast<unsigned char>(src[i]);
        unsigned b = (i + 1 < len) ? static_cast<unsigned char>(src[i + 1]) : 0u;
        unsigned c = (i + 2 < len) ? static_cast<unsigned char>(src[i + 2]) : 0u;
        unsigned n = (a << 16) | (b << 8) | c;
        out.push_back(B64[(n >> 18) & 63]);
        out.push_back(B64[(n >> 12) & 63]);
        out.push_back((i + 1 < len) ? B64[(n >> 6) & 63] : '=');
        out.push_back((i + 2 < len) ? B64[n & 63] : '=');
    }
    return out;
}

// ── MD5 ──────────────────────────────────────────────────────────────

static const uint32_t MD5_S[64] = {
    7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
    5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
    6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
};

static uint32_t MD5_K[64];

static struct MD5KInit {
    MD5KInit() {
        for (int i = 0; i < 64; ++i)
            MD5_K[i] = static_cast<uint32_t>(
                std::floor(std::fabs(std::sin(static_cast<double>(i + 1))) * 4294967296.0));
    }
} md5k_init;

static inline uint32_t rotl32(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}

static std::string md5_hex(const char* input, int len) {
    std::string msg(input, len);
    uint64_t bits = static_cast<uint64_t>(len) * 8;
    msg.push_back(static_cast<char>(0x80));
    while (msg.size() % 64 != 56) msg.push_back('\0');
    for (int i = 0; i < 8; ++i)
        msg.push_back(static_cast<char>((bits >> (i * 8)) & 0xFF));

    uint32_t A = 0x67452301, B = 0xefcdab89, C = 0x98badcfe, D = 0x10325476;
    for (size_t pos = 0; pos < msg.size(); pos += 64) {
        uint32_t m[16];
        for (int j = 0; j < 16; ++j) {
            const unsigned char* p =
                reinterpret_cast<const unsigned char*>(msg.data() + pos + j * 4);
            m[j] = p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
        }
        uint32_t a = A, b = B, c = C, d = D;
        for (int j = 0; j < 64; ++j) {
            uint32_t f; int g;
            if (j < 16) { f = (b & c) | (~b & d); g = j; }
            else if (j < 32) { f = (d & b) | (~d & c); g = (5 * j + 1) % 16; }
            else if (j < 48) { f = b ^ c ^ d; g = (3 * j + 5) % 16; }
            else { f = c ^ (b | ~d); g = (7 * j) % 16; }
            uint32_t tmp = d; d = c; c = b;
            b = b + rotl32(a + f + MD5_K[j] + m[g], MD5_S[j]);
            a = tmp;
        }
        A += a; B += b; C += c; D += d;
    }
    char hex[33];
    auto le = [](char* out, uint32_t v) {
        std::snprintf(out, 9, "%02x%02x%02x%02x",
            v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF);
    };
    le(hex, A); le(hex + 8, B); le(hex + 16, C); le(hex + 24, D);
    hex[32] = '\0';
    return std::string(hex, 32);
}

// ── SHA-256 ──────────────────────────────────────────────────────────

static const uint32_t SHA256_K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

static inline uint32_t rotr32(uint32_t x, int n) {
    return (x >> n) | (x << (32 - n));
}

static std::string sha256_hex(const char* input, int len) {
    std::string msg(input, len);
    uint64_t bits = static_cast<uint64_t>(len) * 8;
    msg.push_back(static_cast<char>(0x80));
    while (msg.size() % 64 != 56) msg.push_back('\0');
    for (int i = 7; i >= 0; --i)
        msg.push_back(static_cast<char>((bits >> (i * 8)) & 0xFF));

    uint32_t h[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    for (size_t pos = 0; pos < msg.size(); pos += 64) {
        uint32_t w[64];
        for (int j = 0; j < 16; ++j) {
            const unsigned char* p =
                reinterpret_cast<const unsigned char*>(msg.data() + pos + j * 4);
            w[j] = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
        }
        for (int j = 16; j < 64; ++j) {
            uint32_t s0 = rotr32(w[j-15], 7) ^ rotr32(w[j-15], 18) ^ (w[j-15] >> 3);
            uint32_t s1 = rotr32(w[j-2], 17) ^ rotr32(w[j-2], 19) ^ (w[j-2] >> 10);
            w[j] = w[j-16] + s0 + w[j-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],q=h[7];
        for (int j = 0; j < 64; ++j) {
            uint32_t s1 = rotr32(e,6) ^ rotr32(e,11) ^ rotr32(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = q + s1 + ch + SHA256_K[j] + w[j];
            uint32_t s0 = rotr32(a,2) ^ rotr32(a,13) ^ rotr32(a,22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = s0 + maj;
            q=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d;
        h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=q;
    }
    char hex[65];
    for (int i = 0; i < 8; ++i)
        std::snprintf(hex + i * 8, 9, "%02x%02x%02x%02x",
            (h[i] >> 24) & 0xFF, (h[i] >> 16) & 0xFF,
            (h[i] >> 8) & 0xFF, h[i] & 0xFF);
    hex[64] = '\0';
    return std::string(hex, 64);
}

// ── WeRead shard decode ──────────────────────────────────────────────

static std::vector<int> positions(const std::string& s) {
    int n = static_cast<int>(s.size());
    if (n < 4) return {};
    if (n < 11) return {0, 2};
    int take = std::min(4, (n + 9) / 10);
    std::string pieces;
    for (int i = n - 1; i >= n - take; --i) {
        unsigned x = static_cast<unsigned char>(s[i]);
        std::string bin;
        do { bin = (char)('0' + (x % 2)) + bin; x /= 2; } while (x > 0);
        // interpret binary string as base-4
        long long val = 0;
        for (char c : bin) val = val * 4 + (c - '0');
        pieces += std::to_string(val);
    }
    int mod = n - take - 2;
    if (mod <= 0) return {};
    int step = static_cast<int>(std::to_string(mod).size());
    std::vector<int> out;
    int i = 0;
    while (static_cast<int>(out.size()) < 10 && i + step - 1 < static_cast<int>(pieces.size())) {
        std::string sub1 = pieces.substr(i, step);
        long long v1 = std::atoll(sub1.c_str());
        out.push_back(static_cast<int>(v1 % mod));
        if (i + 1 < static_cast<int>(pieces.size())) {
            int end2 = std::min(i + 1 + step, static_cast<int>(pieces.size()));
            std::string sub2 = pieces.substr(i + 1, end2 - (i + 1));
            long long v2 = std::atoll(sub2.c_str());
            if (static_cast<int>(out.size()) < 10)
                out.push_back(static_cast<int>(v2 % mod));
        }
        i += step;
    }
    return out;
}

static std::string unswap(const std::string& s, const std::vector<int>& p) {
    std::string c = s;
    for (int i = static_cast<int>(p.size()) - 1; i >= 1; i -= 2) {
        // Lua: a=p[i]+2; b=p[i-1]+2  (1-indexed, +2 offset)
        // C++: p is 0-indexed, string is 0-indexed
        // Lua positions are 0-based offsets; the +2 accounts for the removed
        // first char and Lua's 1-indexing. In C++ with 0-indexed string after
        // the first char is already removed, offset is +1.
        int a = p[i] + 1;
        int b = p[i - 1] + 1;
        if (a < static_cast<int>(c.size()) && b < static_cast<int>(c.size())) {
            std::swap(c[a], c[b]);
        }
        int a2 = a - 1, b2 = b - 1;
        if (a2 >= 0 && a2 < static_cast<int>(c.size()) &&
            b2 >= 0 && b2 < static_cast<int>(c.size())) {
            std::swap(c[a2], c[b2]);
        }
    }
    return c;
}

static std::string shard_body_impl(const char* raw, int raw_len) {
    if (raw_len <= 32) return {};
    std::string checksum(raw, 32);
    std::string body(raw + 32, raw_len - 32);
    std::string computed = md5_hex(body.data(), static_cast<int>(body.size()));
    // case-insensitive compare
    for (auto& c : checksum) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    for (auto& c : computed) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    if (checksum != computed) return {}; // checksum mismatch
    return body;
}

static std::string decode_parts_impl(const char** parts, const int* parts_len, int count) {
    std::string joined;
    for (int i = 0; i < count; ++i) {
        std::string body = shard_body_impl(parts[i], parts_len[i]);
        joined += body;
    }
    if (joined.empty()) return {};
    // remove first character (Lua: s=s:sub(2))
    std::string s = joined.substr(1);
    auto p = positions(s);
    std::string unswapped = unswap(s, p);
    return b64_decode(unswapped.data(), static_cast<int>(unswapped.size()));
}

// ── exported API ─────────────────────────────────────────────────────

extern "C" {

MIUCODEC_API char* miucodec_decode_parts(
        const char** parts, const int* parts_len, int count, int* out_len) {
    std::string result = decode_parts_impl(parts, parts_len, count);
    return dup_str(result, out_len);
}

MIUCODEC_API char* miucodec_shard_body(
        const char* raw, int raw_len, int* out_len) {
    std::string result = shard_body_impl(raw, raw_len);
    return dup_str(result, out_len);
}

MIUCODEC_API char* miucodec_b64decode(
        const char* input, int input_len, int* out_len) {
    std::string result = b64_decode(input, input_len);
    return dup_str(result, out_len);
}

MIUCODEC_API char* miucodec_b64encode(
        const char* input, int input_len, int* out_len) {
    std::string result = b64_encode(input, input_len);
    return dup_str(result, out_len);
}

MIUCODEC_API char* miucodec_md5(const char* input, int input_len) {
    return dup_hex(md5_hex(input, input_len));
}

MIUCODEC_API char* miucodec_sha256(const char* input, int input_len) {
    return dup_hex(sha256_hex(input, input_len));
}

MIUCODEC_API void miucodec_free(void* ptr) {
    std::free(ptr);
}

} // extern "C"
