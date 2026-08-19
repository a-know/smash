import Foundation
import MarkdownDriveCore

actor UserDefaultsDriveChangeCursorStore: DriveChangeCursorStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        suiteName: String? = nil,
        key: String = "driveChangeCursors"
    ) {
        if let suiteName, let suiteDefaults = UserDefaults(suiteName: suiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
        self.key = key
    }

    func loadCursor(for scope: DriveChangeCursorScope) throws -> DriveChangeCursor? {
        try loadEntries().first { $0.scope == scope }?.cursor
    }

    func saveCursor(
        _ cursor: DriveChangeCursor,
        for scope: DriveChangeCursorScope
    ) throws {
        var entries = try loadEntries()
        entries.removeAll { $0.scope == scope }
        entries.append(Entry(scope: scope, cursor: cursor))
        entries.sort(by: Self.isOrderedBefore)
        try saveEntries(entries)
    }

    func removeCursor(for scope: DriveChangeCursorScope) throws {
        var entries = try loadEntries()
        entries.removeAll { $0.scope == scope }
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            try saveEntries(entries)
        }
    }

    private func loadEntries() throws -> [Entry] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return try JSONDecoder().decode(Snapshot.self, from: data).entries
    }

    private func saveEntries(_ entries: [Entry]) throws {
        defaults.set(
            try JSONEncoder().encode(Snapshot(entries: entries)),
            forKey: key
        )
    }

    private static func isOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.scope.accountID.rawValue != rhs.scope.accountID.rawValue {
            return lhs.scope.accountID.rawValue < rhs.scope.accountID.rawValue
        }
        return lhs.scope.vaultRootFolderID < rhs.scope.vaultRootFolderID
    }
}

private struct Snapshot: Codable {
    let entries: [Entry]
}

private struct Entry: Codable {
    let scope: DriveChangeCursorScope
    let cursor: DriveChangeCursor
}
