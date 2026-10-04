import Combine
import Foundation

@MainActor
final class ModFolderStore: ObservableObject {
    enum InstallerAvailability: Equatable {
        case available
        case noGameFolder
        case noModsFolder
        case busy

        var message: String {
            switch self {
            case .available: "Ready to install mods."
            case .noGameFolder: "Choose a Lovely Mobile Maker game folder before installing mods."
            case .noModsFolder: "This game folder has no accessible Mods directory. Launch Lovely Mobile Maker's Balatro once, then re-select the game folder."
            case .busy: "Another install or update is in progress."
            }
        }
    }
    @Published private(set) var gameFolderURL: URL?
    @Published private(set) var enabledMods: [InstalledMod] = []
    @Published private(set) var disabledMods: [InstalledMod] = []
    @Published private(set) var installedFolderNames: Set<String> = []
    @Published private(set) var updateAvailableNames: Set<String> = []
    @Published private(set) var catalogItems: [CatalogMod] = []
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var installingModIDs: Set<String> = []
    @Published private(set) var installingModName: String?
    @Published private(set) var isFolderOperationBusy = false
    @Published var dependencyInstallRequest: DependencyInstallRequest?
    @Published private(set) var needsGameFolderRelink = false
    @Published var isShowingGameFolderRelinkNotice = false
    @Published var isShowingError = false
    @Published private(set) var errorMessage = ""
    @Published var isShowingCatalogInfo = false
    @Published private(set) var catalogInfoMessage = ""

    private let bookmarkKey = "gameFolderBookmark"
    private let folderIdentityKey = "gameFolderIdentity"
    private let pendingRelinkIdentityKey = "pendingGameFolderRelinkIdentity"
    private let catalogFileCache = CatalogFileCache()
    private let downloadSession = TrustedDownloadSession()
    private lazy var githubCatalog = GitHubCatalogService(session: downloadSession)
    private lazy var fileService = ModFileService(downloadSession: downloadSession)
    private let catalogCacheLifetime: TimeInterval = 60 * 15
    private let detailCacheLifetime: TimeInterval = 60 * 60 * 48
    private var activeGameFolderURL: URL?
    private var catalogMods: [String: CatalogMod] = [:]
    private var catalogNameAliases: [String: String] = [:]
    private var catalogFolderAliases: [String: String] = [:]
    private var installedCatalogIDsByPath: [String: String] = [:]
    private var sourceRevision: String?
    private var sourceFileHashes: [String: String] = [:]
    private var catalogRefreshedAt: Date?
    private var detailCache: [String: DetailCacheEntry] = [:]
    private var refreshTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var detailTasks: [String: Task<CatalogMod?, Never>] = [:]
    private var scanTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var folderTransitionTask: Task<Void, Never>?
    private var modsFolderPresenter: ModsFolderPresenter?
    private var isApplicationActive = true
    private var installTask: Task<Void, Never>?
    private var gameFolderGeneration = 0
    private var catalogGeneration = 0
    private var cacheRevision = 0
    private var activeGameFolderID: String?
    private var activeFileResourceIdentifier: AnyHashable?
    private var legacyGameFolderIDs: Set<String> = []
    private lazy var cacheLoadTask: Task<Void, Never> = Task { [weak self] in
        guard let self, let snapshot = try? await self.catalogFileCache.load(), self.cacheRevision == 0 else { return }
        self.catalogMods = self.indexed(Array(snapshot.records.values))
        self.detailCache = snapshot.details
        self.sourceRevision = snapshot.sourceRevision
        self.sourceFileHashes = snapshot.sourceFileHashes ?? [:]
        self.catalogRefreshedAt = snapshot.catalogRefreshedAt
        self.rebuildCatalogAliases()
        self.applyCachedDetailsToCatalog()
        self.catalogItems = self.uniqueCatalogItems(from: self.catalogMods)
    }

    private var modsFolderURL: URL? {
        guard let gameFolderURL else { return nil }
        return existingModsFolderURL(in: gameFolderURL)
    }

    private var gameFolderID: String? {
        activeGameFolderID
    }

    /// Migration seam for ModFileService registry lookup. Its scan/recovery APIs should accept
    /// `legacyGameFolderIDs: Set<String>` and re-key the first matching legacy registry to
    /// `gameFolderID`; legacy IDs must never become the identity of new writes.
    var legacyFolderIdentifiersForRegistryMigration: Set<String> { legacyGameFolderIDs }

    var totalModCount: Int { enabledMods.count + disabledMods.count }
    var lastCatalogRefresh: Date? { catalogRefreshedAt }
    var installerAvailability: InstallerAvailability {
        if gameFolderURL == nil { return .noGameFolder }
        if isFolderOperationBusy || folderTransitionTask != nil || recoveryTask != nil { return .busy }
        if modsFolderURL == nil { return .noModsFolder }
        return .available
    }
    var isInstallerAvailable: Bool { installerAvailability == .available }

    /// Starts cache loading immediately, then attempts to restore the last security-scoped game folder.
    init() {
        _ = cacheLoadTask
        restoreFolderAccess()
    }

    isolated deinit {
        refreshTask?.cancel()
        catalogRefreshTask?.cancel()
        detailTasks.values.forEach { $0.cancel() }
        scanTask?.cancel()
        recoveryTask?.cancel()
        updatesTask?.cancel()
        folderTransitionTask?.cancel()
        installTask?.cancel()
        if let modsFolderPresenter { NSFileCoordinator.removeFilePresenter(modsFolderPresenter) }
        activeGameFolderURL?.stopAccessingSecurityScopedResource()
    }

    /// Validates and begins activating a game folder returned by the system document picker.
    func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard !isFolderOperationBusy, folderTransitionTask == nil else {
            showError("Wait for the current install or update to finish before changing the game folder.")
            return
        }
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else {
            showError("iOS did not grant access to this folder. Please try selecting it again.")
            return
        }
        do {
            try gameFolderValidation(at: url)
            let relinkIdentity = needsGameFolderRelink
                ? UserDefaults.standard.string(forKey: pendingRelinkIdentityKey)
                : nil
            beginActivatingGameFolder(at: url, identity: relinkIdentity)
        } catch {
            url.stopAccessingSecurityScopedResource()
            showError(error.localizedDescription)
        }
    }

    /// Toggles Lovely's per-folder ignore marker through the serialized file service.
    func setEnabled(_ enabled: Bool, for mod: InstalledMod) {
        guard let modsFolderURL, let gameFolderID else { return }
        guard reserveFolderOperation() else { return }
        startInstallTask {
            do {
                try await self.fileService.setEnabled(enabled, modURL: mod.id, modsFolderURL: modsFolderURL, gameFolderID: gameFolderID)
                self.refreshMods()
            } catch is CancellationError {
                return
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    /// Deletes an installed mod after the file service confirms no other managed mod depends on it.
    func delete(_ mod: InstalledMod) {
        guard let gameFolderID else { return }
        guard reserveFolderOperation() else { return }
        startInstallTask {
            do {
                try await self.fileService.delete(mod: mod, gameFolderID: gameFolderID)
                self.refreshMods()
            } catch is CancellationError {
                return
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    /// Combines local folder state with any matching BMI record for installed-mod UI.
    func presentation(for mod: InstalledMod) -> ModPresentation {
        let catalogMod = catalogMod(forInstalledMod: mod)
        let summary = catalogMod?.cleanedSummary

        return ModPresentation(
            title: catalogMod?.name ?? mod.name,
            description: summary?.isEmpty == false ? summary! : "Local mod folder",
            author: catalogMod?.author,
            version: catalogMod?.version,
            categories: catalogMod?.categories ?? [],
            repositoryURL: catalogMod?.websiteURL,
            thumbnailURL: catalogMod?.thumbnailURL,
            requiresSteamodded: catalogMod?.requiresSteamodded ?? false,
            requiresTalisman: catalogMod?.requiresTalisman ?? false,
            downloads: catalogMod?.downloads?.total,
            updatedAt: catalogMod?.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0.value)) },
            colors: catalogMod?.colors
        )
    }

    /// Looks up an installed mod by its normalized filesystem URL.
    func installedMod(id: URL) -> InstalledMod? {
        let path = id.standardizedFileURL.path.lowercased()
        return (enabledMods + disabledMods).first { $0.id.standardizedFileURL.path.lowercased() == path }
    }

    /// Reports whether the mod belongs to the scan result without a `.lovelyignore` marker.
    func isEnabled(_ mod: InstalledMod) -> Bool {
        enabledMods.contains { $0.id.standardizedFileURL.path.lowercased() == mod.id.standardizedFileURL.path.lowercased() }
    }

    /// Requests a catalog refresh that also bypasses the separate download-count cache.
    func forceRefreshCatalog() {
        startCatalogRefresh()
    }

    /// Invalidates catalog, detail, download, and thumbnail caches before fetching a clean BMI snapshot.
    func clearCatalogCache() {
        catalogGeneration += 1
        cacheRevision += 1
        let generation = catalogGeneration
        let revision = cacheRevision
        let oldRefreshTask = catalogRefreshTask
        let oldDetailTasks = Array(detailTasks.values)
        catalogRefreshTask = nil
        detailTasks = [:]
        oldRefreshTask?.cancel()
        oldDetailTasks.forEach { $0.cancel() }
        isLoadingCatalog = true
        ThumbnailCache.shared.invalidateAll()
        catalogMods = [:]
        catalogNameAliases = [:]
        catalogFolderAliases = [:]
        catalogItems = []
        sourceRevision = nil
        sourceFileHashes = [:]
        catalogRefreshedAt = nil
        detailCache = [:]
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await cacheLoadTask.value
            await oldRefreshTask?.value
            for task in oldDetailTasks { _ = await task.value }
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            try? await catalogFileCache.remove(revision: revision)
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            await fetchCatalog(generation: generation, managesLoadingState: false)
            guard generation == catalogGeneration else { return }
            isLoadingCatalog = false
            catalogRefreshTask = nil
        }
    }

    /// Resolves an installed folder to BMI before requesting its lazy full detail record.
    func loadDetail(for mod: InstalledMod) async {
        guard let catalogMod = catalogMod(forInstalledMod: mod) else { return }
        await loadDetail(for: catalogMod)
    }

    /// Convenience detail loader for views that retain only a stable folder URL.
    func loadDetail(forInstalledModID id: URL) async {
        guard let mod = installedMod(id: id) else { return }
        await loadDetail(for: mod)
    }

    /// Returns the catalog entry for BMI's case-insensitive stable identifier.
    func catalogMod(id: String) -> CatalogMod? {
        catalogMods[id.lowercased()]
    }

    /// Loads a full BMI record lazily, coalescing concurrent requests and retaining it for the detail-cache TTL.
    func loadDetail(for catalogMod: CatalogMod) async {
        let key = catalogMod.id.lowercased()
        let currentMod = catalogMods[key] ?? catalogMod
        if let cached = detailCache[key],
           Date().timeIntervalSince(cached.refreshedAt) < detailCacheLifetime,
           currentMod.canUseCachedDetail(cached.mod) {
            apply(currentMod.merged(with: cached.mod))
            return
        }

        if let task = detailTasks[key] {
            _ = await task.value
            return
        }
        let generation = catalogGeneration
        let fileHash = sourceFileHashes[key]
        let task = Task<CatalogMod?, Never> { [weak self] in
            guard let self else { return nil }
            return try? await fetchModDetail(id: catalogMod.id)
        }
        detailTasks[key] = task
        let detail = await task.value
        guard !Task.isCancelled, generation == catalogGeneration else { return }
        detailTasks[key] = nil
        guard let detail else { return }
        guard let current = catalogMods[key],
              sourceFileHashes[key] == fileHash,
              detail.id.caseInsensitiveCompare(current.id) == .orderedSame,
              (detail.updatedAt?.value ?? 0) >= (current.updatedAt?.value ?? 0) else { return }
        detailCache[key] = DetailCacheEntry(mod: detail, refreshedAt: Date())
        persistDetails(generation: generation)
        apply(current.merged(with: detail))
    }

    /// Determines installation through the same resilient matching used by catalog action buttons.
    func isInstalled(_ mod: CatalogMod) -> Bool {
        installedMod(for: mod) != nil
    }

    /// Identifies the Steamodded catalog record, whose development builds may be installed separately from BMI.
    func isSteamodded(_ mod: CatalogMod) -> Bool {
        mod.name?.normalizedDependencyName == "steamodded"
            || mod.id.normalizedDependencyName == "steamodded"
    }

    /// Resolves an installed folder before checking whether it is Steamodded.
    func isSteamodded(_ mod: InstalledMod) -> Bool {
        catalogMod(forInstalledMod: mod).map(isSteamodded) ?? false
    }

    /// Finds a local installation using registry IDs first, then resilient catalog and folder-name matching.
    func installedMod(for targetMod: CatalogMod) -> InstalledMod? {
        let candidates = enabledMods + disabledMods
        if let registryMatch = candidates.first(where: { mod in
            let path = mod.id.standardizedFileURL.path.lowercased()
            return installedCatalogIDsByPath[path]?.caseInsensitiveCompare(targetMod.id) == .orderedSame
        }) {
            return registryMatch
        }

        if let catalogMatch = candidates.first(where: { mod in
            catalogMod(forInstalledMod: mod)?.id.caseInsensitiveCompare(targetMod.id) == .orderedSame
        }) {
            return catalogMatch
        }

        return candidates.first {
            $0.name.caseInsensitiveCompare(targetMod.installFolderName) == .orderedSame
        }
    }

    /// Reports whether this catalog item is the target of the active serialized install.
    func isInstalling(_ mod: CatalogMod) -> Bool {
        installingModIDs.contains(mod.id)
    }

    /// Begins installation after rejecting duplicate installs and concurrent file mutations.
    func install(_ mod: CatalogMod) {
        guard isInstallerAvailable else {
            showError(installerAvailability.message)
            return
        }
        guard !isInstalled(mod) else {
            showError("\(mod.name ?? mod.id) is already installed.")
            return
        }
        guard !isInstalling(mod), installingModIDs.isEmpty else {
            showError("Another install or update is already in progress.")
            return
        }

        beginInstall(mod, replacing: false)
    }

    /// Continues a deferred install after the user confirms its dependency plan or Talisman provider.
    func confirmDependencyInstall(talismanProvider: CatalogMod? = nil) {
        guard let request = dependencyInstallRequest else { return }
        dependencyInstallRequest = nil

        guard let graph = resolveDependencyGraph(for: request.mod, talismanProvider: talismanProvider) else {
            releaseFolderOperation()
            return
        }

        startInstallTask {
            for dependency in graph.order where !self.isInstalled(dependency) {
                guard await self.downloadAndInstall(dependency, dependencies: graph.directDependencies[dependency.id.lowercased()] ?? []) else { return }
            }
            _ = await self.downloadAndInstall(
                request.mod,
                replacing: request.replacing,
                dependencies: graph.directDependencies[request.mod.id.lowercased()] ?? [],
                replacementModURL: request.replacementModURL
            )
        }
    }

    /// Dismisses a pending dependency decision and releases the reserved file-operation slot.
    func cancelDependencyInstall() {
        dependencyInstallRequest = nil
        releaseFolderOperation()
    }

    /// Restores the persisted security-scoped bookmark, requesting a re-link if it is no longer usable.
    private func restoreFolderAccess() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        let storedIdentity = UserDefaults.standard.string(forKey: folderIdentityKey)
        var restoredURL: URL?

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            guard url.startAccessingSecurityScopedResource() else {
                markGameFolderForRelink(previousIdentity: storedIdentity)
                return
            }
            restoredURL = url

            try gameFolderValidation(at: url)

            if isStale {
                let refreshedBookmark = try url.bookmarkData(options: .minimalBookmark)
                UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
            }

            let identity = UserDefaults.standard.string(forKey: folderIdentityKey) ?? UUID().uuidString
            beginActivatingGameFolder(at: url, bookmark: nil, identity: identity)
        } catch {
            restoredURL?.stopAccessingSecurityScopedResource()
            markGameFolderForRelink(previousIdentity: storedIdentity)
        }
    }

    /// Clears an unusable bookmark while preserving its registry identity for a later folder re-link.
    private func markGameFolderForRelink(previousIdentity: String?) {
        if let previousIdentity, !previousIdentity.isEmpty {
            UserDefaults.standard.set(previousIdentity, forKey: pendingRelinkIdentityKey)
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderIdentityKey)
        needsGameFolderRelink = true
        isShowingGameFolderRelinkNotice = true
    }

    /// Captures a bookmark off the picker path and serializes the asynchronous folder transition.
    private func beginActivatingGameFolder(at url: URL, bookmark suppliedBookmark: Data? = nil, identity suppliedIdentity: String? = nil) {
        guard folderTransitionTask == nil else {
            url.stopAccessingSecurityScopedResource()
            showError("Wait for the current folder change to finish before choosing another folder.")
            return
        }

        folderTransitionTask = Task { [weak self] in
            guard let self else {
                url.stopAccessingSecurityScopedResource()
                return
            }
            do {
                let bookmark = try suppliedBookmark ?? url.bookmarkData(options: .minimalBookmark)
                await activateGameFolder(at: url, bookmark: bookmark, identity: suppliedIdentity ?? UUID().uuidString)
            } catch {
                url.stopAccessingSecurityScopedResource()
                showError(error.localizedDescription)
            }
            folderTransitionTask = nil
        }
    }

    /// Replaces the active folder safely, then reconnects observation, recovery, scanning, and catalog refresh.
    private func activateGameFolder(at url: URL, bookmark: Data?, identity: String) async {
        let resourceIdentifier = fileResourceIdentifier(for: url)
        if activeGameFolderURL?.standardizedFileURL == url.standardizedFileURL,
           activeFileResourceIdentifier == resourceIdentifier {
            url.stopAccessingSecurityScopedResource()
            return
        }

        await stopAccessingCurrentFolder()
        guard !Task.isCancelled else {
            url.stopAccessingSecurityScopedResource()
            return
        }
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: bookmarkKey) }
        UserDefaults.standard.set(identity, forKey: folderIdentityKey)
        UserDefaults.standard.removeObject(forKey: pendingRelinkIdentityKey)
        needsGameFolderRelink = false
        isShowingGameFolderRelinkNotice = false
        legacyGameFolderIDs = legacyFolderIdentifiers(for: url)
        activeGameFolderID = identity
        activeFileResourceIdentifier = resourceIdentifier
        activeGameFolderURL = url
        gameFolderURL = url
        observeModsFolder()
        recoverInterruptedUpdates()
        refreshMods()
        refreshCatalogIfNeeded()
    }

    /// Ensures the user selected Lovely Mobile Maker's `game` directory, not a parent or Mods itself.
    private func gameFolderValidation(at url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues.isDirectory == true else {
            throw GameFolderError.notDirectory
        }

        guard url.lastPathComponent.caseInsensitiveCompare("game") == .orderedSame else {
            throw GameFolderError.invalidLayout
        }
    }

    /// Finds an existing Mods directory case-insensitively without creating application-owned folders.
    private func existingModsFolderURL(in gameFolderURL: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: gameFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first { child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return child.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame
                && values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// Re-scans the Mods directory and rebuilds UI state and registry-to-catalog associations.
    private func refreshMods() {
        guard isApplicationActive, !isFolderOperationBusy, recoveryTask == nil,
              let modsFolderURL, let gameFolderID else { return }
        let generation = gameFolderGeneration
        let previousTask = scanTask
        scanTask = Task { [weak self] in
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled, let self else { return }
            do {
                let result = try await fileService.scan(
                    modsFolderURL: modsFolderURL,
                    gameFolderID: gameFolderID,
                    legacyGameFolderIDs: legacyGameFolderIDs
                )
                guard !Task.isCancelled, generation == gameFolderGeneration else { return }
                enabledMods = result.enabled
                disabledMods = result.disabled
                installedFolderNames = result.folderNames
                let installedMods = result.enabled + result.disabled
                let records = try await fileService.updateRecords(for: installedMods, gameFolderID: gameFolderID)
                guard !Task.isCancelled, generation == gameFolderGeneration else { return }
                installedCatalogIDsByPath = Dictionary(
                    uniqueKeysWithValues: records.compactMap { record in
                        guard let catalogID = record.catalogID, !catalogID.isEmpty else { return nil }
                        return (record.normalizedModPath, catalogID)
                    }
                )
                refreshAvailableUpdates()
            } catch is CancellationError {
                return
            } catch {
                guard generation == gameFolderGeneration else { return }
                showError(error.localizedDescription)
            }
        }
    }

    /// Pauses disk activity in the background and refreshes folder state when the app becomes active.
    func applicationLifecycleDidChange(isActive: Bool) {
        isApplicationActive = isActive
        if isActive { requestModsRefresh() }
    }

    /// Coalesces bursts of file-presenter notifications into one delayed directory scan.
    private func requestModsRefresh() {
        let previousTask = refreshTask
        refreshTask = Task { [weak self] in
            previousTask?.cancel()
            await previousTask?.value
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.refreshMods()
        }
    }

    /// Watches the external Mods directory and debounces a refresh after Files-app changes.
    private func observeModsFolder() {
        guard let modsFolderURL else { return }
        if let modsFolderPresenter { NSFileCoordinator.removeFilePresenter(modsFolderPresenter) }
        let presenter = ModsFolderPresenter(url: modsFolderURL) { [weak self] in
            self?.requestModsRefresh()
        }
        modsFolderPresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    /// Completes an update after a restart, or restores the original if its replacement never arrived.
    private func recoverInterruptedUpdates() {
        guard let gameFolderID, let modsFolderURL else { return }
        let generation = gameFolderGeneration
        let previousTask = recoveryTask
        recoveryTask = Task { [weak self] in
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled, let self else { return }
            await fileService.recoverInterruptedUpdates(
                modsFolderURL: modsFolderURL,
                gameFolderID: gameFolderID,
                legacyGameFolderIDs: legacyGameFolderIDs
            )
            guard !Task.isCancelled, generation == gameFolderGeneration else { return }
            recoveryTask = nil
            refreshMods()
        }
    }


    /// Checks the current update snapshot using the local folder name as its stable UI key.
    func isUpdateAvailable(for mod: InstalledMod) -> Bool {
        updateAvailableNames.contains(mod.name.lowercased())
    }

    /// Reinstalls a newer catalog release into the existing folder while preserving its enabled state.
    func update(_ localMod: InstalledMod) {
        guard let gameFolderID, isUpdateAvailable(for: localMod) else { return }
        guard reserveFolderOperation() else { return }
        startInstallTask {
            let record = try? await self.fileService.updateRecords(for: [localMod], gameFolderID: gameFolderID).first
            let catalogMod = record?.catalogID.flatMap { self.catalogMods[$0.lowercased()] }
                ?? self.catalogMod(forInstalledMod: localMod)
            guard let catalogMod else { return }
            if let providers = self.uninstalledTalismanProviderOptions(for: catalogMod) {
                // DependencyInstallRequest is the temporary integration seam for the dependency-model owner.
                self.dependencyInstallRequest = DependencyInstallRequest(mod: catalogMod, dependencies: [], directDependencies: [:], talismanProviderOptions: providers, replacing: true, replacementModURL: localMod.id)
                return
            }
            guard let graph = self.resolveDependencyGraph(for: catalogMod) else { return }
            let missingDependencies = graph.order.filter { !self.isInstalled($0) }
            if !missingDependencies.isEmpty {
                self.dependencyInstallRequest = DependencyInstallRequest(mod: catalogMod, dependencies: missingDependencies, directDependencies: graph.directDependencies, talismanProviderOptions: [], replacing: true, replacementModURL: localMod.id)
                return
            }
            for dependency in graph.order where !self.isInstalled(dependency) {
                guard await self.downloadAndInstall(dependency, dependencies: graph.directDependencies[dependency.id.lowercased()] ?? []) else { return }
            }
            _ = await self.downloadAndInstall(catalogMod, replacing: true, dependencies: graph.directDependencies[catalogMod.id.lowercased()] ?? [], replacementModURL: localMod.id)
        }
    }

    /// Replaces Steamodded with the current `main` branch archive from its official GitHub repository.
    func installSteamoddedDevelopment(_ localMod: InstalledMod) {
        guard let catalogMod = catalogMod(forInstalledMod: localMod), isSteamodded(catalogMod) else { return }
        installSteamoddedDevelopment(catalogMod, replacing: localMod)
    }

    private func installSteamoddedDevelopment(_ mod: CatalogMod, replacing localMod: InstalledMod?) {
        guard isInstallerAvailable else {
            showError(installerAvailability.message)
            return
        }
        guard isSteamodded(mod) else { return }
        guard reserveFolderOperation() else { return }
        startInstallTask {
            _ = await self.downloadAndInstall(
                mod,
                replacing: localMod != nil,
                replacementModURL: localMod?.id,
                downloadURLOverride: Self.steamoddedDevelopmentURL
            )
        }
    }

    /// Computes update badges from tracked versions, with a timestamp fallback for recovered local folders.
    private func refreshAvailableUpdates() {
        guard let gameFolderID else { return }
        let mods = enabledMods + disabledMods
        let generation = gameFolderGeneration
        let previousTask = updatesTask
        updatesTask = Task { [weak self] in
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled, let self else { return }
            do {
                let records = try await fileService.updateRecords(for: mods, gameFolderID: gameFolderID)
                let modificationDates = await fileService.modificationDates(for: mods)
                guard !Task.isCancelled, generation == gameFolderGeneration else { return }
                let recordsByPath = Dictionary(uniqueKeysWithValues: records.map {
                    ($0.normalizedModPath, $0)
                })
                var updateNames = Set<String>(records.compactMap { (record: InstalledModRecord) -> String? in
                    guard let catalogID = record.catalogID,
                          let catalogMod = self.catalogMods[catalogID.lowercased()],
                          let current = record.currentVersion,
                          let available = catalogMod.version,
                          current != available else { return nil }
                    return record.name.lowercased()
                })
                updateNames.formUnion(mods.compactMap { mod in
                    let path = mod.id.standardizedFileURL.path.lowercased()
                    let hasTrackedVersion = recordsByPath[path].flatMap { record in
                        guard let catalogID = record.catalogID,
                              let catalogMod = self.catalogMods[catalogID.lowercased()] else {
                            return nil
                        }
                        return record.currentVersion != nil && catalogMod.version != nil
                    } ?? false
                    guard !hasTrackedVersion,
                          let catalogMod = self.catalogMod(forInstalledMod: mod),
                          let updatedAt = catalogMod.updatedAt,
                          let modificationDate = modificationDates[path],
                          modificationDate.timeIntervalSince1970 < TimeInterval(updatedAt.value) else {
                        return nil
                    }
                    return mod.name.lowercased()
                })
                updateAvailableNames = updateNames
            } catch is CancellationError { return
            } catch {
                guard generation == gameFolderGeneration else { return }
                updateAvailableNames = []
                showError(error.localizedDescription)
            }
        }
    }

    /// Starts a background BMI refresh only after the catalog cache exceeds its TTL.
    func refreshCatalogIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            await cacheLoadTask.value
            guard catalogNeedsRefresh else { return }
            startCatalogRefresh()
        }
    }

    private var catalogNeedsRefresh: Bool {
        guard sourceRevision != nil else { return true }
        guard let catalogRefreshedAt else {
            return true
        }
        return Date().timeIntervalSince(catalogRefreshedAt) > catalogCacheLifetime
    }

    /// Ensures only one catalog synchronization task runs for the current cache generation.
    private func startCatalogRefresh() {
        guard catalogRefreshTask == nil else { return }
        let generation = catalogGeneration
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await fetchCatalog(generation: generation)
            guard generation == catalogGeneration else { return }
            catalogRefreshTask = nil
        }
    }

    /// Publishes only a complete commit-pinned index; failures preserve the previous offline catalog.
    private func fetchCatalog(generation: Int, managesLoadingState: Bool = true) async {
        await cacheLoadTask.value
        guard !Task.isCancelled, generation == catalogGeneration else { return }
        if managesLoadingState { isLoadingCatalog = true }
        catalogErrorMessage = nil
        defer {
            if managesLoadingState, generation == catalogGeneration { isLoadingCatalog = false }
        }
        do {
            let snapshot = try await githubCatalog.fetch(records: catalogMods, fileHashes: sourceFileHashes)
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            detailCache = detailCache.filter { key, _ in
                sourceFileHashes[key] == snapshot.fileHashes[key] && snapshot.fileHashes[key] != nil
            }
            catalogMods = snapshot.records
            sourceRevision = snapshot.revision
            sourceFileHashes = snapshot.fileHashes
            if !snapshot.skippedEntries.isEmpty {
                let count = snapshot.skippedEntries.count
                catalogErrorMessage = "\(count) index entr\(count == 1 ? "y has" : "ies have") invalid metadata. Cached details were kept where available; other mods are ready to browse."
            }
            applyCachedDetailsToCatalog()
            catalogRefreshedAt = Date()
            persistCatalog(generation: generation)
            refreshMods()
            refreshAvailableUpdates()
        } catch {
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            if let error = error as? GitHubCatalogError {
                catalogErrorMessage = error.localizedDescription
            } else {
                catalogErrorMessage = "Couldn’t refresh the GitHub mod index. Your cached catalog is still available. Check your connection or try again later."
            }
        }
    }

    /// Loads the description from the same commit as the visible catalog metadata.
    private func fetchModDetail(id: String) async throws -> CatalogMod {
        guard let mod = catalogMods[id.lowercased()], let sourceRevision else { throw GitHubCatalogError.invalidIndex }
        return try await githubCatalog.detail(for: mod, revision: sourceRevision)
    }

    /// Indexes catalog records by lowercase BMI ID, merging duplicates from incremental responses.
    private func indexed(_ mods: [CatalogMod]) -> [String: CatalogMod] {
        var indexed: [String: CatalogMod] = [:]
        for mod in mods {
            let key = mod.id.lowercased()
            indexed[key] = indexed[key].map { $0.merged(with: mod) } ?? mod
        }
        return indexed
    }

    /// Merges one catalog response and republishes the visible collection for SwiftUI detail updates.
    private func apply(_ mod: CatalogMod) {
        let current = catalogMods[mod.id.lowercased()]
        if let cached = detailCache[mod.id.lowercased()], !mod.canUseCachedDetail(cached.mod) {
            detailCache.removeValue(forKey: mod.id.lowercased())
        }
        catalogMods[mod.id.lowercased()] = current?.merged(with: mod) ?? mod
        rebuildCatalogAliases()
        // Publishing the refreshed collection redraws catalog detail screens after their lazy detail request completes.
        catalogItems = uniqueCatalogItems(from: catalogMods)
    }

    /// Overlays still-fresh full-detail responses onto summary records loaded from the disk cache.
    private func applyCachedDetailsToCatalog() {
        let now = Date()
        for entry in detailCache.values where now.timeIntervalSince(entry.refreshedAt) < detailCacheLifetime {
            guard let current = catalogMods[entry.mod.id.lowercased()], current.canUseCachedDetail(entry.mod) else { continue }
            catalogMods[entry.mod.id.lowercased()] = current.merged(with: entry.mod)
        }
        rebuildCatalogAliases()
        catalogItems = uniqueCatalogItems(from: catalogMods)
    }


    /// Rebuilds unambiguous display-name and folder-name aliases after catalog mutations.
    private func rebuildCatalogAliases() {
        catalogNameAliases = aliasIndex { $0.name }
        catalogFolderAliases = aliasIndex { $0.folderName }
    }

    /// Maps only unique normalized aliases so collisions cannot identify the wrong local folder.
    private func aliasIndex(_ value: (CatalogMod) -> String?) -> [String: String] {
        var resolved: [String: String] = [:]
        var ambiguous = Set<String>()
        for mod in catalogMods.values.sorted(by: { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) {
            guard let alias = value(mod)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !alias.isEmpty else { continue }
            if let existing = resolved[alias], existing != mod.id.lowercased() {
                resolved.removeValue(forKey: alias)
                ambiguous.insert(alias)
            } else if !ambiguous.contains(alias) {
                resolved[alias] = mod.id.lowercased()
            }
        }
        return resolved
    }

    /// Resolves an on-disk folder name through BMI's stable ID, display-name, and folder-name aliases.
    private func catalogMod(matchingLocalName name: String) -> CatalogMod? {
        let key = name.lowercased()
        // BMI commonly uses publisher@mod as its stable ID and as the installed folder name.
        // A registry can be unavailable after the game container is replaced, so always try
        // that stable ID before the human-readable name and optional folder-name aliases.
        if let directIDMatch = catalogMods[key] {
            return directIDMatch
        }
        let canonicalID = catalogNameAliases[key] ?? catalogFolderAliases[key]
        return canonicalID.flatMap { catalogMods[$0] }
    }

    /// Resolves local metadata through the registry first, with folder-name matching as recovery fallback.
    private func catalogMod(forInstalledMod mod: InstalledMod) -> CatalogMod? {
        let path = mod.id.standardizedFileURL.path.lowercased()
        if let catalogID = installedCatalogIDsByPath[path], let catalogMod = catalogMods[catalogID.lowercased()] {
            return catalogMod
        }
        return catalogMod(matchingLocalName: mod.name)
    }

    /// Persists catalog changes through the shared snapshot writer.
    private func persistCatalog(generation: Int) {
        persistCache(generation: generation)
    }

    /// Persists full-detail cache changes through the shared snapshot writer.
    private func persistDetails(generation: Int) {
        persistCache(generation: generation)
    }

    /// Schedules a revision-guarded cache write so obsolete asynchronous work cannot overwrite fresh data.
    private func persistCache(generation: Int) {
        guard generation == catalogGeneration else { return }
        cacheRevision += 1
        let revision = cacheRevision
        let snapshot = CatalogFileCache.Snapshot(records: catalogMods, details: detailCache, latestCatalogUpdate: nil, catalogRefreshedAt: catalogRefreshedAt, downloadsRefreshedAt: nil, sourceRevision: sourceRevision, sourceFileHashes: sourceFileHashes)
        Task { [weak self] in
            guard let self, generation == self.catalogGeneration else { return }
            try? await catalogFileCache.save(snapshot, revision: revision)
        }
    }

    /// Builds the dependency plan before handing a serialized install or replacement to the file service.
    private func beginInstall(_ mod: CatalogMod, replacing: Bool, replacementModURL: URL? = nil) {
        guard reserveFolderOperation() else { return }
        if let talismanOptions = uninstalledTalismanProviderOptions(for: mod) {
            dependencyInstallRequest = DependencyInstallRequest(
                mod: mod,
                dependencies: [],
                directDependencies: [:],
                talismanProviderOptions: talismanOptions,
                replacing: replacing,
                replacementModURL: replacementModURL
            )
            return
        }

        guard let graph = resolveDependencyGraph(for: mod) else {
            releaseFolderOperation()
            return
        }
        let missingDependencies = graph.order.filter { !isInstalled($0) }
        if !missingDependencies.isEmpty {
            dependencyInstallRequest = DependencyInstallRequest(
                mod: mod,
                dependencies: missingDependencies,
                directDependencies: graph.directDependencies,
                talismanProviderOptions: [],
                replacing: replacing,
                replacementModURL: replacementModURL
            )
            return
        }

        startInstallTask {
            _ = await self.downloadAndInstall(
                mod,
                replacing: replacing,
                dependencies: graph.directDependencies[mod.id.lowercased()] ?? [],
                replacementModURL: replacementModURL
            )
        }
    }

    /// Runs an install flow while retaining the folder-operation lock across dependency prompts.
    private func startInstallTask(_ operation: @escaping @MainActor () async -> Void) {
        guard isFolderOperationBusy, installTask == nil else { return }
        installTask = Task { [weak self] in
            await operation()
            guard let self else { return }
            if dependencyInstallRequest == nil {
                releaseFolderOperation()
            } else {
                installTask = nil
            }
        }
    }

    /// Acquires the single-writer guard used for all game-folder mutations.
    private func reserveFolderOperation() -> Bool {
        guard isInstallerAvailable else {
            showError(installerAvailability.message)
            return false
        }
        isFolderOperationBusy = true
        return true
    }

    /// Clears the single-writer guard after a completed, cancelled, or rejected install flow.
    private func releaseFolderOperation() {
        isFolderOperationBusy = false
        installTask = nil
        refreshMods()
    }

    private struct DependencyGraph {
        let order: [CatalogMod]
        let directDependencies: [String: [String]]
    }

    /// Topologically resolves required loaders, detecting cycles and deferring the Talisman-versus-Amulet choice.
    private func resolveDependencyGraph(for root: CatalogMod, talismanProvider: CatalogMod? = nil) -> DependencyGraph? {
        var visiting = Set<String>()
        var visited = Set<String>()
        var order: [CatalogMod] = []
        var directDependencies: [String: [String]] = [:]
        var needsProvider = false

        /// Performs depth-first dependency resolution while retaining a visiting set for cycle detection.
        func visit(_ mod: CatalogMod) -> Bool {
            let key = mod.id.lowercased()
            if visited.contains(key) { return true }
            if !visiting.insert(key).inserted {
                showError(ModInstallError.dependencyCycle.localizedDescription)
                return false
            }
            var direct: [CatalogMod] = []
            if mod.requiresSteamodded == true {
                guard let steamodded = steamoddedDependency(for: mod) else {
                    showError("\(mod.name ?? mod.id) requires Steamodded, but it is not available in the current catalog.")
                    return false
                }
                direct.append(steamodded)
            }
            if mod.requiresTalisman == true {
                let providers = talismanProviderOptions()
                guard !providers.isEmpty else {
                    showError("\(mod.name ?? mod.id) requires Talisman or Amulet, but neither is available in the current catalog.")
                    return false
                }
                guard let provider = talismanProvider ?? providers.first(where: { installedMod(for: $0).map(isEnabled) == true })
                    ?? providers.first(where: { isInstalled($0) }) else {
                    needsProvider = true
                    visiting.remove(key)
                    return false
                }
                direct.append(provider)
            }
            directDependencies[key] = Array(Set(direct.map(\.id))).sorted()
            for dependency in direct {
                if let installed = installedMod(for: dependency), !isEnabled(installed) {
                    showError("\(mod.name ?? mod.id) requires \(dependency.name ?? dependency.id), which is disabled. Enable it in Installed Mods before continuing.")
                    return false
                }
            }
            for dependency in direct where !isInstalled(dependency) {
                guard visit(dependency) else { return false }
            }
            visiting.remove(key)
            visited.insert(key)
            if key != root.id.lowercased() { order.append(mod) }
            return true
        }

        guard visit(root) else { return nil }
        if needsProvider { return nil }
        return DependencyGraph(order: order, directDependencies: directDependencies)
    }

    /// Resolves Steamodded only for catalog entries which explicitly declare that requirement.
    private func steamoddedDependency(for mod: CatalogMod) -> CatalogMod? {
        guard mod.requiresSteamodded == true else { return nil }
        return catalogDependency(named: "Steamodded")
    }

    /// Returns the user-selectable Talisman providers when a dependency chain needs one and neither is installed.
    private func uninstalledTalismanProviderOptions(for mod: CatalogMod) -> [CatalogMod]? {
        var visited = Set<String>()
        /// Walks loader requirements to determine whether this install path ultimately needs a provider.
        func transitivelyRequiresProvider(_ candidate: CatalogMod) -> Bool {
            guard visited.insert(candidate.id.lowercased()).inserted else { return false }
            if candidate.requiresTalisman == true { return true }
            return steamoddedDependency(for: candidate).map(transitivelyRequiresProvider) ?? false
        }
        guard transitivelyRequiresProvider(mod) else { return nil }
        let providers = talismanProviderOptions()
        guard !providers.isEmpty else { return nil }
        return providers.contains(where: isInstalled) ? nil : providers
    }

    /// Treats either Talisman or its Amulet fork as a valid provider for BMI's Talisman requirement.
    private func talismanProviderOptions() -> [CatalogMod] {
        ["Talisman", "Amulet"].compactMap { catalogDependency(named: $0) }
    }

    /// Finds a dependency by normalized BMI name or stable ID.
    private func catalogDependency(named name: String) -> CatalogMod? {
        catalogItems.first {
            $0.name?.normalizedDependencyName == name.normalizedDependencyName
                || $0.id.normalizedDependencyName == name.normalizedDependencyName
        }
    }

    /// Resolves the authoritative download URL, installs transactionally, then refreshes local state.
    private func downloadAndInstall(
        _ mod: CatalogMod,
        replacing: Bool = false,
        dependencies: [String] = [],
        replacementModURL: URL? = nil,
        downloadURLOverride: URL? = nil
    ) async -> Bool {
        guard let modsFolderURL, let gameFolderID else { return false }

        installingModIDs.insert(mod.id)
        installingModName = mod.name ?? mod.id
        defer {
            installingModIDs.remove(mod.id)
            installingModName = nil
        }

        do {
            let downloadURL: URL
            if let downloadURLOverride {
                downloadURL = downloadURLOverride
            } else {
                downloadURL = try await resolveDownloadURL(for: mod)
            }
            try await fileService.downloadAndInstall(from: downloadURL, mod: mod, dependencies: dependencies, modsFolderURL: modsFolderURL, gameFolderID: gameFolderID, replacing: replacing ? replacementModURL : nil)
            refreshMods()
            refreshAvailableUpdates()
            return true
        } catch is CancellationError {
            return false
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    /// Uses the index's author-provided URL without contacting the retired BMI download tracker.
    private func resolveDownloadURL(for mod: CatalogMod) async throws -> URL {
        if isSteamodded(mod) { return try await latestSteamoddedReleaseURL() }
        guard let value = mod.downloadURL, let url = URL(string: value) else { throw ModInstallError.downloadFailed }
        guard TrustedDownloadSession.isTrusted(url) else { throw ModInstallError.untrustedDownloadURL }
        return url
    }

    /// Installs the official published release, keeping development builds an explicit choice.
    private func latestSteamoddedReleaseURL() async throws -> URL {
        struct Release: Decodable {
            let zipball_url: URL
        }
        let endpoint = URL(string: "https://api.github.com/repos/Steamodded/smods/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await downloadSession.data(for: request, maximumBytes: 1024 * 1024)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard TrustedDownloadSession.isTrusted(release.zipball_url) else { throw ModInstallError.untrustedDownloadURL }
        return release.zipball_url
    }

    private static let steamoddedDevelopmentURL = URL(string: "https://github.com/Steamodded/smods/archive/refs/heads/main.zip")!

    /// Produces the deduplicated user-visible catalog while excluding Lovely's automatically installed folder.
    private func uniqueCatalogItems(from items: [String: CatalogMod]) -> [CatalogMod] {
        let unique = Dictionary(items.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values
            .filter { $0.installFolderName.caseInsensitiveCompare("lovely") != .orderedSame }
            .sorted {
            ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending
        }
    }

    /// Cancels folder-bound work and relinquishes the previous security-scoped resource before a switch.
    private func stopAccessingCurrentFolder() async {
        gameFolderGeneration += 1
        let tasks = [refreshTask, scanTask, recoveryTask, updatesTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        refreshTask = nil
        scanTask = nil
        recoveryTask = nil
        updatesTask = nil
        if let modsFolderPresenter { NSFileCoordinator.removeFilePresenter(modsFolderPresenter) }
        modsFolderPresenter = nil
        gameFolderURL = nil
        enabledMods = []
        disabledMods = []
        installedFolderNames = []
        installedCatalogIDsByPath = [:]
        updateAvailableNames = []
        for task in tasks {
            await task.value
        }
        activeGameFolderURL?.stopAccessingSecurityScopedResource()
        activeGameFolderURL = nil
        activeGameFolderID = nil
        activeFileResourceIdentifier = nil
        legacyGameFolderIDs = []
    }

    /// Reads the filesystem identifier used to detect a no-op re-selection of the same folder.
    private func fileResourceIdentifier(for url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? AnyHashable
    }

    /// Collects historical path and resource identifiers used to migrate older registry records.
    private func legacyFolderIdentifiers(for url: URL) -> Set<String> {
        var identifiers = [url.standardizedFileURL.path.lowercased()]
        if let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            identifiers.append(String(describing: identifier))
        }
        return Set(identifiers)
    }

    /// Publishes an actionable operation error for the shared alert presentation.
    private func showError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

    /// Publishes non-fatal catalog maintenance information for the shared alert presentation.
    private func showCatalogInfo(_ message: String) {
        catalogInfoMessage = message
        isShowingCatalogInfo = true
    }
}
