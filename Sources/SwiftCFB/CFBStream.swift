// SwiftCFB — a read-only Microsoft Compound File Binary (CFB / OLE2 /
// Structured Storage) reader.
//
// Derived from pyaaf2's cfb.py (MIT-licensed, © Mark Reid). See NOTICE.md.
//
// Read-only stream view over a CFB directory entry — same chain semantics,
// zero-pad-on-EOF, and mini-stream-vs-full-stream branching as the spec.

import Foundation

/// A stream of bytes addressed by a `DirEntry`. Wraps the (mini-)FAT chain
/// and exposes `seek` / `read`.
///
/// Reference semantics: `position` mutates on each read. Sharing a single
/// `CFBStream` across threads requires external synchronization; the
/// typical usage is one stream per thread for the duration of a read pass.
public final class CFBStream {

    private unowned let compound: CompoundFile

    /// The directory entry this stream reads from.
    public let entry: DirEntry

    /// The FAT chain (mini-FAT for small streams, full FAT otherwise) of
    /// SIDs walked to satisfy reads.
    private let chain: [UInt32]

    /// `true` when the stream uses the mini-stream pathway (which has an
    /// extra indirection through the mini-stream container).
    public let isMiniStream: Bool

    /// Cumulative byte offset; updated on each read/seek.
    public private(set) var position: UInt64 = 0

    /// Stream size in bytes.
    public var size: UInt64 { entry.byteSize }

    init(compound: CompoundFile, entry: DirEntry) {
        self.compound = compound
        self.entry = entry

        // Mini-stream iff not root-storage AND smaller than the cutoff.
        // (Root storage's "byte_size" is the mini-stream container size,
        // but the root itself is read through the full FAT.)
        let isMini = entry.objectType != .rootStorage
            && entry.byteSize < UInt64(compound.miniStreamCutoff)
        self.isMiniStream = isMini

        if entry.sectorID == nil {
            self.chain = []
        } else {
            // A cyclic chain here would mean the file is corrupt; surface it
            // as an empty chain rather than throwing from a stream view.
            self.chain = (try? compound.fatChain(
                startSID: entry.sectorID,
                isMiniFAT: isMini
            )) ?? []
        }
    }

    /// Seek to `offset` from the start of the stream. Only SEEK_SET
    /// semantics are exposed, clamped to `size`.
    public func seek(to offset: UInt64) {
        position = min(offset, size)
    }

    /// Read up to `count` bytes (or the rest of the stream if `count` is
    /// nil). The returned `Data` length is `min(count, size - position)`.
    /// `position` advances by the returned length.
    ///
    /// Hot path: bytes are copied directly from the memory-mapped file into
    /// a pre-allocated buffer, avoiding the per-sector `Data.subdata`
    /// allocation that an obvious implementation would do.
    public func read(_ count: Int? = nil) -> Data {
        let remaining = size - position
        let want: Int
        if let c = count {
            want = min(c, Int(remaining))
        } else {
            want = Int(remaining)
        }
        if want == 0 { return Data() }

        // Zero-initialized so any partial-EOF tail is naturally padded.
        var out = [UInt8](repeating: 0, count: want)

        let fullSectorSize = compound.sectorSize
        let miniSectorSize = compound.miniSectorSize
        let mmap = compound.data
        let mmapCount = mmap.count

        var writeOffset = 0
        var bytesToRead = want

        // Nest the loops inside one `withUnsafeBytes` /
        // `withUnsafeMutableBufferPointer` so the per-sector memcpy is a
        // single call with no allocation.
        let chainArr = chain  // immutable local for closure capture
        let miniStreamChainArr = compound.miniStreamChain
        let isMini = isMiniStream
        let initialPos = position

        out.withUnsafeMutableBufferPointer { (dstBuf: inout UnsafeMutableBufferPointer<UInt8>) in
            let dstBase = dstBuf.baseAddress!

            mmap.withUnsafeBytes { (srcBytes: UnsafeRawBufferPointer) in
                guard let srcBase = srcBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                @inline(__always)
                func copy(absStart: Int, count: Int) {
                    let avail = max(0, min(count, mmapCount - absStart))
                    if avail > 0 {
                        (dstBase + writeOffset).update(from: srcBase + absStart, count: avail)
                    }
                    // bytes [avail..<count) remain zero — matches the
                    // zero-pad-past-EOF behavior of the reference reader.
                }

                if isMini {
                    var miniFATIndex = Int(initialPos) / miniSectorSize
                    var miniSectorOffset = Int(initialPos) % miniSectorSize

                    while bytesToRead > 0 {
                        guard miniFATIndex < chainArr.count else { break }
                        let miniStreamSID = chainArr[miniFATIndex]

                        let miniStreamPos = Int(miniStreamSID) * miniSectorSize + miniSectorOffset
                        let chainIndex = miniStreamPos / fullSectorSize
                        let sidOffset = miniStreamPos % fullSectorSize

                        guard chainIndex < miniStreamChainArr.count else { break }
                        let sid = miniStreamChainArr[chainIndex]

                        let sectorOffset = miniSectorOffset
                        miniSectorOffset = 0
                        miniFATIndex += 1

                        let canRead = min(bytesToRead, miniSectorSize - sectorOffset)
                        let absStart = (Int(sid) + 1) * fullSectorSize + sidOffset
                        copy(absStart: absStart, count: canRead)
                        writeOffset += canRead
                        bytesToRead -= canRead
                    }
                } else {
                    var index = Int(initialPos) / fullSectorSize
                    var startOffset = Int(initialPos) % fullSectorSize

                    while bytesToRead > 0 {
                        guard index < chainArr.count else { break }
                        let sid = chainArr[index]
                        let sectorOffset = startOffset
                        let sidOffset = startOffset
                        index += 1
                        startOffset = 0

                        let canRead = min(bytesToRead, fullSectorSize - sectorOffset)
                        let absStart = (Int(sid) + 1) * fullSectorSize + sidOffset
                        copy(absStart: absStart, count: canRead)
                        writeOffset += canRead
                        bytesToRead -= canRead
                    }
                }
            }
        }

        position += UInt64(writeOffset)
        if writeOffset < out.count {
            out.removeLast(out.count - writeOffset)
        }
        return Data(out)
    }

    /// Convenience: read the whole stream from the start. Resets `position`
    /// to 0 first.
    public func readAll() -> Data {
        position = 0
        return read(nil)
    }
}
