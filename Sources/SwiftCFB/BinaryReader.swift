// SwiftCFB — a read-only Microsoft Compound File Binary (CFB / OLE2 /
// Structured Storage) reader.
//
// Derived from pyaaf2's cfb.py (MIT-licensed, © Mark Reid). See NOTICE.md.
//
// Little-endian binary readers over a Data buffer. CFB is little-endian
// throughout (the byte-order field in the header is *checked* — never
// honored for big-endian, since the spec disallows that).
//
// We deliberately avoid `Data.withUnsafeBytes` + `loadUnaligned` here for
// the hot path — Data subscripting on a memory-mapped file is fast enough
// for the sector sizes we see (512 / 4096), and keeping the code obviously
// little-endian aids future readers more than a microbench would.

import Foundation

@inlinable
func u8(_ data: Data, _ offset: Int) -> UInt8 {
    return data[data.startIndex + offset]
}

@inlinable
func u16le(_ data: Data, _ offset: Int) -> UInt16 {
    let base = data.startIndex + offset
    return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
}

@inlinable
func u32le(_ data: Data, _ offset: Int) -> UInt32 {
    let base = data.startIndex + offset
    return UInt32(data[base])
        | (UInt32(data[base + 1]) << 8)
        | (UInt32(data[base + 2]) << 16)
        | (UInt32(data[base + 3]) << 24)
}

@inlinable
func u64le(_ data: Data, _ offset: Int) -> UInt64 {
    // Assemble from two 32-bit halves. A single 8-term shift/or expression
    // trips the Swift type-checker's "unable to type-check in reasonable
    // time" limit on some compiler versions; this stays trivial to check.
    let lo = UInt64(u32le(data, offset))
    let hi = UInt64(u32le(data, offset + 4))
    return lo | (hi << 32)
}

/// Decode an on-disk SID value: `0xFFFFFFFF` is the "none" sentinel.
/// Returned as `Optional` instead of a magic value so call sites read
/// cleanly.
func decodeSID(_ raw: UInt32) -> UInt32? {
    return raw == CFBSector.free ? nil : raw
}

/// Decode a CFB directory-entry name field (first 64 bytes of the entry,
/// UTF-16LE, null-terminated within `name_size` bytes).
///
/// Falls back to a lossy char-by-char decode (emitting U+FFFD for bad code
/// units) when the strict UTF-16LE decode fails. The only place this should
/// matter is corrupt files; entries are looked up by path and their *bytes*
/// are returned, so the decoded string only affects path matching.
func decodeUTF16LE(_ data: Data) -> String {
    // `data` is the raw bytes up to name_size (which includes the
    // 2-byte null terminator). Trim the trailing null if present, then
    // split on the first embedded null.
    var bytes = [UInt8](data)
    // Strip trailing null code units in pairs.
    while bytes.count >= 2 && bytes[bytes.count - 1] == 0 && bytes[bytes.count - 2] == 0 {
        bytes.removeLast(2)
    }
    if bytes.isEmpty { return "" }

    // Try strict UTF-16LE decode. If it fails (malformed surrogates), fall
    // back to a char-by-char decoder that emits U+FFFD for bad code units.
    if let s = String(bytes: bytes, encoding: .utf16LittleEndian) {
        // Split on first embedded null.
        if let nullIdx = s.firstIndex(of: "\0") {
            return String(s[..<nullIdx])
        }
        return s
    }
    // Fallback: best-effort char-by-char.
    var out = String.UnicodeScalarView()
    var i = 0
    while i + 1 < bytes.count {
        let cu = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
        if cu == 0 { break }
        if let scalar = Unicode.Scalar(cu) {
            out.append(scalar)
        } else {
            out.append(Unicode.Scalar(0xFFFD)!)
        }
        i += 2
    }
    return String(out)
}
