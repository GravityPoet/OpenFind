# FinderSearch adoption

Browser source adapted from https://github.com/zeusinsight/FinderSearch at
`021ad61679fbb1c1f18f9dc57a7d1bbc6883863e` (MIT). Copyright 2026 zeusinsight.
The license is shipped in `ThirdPartyNotices/FinderSearch.txt`.

The native browsing views, tabs, file operations, conflict handling, undo,
background icon/thumbnail loading, bounded navigation caches and directory
metadata implementation are reused in the separate `OpenFindBrowser` module.
Search requests are supplied by OpenFind; fsearch is not installed or spawned.
OpenFind retains its full search and document/archive content search.

Durable base snapshots keep the existing `OFZ1`/`OFIX` envelope for compatibility,
while the node and string-pool section is written to a checksummed `nodes-v1.bin`
sidecar and read through `mmap`. A loaded `SearchIndex` therefore uses the mapped
node store directly instead of materializing `[IndexedFileNode]`; invalid or absent
sidecars fall back to the validated heap decoder.
