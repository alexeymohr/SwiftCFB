// SwiftCFB — a read-only Microsoft Compound File Binary (CFB / OLE2 /
// Structured Storage) reader.
//
// Derived from pyaaf2's cfb.py (MIT-licensed, © Mark Reid). See NOTICE.md.
//
// CFB directory entry — a 128-byte record describing a storage, stream, or
// the root entry. See MS-CFB §2.6.1 for the on-disk layout.

import Foundation

/// A single directory entry decoded from its 128-byte slot.
///
/// All parseable fields are materialized up-front (rather than re-read on
/// every access) because the directory section is tiny and every entry is
/// read once at open() time.
public struct DirEntry: Equatable, Sendable {

    /// Index into the directory and the entry's on-disk position.
    public let dirID: UInt32

    /// Storage / stream / rootStorage / etc.
    public let objectType: CFBObjectType

    /// Decoded UTF-16LE name. Empty for unused entries.
    public let name: String

    /// Left/right children in the red-black tree of sibling entries.
    public let leftID: UInt32?
    public let rightID: UInt32?
    /// First child (root of the sibling rbtree). Only meaningful for storages.
    public let childID: UInt32?

    /// First sector of this stream's data — meaning depends on stream type:
    /// - Stream + byte_size < mini-stream cutoff: first index into the mini-FAT.
    /// - Stream + byte_size ≥ mini-stream cutoff: first SID into the full FAT.
    /// - Root storage: first SID of the *mini-stream container* (i.e. the
    ///   bytes that mini-streams are sliced out of).
    public let sectorID: UInt32?

    /// Stream size in bytes (for the root storage: size of the mini-stream).
    public let byteSize: UInt64

    /// CLSID at offset 80. Most entries leave this zero; some storages set
    /// it. The raw 16 bytes are exposed for callers that interpret them.
    public let classID: Data

    /// Is this entry a directory (storage or rootStorage)?
    public var isDir: Bool {
        return objectType == .storage || objectType == .rootStorage
    }

    /// Build from a 128-byte slice. Non-throwing — invalid data produces a
    /// well-formed-but-meaningless entry (objectType = .empty, etc.).
    init(dirID: UInt32, slice: Data) {
        self.dirID = dirID

        let nameSize = Int(u16le(slice, 64))
        if nameSize > 0 && nameSize <= 64 {
            let nameRange = slice.startIndex ..< slice.startIndex + nameSize
            self.name = decodeUTF16LE(slice[nameRange])
        } else {
            self.name = ""
        }

        let typeByte = u8(slice, 66)
        self.objectType = CFBObjectType(rawValue: typeByte) ?? .unknown

        self.leftID = decodeSID(u32le(slice, 68))
        self.rightID = decodeSID(u32le(slice, 72))
        self.childID = decodeSID(u32le(slice, 76))

        let classBase = slice.startIndex + 80
        self.classID = slice[classBase ..< classBase + 16]

        // 96..100 flags — not needed for the read path.
        // 100..108 create_time, 108..116 modify_time — informational.
        self.sectorID = decodeSID(u32le(slice, 116))
        self.byteSize = u64le(slice, 120)
    }

    /// Construct an entry for an out-of-range / corrupt slot. Used during
    /// init when the directory chain extends past EOF.
    static func empty(dirID: UInt32) -> DirEntry {
        return DirEntry(
            dirID: dirID,
            objectType: .empty,
            name: "",
            leftID: nil,
            rightID: nil,
            childID: nil,
            sectorID: nil,
            byteSize: 0,
            classID: Data(count: 16)
        )
    }

    private init(
        dirID: UInt32,
        objectType: CFBObjectType,
        name: String,
        leftID: UInt32?,
        rightID: UInt32?,
        childID: UInt32?,
        sectorID: UInt32?,
        byteSize: UInt64,
        classID: Data
    ) {
        self.dirID = dirID
        self.objectType = objectType
        self.name = name
        self.leftID = leftID
        self.rightID = rightID
        self.childID = childID
        self.sectorID = sectorID
        self.byteSize = byteSize
        self.classID = classID
    }
}
