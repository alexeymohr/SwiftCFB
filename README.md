# SwiftCFB

[![CI](https://github.com/alexeymohr/SwiftCFB/actions/workflows/ci.yml/badge.svg)](https://github.com/alexeymohr/SwiftCFB/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Linux-lightgrey.svg)](Package.swift)

A small, dependency-free Swift reader for **Microsoft Compound File Binary**
(CFB) files — also known as OLE2, Structured Storage, or "compound documents."

CFB is a FAT-like filesystem packed inside a single file. A surprising number
of formats are built on it:

- Legacy Microsoft Office documents — `.doc`, `.xls`, `.ppt`
- Windows Installer packages — `.msi`
- Outlook messages and contacts — `.msg`, `.vcf` exports
- AAF (Advanced Authoring Format) — a pro audio/video interchange format
- Thumbnail caches, JET databases, and various legacy Windows artifacts

If you need to crack one of these open in Swift and read the streams inside,
SwiftCFB gives you a tiny, read-only, memory-mapped API to do it — with no
third-party dependencies (just `Foundation`), and it works on macOS, iOS,
tvOS, watchOS, and Linux.

> **Read-only by design.** SwiftCFB parses and reads. It never writes,
> allocates sectors, or modifies a file. That keeps it small and safe to point
> at untrusted input.

## Install

Swift Package Manager — add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/alexeymohr/SwiftCFB.git", from: "1.0.0")
]
```

…and add `"SwiftCFB"` to your target's dependencies. In Xcode: **File ▸ Add
Package Dependencies…** and paste the repo URL.

## Usage

```swift
import SwiftCFB

let cfb = try CompoundFile(url: fileURL)

// Walk the tree.
for entry in cfb.children(of: cfb.root) {
    print(entry.name, entry.isDir ? "(storage)" : "(\(entry.byteSize) bytes)")
}

// Look something up by path.
if let entry = cfb.find(path: "/Storage1/Stream1") {
    print(entry.objectType, entry.byteSize)
}

// Read a whole stream in one call.
let data = try cfb.readStream(at: "/Storage1/Stream1")

// Or stream it in chunks with seek/read.
let stream = try cfb.openStream(at: "/Doc")
stream.seek(to: 1024)
let chunk = stream.read(4096)   // advances position; clamps at end-of-stream
```

The whole public surface is small:

| Type | What it is |
| --- | --- |
| `CompoundFile` | Opens a file; `root`, `find(path:)`, `children(of:)`, `listing(of:)`, `openStream(at:)`, `readStream(at:)` |
| `DirEntry` | A directory entry — `name`, `objectType`, `byteSize`, `classID`, `isDir`, … |
| `CFBStream` | A read cursor over one stream — `read(_:)`, `readAll()`, `seek(to:)`, `size`, `position` |
| `CFBObjectType` | `storage` / `stream` / `rootStorage` / … |
| `CFBError` | Typed errors (`invalidMagic`, `notFound`, `notAStream`, `cyclicChain`, …) |

## Command-line tool

The package ships a `cfb-dump` executable that prints a compound file's tree
and can hexdump any stream inside it:

```console
$ swift run cfb-dump MyProject.aaf
MyProject.aaf
[root] /
├─ [dir ] Header-2
│  ├─ [dir ] Content-3b03
│  │  ├─ [file] EssenceData-1902 index  (55 bytes)
│  │  ├─ [dir ] EssenceData-1902{0}
│  │  │  ├─ [file] Data-2702  (102586 bytes)
│  │  │  └─ [file] properties  (69 bytes)
│  │  └─ …
│  └─ …
└─ …

$ swift run cfb-dump MyProject.aaf "/Header-2/properties"
/Header-2/properties  (186 bytes total, showing first 186)

00000000  4c 20 08 00 09 3b 82 00 10 00 07 3b 82 00 04 00  |L ...;.....;....|
00000010  05 3b 82 00 02 00 04 3b 22 00 20 00 03 3b 22 00  |.;.....;". ..;".|
…
```

## What's supported

- Both sector sizes seen in the wild: **512-byte** (v3) and **4096-byte** (v4)
- The **mini-stream** path for small streams and the **full-FAT** path for
  large ones
- DIFAT chains (files with more FAT sectors than fit in the header)
- The directory red-black tree, walked iteratively with a depth cap so a
  corrupt or adversarial file can't hang the reader
- Cyclic-chain detection (Floyd's tortoise-and-hare) on FAT walks
- Zero-padding past end-of-file, matching the reference reader's behavior
- Memory-mapped reads (`.mappedIfSafe`), so opening a hundreds-of-MB file
  doesn't pull it all into RAM

Out of scope: writing, the rare 128/256/2048-byte sector variants the spec
allows but that don't appear in practice, and any format-specific
interpretation of stream *contents* (that's the caller's job — SwiftCFB just
hands you the bytes).

## Credits & license

SwiftCFB is **MIT-licensed** (see [LICENSE](LICENSE)).

The reader is a clean-room Swift port of the read path of
[pyaaf2](https://github.com/markreidvfx/pyaaf2)'s `cfb.py` by Mark Reid, also
MIT-licensed. The upstream copyright is preserved in [NOTICE.md](NOTICE.md).
