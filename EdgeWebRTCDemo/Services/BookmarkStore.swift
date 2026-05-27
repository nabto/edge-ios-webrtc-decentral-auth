import Foundation
import Observation

/// Observable list of paired devices, persisted to `<Documents>/bookmarks.json`.
/// The on-disk format matches `edge-ios-rtsp` so the file is portable between
/// the two demo apps.
@Observable
final class BookmarkStore {
    private(set) var bookmarks: [Bookmark] = []

    init() {
        try? load()
    }

    func add(_ bookmark: Bookmark) throws {
        if let idx = bookmarks.firstIndex(of: bookmark) {
            bookmarks.remove(at: idx)
        }
        bookmark.timeAdded = Date()
        bookmarks.append(bookmark)
        try save()
    }

    func update(_ bookmark: Bookmark) throws {
        if let idx = bookmarks.firstIndex(of: bookmark) {
            bookmarks[idx] = bookmark
        }
        try save()
    }

    func remove(_ bookmark: Bookmark) throws {
        bookmarks.removeAll { $0 == bookmark }
        try save()
    }

    func clear() throws {
        bookmarks.removeAll()
        let url = Self.fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func exists(_ bookmark: Bookmark) -> Bool {
        bookmarks.contains(bookmark)
    }

    private func save() throws {
        let data = try JSONEncoder().encode(bookmarks)
        try data.write(to: Self.fileURL(), options: .atomic)
    }

    private func load() throws {
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Bookmark].self, from: data)
        bookmarks = decoded.sorted { (a, b) in
            switch (a.timeAdded, b.timeAdded) {
            case let (l?, r?): return l < r
            default: return false
            }
        }
    }

    private static func fileURL() -> URL {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return URL(fileURLWithPath: dir).appendingPathComponent("bookmarks.json")
    }
}
