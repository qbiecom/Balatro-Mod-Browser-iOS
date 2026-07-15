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
        records.removeAll { $0.name.caseInsensitiveCompare(record.name) == .orderedSame }
        records.append(record)
        try save(records)
    }

    func remove(named name: String) {
        try? save(load().filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
    }

    func reconcile(existingNames: Set<String>) {
        try? save(load().map { record in
            InstalledModRecord(
                name: record.name,
                path: record.path,
                dependencies: record.dependencies,
                currentVersion: record.currentVersion,
                orphaned: !existingNames.contains(record.name.lowercased()),
                catalogID: record.catalogID
            )
        })
    }

    func record(named name: String) -> InstalledModRecord? {
        load().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func dependents(of dependency: String) -> [InstalledModRecord] {
        let normalizedDependency = dependency.normalizedDependencyName
        return load().filter { record in
            record.dependencies.contains { $0.normalizedDependencyName == normalizedDependency }
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
