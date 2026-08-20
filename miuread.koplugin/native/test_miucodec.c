#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef char* (*fn_b64decode)(const char*, int, int*);
typedef char* (*fn_b64encode)(const char*, int, int*);
typedef char* (*fn_md5)(const char*, int);
typedef char* (*fn_sha256)(const char*, int);
typedef char* (*fn_shard_body)(const char*, int, int*);
typedef char* (*fn_decode_parts)(const char**, const int*, int, int*);
typedef void  (*fn_free)(void*);

int main(void) {
    void* lib = dlopen("./libmiucodec.dylib", RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    fn_b64encode enc = (fn_b64encode)dlsym(lib, "miucodec_b64encode");
    fn_b64decode dec = (fn_b64decode)dlsym(lib, "miucodec_b64decode");
    fn_md5 md5 = (fn_md5)dlsym(lib, "miucodec_md5");
    fn_sha256 sha = (fn_sha256)dlsym(lib, "miucodec_sha256");
    fn_free mfree = (fn_free)dlsym(lib, "miucodec_free");

    int ok = 1;

    /* base64 roundtrip */
    {
        const char* plain = "Hello, World!";
        int enc_len = 0, dec_len = 0;
        char* encoded = enc(plain, strlen(plain), &enc_len);
        char* decoded = dec(encoded, enc_len, &dec_len);
        if (dec_len != (int)strlen(plain) || memcmp(decoded, plain, dec_len) != 0) {
            fprintf(stderr, "FAIL: b64 roundtrip\n"); ok = 0;
        } else {
            printf("PASS: b64 roundtrip -> %s\n", encoded);
        }
        mfree(encoded); mfree(decoded);
    }

    /* MD5 */
    {
        char* h = md5("", 0);
        if (strcmp(h, "d41d8cd98f00b204e9800998ecf8427e") != 0) {
            fprintf(stderr, "FAIL: md5 empty = %s\n", h); ok = 0;
        } else { printf("PASS: md5 empty\n"); }
        mfree(h);
        h = md5("abc", 3);
        if (strcmp(h, "900150983cd24fb0d6963f7d28e17f72") != 0) {
            fprintf(stderr, "FAIL: md5 abc = %s\n", h); ok = 0;
        } else { printf("PASS: md5 abc\n"); }
        mfree(h);
    }

    /* SHA-256 */
    {
        char* h = sha("abc", 3);
        if (strcmp(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") != 0) {
            fprintf(stderr, "FAIL: sha256 abc = %s\n", h); ok = 0;
        } else { printf("PASS: sha256 abc\n"); }
        mfree(h);
    }

    dlclose(lib);
    printf(ok ? "\nAll tests passed.\n" : "\nSome tests FAILED.\n");
    return ok ? 0 : 1;
}
