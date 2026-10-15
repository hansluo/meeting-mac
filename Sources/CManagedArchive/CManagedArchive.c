#include "CManagedArchive.h"
#include "vendor/archive.h"
#include "vendor/archive_entry.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static int safe_path(const char *p) {
    if (!p || !*p || *p == '/' || strlen(p) > 1024 || strchr(p, '\\')) return 0;
    char copy[1025]; strcpy(copy,p); char *save;
    for (char *part=strtok_r(copy,"/",&save); part; part=strtok_r(NULL,"/",&save))
        if (!strcmp(part,"..") || !strcmp(part,".")) return 0;
    return 1;
}
int mm_extract(const char *source, const char *destination, const char **members,
               const char **outputs, const int64_t *sizes, int count,
               int (*cancelled)(void *), void *context, char *error, int error_size) {
    struct archive *a=archive_read_new(); archive_read_support_filter_all(a); archive_read_support_format_tar(a);
    int result=1, fd=-1, headers=0; int *seen=calloc(count,sizeof(int));
    if (archive_read_open_filename(a,source,65536)!=ARCHIVE_OK) goto done;
    struct archive_entry *e; int next;
    while ((next=archive_read_next_header(a,&e))==ARCHIVE_OK) {
        if (++headers>10000 || cancelled(context)) goto done;
        const char *path=archive_entry_pathname(e);
        if (!safe_path(path)) goto done;
        int selected=-1;
        for(int i=0;i<count;i++) if (!strcmp(path,members[i])) { selected=i; break; }
        // Ignore unselected archive members, including upstream's unrelated dylib aliases.
        // They are never written or traversed. Selected links/special files always fail.
        if (selected<0) { if (archive_read_data_skip(a)!=ARCHIVE_OK) goto done; continue; }
        if (seen[selected]++ || archive_entry_filetype(e)!=AE_IFREG || archive_entry_symlink(e) || archive_entry_hardlink(e) || archive_entry_size(e)!=sizes[selected] || !safe_path(outputs[selected])) goto done;
        char target[PATH_MAX]; if (snprintf(target,sizeof(target),"%s/%s",destination,outputs[selected]) >= sizeof(target)) goto done;
        // Parent directories are created by trusted Swift manifest code before extraction.
        fd=open(target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600); if(fd<0) goto done;
        char buffer[65536]; int64_t total=0; ssize_t n;
        while((n=archive_read_data(a,buffer,sizeof(buffer)))>0) {
            if (cancelled(context) || total+n>sizes[selected]) goto done;
            ssize_t offset=0; while(offset<n) { ssize_t written=write(fd,buffer+offset,n-offset); if(written<=0) goto done; offset+=written; }
            total+=n;
        }
        if(n<0 || total!=sizes[selected]) goto done;
        close(fd); fd=-1;
    }
    if(next!=ARCHIVE_EOF) goto done;
    for(int i=0;i<count;i++) if(seen[i]!=1) goto done;
    result=0;
done:
    if(result && error && error_size>0) snprintf(error,error_size,"Archive rejected: unsafe, incomplete, duplicate, oversized or cancelled payload%s%s",archive_error_string(a)?": ":"",archive_error_string(a)?archive_error_string(a):"");
    if(fd>=0)close(fd); free(seen); archive_read_free(a); return result;
}
