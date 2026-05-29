// cfb-dump — print the storage/stream tree of a Compound File Binary.
//
// Usage:
//   cfb-dump <file>            # print the tree
//   cfb-dump <file> <path>     # hexdump the first 256 bytes of a stream

import Foundation
import SwiftCFB

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Print a classic offset / hex / ASCII hexdump of `data`.
func hexdump(_ data: Data) {
    let bytes = [UInt8](data)
    var offset = 0
    while offset < bytes.count {
        let row = bytes[offset ..< min(offset + 16, bytes.count)]
        let hex = row.map { String(format: "%02x", $0) }
            .joined(separator: " ")
            .padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
        let ascii = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
        print(String(format: "%08x  %@  |%@|", offset, hex, ascii))
        offset += 16
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("""
    usage:
      \(args.first.map { ($0 as NSString).lastPathComponent } ?? "cfb-dump") <file> [stream-path]

      <file>         a Compound File Binary (.aaf, legacy .doc/.xls/.ppt, .msg, .msi, …)
      [stream-path]  optional CFB path to a stream, e.g. /Storage/Stream
    """)
}

let url = URL(fileURLWithPath: args[1])

let cfb: CompoundFile
do {
    cfb = try CompoundFile(url: url)
} catch {
    fail("could not open \(url.path): \(error)")
}

// Mode 2: hexdump a single stream.
if args.count >= 3 {
    let path = args[2]
    do {
        let stream = try cfb.openStream(at: path)
        let data = stream.read(256)
        print("\(path)  (\(stream.size) bytes total, showing first \(data.count))\n")
        hexdump(data)
    } catch {
        fail("could not read stream \(path): \(error)")
    }
    exit(0)
}

// Mode 1: print the tree.
func typeLabel(_ t: CFBObjectType) -> String {
    switch t {
    case .rootStorage: return "root"
    case .storage: return "dir "
    case .stream: return "file"
    default: return "?   "
    }
}

func printTree(_ entry: DirEntry, prefix: String, isLast: Bool, isRoot: Bool) {
    if isRoot {
        print("[\(typeLabel(entry.objectType))] /")
    } else {
        let branch = isLast ? "└─ " : "├─ "
        let size = entry.objectType == .stream ? "  (\(entry.byteSize) bytes)" : ""
        print("\(prefix)\(branch)[\(typeLabel(entry.objectType))] \(entry.name)\(size)")
    }

    guard entry.isDir else { return }
    let kids = cfb.children(of: entry)
    let childPrefix = isRoot ? "" : prefix + (isLast ? "   " : "│  ")
    for (i, child) in kids.enumerated() {
        printTree(child, prefix: childPrefix, isLast: i == kids.count - 1, isRoot: false)
    }
}

print(url.lastPathComponent)
printTree(cfb.root, prefix: "", isLast: true, isRoot: true)
