# libarchive public headers

archive.h and archive_entry.h are vendored unchanged from libarchive v3.7.9:

- https://github.com/libarchive/libarchive/blob/v3.7.9/libarchive/archive.h
- https://github.com/libarchive/libarchive/blob/v3.7.9/libarchive/archive_entry.h

The C bridge links the macOS system libarchive. Only these public headers and the matching COPYING notice are vendored; no libarchive runtime is bundled. CLT SDKs omit these headers, which is why they are included here.
