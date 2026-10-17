#include "SlateArchive.h"
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>

/* macOS ships libarchive but not its headers in the SDK. This narrow shim uses
 * only the stable public libarchive C ABI; no archive structs are dereferenced.
 * Status/file-type constants below are public libarchive/POSIX values. */
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_filter_none(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern int archive_format(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_perm(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);
struct SlateZIP { struct archive *reader; };

SlateZIP *slate_zip_open(const char *path) {
    SlateZIP *zip = calloc(1, sizeof(*zip));
    if (!zip) return NULL;
    zip->reader = archive_read_new();
    if (!zip->reader || archive_read_support_filter_none(zip->reader) != 0 ||
        archive_read_support_format_zip(zip->reader) != 0 ||
        archive_read_open_filename(zip->reader, path, 65536) != 0) {
        slate_zip_close(zip);
        return NULL;
    }
    return zip;
}
int slate_zip_next(SlateZIP *zip, SlateZIPEntry *result) {
    struct archive_entry *entry = NULL;
    int status = archive_read_next_header(zip->reader, &entry);
    if (status != 0) return status == 1 ? 1 : -1;
    if ((archive_format(zip->reader) & 0xff0000) != 0x50000) return -1;
    result->path = archive_entry_pathname_utf8(entry);
    result->size = archive_entry_size(entry);
    result->directory = archive_entry_filetype(entry) == S_IFDIR;
    result->regular = archive_entry_filetype(entry) == S_IFREG;
    result->executable = (archive_entry_perm(entry) & S_IXUSR) != 0;
    result->linked = archive_entry_symlink(entry) != NULL || archive_entry_hardlink(entry) != NULL;
    result->encrypted = archive_entry_is_encrypted(entry);
    return 0;
}
int64_t slate_zip_read(SlateZIP *zip, void *buffer, size_t count) {
    return archive_read_data(zip->reader, buffer, count);
}
const char *slate_zip_error(SlateZIP *zip) { return archive_error_string(zip->reader); }
void slate_zip_close(SlateZIP *zip) {
    if (!zip) return;
    if (zip->reader) archive_read_free(zip->reader);
    free(zip);
}
