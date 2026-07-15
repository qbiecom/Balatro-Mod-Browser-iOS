import Foundation
import ZIPFoundation

/// Serializes all mutable game-folder and registry access off the main actor.
actor ModFileService {
    private static let maximumArchiveCompressedSize: Int64 = 256 * 1024 * 1024
    private static let maximumArchiveFileCount = 5_000
    private static let maximumArchiveUncompressedSize: UInt64 = 1 * 1024 * 1024 * 1024
    private static let maximumArchiveEntrySize: UInt64 = 128 * 1024 * 1024
    private static let maximumArchivePathDepth = 32
    private let fileManager = FileManager.default
    private let downloadSession: TrustedDownloadSession
    private let registry = InstalledModRegistry()
    private let recoveryStore = UpdateRecoveryStore()

    init(downloadSession: TrustedDownloadSession = TrustedDownloadSession()) {
        self.downloadSession = downloadSession
    }

    struct ScanResult {
        let enabled: [InstalledMod]
        let disabled: [InstalledMod]
        let folderNames: Set<String>
    }

    func scan(modsFolderURL: URL, gameFolderID: String) throws -> ScanResult {
        try Task.checkCancellation()
        do {
            guard try modsFolderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ModFileServiceError.folderAccess(modsFolderURL)
            }
        } catch let error as ModFileServiceError {
            throw error
        } catch {
            throw ModFileServiceError.folderAccess(modsFolderURL)
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: modsFolderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ModFileServiceError.folderAccess(modsFolderURL)
        }
        let mods = entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.caseInsensitiveCompare("lovely") != .orderedSame }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { InstalledMod(id: $0, name: $0.lastPathComponent) }
        try Task.checkCancellation()

        let enabled = mods.filter { !fileManager.fileExists(atPath: $0.id.appendingPathComponent(".lovelyignore").path) }
        let disabled = mods.filter { fileManager.fileExists(atPath: $0.id.appendingPathComponent(".lovelyignore").path) }
        try registry.reconcile(
            gameFolderID: gameFolderID,
            existingPaths: Set(mods.map { $0.id.standardizedFileURL.path.lowercased() })
        )
        return ScanResult(
            enabled: enabled,
            disabled: disabled,
            folderNames: Set(mods.map { $0.name.lowercased() })
        )
    }

    func setEnabled(_ enabled: Bool, modURL: URL) throws {
        try Task.checkCancellation()
        let ignoreURL = modURL.appendingPathComponent(".lovelyignore")
        if enabled {
            if fileManager.fileExists(atPath: ignoreURL.path) { try fileManager.removeItem(at: ignoreURL) }
        } else {
            guard fileManager.createFile(atPath: ignoreURL.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func delete(mod: InstalledMod, gameFolderID: String) throws {
        try Task.checkCancellation()
        let dependents = try registry.dependents(of: mod.name, in: gameFolderID)
        guard dependents.isEmpty else {
            throw ModFileServiceError.hasDependents(dependents.map(\.name))
        }
        let temporaryURL = mod.id.deletingLastPathComponent()
            .appendingPathComponent(".deleting_\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: mod.id, to: temporaryURL)
        do {
            try Task.checkCancellation()
            try registry.remove(gameFolderID: gameFolderID, modPath: mod.id.standardizedFileURL.path.lowercased())
            try fileManager.removeItem(at: temporaryURL)
        } catch {
            try? fileManager.moveItem(at: temporaryURL, to: mod.id)
            throw error
        }
    }

    func updateRecords(for mods: [InstalledMod], gameFolderID: String) throws -> [InstalledModRecord] {
        try mods.compactMap { try registry.record(gameFolderID: gameFolderID, modPath: $0.id.standardizedFileURL.path.lowercased()) }
    }

    func recoverInterruptedUpdates(gameFolderID: String) {
        for transaction in recoveryStore.load() where transaction.replacementRecord.gameFolderID == gameFolderID {
            let destinationURL = URL(fileURLWithPath: transaction.destinationPath)
            let backupURL = URL(fileURLWithPath: transaction.backupPath)
            do {
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    guard fileManager.fileExists(atPath: backupURL.path) else { continue }
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                    try registry.add(transaction.originalRecord)
                } else {
                    try registry.add(transaction.replacementRecord)
                    if fileManager.fileExists(atPath: backupURL.path) { try fileManager.removeItem(at: backupURL) }
                }
                try recoveryStore.remove(transaction)
            } catch { continue }
        }
    }

    func downloadAndInstall(
        from downloadURL: URL,
        mod: CatalogMod,
        dependencies: [String],
        modsFolderURL: URL,
        gameFolderID: String,
        replacing replacementModURL: URL?
    ) async throws {
        try Task.checkCancellation()
        let archiveURL = try await downloadArchive(from: downloadURL)
        defer { try? fileManager.removeItem(at: archiveURL) }
        let destinationURL: URL
        let folderName: String
        if let replacementModURL {
            destinationURL = try validatedImmediateModChild(replacementModURL, in: modsFolderURL)
            folderName = destinationURL.lastPathComponent
        } else {
            folderName = try validatedInstallFolderName(for: mod)
            destinationURL = try containedChildURL(named: folderName, in: modsFolderURL)
        }
        try verifyGameFolderIdentity(modsFolderURL: modsFolderURL, expectedID: gameFolderID)
        guard try isZIPArchive(at: archiveURL) else { throw ModInstallError.unsupportedArchive }

        let stagingURL = modsFolderURL.appendingPathComponent(".staging_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try extractZIPArchive(at: archiveURL, to: stagingURL)
        try Task.checkCancellation()

        let entries = try fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let hasRootFiles = entries.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        let sourceURL = folders.count == 1 && !hasRootFiles ? folders[0] : stagingURL
        let wasDisabled = replacementModURL != nil && fileManager.fileExists(atPath: destinationURL.appendingPathComponent(".lovelyignore").path)
        var transaction: UpdateTransaction?
        if fileManager.fileExists(atPath: destinationURL.path) {
            try verifyGameFolderIdentity(modsFolderURL: modsFolderURL, expectedID: gameFolderID)
            guard replacementModURL != nil else { throw ModInstallError.alreadyInstalled }
            let backupsURL = modsFolderURL.appendingPathComponent(".BMM Backups", isDirectory: true)
            try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
            let backupURL = try containedChildURL(named: "\(folderName)-\(UUID().uuidString)", in: backupsURL)
            let normalizedPath = destinationURL.standardizedFileURL.path.lowercased()
            let originalRecord = try registry.record(gameFolderID: gameFolderID, modPath: normalizedPath) ?? InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: normalizedPath, dependencies: [], currentVersion: nil, orphaned: false, catalogID: nil)
            let replacementRecord = InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: normalizedPath, dependencies: dependencies, currentVersion: mod.version, orphaned: false, catalogID: mod.id)
            let pending = UpdateTransaction(destinationPath: destinationURL.path, backupPath: backupURL.path, replacementRecord: replacementRecord, originalRecord: originalRecord)
            try recoveryStore.save(pending)
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            transaction = pending
        }
        do {
            try Task.checkCancellation()
            try verifyGameFolderIdentity(modsFolderURL: modsFolderURL, expectedID: gameFolderID)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            if wasDisabled { try Data().write(to: destinationURL.appendingPathComponent(".lovelyignore"), options: .atomic) }
        } catch {
            rollback(destinationURL: destinationURL, transaction: transaction)
            throw error
        }
        let record = InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: destinationURL.standardizedFileURL.path.lowercased(), dependencies: dependencies, currentVersion: mod.version, orphaned: false, catalogID: mod.id)
        do {
            try verifyGameFolderIdentity(modsFolderURL: modsFolderURL, expectedID: gameFolderID)
            try registry.add(record)
        } catch {
            rollback(destinationURL: destinationURL, transaction: transaction)
            throw error
        }
        if let transaction {
            try fileManager.removeItem(at: URL(fileURLWithPath: transaction.backupPath))
            try recoveryStore.remove(transaction)
        }
    }

    private func downloadArchive(from url: URL) async throws -> URL {
        guard TrustedDownloadSession.isTrusted(url) else { throw ModInstallError.untrustedDownloadURL }
        let (bytes, response) = try await downloadSession.session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else { throw ModInstallError.downloadFailed }
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > Self.maximumArchiveCompressedSize {
            throw ModInstallError.archiveTooLarge
        }
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileManager.createFile(atPath: archiveURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archiveURL)
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= Self.maximumArchiveCompressedSize else { throw ModInstallError.archiveTooLarge }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.close()
            return archiveURL
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
    }

    private func isZIPArchive(at url: URL) throws -> Bool { let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; let magic = try handle.read(upToCount: 4) ?? Data(); return magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) || magic.starts(with: [0x50, 0x4B, 0x05, 0x06]) || magic.starts(with: [0x50, 0x4B, 0x07, 0x08]) }
    private func extractZIPArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var count = 0; var size: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation(); count += 1
            guard count <= Self.maximumArchiveFileCount else { throw ModInstallError.tooManyArchiveFiles }
            guard entry.uncompressedSize <= Self.maximumArchiveEntrySize else { throw ModInstallError.archiveTooLarge }
            size += entry.uncompressedSize
            guard size <= Self.maximumArchiveUncompressedSize else { throw ModInstallError.archiveTooLarge }
            _ = try safeArchiveOutputURL(for: entry.path, in: destinationURL)
        }
        let available = try destinationURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard available == nil || available! >= Int64(size) else { throw ModInstallError.insufficientStorage }
        for entry in archive {
            try Task.checkCancellation()
            let output = try safeArchiveOutputURL(for: entry.path, in: destinationURL)
            switch entry.type { case .directory: try fileManager.createDirectory(at: output, withIntermediateDirectories: true); case .file: try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true); _ = try archive.extract(entry, to: output, bufferSize: 64 * 1024); case .symlink: throw ModInstallError.unsafeArchive; @unknown default: throw ModInstallError.unsafeArchive }
        }
    }
    private func safeArchiveOutputURL(for path: String, in destination: URL) throws -> URL { let components = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", omittingEmptySubsequences: true); guard !components.isEmpty else { return destination }; guard components.count <= Self.maximumArchivePathDepth, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else { throw ModInstallError.unsafeArchive }; return components.reduce(destination) { $0.appendingPathComponent(String($1), isDirectory: false) } }
    private func validatedInstallFolderName(for mod: CatalogMod) throws -> String { let name = (mod.folderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? mod.folderName! : mod.id).trimmingCharacters(in: .whitespacesAndNewlines); let reserved: Set<String> = [".", "..", "mods", "disabled mods", ".bmm backups", "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]; let device = name.split(separator: ".", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""; guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains(":"), name.rangeOfCharacter(from: .controlCharacters) == nil, !reserved.contains(name.lowercased()), !reserved.contains(device) else { throw ModInstallError.unsafeFolderName }; return name }
    private func containedChildURL(named name: String, in rootURL: URL) throws -> URL { let root = rootURL.standardizedFileURL; let child = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL; guard child.deletingLastPathComponent().path == root.path else { throw ModInstallError.unsafeFolderName }; return child }
    private func validatedImmediateModChild(_ url: URL, in modsFolderURL: URL) throws -> URL { let destination = url.standardizedFileURL; guard destination.deletingLastPathComponent() == modsFolderURL.standardizedFileURL, (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ModInstallError.invalidUpdateTarget }; return destination }
    private func verifyGameFolderIdentity(modsFolderURL: URL, expectedID: String) throws {
        let gameFolderURL = modsFolderURL.deletingLastPathComponent()
        let identifier = (try? gameFolderURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            .map { String(describing: $0) }
            ?? gameFolderURL.standardizedFileURL.path.lowercased()
        guard identifier == expectedID else { throw ModInstallError.invalidUpdateTarget }
    }
    private func rollback(destinationURL: URL, transaction: UpdateTransaction?) { if fileManager.fileExists(atPath: destinationURL.path) { try? fileManager.removeItem(at: destinationURL) }; if let transaction { try? fileManager.moveItem(at: URL(fileURLWithPath: transaction.backupPath), to: destinationURL); if fileManager.fileExists(atPath: destinationURL.path) { try? recoveryStore.remove(transaction) } } }
}

enum ModFileServiceError: LocalizedError {
    case hasDependents([String])
    case folderAccess(URL)

    var errorDescription: String? {
        switch self {
        case let .hasDependents(names):
            "This mod is required by: \(names.joined(separator: ", ")). Remove those mods first."
        case .folderAccess:
            "BMM Mobile could not read this game's Mods folder. Re-select the game folder to restore access; installed mods have not been changed."
        }
    }
}

nonisolated private struct UpdateTransaction: Codable, Identifiable {
    let id: UUID
    let destinationPath: String
    let backupPath: String
    let replacementRecord: InstalledModRecord
    let originalRecord: InstalledModRecord

    init(destinationPath: String, backupPath: String, replacementRecord: InstalledModRecord, originalRecord: InstalledModRecord) {
        id = UUID()
        self.destinationPath = destinationPath
        self.backupPath = backupPath
        self.replacementRecord = replacementRecord
        self.originalRecord = originalRecord
    }
}

nonisolated private final class UpdateRecoveryStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("update-transactions", isDirectory: true)
    }

    func load() -> [UpdateTransaction] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(UpdateTransaction.self, from: data)
        }
    }

    func save(_ transaction: UpdateTransaction) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(transaction).write(to: fileURL(for: transaction), options: .atomic)
    }

    func remove(_ transaction: UpdateTransaction) throws {
        let url = fileURL(for: transaction)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for transaction: UpdateTransaction) -> URL { directoryURL.appendingPathComponent("\(transaction.id.uuidString).json") }
}
