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

    func add(_ record: InstalledModRecord) {
        var records = load()
        records.removeAll { $0.name.caseInsensitiveCompare(record.name) == .orderedSame }
        records.append(record)
        save(records)
    }

    func remove(named name: String) {
        save(load().filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
    }

    func reconcile(existingNames: Set<String>) {
        save(load().map { record in
            InstalledModRecord(
                name: record.name,
                path: record.path,
                dependencies: record.dependencies,
                currentVersion: record.currentVersion,
                orphaned: !existingNames.contains(record.name.lowercased())
            )
        })
    }

    func isTracked(_ name: String) -> Bool {
        load().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func load() -> [InstalledModRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([InstalledModRecord].self, from: data)) ?? []
    }

    private func save(_ records: [InstalledModRecord]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
