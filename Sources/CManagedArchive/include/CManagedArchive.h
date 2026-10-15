#include <stdint.h>
// Extract only explicit regular-file payloads. No archive-provided path is used for writes.
int mm_extract(const char *archive_path, const char *destination, const char **members,
               const char **outputs, const int64_t *sizes, int count,
               int (*cancelled)(void *), void *context, char *error, int error_size);
