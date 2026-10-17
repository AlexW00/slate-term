#ifndef SLATE_ARCHIVE_H
#define SLATE_ARCHIVE_H
#include <stdint.h>
#include <stddef.h>

typedef struct SlateZIP SlateZIP;
typedef struct {
    const char *path;
    int64_t size;
    int directory;
    int regular;
    int executable;
    int linked;
    int encrypted;
} SlateZIPEntry;
SlateZIP *slate_zip_open(const char *path);
/* 0 = entry, 1 = EOF, negative = error (including archive warnings). */
int slate_zip_next(SlateZIP *zip, SlateZIPEntry *entry);
int64_t slate_zip_read(SlateZIP *zip, void *buffer, size_t count);
const char *slate_zip_error(SlateZIP *zip);
void slate_zip_close(SlateZIP *zip);
#endif
