import Combine
import Foundation

@MainActor
final class ModFolderStore: ObservableObject {
    enum InstallerAvailability: Equatable {
        case available
        case noGameFolder
        case busy

        var message: String {
            switch self {
            case .available: "Ready to install mods."
            case .noGameFolder: "Choose a Lovely Mobile Maker game folder before installing mods."
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
    @Published var isShowingError = false
    @Published private(set) var errorMessage = ""
    @Published var isShowingCatalogInfo = false
    @Published private(set) var catalogInfoMessage = ""

    private let bookmarkKey = "gameFolderBookmark"
    private let folderIdentityKey = "gameFolderIdentity"
    private let catalogFileCache = CatalogFileCache()
    private let downloadSession = TrustedDownloadSession()
    private lazy var fileService = ModFileService(downloadSession: downloadSession)
    private let catalogCacheLifetime: TimeInterval = 60 * 15
    private let detailCacheLifetime: TimeInterval = 60 * 60 * 48
    private let downloadsCacheLifetime: TimeInterval = 60 * 15
    private var activeGameFolderURL: URL?
    private var catalogMods: [String: CatalogMod] = [:]
    private var catalogNameAliases: [String: String] = [:]
    private var catalogFolderAliases: [String: String] = [:]
    private var installedCatalogIDsByPath: [String: String] = [:]
    private var latestCatalogUpdate: FlexibleTimestamp?
    private var catalogRefreshedAt: Date?
    private var detailCache: [String: DetailCacheEntry] = [:]
    private var downloadsRefreshedAt: Date?
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
        self.latestCatalogUpdate = snapshot.latestCatalogUpdate
        self.catalogRefreshedAt = snapshot.catalogRefreshedAt
        self.downloadsRefreshedAt = snapshot.downloadsRefreshedAt
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
        if isFolderOperationBusy || folderTransitionTask != nil { return .busy }
        return .available
    }
    var isInstallerAvailable: Bool { installerAvailability == .available }

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
            beginActivatingGameFolder(at: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            showError(error.localizedDescription)
        }
    }

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

    func installedMod(id: URL) -> InstalledMod? {
        let path = id.standardizedFileURL.path.lowercased()
        return (enabledMods + disabledMods).first { $0.id.standardizedFileURL.path.lowercased() == path }
    }

    func isEnabled(_ mod: InstalledMod) -> Bool {
        enabledMods.contains { $0.id.standardizedFileURL.path.lowercased() == mod.id.standardizedFileURL.path.lowercased() }
    }

    func forceRefreshCatalog() {
        startCatalogRefresh(forceDownloads: true)
    }

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
        latestCatalogUpdate = nil
        catalogRefreshedAt = nil
        detailCache = [:]
        downloadsRefreshedAt = nil
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await cacheLoadTask.value
            await oldRefreshTask?.value
            for task in oldDetailTasks { _ = await task.value }
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            try? await catalogFileCache.remove(revision: revision)
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            await fetchCatalog(forceDownloads: true, generation: generation, managesLoadingState: false)
            guard generation == catalogGeneration else { return }
            isLoadingCatalog = false
            catalogRefreshTask = nil
        }
    }

    func loadDetail(for mod: InstalledMod) async {
        guard let catalogMod = catalogMod(forInstalledMod: mod) else { return }
        await loadDetail(for: catalogMod)
    }

    func loadDetail(forInstalledModID id: URL) async {
        guard let mod = installedMod(id: id) else { return }
        await loadDetail(for: mod)
    }

    func catalogMod(id: String) -> CatalogMod? {
        catalogMods[id.lowercased()]
    }

    func loadDetail(for catalogMod: CatalogMod) async {
        let key = catalogMod.id.lowercased()
        if let cached = detailCache[key],
           Date().timeIntervalSince(cached.refreshedAt) < detailCacheLifetime {
            apply(catalogMod.merged(with: cached.mod))
            return
        }

        if let task = detailTasks[key] {
            _ = await task.value
            return
        }
        let generation = catalogGeneration
        let task = Task<CatalogMod?, Never> { [weak self] in
            guard let self else { return nil }
            return try? await fetchModDetail(id: catalogMod.id)
        }
        detailTasks[key] = task
        let detail = await task.value
        detailTasks[key] = nil
        guard !Task.isCancelled, generation == catalogGeneration else { return }
        guard let detail else { return }
        detailCache[key] = DetailCacheEntry(mod: detail, refreshedAt: Date())
        persistDetails(generation: generation)
        apply(catalogMod.merged(with: detail))
    }

    func isInstalled(_ mod: CatalogMod) -> Bool {
        installedMod(for: mod) != nil
    }

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

    func isInstalling(_ mod: CatalogMod) -> Bool {
        installingModIDs.contains(mod.id)
    }

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

    func cancelDependencyInstall() {
        dependencyInstallRequest = nil
        releaseFolderOperation()
    }

    private func restoreFolderAccess() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
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
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
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
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            UserDefaults.standard.removeObject(forKey: folderIdentityKey)
        }
    }

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

    private func gameFolderValidation(at url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues.isDirectory == true else {
            throw GameFolderError.notDirectory
        }

        guard url.lastPathComponent.caseInsensitiveCompare("game") == .orderedSame,
              existingModsFolderURL(in: url) != nil else {
            throw GameFolderError.invalidLayout
        }
    }

    private func existingModsFolderURL(in gameFolderURL: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: gameFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first { child in
            child.lastPathComponent.caseInsensitiveCompare("Mods") == .orderedSame
                && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func refreshMods() {
        guard isApplicationActive, let modsFolderURL, let gameFolderID else { return }
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

    func applicationLifecycleDidChange(isActive: Bool) {
        isApplicationActive = isActive
        if isActive { requestModsRefresh() }
    }

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
            refreshMods()
        }
    }


    func isUpdateAvailable(for mod: InstalledMod) -> Bool {
        updateAvailableNames.contains(mod.name.lowercased())
    }

    func update(_ localMod: InstalledMod) {
        guard let gameFolderID, isUpdateAvailable(for: localMod) else { return }
        guard reserveFolderOperation() else { return }
        startInstallTask {
            guard let record = try? await self.fileService.updateRecords(for: [localMod], gameFolderID: gameFolderID).first,
                  let catalogID = record.catalogID,
                  let catalogMod = self.catalogMods[catalogID.lowercased()] else { return }
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
                guard !Task.isCancelled, generation == gameFolderGeneration else { return }
                updateAvailableNames = Set(records.compactMap { record in
                    guard let catalogID = record.catalogID, let catalogMod = self.catalogMods[catalogID.lowercased()], let current = record.currentVersion, let available = catalogMod.version, current != available else { return nil }
                    return record.name.lowercased()
                })
            } catch is CancellationError { return
            } catch {
                guard generation == gameFolderGeneration else { return }
                updateAvailableNames = []
                showError(error.localizedDescription)
            }
        }
    }

    func refreshCatalogIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            await cacheLoadTask.value
            guard catalogNeedsRefresh else { return }
            startCatalogRefresh()
        }
    }

    private var catalogNeedsRefresh: Bool {
        guard let catalogRefreshedAt else {
            return true
        }
        return Date().timeIntervalSince(catalogRefreshedAt) > catalogCacheLifetime
    }

    private func startCatalogRefresh(forceDownloads: Bool = false) {
        guard catalogRefreshTask == nil else { return }
        let generation = catalogGeneration
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await fetchCatalog(forceDownloads: forceDownloads, generation: generation)
            guard generation == catalogGeneration else { return }
            catalogRefreshTask = nil
        }
    }

    private func fetchCatalog(forceDownloads: Bool = false, generation: Int, managesLoadingState: Bool = true) async {
        await cacheLoadTask.value
        guard !Task.isCancelled, generation == catalogGeneration else { return }

        if managesLoadingState { isLoadingCatalog = true }
        catalogErrorMessage = nil
        defer {
            if managesLoadingState, generation == catalogGeneration { isLoadingCatalog = false }
        }

        do {
            if catalogMods.isEmpty || latestCatalogUpdate == nil {
                let fetched = try await fetchCatalogPages(path: "mods", query: [])
                guard !Task.isCancelled, generation == catalogGeneration else { return }
                catalogMods = indexed(fetched)
                rebuildCatalogAliases()
                latestCatalogUpdate = fetched.compactMap(\.updatedAt).max { $0.value < $1.value }
            } else if let latestCatalogUpdate {
                let changed = try await fetchCatalogPages(
                    path: "mods/changed",
                    query: [URLQueryItem(name: "since", value: String(latestCatalogUpdate.value))]
                )
                guard !Task.isCancelled, generation == catalogGeneration else { return }
                for mod in changed {
                    if mod.isDeleted == true {
                        remove(mod)
                    } else {
                        apply(mod)
                    }
                }
                rebuildCatalogAliases()
                if let newest = changed.compactMap(\.updatedAt).max(by: { $0.value < $1.value }) {
                    self.latestCatalogUpdate = newest
                }
            }

            applyCachedDetailsToCatalog()

            catalogRefreshedAt = Date()
            catalogItems = uniqueCatalogItems(from: catalogMods)
            persistCatalog(generation: generation)
            refreshMods()
            refreshAvailableUpdates()
            await refreshDownloadsIfNeeded(force: forceDownloads, generation: generation)
        } catch {
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            catalogErrorMessage = "Couldn’t update the mod catalog. Check your connection and try again."
            return
        }
    }

    private func refreshDownloadsIfNeeded(force: Bool, generation: Int) async {
        guard force || downloadsRefreshedAt.map({ Date().timeIntervalSince($0) > downloadsCacheLifetime }) ?? true else { return }
        do {
            let mods = try await fetchCatalogPages(path: "mods", query: [])
            guard !Task.isCancelled, generation == catalogGeneration else { return }
            let prunedCount = pruneRemovedCatalogMods(using: mods)
            for mod in mods where mod.downloads != nil {
                apply(mod)
            }
            downloadsRefreshedAt = Date()
            catalogItems = uniqueCatalogItems(from: catalogMods)
            persistCatalog(generation: generation)
            if prunedCount > 0 {
                let suffix = prunedCount == 1 ? "" : "s"
                showCatalogInfo("Pruned \(prunedCount) removed mod\(suffix) from the catalog cache.")
            }
        } catch {
            return
        }
    }

    private func fetchCatalogPages(path: String, query: [URLQueryItem]) async throws -> [CatalogMod] {
        var cursor: String?
        var results: [CatalogMod] = []
        repeat {
            var components = URLComponents(string: "https://api-bmi.dasguney.com/\(path)")
            var items = query + [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "sort", value: "name_asc")
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            components?.queryItems = items
            guard let url = components?.url else { throw URLError(.badURL) }
            let (data, response) = try await downloadSession.session.data(from: url)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(CatalogPage.self, from: data)
            results.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        return results
    }

    private func fetchModDetail(id: String) async throws -> CatalogMod {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "https://api-bmi.dasguney.com/mods/\(encodedID)") else { throw URLError(.badURL) }
        let (data, response) = try await downloadSession.session.data(from: url)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CatalogMod.self, from: data)
    }

    private func indexed(_ mods: [CatalogMod]) -> [String: CatalogMod] {
        var indexed: [String: CatalogMod] = [:]
        for mod in mods {
            let key = mod.id.lowercased()
            indexed[key] = indexed[key].map { $0.merged(with: mod) } ?? mod
        }
        return indexed
    }

    private func apply(_ mod: CatalogMod) {
        let current = catalogMods[mod.id.lowercased()]
        catalogMods[mod.id.lowercased()] = current?.merged(with: mod) ?? mod
        rebuildCatalogAliases()
        // Publishing the refreshed collection redraws catalog detail screens after their lazy detail request completes.
        catalogItems = uniqueCatalogItems(from: catalogMods)
    }

    private func applyCachedDetailsToCatalog() {
        let now = Date()
        for entry in detailCache.values where now.timeIntervalSince(entry.refreshedAt) < detailCacheLifetime {
            guard let current = catalogMods[entry.mod.id.lowercased()] else { continue }
            catalogMods[entry.mod.id.lowercased()] = current.merged(with: entry.mod)
        }
        rebuildCatalogAliases()
        catalogItems = uniqueCatalogItems(from: catalogMods)
    }

    private func remove(_ mod: CatalogMod) {
        catalogMods.removeValue(forKey: mod.id.lowercased())
        detailCache.removeValue(forKey: mod.id.lowercased())
        rebuildCatalogAliases()
    }

    private func pruneRemovedCatalogMods(using freshMods: [CatalogMod]) -> Int {
        let incomingIDs = Set(freshMods.map { $0.id.lowercased() })
        let existingCount = catalogMods.count
        let minimumTrustedCount = max(10, existingCount / 2)
        guard !incomingIDs.isEmpty, incomingIDs.count >= minimumTrustedCount else { return 0 }

        let removedIDs = Set(catalogMods.keys).subtracting(incomingIDs)
        guard !removedIDs.isEmpty else { return 0 }
        for id in removedIDs {
            catalogMods.removeValue(forKey: id)
            detailCache.removeValue(forKey: id)
        }
        rebuildCatalogAliases()
        return removedIDs.count
    }

    private func rebuildCatalogAliases() {
        catalogNameAliases = aliasIndex { $0.name }
        catalogFolderAliases = aliasIndex { $0.folderName }
    }

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

    private func catalogMod(matchingLocalName name: String) -> CatalogMod? {
        let key = name.lowercased()
        let canonicalID = catalogNameAliases[key] ?? catalogFolderAliases[key]
        return canonicalID.flatMap { catalogMods[$0] }
    }

    private func catalogMod(forInstalledMod mod: InstalledMod) -> CatalogMod? {
        let path = mod.id.standardizedFileURL.path.lowercased()
        if let catalogID = installedCatalogIDsByPath[path], let catalogMod = catalogMods[catalogID.lowercased()] {
            return catalogMod
        }
        return catalogMod(matchingLocalName: mod.name)
    }

    private func persistCatalog(generation: Int) {
        persistCache(generation: generation)
    }

    private func persistDetails(generation: Int) {
        persistCache(generation: generation)
    }

    private func persistCache(generation: Int) {
        guard generation == catalogGeneration else { return }
        cacheRevision += 1
        let revision = cacheRevision
        let snapshot = CatalogFileCache.Snapshot(records: catalogMods, details: detailCache, latestCatalogUpdate: latestCatalogUpdate, catalogRefreshedAt: catalogRefreshedAt, downloadsRefreshedAt: downloadsRefreshedAt)
        Task { [weak self] in
            guard let self, generation == self.catalogGeneration else { return }
            try? await catalogFileCache.save(snapshot, revision: revision)
        }
    }

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

    private func reserveFolderOperation() -> Bool {
        guard !isFolderOperationBusy, folderTransitionTask == nil else {
            showError(InstallerAvailability.busy.message)
            return false
        }
        isFolderOperationBusy = true
        return true
    }

    private func releaseFolderOperation() {
        isFolderOperationBusy = false
        installTask = nil
    }

    private struct DependencyGraph {
        let order: [CatalogMod]
        let directDependencies: [String: [String]]
    }

    private func resolveDependencyGraph(for root: CatalogMod, talismanProvider: CatalogMod? = nil) -> DependencyGraph? {
        var visiting = Set<String>()
        var visited = Set<String>()
        var order: [CatalogMod] = []
        var directDependencies: [String: [String]] = [:]
        var needsProvider = false

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
                guard let provider = talismanProvider ?? providers.first(where: { isInstalled($0) }) else {
                    needsProvider = true
                    visiting.remove(key)
                    return false
                }
                direct.append(provider)
            }
            directDependencies[key] = Array(Set(direct.map(\.id))).sorted()
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

    private func steamoddedDependency(for mod: CatalogMod) -> CatalogMod? {
        guard mod.requiresSteamodded == true else { return nil }
        return catalogDependency(named: "Steamodded")
    }

    private func uninstalledTalismanProviderOptions(for mod: CatalogMod) -> [CatalogMod]? {
        var visited = Set<String>()
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

    private func talismanProviderOptions() -> [CatalogMod] {
        ["Talisman", "Amulet"].compactMap { catalogDependency(named: $0) }
    }

    private func catalogDependency(named name: String) -> CatalogMod? {
        catalogItems.first {
            $0.name?.normalizedDependencyName == name.normalizedDependencyName
                || $0.id.normalizedDependencyName == name.normalizedDependencyName
        }
    }

    private func downloadAndInstall(
        _ mod: CatalogMod,
        replacing: Bool = false,
        dependencies: [String] = [],
        replacementModURL: URL? = nil
    ) async -> Bool {
        guard let modsFolderURL, let gameFolderID else { return false }

        installingModIDs.insert(mod.id)
        installingModName = mod.name ?? mod.id
        defer {
            installingModIDs.remove(mod.id)
            installingModName = nil
        }

        do {
            let downloadURL = try await resolveDownloadURL(for: mod)
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

    private func resolveDownloadURL(for mod: CatalogMod) async throws -> URL {
        if mod.name?.normalizedDependencyName == "steamodded" || mod.id.normalizedDependencyName == "steamodded" {
            return try await latestSteamoddedReleaseURL()
        }

        let id = mod.id
        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? id
        guard let url = URL(string: "https://api-bmi.dasguney.com/mods/\(encodedID)/download") else {
            throw ModInstallError.downloadFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await downloadSession.session.data(for: request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw ModInstallError.downloadFailed
        }

        struct DownloadResponse: Decodable {
            let downloadURL: String?

            enum CodingKeys: String, CodingKey {
                case downloadURL = "download_url"
                case downloadURLCamelCase = "downloadUrl"
                case url
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
                    ?? container.decodeIfPresent(String.self, forKey: .downloadURLCamelCase)
                    ?? container.decodeIfPresent(String.self, forKey: .url)
            }
        }

        if response.statusCode == 204 {
            guard let detailURL = URL(string: "https://api-bmi.dasguney.com/mods/\(encodedID)") else {
                throw ModInstallError.downloadFailed
            }
            let (detailData, detailResponse) = try await downloadSession.session.data(from: detailURL)
            guard let detailResponse = detailResponse as? HTTPURLResponse, 200..<300 ~= detailResponse.statusCode else {
                throw ModInstallError.downloadFailed
            }
            let payload = try JSONDecoder().decode(DownloadResponse.self, from: detailData)
            guard let downloadURL = payload.downloadURL, let url = URL(string: downloadURL) else {
                throw ModInstallError.downloadFailed
            }
            return url
        }

        let payload = try JSONDecoder().decode(DownloadResponse.self, from: data)
        guard let downloadURL = payload.downloadURL, let url = URL(string: downloadURL) else {
            throw ModInstallError.downloadFailed
        }
        return url
    }

    private func latestSteamoddedReleaseURL() async throws -> URL {
        struct GitHubRelease: Decodable {
            let tagName: String

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
            }
        }

        guard let releaseURL = URL(string: "https://api.github.com/repos/Steamodded/smods/releases/latest") else {
            throw ModInstallError.downloadFailed
        }
        var request = URLRequest(url: releaseURL)
        request.setValue("BMM-Mobile", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await downloadSession.session.data(for: request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw ModInstallError.downloadFailed
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let tag = release.tagName.addingPercentEncoding(withAllowedCharacters: allowed),
              let archiveURL = URL(string: "https://github.com/Steamodded/smods/archive/refs/tags/\(tag).zip") else {
            throw ModInstallError.downloadFailed
        }
        return archiveURL
    }

    private func uniqueCatalogItems(from items: [String: CatalogMod]) -> [CatalogMod] {
        let unique = Dictionary(items.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values
            .filter { $0.installFolderName.caseInsensitiveCompare("lovely") != .orderedSame }
            .sorted {
            ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending
        }
    }

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

    private func fileResourceIdentifier(for url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? AnyHashable
    }

    private func legacyFolderIdentifiers(for url: URL) -> Set<String> {
        var identifiers = [url.standardizedFileURL.path.lowercased()]
        if let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            identifiers.append(String(describing: identifier))
        }
        return Set(identifiers)
    }

    private func showError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

    private func showCatalogInfo(_ message: String) {
        catalogInfoMessage = message
        isShowingCatalogInfo = true
    }
}
