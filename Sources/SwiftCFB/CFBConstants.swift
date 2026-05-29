// SwiftCFB — a read-only Microsoft Compound File Binary (CFB / OLE2 /
// Structured Storage) reader.
//
// Derived from pyaaf2's cfb.py (MIT-licensed, © Mark Reid). See NOTICE.md.
//
// CFB format constants — names and values mirror the MS-CFB spec §2.1–§2.6.

import Foundation

/// Special sector-ID values from MS-CFB §2.1 (`SECT` reserved IDs).
enum CFBSector {
    /// `MAXREGSECT` — the largest legal sector index. Above this are reserved IDs.
    static let maxReg: UInt32 = 0xFFFFFFFA
    /// `DIFSECT` — marks a sector as part of the DIFAT chain.
    static let difat: UInt32 = 0xFFFFFFFC
    /// `FATSECT` — marks a sector as part of the FAT.
    static let fat: UInt32 = 0xFFFFFFFD
    /// `ENDOFCHAIN` — terminator for any sector chain.
    static let endOfChain: UInt32 = 0xFFFFFFFE
    /// `FREESECT` — an unused sector / unused FAT entry / null stream-id sentinel.
    static let free: UInt32 = 0xFFFFFFFF
}

/// Special directory-entry-ID values. `FREESECT` (0xFFFFFFFF) is used as the
/// no-such-entry sentinel for left/right/child links.
enum CFBDirID {
    static let none: UInt32 = 0xFFFFFFFF
    /// Guard against pathologically deep / corrupt directory trees.
    static let max: UInt32 = 0x00FFFFFF
}

/// CFB compound-file magic header: `D0 CF 11 E0 A1 B1 1A E1`.
let cfbMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

/// Directory-entry object type — the type byte at offset 66 of each
/// 128-byte directory entry (MS-CFB §2.6.1). `lockBytes` and `property`
/// exist in the spec for historical reasons and almost never appear in
/// real files.
public enum CFBObjectType: UInt8, Sendable {
    case empty = 0x00
    case storage = 0x01
    case stream = 0x02
    case lockBytes = 0x03
    case property = 0x04
    case rootStorage = 0x05
    case unknown = 0xFF
}

/// Errors raised by the read path.
public enum CFBError: Error, CustomStringConvertible {
    case ioError(String)
    case invalidMagic(found: [UInt8])
    case unsupportedSectorSize(Int)
    case unsupportedMiniSectorSize(Int)
    case unsupportedByteOrder(UInt16)
    case cyclicChain(name: String, startSID: UInt32)
    case maxDepthExceeded(String)
    case corrupt(String)
    case notFound(path: String)
    case notAStream(path: String)
    case notAStorage(path: String)

    public var description: String {
        switch self {
        case .ioError(let msg): return "CFB I/O error: \(msg)"
        case .invalidMagic(let found): return "Invalid CFB magic: \(found)"
        case .unsupportedSectorSize(let s): return "Unsupported sector size: \(s)"
        case .unsupportedMiniSectorSize(let s): return "Unsupported mini sector size: \(s)"
        case .unsupportedByteOrder(let bo): return String(format: "Unsupported byte order: 0x%04X", bo)
        case .cyclicChain(let name, let sid): return "Cyclic \(name) chain starting at \(sid)"
        case .maxDepthExceeded(let what): return "Max depth exceeded: \(what)"
        case .corrupt(let msg): return "Corrupt CFB: \(msg)"
        case .notFound(let p): return "Path not found: \(p)"
        case .notAStream(let p): return "Not a stream: \(p)"
        case .notAStorage(let p): return "Not a storage: \(p)"
        }
    }
}
