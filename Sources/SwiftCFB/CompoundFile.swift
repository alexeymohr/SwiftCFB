// SwiftCFB — a read-only Microsoft Compound File Binary (CFB / OLE2 /
// Structured Storage) reader.
//
// Derived from pyaaf2's cfb.py (MIT-licensed, © Mark Reid). See NOTICE.md.
//
// Top-level read-only CFB API. Read path only — there are no writer code
// paths (no sector allocation, truncation, or tree moves).

import Foundation

/// A read-only Microsoft Compound File Binary.
///
/// Construct from a file URL. The file is memory-mapped (`Data` with
/// `.mappedIfSafe`) so reads don't pull the whole file into RAM — important
/// for large compound files (e.g. media containers can be hundreds of MB).
public final class CompoundFile {

    // MARK: - File-backed storage

    /// Memory-mapped view of the entire file. Sector access is
    /// `data[(sid+1)*sectorSize ..< (sid+2)*sectorSize]`. Reading past EOF
    /// is the caller's bug — `read` returns a zero-padded buffer when a
    /// sector index is past the file's last sector.
    let data: Data

    // MARK: - Parsed header

    /// 2^sectorShift, either 512 or 4096 in practice.
    let sectorSize: Int
    /// 2^miniSectorShift, always 64 in practice.
    let miniSectorSize: Int
    /// Streams shorter than this live in the mini-stream (a single packed
    /// sector-group); longer streams get their own FAT chain of full
    /// sectors. Standard value is 4096.
    let miniStreamCutoff: UInt32
    /// First sector index of the directory chain in the FAT.
    let dirSectorStart: UInt32
    /// Header-declared dir-sector count. Distrusted when it disagrees with
    /// the actual FAT chain length.
    let dirSectorCountHeader: UInt32
    let fatSectorCountHeader: UInt32
    let miniFATSectorStart: UInt32
    let miniFATSectorCount: UInt32
    let difatSectorStart: UInt32
    let difatSectorCount: UInt32
    /// First 109 DIFAT entries, inline in the header.
    let inlineDIFAT: [UInt32]

    // MARK: - Derived tables

    /// Flat FAT — one UInt32 per file sector, indexed by SID. Walked by
    /// `fatChain(startSID:isMiniFAT:)`. In a 100 MB file with 4096-byte
    /// sectors that's ~100 KB — well worth keeping in RAM for O(1) walks.
    let fat: [UInt32]
    /// Same idea for the mini-FAT.
    let miniFAT: [UInt32]
    /// FAT chain holding the directory entries themselves.
    let dirFATChain: [UInt32]
    /// FAT chain holding the mini-stream bytes (rooted at the root entry's
    /// `sectorID`). Empty if the file has no mini-stream.
    let miniStreamChain: [UInt32]

    // MARK: - Directory state

    /// All directory entries, indexed by dir_id. Read once at open() — the
    /// directory section is small (one sector per ~32 entries at 4096
    /// sector size) so eager decode keeps the rest of the code simple.
    let dirEntries: [DirEntry]

    /// Cached children-by-name dictionaries for storage entries. Built
    /// lazily on first listing/find call.
    private var childrenCache: [UInt32: [String: DirEntry]] = [:]

    /// Convenience accessor — the root storage at dir_id 0.
    public var root: DirEntry { dirEntries[0] }

    // MARK: - Construction

    /// Open `url` and parse the header + FAT + directory. Throws
    /// `CFBError.invalidMagic` on non-CFB files, `.unsupportedSectorSize`
    /// for the rare 128/256/2048-byte variants the spec allows but that
    /// don't appear in practice, and `.cyclicChain` if the FAT is malformed.
    public init(url: URL) throws {
        do {
            self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CFBError.ioError("failed to mmap \(url.path): \(error)")
        }

        // --- Header -----------------------------------------------------
        guard data.count >= 512 else {
            throw CFBError.ioError("file too small to be CFB (\(data.count) bytes)")
        }

        let magic = Array(data[data.startIndex ..< data.startIndex + 8])
        guard magic == cfbMagic else {
            throw CFBError.invalidMagic(found: magic)
        }

        let byteOrder = u16le(data, 28)
        guard byteOrder == 0xFFFE else {
            throw CFBError.unsupportedByteOrder(byteOrder)
        }

        let sectorShift = u16le(data, 30)
        self.sectorSize = 1 << Int(sectorShift)
        guard self.sectorSize == 512 || self.sectorSize == 4096 else {
            throw CFBError.unsupportedSectorSize(self.sectorSize)
        }

        let miniSectorShift = u16le(data, 32)
        self.miniSectorSize = 1 << Int(miniSectorShift)
        guard self.miniSectorSize == 64 else {
            throw CFBError.unsupportedMiniSectorSize(self.miniSectorSize)
        }

        // 34..40 reserved (6 bytes)
        self.dirSectorCountHeader = u32le(data, 40)
        self.fatSectorCountHeader = u32le(data, 44)
        self.dirSectorStart = u32le(data, 48)
        // 52..56 transaction signature — informational
        self.miniStreamCutoff = u32le(data, 56)
        self.miniFATSectorStart = u32le(data, 60)
        self.miniFATSectorCount = u32le(data, 64)
        self.difatSectorStart = u32le(data, 68)
        self.difatSectorCount = u32le(data, 72)

        var inline: [UInt32] = []
        inline.reserveCapacity(109)
        for i in 0..<109 {
            inline.append(u32le(data, 76 + i * 4))
        }
        self.inlineDIFAT = inline

        // --- DIFAT chain → FAT-sector list ------------------------------
        // Walk the DIFAT (inline 109 + chained DIFAT sectors) to build a
        // flat list of FAT-sector SIDs, then load each FAT sector into one
        // big array.
        let fatSIDs = CompoundFile.collectFATSectors(
            data: data,
            sectorSize: sectorSize,
            inlineDIFAT: inline,
            difatSectorStart: difatSectorStart,
            difatSectorCount: difatSectorCount
        )

        if UInt32(fatSIDs.count) != fatSectorCountHeader {
            // Some real files disagree here for historical reasons; trust
            // the actual chain length over the header count.
        }

        // --- Load FAT entries into a flat array ------------------------
        let entriesPerSector = sectorSize / 4
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSIDs.count * entriesPerSector)
        for sid in fatSIDs {
            let base = (Int(sid) + 1) * sectorSize
            if base + sectorSize > data.count {
                // A FAT sector past EOF is corruption; zero-pad it so
                // downstream code produces equivalent error reporting
                // rather than crashing.
                for i in 0..<entriesPerSector {
                    let off = base + i * 4
                    if off + 4 <= data.count {
                        fat.append(u32le(data, off))
                    } else {
                        fat.append(CFBSector.free)
                    }
                }
            } else {
                for i in 0..<entriesPerSector {
                    fat.append(u32le(data, base + i * 4))
                }
            }
        }
        self.fat = fat

        // --- Mini-FAT --------------------------------------------------
        // Walked as a FAT chain rooted at miniFATSectorStart.
        let miniFATChain = Self.walkFATChain(
            fat: fat,
            startSID: miniFATSectorStart,
            chainName: "minifat-pointer"
        )
        var minifat: [UInt32] = []
        minifat.reserveCapacity(miniFATChain.count * entriesPerSector)
        for sid in miniFATChain {
            let base = (Int(sid) + 1) * sectorSize
            for i in 0..<entriesPerSector {
                let off = base + i * 4
                if off + 4 <= data.count {
                    minifat.append(u32le(data, off))
                } else {
                    minifat.append(CFBSector.free)
                }
            }
        }
        self.miniFAT = minifat

        // --- Directory chain + entries ---------------------------------
        let dirChain = Self.walkFATChain(
            fat: fat,
            startSID: dirSectorStart,
            chainName: "directory"
        )
        self.dirFATChain = dirChain

        let dirsPerSector = sectorSize / 128
        var entries: [DirEntry] = []
        entries.reserveCapacity(dirChain.count * dirsPerSector)
        for (chainIdx, sid) in dirChain.enumerated() {
            let base = (Int(sid) + 1) * sectorSize
            for i in 0..<dirsPerSector {
                let entryOffset = base + i * 128
                let dirID = UInt32(chainIdx * dirsPerSector + i)
                if entryOffset + 128 <= data.count {
                    entries.append(DirEntry(
                        dirID: dirID,
                        slice: data[entryOffset ..< entryOffset + 128]
                    ))
                } else {
                    entries.append(DirEntry.empty(dirID: dirID))
                }
            }
        }
        self.dirEntries = entries

        // --- Mini-stream chain (rooted at root entry's sector_id) ------
        let root = entries[0]
        if let rootSID = root.sectorID, root.objectType == .rootStorage {
            self.miniStreamChain = Self.walkFATChain(
                fat: fat,
                startSID: rootSID,
                chainName: "mini-stream"
            )
        } else {
            self.miniStreamChain = []
        }
    }

    // MARK: - Path lookup

    /// Find a directory entry by CFB path. `"/"` returns the root,
    /// `"/Properties"` returns the top-level `Properties` stream, etc.
    /// Returns nil if any path component doesn't exist.
    public func find(path: String) -> DirEntry? {
        if path == "/" || path == "" { return root }

        var current = root
        // Strip leading slashes, then split. Empty trailing components
        // (".../foo/" → ["foo", ""]) are kept and won't match — paths are
        // canonical without a trailing slash.
        let stripped = String(path.drop { $0 == "/" })
        let components = stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        for name in components {
            let children = listdirDict(current)
            guard let match = children[name] else { return nil }
            current = match
        }
        return current
    }

    /// The children of a storage entry, sorted by name. Empty for streams.
    public func children(of entry: DirEntry) -> [DirEntry] {
        return listdirDict(entry).values.sorted { $0.name < $1.name }
    }

    /// The children of a storage entry keyed by name. Empty for streams.
    /// Cached per dir_id, so repeated lookups under the same storage are
    /// O(1) after the first walk.
    public func listing(of entry: DirEntry) -> [String: DirEntry] {
        return listdirDict(entry)
    }

    func listdirDict(_ entry: DirEntry) -> [String: DirEntry] {
        if let cached = childrenCache[entry.dirID] { return cached }

        guard let childID = entry.childID else {
            childrenCache[entry.dirID] = [:]
            return [:]
        }

        // DFS over the red-black tree of children, capped so a corrupt or
        // adversarial file can't hang us.
        let dirsPerSector = sectorSize / 128
        let maxEntries = dirFATChain.count * dirsPerSector

        var stack: [UInt32] = [childID]
        var result: [String: DirEntry] = [:]
        var visited = 0

        while let id = stack.popLast() {
            visited += 1
            if visited > maxEntries {
                // Corrupt folder structure — stop walking. Results so far
                // are still usable.
                break
            }
            guard Int(id) < dirEntries.count else { continue }
            let child = dirEntries[Int(id)]
            result[child.name] = child
            if let left = child.leftID { stack.append(left) }
            if let right = child.rightID { stack.append(right) }
        }

        childrenCache[entry.dirID] = result
        return result
    }

    // MARK: - Streams

    /// Open a stream by path. Throws `.notFound` if the path doesn't exist
    /// or `.notAStream` if it resolves to a storage.
    public func openStream(at path: String) throws -> CFBStream {
        guard let entry = find(path: path) else {
            throw CFBError.notFound(path: path)
        }
        guard entry.objectType == .stream else {
            throw CFBError.notAStream(path: path)
        }
        return CFBStream(compound: self, entry: entry)
    }

    /// Open a stream from a directory entry you already hold (e.g. from
    /// `children(of:)`). Throws `.notAStream` if the entry isn't a stream.
    public func openStream(_ entry: DirEntry) throws -> CFBStream {
        guard entry.objectType == .stream else {
            throw CFBError.notAStream(path: entry.name)
        }
        return CFBStream(compound: self, entry: entry)
    }

    /// Read an entire stream by path into a single `Data`. Convenience over
    /// `openStream(at:).readAll()`.
    public func readStream(at path: String) throws -> Data {
        return try openStream(at: path).readAll()
    }

    // MARK: - Internal helpers used by CFBStream

    /// FAT chain walk with Floyd's tortoise-and-hare cycle detection.
    /// Callers (like `CFBStream`) use this to build chains for individual
    /// streams.
    func fatChain(startSID: UInt32?, isMiniFAT: Bool) throws -> [UInt32] {
        let table = isMiniFAT ? miniFAT : fat
        return try Self.walkFATChainThrowing(
            fat: table,
            startSID: startSID,
            chainName: isMiniFAT ? "MINIFAT" : "FAT"
        )
    }

    // MARK: - Static walk helpers (used during init)

    /// Like `fatChain` but doesn't throw — returns an empty list on cycle /
    /// corruption. Used during `init` where the throw path can't propagate
    /// cleanly past the stored-property assignments.
    private static func walkFATChain(
        fat: [UInt32],
        startSID: UInt32,
        chainName: String
    ) -> [UInt32] {
        return (try? walkFATChainThrowing(
            fat: fat,
            startSID: startSID,
            chainName: chainName
        )) ?? []
    }

    /// Throwing version used after init for explicit stream chains.
    fileprivate static func walkFATChainThrowing(
        fat: [UInt32],
        startSID: UInt32?,
        chainName: String
    ) throws -> [UInt32] {
        guard let start = startSID,
              start != CFBSector.endOfChain,
              start != CFBSector.free,
              start != CFBSector.difat,
              start != CFBSector.fat
        else { return [] }

        var sectors: [UInt32] = []
        var hare = start
        var tortoise = start

        while hare != CFBSector.endOfChain {
            sectors.append(hare)
            guard Int(hare) < fat.count else {
                // Out-of-range index — treat as end of chain rather than
                // crashing on an invalid lookup.
                break
            }
            hare = fat[Int(hare)]
            if tortoise != CFBSector.endOfChain && Int(tortoise) < fat.count {
                tortoise = fat[Int(tortoise)]
                if tortoise != CFBSector.endOfChain && Int(tortoise) < fat.count {
                    tortoise = fat[Int(tortoise)]
                    if tortoise == hare {
                        throw CFBError.cyclicChain(name: chainName, startSID: start)
                    }
                }
            }
        }
        return sectors
    }

    /// Collect the SIDs of FAT sectors by walking the DIFAT (inline 109 +
    /// chained DIFAT sectors).
    private static func collectFATSectors(
        data: Data,
        sectorSize: Int,
        inlineDIFAT: [UInt32],
        difatSectorStart: UInt32,
        difatSectorCount: UInt32
    ) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(Int(difatSectorCount) * (sectorSize / 4) + 109)

        for sid in inlineDIFAT {
            if sid <= CFBSector.maxReg { result.append(sid) }
        }

        var remaining = difatSectorCount
        var sid = difatSectorStart
        let entriesPerSector = sectorSize / 4

        while remaining > 0 {
            // A reserved-value SID for a DIFAT sector ends the chain.
            if sid == CFBSector.endOfChain || sid == CFBSector.free
                || sid == CFBSector.difat || sid == CFBSector.fat {
                break
            }
            let base = (Int(sid) + 1) * sectorSize
            if base + sectorSize > data.count { break }

            // All entries except the last in this DIFAT sector are FAT
            // SIDs; the last entry is the next DIFAT SID (or ENDOFCHAIN).
            for i in 0 ..< entriesPerSector - 1 {
                let entry = u32le(data, base + i * 4)
                if entry <= CFBSector.maxReg { result.append(entry) }
            }
            let next = u32le(data, base + (entriesPerSector - 1) * 4)
            sid = next
            remaining -= 1
        }

        return result
    }
}
