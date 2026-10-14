#ifndef MEETING_SHERPA_BRIDGE_H
#define MEETING_SHERPA_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MMQwen MMQwen;
// All outputs are caller-owned; release engine and text with the matching functions.
// Error codes: 1 load, 2 symbol, 3 version, 4 configuration, 5 native failure, 6 cancellation.
int mm_qwen_probe(const char *runtime_path, char *error, int32_t error_capacity);
MMQwen *mm_qwen_create(const char *runtime_path, const char *frontend, const char *encoder,
                      const char *decoder, const char *tokenizer, int32_t threads,
                      int32_t *error_code, char *error, int32_t error_capacity);
typedef int (*MMQwenCancelled)(void *context);
int mm_qwen_decode(MMQwen *engine, const float *samples, int32_t count, char **text,
                   MMQwenCancelled cancelled, void *context,
                   char *error, int32_t error_capacity);
void mm_qwen_destroy(MMQwen *engine);
void mm_qwen_free_text(char *text);
#ifdef __cplusplus
}
#endif
#endif
