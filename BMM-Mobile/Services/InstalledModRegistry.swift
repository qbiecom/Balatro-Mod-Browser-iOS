import Foundation

/// Persists the installation metadata independently of the externally selected game folder.
final class InstalledModRegistry {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = applicationSupport
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("installed-mods.json")
    }

    func add(_ record: InstalledModRecord) throws {
        var records = load()
        records.removeAll {
            $0.gameFolderID == record.gameFolderID
                && $0.normalizedModPath == record.normalizedModPath
        }
        records.append(record)
        try save(records)
    }

    func remove(gameFolderID: String, modPath: String) {
        try? save(load().filter {
            $0.gameFolderID != gameFolderID || $0.normalizedModPath != modPath
        })
    }

    func reconcile(gameFolderID: String, existingPaths: Set<String>) {
        try? save(load().map { record in
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
        })
    }

    func record(gameFolderID: String, modPath: String) -> InstalledModRecord? {
        load().first {
            $0.gameFolderID == gameFolderID && $0.normalizedModPath == modPath
        }
    }

    func dependents(of dependency: String, in gameFolderID: String) -> [InstalledModRecord] {
        let normalizedDependency = dependency.normalizedDependencyName
        return load().filter { record in
            record.gameFolderID == gameFolderID
                && record.dependencies.contains { $0.normalizedDependencyName == normalizedDependency }
        }
    }

    private func load() -> [InstalledModRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([InstalledModRecord].self, from: data)) ?? []
    }

    private func save(_ records: [InstalledModRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension String {
    var normalizedDependencyName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
