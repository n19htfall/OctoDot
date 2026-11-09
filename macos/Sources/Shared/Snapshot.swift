import Foundation

/// The engine's UI state for one session, decoded from the versioned
/// little-endian bytes `octo_snapshot` lends (layout: engine/session.goose).
struct Snapshot: Equatable, Sendable {
    static let magic: UInt32 = 0x504E_534F  // "OSNP"
    static let version: UInt16 = 2

    struct Candidate: Equatable, Sendable {
        var text: String
        var comment: String
    }

    /// session::PAGE_SIZE. Digit keys and the candidate grid both use it.
    static let columns = 6

    var isComposing = false
    var hasPreviousPage = false
    var hasNextPage = false
    var isFullCharset = false     // rare characters shown too (Control-g)
    var isExpanded = false        // the multi-row candidate grid (Down)
    var preedit = ""
    var caretUTF8 = 0  // byte offset into preedit
    var commit = ""
    var candidates: [Candidate] = []  // this page, or the visible grid
    var highlighted = 0               // within candidates
    var page = 0                      // page index, or the grid's first row
    var menuCount = 0                 // the whole menu while the grid is open

    static let empty = Snapshot()

    init() {}

    /// nil when the bytes are not a snapshot this host understands.
    init?(bytes: UnsafeRawBufferPointer) {
        var reader = ByteReader(bytes)
        guard reader.u32() == Self.magic, reader.u16() == Self.version,
              let flags = reader.u16(), let preedit = reader.text(), let caret = reader.u32(),
              let commit = reader.text(), let count = reader.u16(), let highlighted = reader.u16(),
              let page = reader.u16(), let total = reader.u16()
        else { return nil }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let text = reader.text(), let comment = reader.text() else { return nil }
            candidates.append(Candidate(text: text, comment: comment))
        }
        guard reader.isAtEnd, Int(caret) <= preedit.utf8.count else { return nil }
        self.isComposing = flags & 1 != 0
        self.hasPreviousPage = flags & 4 != 0
        self.hasNextPage = flags & 8 != 0
        self.isFullCharset = flags & 16 != 0
        self.isExpanded = flags & 32 != 0
        self.preedit = preedit
        self.caretUTF8 = Int(caret)
        self.commit = commit
        self.candidates = candidates
        self.highlighted = Int(highlighted)
        self.page = Int(page)
        self.menuCount = Int(total)
    }
}

/// Bounds-checked little-endian reads. Every read fails (nil) rather than
/// trapping, since the bytes come from across a language boundary.
private struct ByteReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func u16() -> UInt16? {
        take(2).map { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    mutating func u32() -> UInt32? {
        take(4).map { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func text() -> String? {
        guard let length = u32(), let utf8 = take(Int(length)) else { return nil }
        return String(bytes: utf8, encoding: .utf8)  // nil for invalid UTF-8
    }

    private mutating func take(_ count: Int) -> UnsafeRawBufferPointer? {
        guard count >= 0, count <= bytes.count - offset else { return nil }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count])
    }
}
