#pragma once

#include <stddef.h>
#include <sys/mman.h>

/*
 * A successful file-backed RX mmap is not sufficient on TXM devices: the
 * executable pages still have to be prepared through the Universal JIT
 * debugger before dyld can enter them.  Keep this decision side-effect free so
 * it can be regression-tested without running iOS dyld.
 */
static inline int ais_should_prepare_executable_mapping(
    const void *mapping,
    size_t length,
    int protection,
    int file_descriptor,
    int has_txm)
{
    return has_txm != 0 &&
           mapping != (const void *)-1 &&
           length != 0u &&
           file_descriptor >= 0 &&
           (protection & PROT_EXEC) != 0;
}

/*
 * On TXM devices a file-backed executable mapping can succeed while still
 * being non-executable to the process.  Preparing that mapping in place does
 * not turn it into a valid TXM JIT image.  The dyld bypass must therefore
 * replace it with an anonymous executable mapping and copy the file bytes
 * into that prepared region.
 */
static inline int ais_should_replace_executable_mapping(
    const void *mapping,
    size_t length,
    int protection,
    int file_descriptor,
    int has_txm)
{
    return ais_should_prepare_executable_mapping(
        mapping,
        length,
        protection,
        file_descriptor,
        has_txm);
}

/*
 * JIT26PrepareRegion initially makes an anonymous executable mapping usable
 * by TXM, but dyld then fills that mapping through a writable mirror.  TXM
 * must see the final bytes written by the debugger as well.  Keep each
 * debugger transaction to one iOS page so the Universal extension does not
 * have to carry a very large remote-protocol packet for libraries such as
 * libawt.
 */
static inline size_t ais_executable_reprepare_chunk_length(
    size_t remaining,
    size_t page_size)
{
    if (remaining == 0u || page_size == 0u) {
        return 0u;
    }

    return remaining < page_size ? remaining : page_size;
}