#ifndef MIUCODEC_H
#define MIUCODEC_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
  #define MIUCODEC_API __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
  #define MIUCODEC_API __attribute__((visibility("default")))
#else
  #define MIUCODEC_API
#endif

MIUCODEC_API char* miucodec_decode_parts(
    const char** parts, const int* parts_len, int count, int* out_len);

MIUCODEC_API char* miucodec_shard_body(
    const char* raw, int raw_len, int* out_len);

MIUCODEC_API char* miucodec_b64decode(
    const char* input, int input_len, int* out_len);

MIUCODEC_API char* miucodec_b64encode(
    const char* input, int input_len, int* out_len);

MIUCODEC_API char* miucodec_md5(const char* input, int input_len);

MIUCODEC_API char* miucodec_sha256(const char* input, int input_len);

MIUCODEC_API void  miucodec_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif
