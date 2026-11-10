// The grammar model's mapping. The .gram file (librime-octagram's format;
// 万象's is 418 MB) is mapped read-only and read in place: its pages stay
// clean and file-backed, so the system can drop them under pressure and
// they are not part of the IME's memory footprint.
//
// Goose cannot hold a slice into mapped memory, so only the mapping stays
// in C. grammar.goose does the walk, the key encoding and the query, and
// reads units through octo_gram_unit one at a time. An index at or past
// the array's end reads as 0, so a damaged file gives wrong scores and
// never a read outside the mapping.
//
// Opening checks the header and that the array lies inside the file. The
// header check is librime-octagram's (BSD-3-Clause, by the RIME developers),
// from gram_db.cc. The query that uses these units is ported in
// grammar.goose.
//
// Included into the engine's generated C (engine/octo.build), so it sees
// Goose's types (sl_u8, gs_u64, ...). The extern fns in grammar.goose bind
// to these functions, with exactly the prototypes Goose declares (a bool
// is a uint8_t). Each accessor is static inline, so the unit read is
// inlined at every call.
#ifndef OCTO_GRAM_H
#define OCTO_GRAM_H

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { OCTO_GRAM_HEADER = 44 };

static struct {
    void *map;                      // the whole file, or NULL
    size_t map_size;
    const uint32_t *units;          // the double array inside it
    uint32_t count;
} octo_gram;

static inline void octo_gram_close(void) {
    if (octo_gram.map) munmap(octo_gram.map, octo_gram.map_size);
    octo_gram.map = NULL;
    octo_gram.units = NULL;
    octo_gram.count = 0;
}

// Maps the .gram file at `path` and makes it the one queried, replacing any
// other: 0, or 1 if it cannot be opened or mapped, 2 if it is not a .gram
// file, 3 if its array lies outside it, 4 if its size is not `size`.
static inline gs_i32 octo_gram_open(sl_u8 path, gs_u64 size) {
    char name[1024];
    if (path.len <= 0 || path.len >= (int64_t)sizeof name) return 1;
    memcpy(name, path.data, (size_t)path.len);
    name[path.len] = 0;
    int fd = open(name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < OCTO_GRAM_HEADER) { close(fd); return 1; }
    size_t length = (size_t)st.st_size;
    void *map = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return 1;
    const uint8_t *bytes = map;
    int32_t code = 0;
    uint32_t count = 0;
    int32_t offset = 0;
    memcpy(&count, bytes + 36, 4);
    memcpy(&offset, bytes + 40, 4);
    int64_t start = 40 + (int64_t)offset;
    if (memcmp(bytes, "Rime::Grammar/", 14) != 0) code = 2;
    else if (count < 256 || start < OCTO_GRAM_HEADER || start % 4 != 0 ||
             start + (int64_t)count * 4 > (int64_t)length) code = 3;
    else if (size != 0 && (uint64_t)length != size) code = 4;
    if (code != 0) { munmap(map, length); return code; }
    madvise(map, length, MADV_RANDOM);       // queries jump around; read no pages ahead
    octo_gram_close();
    octo_gram.map = map;
    octo_gram.map_size = length;
    octo_gram.units = (const uint32_t *)(bytes + start);
    octo_gram.count = count;
    return 0;
}

static inline uint8_t octo_gram_loaded(void) { return octo_gram.units != NULL; }

static inline gs_u64 octo_gram_count(void) { return octo_gram.count; }

// One unit, or 0 when i is past the array. 0's label matches no key byte
// and it has no leaf, so a walk through it fails closed.
static inline gs_u32 octo_gram_unit(gs_u64 i) {
    return i < octo_gram.count ? octo_gram.units[i] : 0;
}

#endif
