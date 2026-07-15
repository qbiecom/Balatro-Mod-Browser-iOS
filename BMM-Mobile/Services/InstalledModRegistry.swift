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
            let migratesLegacyRecord = record.gameFolderID.hasPrefix("legacy:")
                && existingPaths.contains(record.normalizedModPath)
            guard record.gameFolderID == gameFolderID || migratesLegacyRecord else {
                return record
            }

            return InstalledModRecord(
                gameFolderID: migratesLegacyRecord ? gameFolderID : record.gameFolderID,
                name: record.name,
                path: record.path,
                normalizedModPath: record.normalizedModPath,
                dependencies: record.dependencies,
                currentVersion: record.currentVersion,
                orphaned: !existingPaths.contains(record.normalizedModPath),
                catalogID: record.catalogID,
                dependencyReferences: record.dependencyReferences
            )
        }
        if reconciled != records { try save(reconciled) }
    }

    /// Moves records for paths that still exist from transient folder IDs to a durable folder ID.
    func migrateRecords(
        from legacyGameFolderIDs: Set<String>,
        to gameFolderID: String,
        existingPaths: Set<String>
    ) throws {
        guard !legacyGameFolderIDs.isEmpty else { return }

        let records = try load()
        let migrated = records.map { record in
            guard legacyGameFolderIDs.contains(record.gameFolderID),
                  existingPaths.contains(record.normalizedModPath) else {
                return record
            }

            return replacingGameFolderID(of: record, with: gameFolderID)
        }
        if migrated != records { try save(migrated) }
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
                && !record.orphaned
                && (record.dependencies.contains { $0.normalizedDependencyName == normalizedDependency }
                    || record.dependencyReferences.contains {
                        $0.catalogID?.normalizedDependencyName == normalizedDependency
                    })
        }
    }

    func dependents(
        of dependency: InstalledModDependencyReference,
        in gameFolderID: String
    ) throws -> [InstalledModRecord] {
        guard dependency.catalogID != nil || dependency.normalizedInstalledPath != nil else { return [] }
        return (try load()).filter { record in
            record.gameFolderID == gameFolderID
                && !record.orphaned
                && record.dependencyReferences.contains { reference in
                    if let path = dependency.normalizedInstalledPath,
                       reference.normalizedInstalledPath != path {
                        return false
                    }
                    if let catalogID = dependency.catalogID,
                       reference.catalogID?.caseInsensitiveCompare(catalogID) != .orderedSame {
                        return false
                    }
                    return dependency.catalogID != nil || dependency.normalizedInstalledPath != nil
                }
        }
    }

    private func load() throws -> [InstalledModRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return canonicalized(try JSONDecoder().decode([InstalledModRecord].self, from: data))
        } catch {
            let corruptURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try fileManager.moveItem(at: fileURL, to: corruptURL)
            throw error
        }
    }

    private func save(_ records: [InstalledModRecord]) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(canonicalized(records))
        try data.write(to: fileURL, options: .atomic)
    }

    private func canonicalized(_ records: [InstalledModRecord]) -> [InstalledModRecord] {
        let groups = Dictionary(grouping: records) {
            "\($0.gameFolderID)\u{0}\($0.normalizedModPath)"
        }

        return groups.keys.sorted().compactMap { key in
            guard let candidates = groups[key] else { return nil }
            let ranked = candidates.sorted(by: isPreferredCanonicalRecord)
            guard let preferred = ranked.first else { return nil }

            return InstalledModRecord(
                gameFolderID: preferred.gameFolderID,
                name: preferred.name,
                path: preferred.path,
                normalizedModPath: preferred.normalizedModPath,
                dependencies: preferred.dependencies,
                currentVersion: preferred.currentVersion,
                orphaned: preferred.orphaned,
                catalogID: preferred.catalogID,
                dependencyReferences: preferred.dependencyReferences
            )
        }
    }

    private func isPreferredCanonicalRecord(
        _ lhs: InstalledModRecord,
        _ rhs: InstalledModRecord
    ) -> Bool {
        let lhsLegacy = lhs.gameFolderID.hasPrefix("legacy:")
        let rhsLegacy = rhs.gameFolderID.hasPrefix("legacy:")
        if lhsLegacy != rhsLegacy { return !lhsLegacy }
        if lhs.orphaned != rhs.orphaned { return !lhs.orphaned }

        let lhsCatalog = lhs.catalogID?.isEmpty == false
        let rhsCatalog = rhs.catalogID?.isEmpty == false
        if lhsCatalog != rhsCatalog { return lhsCatalog }

        let lhsVersion = lhs.currentVersion?.isEmpty == false
        let rhsVersion = rhs.currentVersion?.isEmpty == false
        if lhsVersion != rhsVersion { return lhsVersion }

        let lhsRichness = lhs.dependencies.count + lhs.dependencyReferences.count
        let rhsRichness = rhs.dependencies.count + rhs.dependencyReferences.count
        if lhsRichness != rhsRichness { return lhsRichness > rhsRichness }

        return canonicalTieBreaker(for: lhs) < canonicalTieBreaker(for: rhs)
    }

    private func canonicalTieBreaker(for record: InstalledModRecord) -> String {
        let references = record.dependencyReferences.map {
            "\($0.catalogID ?? "")\u{0}\($0.normalizedInstalledPath ?? "")"
        }.sorted()
        return ([
            record.catalogID ?? "", record.currentVersion ?? "", record.name, record.path
        ] + record.dependencies.sorted() + references).joined(separator: "\u{1}")
    }

    private func replacingGameFolderID(
        of record: InstalledModRecord,
        with gameFolderID: String
    ) -> InstalledModRecord {
        InstalledModRecord(
            gameFolderID: gameFolderID,
            name: record.name,
            path: record.path,
            normalizedModPath: record.normalizedModPath,
            dependencies: record.dependencies,
            currentVersion: record.currentVersion,
            orphaned: record.orphaned,
            catalogID: record.catalogID,
            dependencyReferences: record.dependencyReferences
        )
    }
}

nonisolated extension String {
    var normalizedDependencyName: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
