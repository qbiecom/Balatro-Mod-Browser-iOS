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
    private let deletionRecoveryStore = DeletionRecoveryStore()

    init(downloadSession: TrustedDownloadSession = TrustedDownloadSession()) {
        self.downloadSession = downloadSession
    }

    struct ScanResult {
        let enabled: [InstalledMod]
        let disabled: [InstalledMod]
        let folderNames: Set<String>
    }

    func scan(
        modsFolderURL: URL,
        gameFolderID: String,
        legacyGameFolderIDs: Set<String> = []
    ) throws -> ScanResult {
        try Task.checkCancellation()
        do {
            let values = try modsFolderURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
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
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ModFileServiceError.folderAccess(modsFolderURL)
        }
        let mods = entries
        .filter {
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        .filter { $0.lastPathComponent.caseInsensitiveCompare("lovely") != .orderedSame }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { InstalledMod(id: $0, name: $0.lastPathComponent) }
        try Task.checkCancellation()

        let enabled = mods.filter { !fileManager.fileExists(atPath: $0.id.appendingPathComponent(".lovelyignore").path) }
        let disabled = mods.filter { fileManager.fileExists(atPath: $0.id.appendingPathComponent(".lovelyignore").path) }
        let existingPaths = Set(mods.map { $0.id.standardizedFileURL.path.lowercased() })
        try registry.migrateRecords(
            from: legacyGameFolderIDs,
            to: gameFolderID,
            existingPaths: existingPaths
        )
        try registry.reconcile(
            gameFolderID: gameFolderID,
            existingPaths: existingPaths
        )
        return ScanResult(
            enabled: enabled,
            disabled: disabled,
            folderNames: Set(mods.map { $0.name.lowercased() })
        )
    }

    func setEnabled(_ enabled: Bool, modURL: URL, modsFolderURL: URL, gameFolderID: String) throws {
        try Task.checkCancellation()
        let modsFolderIdentity = try verifiedModsFolderIdentity(modsFolderURL: modsFolderURL, expectedGameFolderID: gameFolderID)
        let validatedModURL = try validatedImmediateModChild(modURL, in: modsFolderURL)
        let ignoreURL = validatedModURL.appendingPathComponent(".lovelyignore")
        let previousMarker = fileManager.fileExists(atPath: ignoreURL.path)
            ? try Data(contentsOf: ignoreURL)
            : nil

        do {
            try Task.checkCancellation()
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            _ = try validatedImmediateModChild(validatedModURL, in: modsFolderURL)
            if enabled {
                if previousMarker != nil { try fileManager.removeItem(at: ignoreURL) }
            } else {
                try Data().write(to: ignoreURL, options: .atomic)
            }

            guard fileManager.fileExists(atPath: ignoreURL.path) == !enabled else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            if let previousMarker {
                try? previousMarker.write(to: ignoreURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: ignoreURL)
            }
            throw error
        }
    }

    func delete(mod: InstalledMod, gameFolderID: String) throws {
        try Task.checkCancellation()
        let modsFolderURL = mod.id.deletingLastPathComponent()
        let modsFolderIdentity = try verifiedModsFolderIdentity(modsFolderURL: modsFolderURL, expectedGameFolderID: gameFolderID)
        let modURL = try validatedImmediateModChild(mod.id, in: modsFolderURL)
        let normalizedPath = modURL.standardizedFileURL.path.lowercased()
        let record = try registry.record(gameFolderID: gameFolderID, modPath: normalizedPath)
        let stableDependents = try registry.dependents(
            of: InstalledModDependencyReference(
                catalogID: record?.catalogID,
                normalizedInstalledPath: nil
            ),
            in: gameFolderID
        )
        let legacyDependents = try registry.dependents(of: mod.name, in: gameFolderID)
        let dependents = Dictionary(
            (stableDependents + legacyDependents).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        guard dependents.isEmpty else {
            throw ModFileServiceError.hasDependents(dependents.map(\.name))
        }
        let temporaryURL = try containedChildURL(named: ".deleting_\(UUID().uuidString)", in: modsFolderURL)
        var transaction = DeletionTransaction(
            gameFolderID: gameFolderID,
            modsFolderPath: modsFolderURL.standardizedFileURL.path,
            modsFolderIdentity: modsFolderIdentity,
            modPath: modURL.path,
            temporaryPath: temporaryURL.path,
            record: record,
            phase: .prepared
        )
        try deletionRecoveryStore.save(transaction)
        do {
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            try fileManager.moveItem(at: modURL, to: temporaryURL)
            transaction.phase = .moved
            try deletionRecoveryStore.save(transaction)
            try Task.checkCancellation()
            transaction.phase = .committing
            try deletionRecoveryStore.save(transaction)
            try registry.remove(gameFolderID: gameFolderID, modPath: normalizedPath)
            transaction.phase = .committed
            try deletionRecoveryStore.save(transaction)
            try Task.checkCancellation()
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            try fileManager.removeItem(at: temporaryURL)
            try deletionRecoveryStore.remove(transaction)
        } catch {
            if transaction.phase != .committing && transaction.phase != .committed {
                try? rollbackDeletion(&transaction, modURL: modURL, temporaryURL: temporaryURL)
            }
            throw error
        }
    }

    func updateRecords(for mods: [InstalledMod], gameFolderID: String) throws -> [InstalledModRecord] {
        try mods.compactMap { try registry.record(gameFolderID: gameFolderID, modPath: $0.id.standardizedFileURL.path.lowercased()) }
    }

    func recoverInterruptedUpdates(
        modsFolderURL: URL,
        gameFolderID: String,
        legacyGameFolderIDs: Set<String> = []
    ) {
        guard !Task.isCancelled,
              let modsFolderIdentity = try? verifiedModsFolderIdentity(modsFolderURL: modsFolderURL, expectedGameFolderID: gameFolderID) else { return }
        let acceptedFolderIDs = legacyGameFolderIDs.union([gameFolderID])
        for storedTransaction in recoveryStore.load() where acceptedFolderIDs.contains(storedTransaction.gameFolderID) {
            var transaction = storedTransaction
            if transaction.gameFolderID != gameFolderID {
                transaction = transaction.replacingGameFolderID(with: gameFolderID)
                try? recoveryStore.save(transaction)
            }
            let destinationURL = URL(fileURLWithPath: transaction.destinationPath)
            let backupURL = URL(fileURLWithPath: transaction.backupPath)
            do {
                try Task.checkCancellation()
                guard (transaction.modsFolderIdentity.isEmpty || transaction.modsFolderIdentity == modsFolderIdentity),
                      transaction.modsFolderPath == modsFolderURL.standardizedFileURL.path else { continue }
                try validateTransactionPaths(destinationURL: destinationURL, backupURL: backupURL, modsFolderURL: modsFolderURL)
                try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
                if transaction.phase.isCommit {
                    guard fileManager.fileExists(atPath: destinationURL.path) else { continue }
                    try registry.add(transaction.replacementRecord)
                    try Task.checkCancellation()
                    if fileManager.fileExists(atPath: backupURL.path) { try fileManager.removeItem(at: backupURL) }
                } else {
                    var pending = transaction
                    try rollbackUpdate(&pending, destinationURL: destinationURL)
                    continue
                }
                try recoveryStore.remove(transaction)
            } catch is CancellationError { return }
            catch { continue }
        }
        recoverInterruptedDeletions(
            modsFolderURL: modsFolderURL,
            gameFolderID: gameFolderID,
            legacyGameFolderIDs: legacyGameFolderIDs,
            modsFolderIdentity: modsFolderIdentity
        )
    }

    // Retains source compatibility while old callers migrate to supplying their active Mods URL.
    func recoverInterruptedUpdates(gameFolderID: String) {
        let paths = Set(recoveryStore.load().filter { $0.gameFolderID == gameFolderID }.map(\.modsFolderPath))
            .union(deletionRecoveryStore.load().filter { $0.gameFolderID == gameFolderID }.map(\.modsFolderPath))
        for path in paths {
            guard !Task.isCancelled else { return }
            recoverInterruptedUpdates(modsFolderURL: URL(fileURLWithPath: path, isDirectory: true), gameFolderID: gameFolderID)
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
        let modsFolderIdentity = try verifiedModsFolderIdentity(modsFolderURL: modsFolderURL, expectedGameFolderID: gameFolderID)
        guard try isZIPArchive(at: archiveURL) else { throw ModInstallError.unsupportedArchive }

        let stagingURL = modsFolderURL.appendingPathComponent(".staging_\(UUID().uuidString)", isDirectory: true)
        try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try extractZIPArchive(at: archiveURL, to: stagingURL, mutationCheck: {
            try self.revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
        })
        try Task.checkCancellation()

        let entries = try fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let hasRootFiles = entries.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        let sourceURL = folders.count == 1 && !hasRootFiles ? folders[0] : stagingURL
        let wasDisabled = replacementModURL != nil && fileManager.fileExists(atPath: destinationURL.appendingPathComponent(".lovelyignore").path)
        var transaction: UpdateTransaction?
        if fileManager.fileExists(atPath: destinationURL.path) {
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            guard replacementModURL != nil else { throw ModInstallError.alreadyInstalled }
            let backupsURL = modsFolderURL.appendingPathComponent(".BMM Backups", isDirectory: true)
            try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
            let backupURL = try containedChildURL(named: "\(folderName)-\(UUID().uuidString)", in: backupsURL)
            let normalizedPath = destinationURL.standardizedFileURL.path.lowercased()
            let originalRecord = try registry.record(gameFolderID: gameFolderID, modPath: normalizedPath) ?? InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: normalizedPath, dependencies: [], currentVersion: nil, orphaned: false, catalogID: nil)
            let replacementRecord = InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: normalizedPath, dependencies: dependencies, currentVersion: mod.version, orphaned: false, catalogID: mod.id)
            var pending = UpdateTransaction(gameFolderID: gameFolderID, modsFolderPath: modsFolderURL.standardizedFileURL.path, modsFolderIdentity: modsFolderIdentity, destinationPath: destinationURL.path, backupPath: backupURL.path, replacementRecord: replacementRecord, originalRecord: originalRecord, phase: .prepared)
            try validateTransactionPaths(destinationURL: destinationURL, backupURL: backupURL, modsFolderURL: modsFolderURL)
            try recoveryStore.save(pending)
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            pending.phase = .originalMoved
            try recoveryStore.save(pending)
            transaction = pending
        }
        do {
            try Task.checkCancellation()
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            if wasDisabled { try Data().write(to: destinationURL.appendingPathComponent(".lovelyignore"), options: .atomic) }
            if var pending = transaction {
                pending.phase = .replacementMoved
                try recoveryStore.save(pending)
                transaction = pending
            }
        } catch {
            if var pending = transaction { try? rollbackUpdate(&pending, destinationURL: destinationURL) }
            throw error
        }
        let record = InstalledModRecord(gameFolderID: gameFolderID, name: folderName, path: destinationURL.path, normalizedModPath: destinationURL.standardizedFileURL.path.lowercased(), dependencies: dependencies, currentVersion: mod.version, orphaned: false, catalogID: mod.id)
        do {
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
            if var pending = transaction {
                pending.phase = .committing
                try recoveryStore.save(pending)
                transaction = pending
            }
            try registry.add(record)
            if var pending = transaction {
                pending.phase = .committed
                try recoveryStore.save(pending)
                transaction = pending
            }
        } catch {
            if var pending = transaction, !pending.phase.isCommit {
                try? rollbackUpdate(&pending, destinationURL: destinationURL)
            }
            throw error
        }
        if let transaction {
            try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
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
    private func extractZIPArchive(at archiveURL: URL, to destinationURL: URL, mutationCheck: () throws -> Void) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var count = 0; var size: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let (nextCount, countOverflow) = count.addingReportingOverflow(1)
            guard !countOverflow, nextCount <= Self.maximumArchiveFileCount else { throw ModInstallError.tooManyArchiveFiles }
            count = nextCount
            guard entry.uncompressedSize <= Self.maximumArchiveEntrySize else { throw ModInstallError.archiveTooLarge }
            let (nextSize, sizeOverflow) = size.addingReportingOverflow(entry.uncompressedSize)
            guard !sizeOverflow, nextSize <= Self.maximumArchiveUncompressedSize else { throw ModInstallError.archiveTooLarge }
            size = nextSize
            _ = try safeArchiveOutputURL(for: entry.path, in: destinationURL)
        }
        let available = try destinationURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard available == nil || available! >= Int64(size) else { throw ModInstallError.insufficientStorage }
        for entry in archive {
            try Task.checkCancellation()
            try mutationCheck()
            let output = try safeArchiveOutputURL(for: entry.path, in: destinationURL)
            switch entry.type { case .directory: try fileManager.createDirectory(at: output, withIntermediateDirectories: true); case .file: try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true); _ = try archive.extract(entry, to: output, bufferSize: 64 * 1024); case .symlink: throw ModInstallError.unsafeArchive; @unknown default: throw ModInstallError.unsafeArchive }
        }
    }
    private func safeArchiveOutputURL(for path: String, in destination: URL) throws -> URL { let components = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", omittingEmptySubsequences: true); guard !components.isEmpty else { return destination }; guard components.count <= Self.maximumArchivePathDepth, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else { throw ModInstallError.unsafeArchive }; return components.reduce(destination) { $0.appendingPathComponent(String($1), isDirectory: false) } }
    private func validatedInstallFolderName(for mod: CatalogMod) throws -> String { let name = (mod.folderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? mod.folderName! : mod.id).trimmingCharacters(in: .whitespacesAndNewlines); let reserved: Set<String> = [".", "..", "mods", "disabled mods", ".bmm backups", "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]; let device = name.split(separator: ".", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""; guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains(":"), name.rangeOfCharacter(from: .controlCharacters) == nil, !reserved.contains(name.lowercased()), !reserved.contains(device) else { throw ModInstallError.unsafeFolderName }; return name }
    private func containedChildURL(named name: String, in rootURL: URL) throws -> URL { let root = rootURL.standardizedFileURL; let child = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL; guard child.deletingLastPathComponent().path == root.path, child.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { throw ModInstallError.unsafeFolderName }; return child }
    private func validatedImmediateModChild(_ url: URL, in modsFolderURL: URL) throws -> URL { let destination = url.standardizedFileURL; let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]); guard destination.deletingLastPathComponent() == modsFolderURL.standardizedFileURL, destination.resolvingSymlinksInPath().deletingLastPathComponent() == modsFolderURL.resolvingSymlinksInPath(), values?.isDirectory == true, values?.isSymbolicLink != true else { throw ModInstallError.invalidUpdateTarget }; return destination }
    private func verifiedModsFolderIdentity(modsFolderURL: URL, expectedGameFolderID: String) throws -> String {
        guard !expectedGameFolderID.isEmpty else { throw ModInstallError.invalidUpdateTarget }
        let values = try modsFolderURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, let identifier = values.fileResourceIdentifier else { throw ModInstallError.invalidUpdateTarget }
        return String(describing: identifier)
    }
    private func revalidateMutationRoot(_ modsFolderURL: URL, identity: String, gameFolderID: String) throws {
        guard try verifiedModsFolderIdentity(modsFolderURL: modsFolderURL, expectedGameFolderID: gameFolderID) == identity else { throw ModInstallError.invalidUpdateTarget }
    }
    private func validateTransactionPaths(destinationURL: URL, backupURL: URL, modsFolderURL: URL) throws {
        let root = modsFolderURL.standardizedFileURL
        let backups = try containedChildURL(named: ".BMM Backups", in: root)
        guard destinationURL.standardizedFileURL.deletingLastPathComponent() == root,
              destinationURL.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              backupURL.standardizedFileURL.deletingLastPathComponent() == backups,
              backupURL.resolvingSymlinksInPath().deletingLastPathComponent() == backups.resolvingSymlinksInPath() else { throw ModInstallError.invalidUpdateTarget }
        if fileManager.fileExists(atPath: destinationURL.path) {
            let values = try destinationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModInstallError.invalidUpdateTarget }
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            let values = try backupURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModInstallError.invalidUpdateTarget }
        }
    }
    private func recoverInterruptedDeletions(
        modsFolderURL: URL,
        gameFolderID: String,
        legacyGameFolderIDs: Set<String>,
        modsFolderIdentity: String
    ) {
        let acceptedFolderIDs = legacyGameFolderIDs.union([gameFolderID])
        for storedTransaction in deletionRecoveryStore.load() where acceptedFolderIDs.contains(storedTransaction.gameFolderID) {
            var transaction = storedTransaction
            if transaction.gameFolderID != gameFolderID {
                transaction = transaction.replacingGameFolderID(with: gameFolderID)
                try? deletionRecoveryStore.save(transaction)
            }
            let modURL = URL(fileURLWithPath: transaction.modPath)
            let temporaryURL = URL(fileURLWithPath: transaction.temporaryPath)
            do {
                try Task.checkCancellation()
                guard transaction.modsFolderPath == modsFolderURL.standardizedFileURL.path,
                      (transaction.modsFolderIdentity.isEmpty || transaction.modsFolderIdentity == modsFolderIdentity),
                      modURL.standardizedFileURL.deletingLastPathComponent() == modsFolderURL.standardizedFileURL,
                      temporaryURL.standardizedFileURL.deletingLastPathComponent() == modsFolderURL.standardizedFileURL,
                      modURL.resolvingSymlinksInPath().deletingLastPathComponent() == modsFolderURL.resolvingSymlinksInPath(),
                      temporaryURL.resolvingSymlinksInPath().deletingLastPathComponent() == modsFolderURL.resolvingSymlinksInPath() else { continue }
                try revalidateMutationRoot(modsFolderURL, identity: modsFolderIdentity, gameFolderID: gameFolderID)
                if transaction.phase.isCommit {
                    try registry.remove(gameFolderID: gameFolderID, modPath: modURL.standardizedFileURL.path.lowercased())
                    try Task.checkCancellation()
                    if fileManager.fileExists(atPath: modURL.path) { try fileManager.removeItem(at: modURL) }
                    try Task.checkCancellation()
                    if fileManager.fileExists(atPath: temporaryURL.path) { try fileManager.removeItem(at: temporaryURL) }
                    try deletionRecoveryStore.remove(transaction)
                } else {
                    var pending = transaction
                    try rollbackDeletion(&pending, modURL: modURL, temporaryURL: temporaryURL)
                }
            } catch is CancellationError { return }
            catch { continue }
        }
    }
    private func rollbackUpdate(_ transaction: inout UpdateTransaction, destinationURL: URL) throws {
        let backupURL = URL(fileURLWithPath: transaction.backupPath)
        if !transaction.phase.isRollback {
            transaction.phase = .rollingBack
            try recoveryStore.save(transaction)
        }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path), fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        transaction.phase = .rollbackDestinationRemoved
        try recoveryStore.save(transaction)
        try Task.checkCancellation()
        if !fileManager.fileExists(atPath: destinationURL.path), fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.moveItem(at: backupURL, to: destinationURL)
        }
        transaction.phase = .rollbackOriginalRestored
        try recoveryStore.save(transaction)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            try registry.add(transaction.originalRecord)
        } else {
            try registry.remove(gameFolderID: transaction.gameFolderID, modPath: transaction.originalRecord.normalizedModPath)
        }
        transaction.phase = .rollbackRegistryRestored
        try recoveryStore.save(transaction)
        try recoveryStore.remove(transaction)
    }

    private func rollbackDeletion(_ transaction: inout DeletionTransaction, modURL: URL, temporaryURL: URL) throws {
        if !transaction.phase.isRollback {
            transaction.phase = .rollingBack
            try deletionRecoveryStore.save(transaction)
        }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: modURL.path), fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        } else if !fileManager.fileExists(atPath: modURL.path), fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.moveItem(at: temporaryURL, to: modURL)
        }
        transaction.phase = .rollbackFileRestored
        try deletionRecoveryStore.save(transaction)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: modURL.path), let record = transaction.record {
            try registry.add(record)
        } else {
            try registry.remove(gameFolderID: transaction.gameFolderID, modPath: modURL.standardizedFileURL.path.lowercased())
        }
        transaction.phase = .rollbackRegistryRestored
        try deletionRecoveryStore.save(transaction)
        try deletionRecoveryStore.remove(transaction)
    }
}

enum ModFileServiceError: LocalizedError {
    case hasDependents([String])
    case folderAccess(URL)

    var errorDescription: String? {
        switch self {
        case let .hasDependents(names):
            "This mod is required by: \(names.joined(separator: ", ")). Remove those mods first."
        case .folderAccess:
            "Balatro Mod Browser could not read this game's Mods folder. Re-select the game folder to restore access; installed mods have not been changed."
        }
    }
}

nonisolated private enum UpdateTransactionPhase: String, Codable {
    case prepared, originalMoved, replacementMoved, registryUpdated
    case committing, committed
    case rollingBack, rollbackDestinationRemoved, rollbackOriginalRestored, rollbackRegistryRestored

    var isCommit: Bool { self == .registryUpdated || self == .committing || self == .committed }
    var isRollback: Bool { self == .rollingBack || self == .rollbackDestinationRemoved || self == .rollbackOriginalRestored || self == .rollbackRegistryRestored }
}

nonisolated private struct UpdateTransaction: Codable, Identifiable {
    let id: UUID
    let gameFolderID: String
    let modsFolderPath: String
    let modsFolderIdentity: String
    let destinationPath: String
    let backupPath: String
    let replacementRecord: InstalledModRecord
    let originalRecord: InstalledModRecord
    var phase: UpdateTransactionPhase

    private enum CodingKeys: String, CodingKey {
        case id, gameFolderID, modsFolderPath, modsFolderIdentity, destinationPath, backupPath
        case replacementRecord, originalRecord, phase
    }

    init(gameFolderID: String, modsFolderPath: String, modsFolderIdentity: String, destinationPath: String, backupPath: String, replacementRecord: InstalledModRecord, originalRecord: InstalledModRecord, phase: UpdateTransactionPhase) {
        id = UUID()
        self.gameFolderID = gameFolderID
        self.modsFolderPath = modsFolderPath
        self.modsFolderIdentity = modsFolderIdentity
        self.destinationPath = destinationPath
        self.backupPath = backupPath
        self.replacementRecord = replacementRecord
        self.originalRecord = originalRecord
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        destinationPath = try values.decode(String.self, forKey: .destinationPath)
        backupPath = try values.decode(String.self, forKey: .backupPath)
        replacementRecord = try values.decode(InstalledModRecord.self, forKey: .replacementRecord)
        originalRecord = try values.decode(InstalledModRecord.self, forKey: .originalRecord)
        gameFolderID = try values.decodeIfPresent(String.self, forKey: .gameFolderID)
            ?? replacementRecord.gameFolderID
        modsFolderPath = try values.decodeIfPresent(String.self, forKey: .modsFolderPath)
            ?? URL(fileURLWithPath: destinationPath).deletingLastPathComponent().standardizedFileURL.path
        modsFolderIdentity = try values.decodeIfPresent(String.self, forKey: .modsFolderIdentity) ?? ""
        phase = try values.decodeIfPresent(UpdateTransactionPhase.self, forKey: .phase) ?? .originalMoved
    }

    func replacingGameFolderID(with gameFolderID: String) -> UpdateTransaction {
        UpdateTransaction(
            id: id,
            gameFolderID: gameFolderID,
            modsFolderPath: modsFolderPath,
            modsFolderIdentity: modsFolderIdentity,
            destinationPath: destinationPath,
            backupPath: backupPath,
            replacementRecord: replacementRecord.replacingGameFolderID(with: gameFolderID),
            originalRecord: originalRecord.replacingGameFolderID(with: gameFolderID),
            phase: phase
        )
    }

    private init(id: UUID, gameFolderID: String, modsFolderPath: String, modsFolderIdentity: String, destinationPath: String, backupPath: String, replacementRecord: InstalledModRecord, originalRecord: InstalledModRecord, phase: UpdateTransactionPhase) {
        self.id = id
        self.gameFolderID = gameFolderID
        self.modsFolderPath = modsFolderPath
        self.modsFolderIdentity = modsFolderIdentity
        self.destinationPath = destinationPath
        self.backupPath = backupPath
        self.replacementRecord = replacementRecord
        self.originalRecord = originalRecord
        self.phase = phase
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

nonisolated private enum DeletionTransactionPhase: String, Codable {
    case prepared, moved, registryRemoved
    case committing, committed
    case rollingBack, rollbackFileRestored, rollbackRegistryRestored

    var isCommit: Bool { self == .registryRemoved || self == .committing || self == .committed }
    var isRollback: Bool { self == .rollingBack || self == .rollbackFileRestored || self == .rollbackRegistryRestored }
}

nonisolated private struct DeletionTransaction: Codable, Identifiable {
    let id: UUID
    let gameFolderID: String
    let modsFolderPath: String
    let modsFolderIdentity: String
    let modPath: String
    let temporaryPath: String
    let record: InstalledModRecord?
    var phase: DeletionTransactionPhase

    private enum CodingKeys: String, CodingKey {
        case id, gameFolderID, modsFolderPath, modsFolderIdentity, modPath, temporaryPath, record, phase
    }

    init(gameFolderID: String, modsFolderPath: String, modsFolderIdentity: String, modPath: String, temporaryPath: String, record: InstalledModRecord?, phase: DeletionTransactionPhase) {
        id = UUID()
        self.gameFolderID = gameFolderID
        self.modsFolderPath = modsFolderPath
        self.modsFolderIdentity = modsFolderIdentity
        self.modPath = modPath
        self.temporaryPath = temporaryPath
        self.record = record
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        modPath = try values.decode(String.self, forKey: .modPath)
        temporaryPath = try values.decode(String.self, forKey: .temporaryPath)
        record = try values.decodeIfPresent(InstalledModRecord.self, forKey: .record)
        gameFolderID = try values.decodeIfPresent(String.self, forKey: .gameFolderID)
            ?? record?.gameFolderID
            ?? ""
        modsFolderPath = try values.decodeIfPresent(String.self, forKey: .modsFolderPath)
            ?? URL(fileURLWithPath: modPath).deletingLastPathComponent().standardizedFileURL.path
        modsFolderIdentity = try values.decodeIfPresent(String.self, forKey: .modsFolderIdentity) ?? ""
        phase = try values.decodeIfPresent(DeletionTransactionPhase.self, forKey: .phase) ?? .moved
    }

    func replacingGameFolderID(with gameFolderID: String) -> DeletionTransaction {
        DeletionTransaction(
            id: id,
            gameFolderID: gameFolderID,
            modsFolderPath: modsFolderPath,
            modsFolderIdentity: modsFolderIdentity,
            modPath: modPath,
            temporaryPath: temporaryPath,
            record: record?.replacingGameFolderID(with: gameFolderID),
            phase: phase
        )
    }

    private init(id: UUID, gameFolderID: String, modsFolderPath: String, modsFolderIdentity: String, modPath: String, temporaryPath: String, record: InstalledModRecord?, phase: DeletionTransactionPhase) {
        self.id = id
        self.gameFolderID = gameFolderID
        self.modsFolderPath = modsFolderPath
        self.modsFolderIdentity = modsFolderIdentity
        self.modPath = modPath
        self.temporaryPath = temporaryPath
        self.record = record
        self.phase = phase
    }
}

nonisolated private final class DeletionRecoveryStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BMM Mobile", isDirectory: true)
            .appendingPathComponent("deletion-transactions", isDirectory: true)
    }

    func load() -> [DeletionTransaction] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DeletionTransaction.self, from: data)
        }
    }

    func save(_ transaction: DeletionTransaction) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(transaction).write(to: fileURL(for: transaction), options: .atomic)
    }

    func remove(_ transaction: DeletionTransaction) throws {
        let url = fileURL(for: transaction)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for transaction: DeletionTransaction) -> URL { directoryURL.appendingPathComponent("\(transaction.id.uuidString).json") }
}
