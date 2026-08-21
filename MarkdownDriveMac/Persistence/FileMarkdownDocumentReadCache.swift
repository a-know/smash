import Foundation
import MarkdownDriveCore

actor FileMarkdownDocumentReadCache: MarkdownDocumentReadCache {
    private static let currentSchemaVersion = 1

    private let fileURL: URL
    private let maximumEntryCount: Int

    init(
        fileURL: URL = FileMarkdownDocumentReadCache.defaultFileURL,
        maximumEntryCount: Int = 20
    ) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func loadDocument(
        fileID: String,
        scope: DriveChangeCursorScope
    ) throws -> MarkdownDocument? {
        var entries = try loadEntries()
        guard
            let index = entries.firstIndex(where: {
                $0.fileID == fileID && $0.scope == scope
            })
        else {
            return nil
        }

        let entry = entries.remove(at: index)
        entries.append(entry.withLastAccessedAt(Date()))
        try? saveEntries(entries)
        return entry.document
    }

    func saveDocument(
        _ document: MarkdownDocument,
        scope: DriveChangeCursorScope
    ) throws {
        guard !document.isDirty else {
            return
        }
        var entries = try loadEntries()
        entries.removeAll {
            $0.fileID == document.fileID && $0.scope == scope
        }
        entries.append(
            Entry(
                scope: scope,
                fileID: document.fileID,
                name: document.name,
                text: document.text,
                revision: document.remoteRevision,
                lastAccessedAt: Date()
            )
        )
        entries.sort(by: Self.isMoreRecent)
        try saveEntries(Array(entries.prefix(maximumEntryCount)))
    }

    private func loadEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == Self.currentSchemaVersion else {
                try? FileManager.default.removeItem(at: fileURL)
                return []
            }
            return snapshot.entries
        } catch is DecodingError {
            try? FileManager.default.removeItem(at: fileURL)
            return []
        }
    }

    private func saveEntries(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            Snapshot(version: Self.currentSchemaVersion, entries: entries)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isMoreRecent(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.lastAccessedAt != rhs.lastAccessedAt {
            return lhs.lastAccessedAt > rhs.lastAccessedAt
        }
        if lhs.scope != rhs.scope {
            if lhs.scope.accountID.rawValue != rhs.scope.accountID.rawValue {
                return lhs.scope.accountID.rawValue < rhs.scope.accountID.rawValue
            }
            return lhs.scope.vaultRootFolderID < rhs.scope.vaultRootFolderID
        }
        return lhs.fileID < rhs.fileID
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a-know.MarkdownDrive", isDirectory: true)
            .appendingPathComponent("RecentMarkdownDocuments.json", isDirectory: false)
    }
}

private struct Snapshot: Codable {
    let version: Int
    let entries: [Entry]
}

private struct Entry: Codable {
    let scope: DriveChangeCursorScope
    let fileID: String
    let name: String
    let text: String
    let revision: DriveFileRevision
    let lastAccessedAt: Date

    var document: MarkdownDocument {
        MarkdownDocument(
            fileID: fileID,
            name: name,
            text: text,
            remoteRevision: revision
        )
    }

    func withLastAccessedAt(_ date: Date) -> Entry {
        Entry(
            scope: scope,
            fileID: fileID,
            name: name,
            text: text,
            revision: revision,
            lastAccessedAt: date
        )
    }
}
