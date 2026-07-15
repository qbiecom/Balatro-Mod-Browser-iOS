import Foundation

/// Persists the installation metadata independently of the externally selected game folder.
nonisolated final class InstalledModRegistry {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = applicationSupport
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("installed-mods.json")
    }

    func add(_ record: InstalledModRecord) throws {
        var records = try load()
        records.removeAll {
            $0.gameFolderID == record.gameFolderID
                && $0.normalizedModPath == record.normalizedModPath
        }
        records.append(record)
        try save(records)
    }

    func remove(gameFolderID: String, modPath: String) throws {
        try save((try load()).filter {
            $0.gameFolderID != gameFolderID || $0.normalizedModPath != modPath
        })
    }

    func reconcile(gameFolderID: String, existingPaths: Set<String>) throws {
        let records = try load()
        let reconciled = records.map { record in
            InstalledModRecord(
                gameFolderID: record.gameFolderID,
                name: record.name,
                path: record.path,
                normalizedModPath: record.normalizedModPath,
                dependencies: record.dependencies,
                currentVersion: record.currentVersion,
                orphaned: record.gameFolderID == gameFolderID && !existingPaths.contains(record.normalizedModPath),
                catalogID: record.catalogID
            )
        }
        if reconciled != records { try save(reconciled) }
    }

    func record(gameFolderID: String, modPath: String) throws -> InstalledModRecord? {
        try load().first {
            $0.gameFolderID == gameFolderID && $0.normalizedModPath == modPath
        }
    }

    func dependents(of dependency: String, in gameFolderID: String) throws -> [InstalledModRecord] {
        let normalizedDependency = dependency.normalizedDependencyName
        return (try load()).filter { record in
            record.gameFolderID == gameFolderID
                && record.dependencies.contains { $0.normalizedDependencyName == normalizedDependency }
        }
    }

    private func load() throws -> [InstalledModRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([InstalledModRecord].self, from: data)
        } catch {
            let corruptURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try fileManager.moveItem(at: fileURL, to: corruptURL)
            throw error
        }
    }

    private func save(_ records: [InstalledModRecord]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

nonisolated extension String {
    var normalizedDependencyName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
