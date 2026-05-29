import XCTest
@testable import SwiftCFB

/// These tests build a minimal-but-valid Compound File Binary entirely in
/// memory — no external fixtures — and read it back. The synthetic file
/// exercises every read path the library has: header parsing, the FAT and
/// mini-FAT walks, the directory red-black tree, the mini-stream path (for
/// small streams) and the full-FAT path (for streams ≥ the 4096-byte
/// cutoff).
final class SwiftCFBTests: XCTestCase {

    // Stream contents the fixture embeds.
    static let smallContent = Data("Hello, Compound File Binary!".utf8)   // < 4096 → mini-stream
    static let docByteCount = 5000                                        // ≥ 4096 → full FAT
    static func docContent() -> Data {
        Data((0..<docByteCount).map { UInt8($0 % 251) })
    }

    private var fileURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("swiftcfb-test-\(UUID().uuidString).cfb")
        try MinimalCFB.bytes().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }

    func testOpensAndExposesRoot() throws {
        let cfb = try CompoundFile(url: fileURL)
        XCTAssertEqual(cfb.root.objectType, .rootStorage)
        XCTAssertTrue(cfb.root.isDir)
    }

    func testTopLevelListingIsSortedByName() throws {
        let cfb = try CompoundFile(url: fileURL)
        let names = cfb.children(of: cfb.root).map(\.name)
        XCTAssertEqual(names, ["Doc", "Storage1"])
    }

    func testFindResolvesNestedPath() throws {
        let cfb = try CompoundFile(url: fileURL)
        let storage = try XCTUnwrap(cfb.find(path: "/Storage1"))
        XCTAssertEqual(storage.objectType, .storage)

        let stream = try XCTUnwrap(cfb.find(path: "/Storage1/Stream1"))
        XCTAssertEqual(stream.objectType, .stream)
        XCTAssertEqual(stream.byteSize, UInt64(Self.smallContent.count))
    }

    func testFindReturnsNilForMissingPath() throws {
        let cfb = try CompoundFile(url: fileURL)
        XCTAssertNil(cfb.find(path: "/Storage1/Nope"))
        XCTAssertNil(cfb.find(path: "/Missing"))
    }

    func testReadsSmallStreamFromMiniStream() throws {
        let cfb = try CompoundFile(url: fileURL)
        let stream = try cfb.openStream(at: "/Storage1/Stream1")
        XCTAssertTrue(stream.isMiniStream)
        XCTAssertEqual(stream.readAll(), Self.smallContent)
    }

    func testReadsLargeStreamFromFullFAT() throws {
        let cfb = try CompoundFile(url: fileURL)
        let stream = try cfb.openStream(at: "/Doc")
        XCTAssertFalse(stream.isMiniStream)
        XCTAssertEqual(stream.size, UInt64(Self.docByteCount))
        XCTAssertEqual(stream.readAll(), Self.docContent())
    }

    func testReadStreamConvenience() throws {
        let cfb = try CompoundFile(url: fileURL)
        XCTAssertEqual(try cfb.readStream(at: "/Storage1/Stream1"), Self.smallContent)
        XCTAssertEqual(try cfb.readStream(at: "/Doc"), Self.docContent())
    }

    func testSeekAndPartialRead() throws {
        let cfb = try CompoundFile(url: fileURL)
        let stream = try cfb.openStream(at: "/Doc")
        stream.seek(to: 1000)
        XCTAssertEqual(stream.position, 1000)
        let chunk = stream.read(16)
        XCTAssertEqual(chunk.count, 16)
        XCTAssertEqual([UInt8](chunk), (1000..<1016).map { UInt8($0 % 251) })
        XCTAssertEqual(stream.position, 1016)
    }

    func testReadClampsAtEndOfStream() throws {
        let cfb = try CompoundFile(url: fileURL)
        let stream = try cfb.openStream(at: "/Doc")
        stream.seek(to: UInt64(Self.docByteCount - 10))
        let tail = stream.read(1000)   // ask for more than remains
        XCTAssertEqual(tail.count, 10)
    }

    func testOpeningStorageAsStreamThrows() throws {
        let cfb = try CompoundFile(url: fileURL)
        XCTAssertThrowsError(try cfb.openStream(at: "/Storage1")) { error in
            guard case CFBError.notAStream = error else {
                return XCTFail("expected .notAStream, got \(error)")
            }
        }
    }

    func testOpeningMissingStreamThrows() throws {
        let cfb = try CompoundFile(url: fileURL)
        XCTAssertThrowsError(try cfb.openStream(at: "/Nope")) { error in
            guard case CFBError.notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
    }

    func testInvalidMagicThrows() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcfb-bogus-\(UUID().uuidString).bin")
        try Data(repeating: 0x42, count: 1024).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(try CompoundFile(url: bogus)) { error in
            guard case CFBError.invalidMagic = error else {
                return XCTFail("expected .invalidMagic, got \(error)")
            }
        }
    }
}

// MARK: - Minimal CFB builder

/// Builds a tiny, spec-valid v3 (512-byte sector) compound file:
///
///     /                       (root storage; its sectorID points at the
///     ├─ Doc                   mini-stream container)
///     └─ Storage1
///        └─ Stream1
///
/// Sector map (SID → role):
///   0  FAT          1  Directory      2  Mini-stream container
///   3  Mini-FAT     4..13  Doc data (full-FAT chain)
enum MinimalCFB {

    static let sectorSize = 512
    static let endOfChain: UInt32 = 0xFFFFFFFE
    static let freeSect: UInt32 = 0xFFFFFFFF
    static let fatSect: UInt32 = 0xFFFFFFFD
    static let none: UInt32 = 0xFFFFFFFF

    static func bytes() -> Data {
        // 14 sectors after the 512-byte header.
        let sectorCount = 14
        var file = [UInt8](repeating: 0, count: sectorSize * (sectorCount + 1))

        writeHeader(&file)
        writeFAT(&file)
        writeDirectory(&file)
        writeMiniStream(&file)
        writeMiniFAT(&file)
        writeDoc(&file)

        return Data(file)
    }

    // File offset where SID `sid`'s data begins.
    private static func sectorOffset(_ sid: Int) -> Int { (sid + 1) * sectorSize }

    private static func writeHeader(_ file: inout [UInt8]) {
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for (i, b) in magic.enumerated() { file[i] = b }
        // 8..24 CLSID: zero.
        putU16(&file, 24, 0x003E)   // minor version
        putU16(&file, 26, 0x0003)   // major version (v3 → 512-byte sectors)
        putU16(&file, 28, 0xFFFE)   // byte order (little-endian)
        putU16(&file, 30, 0x0009)   // sector shift (2^9 = 512)
        putU16(&file, 32, 0x0006)   // mini sector shift (2^6 = 64)
        // 34..40 reserved.
        putU32(&file, 40, 0)        // num dir sectors (must be 0 for v3)
        putU32(&file, 44, 1)        // num FAT sectors
        putU32(&file, 48, 1)        // first directory sector SID
        putU32(&file, 52, 0)        // transaction signature
        putU32(&file, 56, 4096)     // mini-stream cutoff
        putU32(&file, 60, 3)        // first mini-FAT sector SID
        putU32(&file, 64, 1)        // num mini-FAT sectors
        putU32(&file, 68, endOfChain) // first DIFAT sector SID (none)
        putU32(&file, 72, 0)        // num DIFAT sectors

        // DIFAT array: 109 entries at offset 76. [0] = FAT sector SID 0.
        putU32(&file, 76, 0)
        for i in 1..<109 { putU32(&file, 76 + i * 4, freeSect) }
    }

    private static func writeFAT(_ file: inout [UInt8]) {
        let base = sectorOffset(0)
        let entries = sectorSize / 4
        // Default every entry to FREESECT.
        for i in 0..<entries { putU32(&file, base + i * 4, freeSect) }
        putU32(&file, base + 0 * 4, fatSect)      // SID 0 is the FAT itself
        putU32(&file, base + 1 * 4, endOfChain)   // directory chain
        putU32(&file, base + 2 * 4, endOfChain)   // mini-stream container
        putU32(&file, base + 3 * 4, endOfChain)   // mini-FAT chain
        // Doc occupies SID 4..13 as one chain.
        for sid in 4..<13 { putU32(&file, base + sid * 4, UInt32(sid + 1)) }
        putU32(&file, base + 13 * 4, endOfChain)
    }

    private static func writeDirectory(_ file: inout [UInt8]) {
        let base = sectorOffset(1)
        // dir 0: Root Entry. child = dir 1; sectorID = mini-stream container
        // SID 2; byteSize = mini-stream size (one 64-byte mini-sector).
        writeDirEntry(&file, at: base + 0 * 128, name: "Root Entry", type: 0x05,
                      left: none, right: none, child: 1, sectorID: 2, byteSize: 64)
        // dir 1: Storage1. right sibling = Doc (dir 3); child = Stream1 (dir 2).
        writeDirEntry(&file, at: base + 1 * 128, name: "Storage1", type: 0x01,
                      left: none, right: 3, child: 2, sectorID: none, byteSize: 0)
        // dir 2: Stream1 (small → mini-stream, mini-FAT index 0).
        writeDirEntry(&file, at: base + 2 * 128, name: "Stream1", type: 0x02,
                      left: none, right: none, child: none,
                      sectorID: 0, byteSize: UInt64(SwiftCFBTests.smallContent.count))
        // dir 3: Doc (large → full FAT, first SID 4).
        writeDirEntry(&file, at: base + 3 * 128, name: "Doc", type: 0x02,
                      left: none, right: none, child: none,
                      sectorID: 4, byteSize: UInt64(SwiftCFBTests.docByteCount))
    }

    private static func writeDirEntry(
        _ file: inout [UInt8], at offset: Int, name: String, type: UInt8,
        left: UInt32, right: UInt32, child: UInt32, sectorID: UInt32, byteSize: UInt64
    ) {
        // Name as UTF-16LE + null terminator, max 32 code units.
        var units = Array(name.utf16)
        units.append(0)
        for (i, u) in units.enumerated() where i < 32 {
            putU16(&file, offset + i * 2, u)
        }
        putU16(&file, offset + 64, UInt16(units.count * 2)) // name length in bytes
        file[offset + 66] = type
        file[offset + 67] = 1 // color flag (black)
        putU32(&file, offset + 68, left)
        putU32(&file, offset + 72, right)
        putU32(&file, offset + 76, child)
        // 80..96 CLSID: zero. 96..116 flags/timestamps: zero.
        putU32(&file, offset + 116, sectorID)
        putU64(&file, offset + 120, byteSize)
    }

    private static func writeMiniStream(_ file: inout [UInt8]) {
        // Stream1 lives at mini-sector 0 of the container (SID 2).
        let base = sectorOffset(2)
        for (i, b) in SwiftCFBTests.smallContent.enumerated() { file[base + i] = b }
    }

    private static func writeMiniFAT(_ file: inout [UInt8]) {
        let base = sectorOffset(3)
        let entries = sectorSize / 4
        for i in 0..<entries { putU32(&file, base + i * 4, freeSect) }
        putU32(&file, base + 0, endOfChain) // Stream1's single mini-sector
    }

    private static func writeDoc(_ file: inout [UInt8]) {
        let base = sectorOffset(4)
        let doc = SwiftCFBTests.docContent()
        for (i, b) in doc.enumerated() { file[base + i] = b }
    }

    // Little-endian writers.
    private static func putU16(_ file: inout [UInt8], _ off: Int, _ v: UInt16) {
        file[off] = UInt8(v & 0xFF)
        file[off + 1] = UInt8((v >> 8) & 0xFF)
    }
    private static func putU32(_ file: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { file[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
    private static func putU64(_ file: inout [UInt8], _ off: Int, _ v: UInt64) {
        for i in 0..<8 { file[off + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) }
    }
}
