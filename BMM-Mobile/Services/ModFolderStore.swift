import Combine
import Foundation

@MainActor
final class ModFolderStore: ObservableObject {
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
    @Published var pendingGameFolderSelection: GameFolderSelection?
    @Published var isShowingError = false
    @Published private(set) var errorMessage = ""

    private let bookmarkKey = "gameFolderBookmark"
    private let catalogCacheKey = "bmiCatalogCacheV2"
    private let detailCacheKey = "bmiDetailCacheV1"
    private let downloadsCacheKey = "bmiDownloadsCacheV1"
    private let downloadSession = TrustedDownloadSession()
    private lazy var fileService = ModFileService(downloadSession: downloadSession)
    private let catalogCacheLifetime: TimeInterval = 60 * 15
    private let detailCacheLifetime: TimeInterval = 60 * 60 * 48
    private let downloadsCacheLifetime: TimeInterval = 60 * 15
    private var activeGameFolderURL: URL?
    private var catalogMods: [String: CatalogMod] = [:]
    private var latestCatalogUpdate: FlexibleTimestamp?
    private var catalogRefreshedAt: Date?
    private var detailCache: [String: DetailCacheEntry] = [:]
    private var downloadsRefreshedAt: Date?
    private var reindexTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    private var modsFolderURL: URL? {
        gameFolderURL?.appendingPathComponent("Mods", isDirectory: true)
    }

    private var gameFolderID: String? {
        guard let gameFolderURL else { return nil }
        if let identifier = try? gameFolderURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            return String(describing: identifier)
        }
        return gameFolderURL.standardizedFileURL.path.lowercased()
    }

    var totalModCount: Int { enabledMods.count + disabledMods.count }
    var lastCatalogRefresh: Date? { catalogRefreshedAt }

    init() {
        loadCachedCatalog()
        loadCachedDetails()
        loadCachedDownloads()
        restoreFolderAccess()
        startBackgroundReindex()
    }

    deinit {
        reindexTask?.cancel()
    }

    func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard !isFolderOperationBusy else {
            showError("Wait for the current install or update to finish before changing the game folder.")
            return
        }
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else {
            showError("iOS did not grant access to this folder. Please try selecting it again.")
            return
        }

        do {
            switch try gameFolderValidation(at: url) {
            case .valid:
                try activateGameFolder(at: url)
            case .requiresConfirmation:
                pendingGameFolderSelection = GameFolderSelection(url: url)
            }
        } catch {
            url.stopAccessingSecurityScopedResource()
            showError(error.localizedDescription)
        }
    }

    func confirmPendingGameFolderSelection() {
        guard !isFolderOperationBusy else { return }
        guard let selection = pendingGameFolderSelection else { return }
        pendingGameFolderSelection = nil

        do {
            _ = try gameFolderValidation(at: selection.url)
            try activateGameFolder(at: selection.url)
        } catch {
            selection.url.stopAccessingSecurityScopedResource()
            showError(error.localizedDescription)
        }
    }

    func cancelPendingGameFolderSelection() {
        pendingGameFolderSelection?.url.stopAccessingSecurityScopedResource()
        pendingGameFolderSelection = nil
    }

    func setEnabled(_ enabled: Bool, for mod: InstalledMod) {
        Task {
            do {
                try await fileService.setEnabled(enabled, modURL: mod.id)
                refreshMods()
            } catch is CancellationError {
                return
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func delete(_ mod: InstalledMod) {
        guard let gameFolderID else { return }
        Task {
            do {
                try await fileService.delete(mod: mod, gameFolderID: gameFolderID)
                refreshMods()
            } catch is CancellationError {
                return
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func presentation(for mod: InstalledMod) -> ModPresentation {
        let catalogMod = catalogMods[mod.name.lowercased()]
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

    func forceRefreshCatalog() {
        guard !isLoadingCatalog else { return }

        Task {
            catalogErrorMessage = nil
            await fetchCatalog(forceDownloads: true)
        }
    }

    func clearCatalogCache() {
        UserDefaults.standard.removeObject(forKey: catalogCacheKey)
        UserDefaults.standard.removeObject(forKey: detailCacheKey)
        UserDefaults.standard.removeObject(forKey: downloadsCacheKey)
        let thumbnailDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModThumbnails", isDirectory: true)
        try? FileManager.default.removeItem(at: thumbnailDirectory)
        catalogMods = [:]
        catalogItems = []
        latestCatalogUpdate = nil
        catalogRefreshedAt = nil
        detailCache = [:]
        downloadsRefreshedAt = nil
        Task { await fetchCatalog(forceDownloads: true) }
    }

    func loadDetail(for mod: InstalledMod) async {
        guard let catalogMod = catalogMods[mod.name.lowercased()] else { return }
        await loadDetail(for: catalogMod)
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

        do {
            let detail = try await fetchModDetail(id: catalogMod.id)
            detailCache[key] = DetailCacheEntry(mod: detail, refreshedAt: Date())
            persistDetails()
            apply(catalogMod.merged(with: detail))
        } catch {
            return
        }
    }

    func isInstalled(_ mod: CatalogMod) -> Bool {
        installedFolderNames.contains(mod.installFolderName.lowercased())
    }

    func isInstalling(_ mod: CatalogMod) -> Bool {
        installingModIDs.contains(mod.id)
    }

    func install(_ mod: CatalogMod) {
        guard gameFolderURL != nil,
              !isInstalled(mod),
              !isInstalling(mod),
              installingModIDs.isEmpty else { return }

        beginInstall(mod, replacing: false)
    }

    func confirmDependencyInstall(talismanProvider: CatalogMod? = nil) {
        guard let request = dependencyInstallRequest else { return }
        dependencyInstallRequest = nil

        guard let graph = resolveDependencyGraph(for: request.mod, talismanProvider: talismanProvider) else { return }

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

            guard try gameFolderValidation(at: url) == .valid else {
                throw GameFolderError.invalidLayout
            }

            if isStale {
                let refreshedBookmark = try url.bookmarkData(options: .minimalBookmark)
                UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
            }

            activeGameFolderURL = url
            gameFolderURL = url
            recoverInterruptedUpdates()
            refreshMods()
            refreshCatalogIfNeeded()
        } catch {
            restoredURL?.stopAccessingSecurityScopedResource()
            stopAccessingCurrentFolder()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func activateGameFolder(at url: URL) throws {
        if activeGameFolderURL?.standardizedFileURL == url.standardizedFileURL {
            url.stopAccessingSecurityScopedResource()
            return
        }

        let bookmark = try url.bookmarkData(options: .minimalBookmark)
        stopAccessingCurrentFolder()
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        activeGameFolderURL = url
        gameFolderURL = url
        recoverInterruptedUpdates()
        refreshMods()
        refreshCatalogIfNeeded()
    }

    private func gameFolderValidation(at url: URL) throws -> GameFolderValidation {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues.isDirectory == true else {
            throw GameFolderError.notDirectory
        }

        let configURL = url.appendingPathComponent("config", isDirectory: true)
        let modsURL = url.appendingPathComponent("Mods", isDirectory: true)
        let hasConfig = (try? configURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let hasMods = (try? modsURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard hasConfig && hasMods else {
            throw GameFolderError.invalidLayout
        }

        return url.lastPathComponent.caseInsensitiveCompare("game") == .orderedSame
            ? .valid
            : .requiresConfirmation
    }

    private func refreshMods() {
        guard let modsFolderURL, let gameFolderID else { return }
        Task {
            do {
                let result = try await fileService.scan(modsFolderURL: modsFolderURL, gameFolderID: gameFolderID)
                enabledMods = result.enabled
                disabledMods = result.disabled
                installedFolderNames = result.folderNames
                refreshAvailableUpdates()
            } catch is CancellationError {
                return
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// Completes an update after a restart, or restores the original if its replacement never arrived.
    private func recoverInterruptedUpdates() {
        guard let gameFolderID else { return }
        Task {
            await fileService.recoverInterruptedUpdates(gameFolderID: gameFolderID)
            refreshMods()
        }
    }

    private func startBackgroundReindex() {
        reindexTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.refreshMods()
            }
        }
    }

    func isUpdateAvailable(for mod: InstalledMod) -> Bool {
        updateAvailableNames.contains(mod.name.lowercased())
    }

    func update(_ localMod: InstalledMod) {
        guard let catalogMod = catalogMods[localMod.name.lowercased()], isUpdateAvailable(for: localMod) else { return }
        beginInstall(catalogMod, replacing: true, replacementModURL: localMod.id)
    }

    private func refreshAvailableUpdates() {
        guard let gameFolderID else { return }
        let mods = enabledMods + disabledMods
        Task {
            do {
                let records = try await fileService.updateRecords(for: mods, gameFolderID: gameFolderID)
                updateAvailableNames = Set(records.compactMap { record in
                    guard let catalogID = record.catalogID, let catalogMod = catalogMods[catalogID.lowercased()], let current = record.currentVersion, let available = catalogMod.version, current != available else { return nil }
                    return record.name.lowercased()
                })
            } catch is CancellationError { return
            } catch { updateAvailableNames = []; showError(error.localizedDescription) }
        }
    }

    func refreshCatalogIfNeeded() {
        guard catalogNeedsRefresh else { return }

        Task {
            await fetchCatalog()
        }
    }

    private var catalogNeedsRefresh: Bool {
        guard let catalogRefreshedAt else {
            return true
        }
        return Date().timeIntervalSince(catalogRefreshedAt) > catalogCacheLifetime
    }

    private func loadCachedCatalog() {
        guard let data = UserDefaults.standard.data(forKey: catalogCacheKey),
              let cached = try? JSONDecoder().decode(CatalogCache.self, from: data) else {
            return
        }
        catalogMods = cached.items
        latestCatalogUpdate = cached.lastUpdatedAt
        catalogRefreshedAt = cached.refreshedAt
        catalogItems = uniqueCatalogItems(from: cached.items)
    }

    private func loadCachedDetails() {
        guard let data = UserDefaults.standard.data(forKey: detailCacheKey),
              let cached = try? JSONDecoder().decode([String: DetailCacheEntry].self, from: data) else { return }
        detailCache = cached
        applyCachedDetailsToCatalog()
    }

    private func loadCachedDownloads() {
        guard let data = UserDefaults.standard.data(forKey: downloadsCacheKey),
              let cache = try? JSONDecoder().decode(CatalogCache.self, from: data) else { return }
        downloadsRefreshedAt = cache.refreshedAt
        for mod in uniqueCatalogItems(from: cache.items) {
            apply(mod)
        }
    }

    private func fetchCatalog(forceDownloads: Bool = false) async {
        guard !isLoadingCatalog else { return }

        isLoadingCatalog = true
        catalogErrorMessage = nil
        defer { isLoadingCatalog = false }

        do {
            if catalogMods.isEmpty || latestCatalogUpdate == nil {
                let fetched = try await fetchCatalogPages(path: "mods", query: [])
                catalogMods = indexed(fetched)
                latestCatalogUpdate = fetched.compactMap(\.updatedAt).max { $0.value < $1.value }
            } else if let latestCatalogUpdate {
                let changed = try await fetchCatalogPages(
                    path: "mods/changed",
                    query: [URLQueryItem(name: "since", value: String(latestCatalogUpdate.value))]
                )
                for mod in changed {
                    if mod.isDeleted == true {
                        remove(mod)
                    } else {
                        apply(mod)
                    }
                }
                if let newest = changed.compactMap(\.updatedAt).max(by: { $0.value < $1.value }) {
                    self.latestCatalogUpdate = newest
                }
            }

            applyCachedDetailsToCatalog()

            catalogRefreshedAt = Date()
            catalogItems = uniqueCatalogItems(from: catalogMods)
            persistCatalog()
            refreshMods()
            refreshAvailableUpdates()
            await refreshDownloadsIfNeeded(force: forceDownloads)
        } catch {
            catalogErrorMessage = "Couldn’t update the mod catalog. Check your connection and try again."
            return
        }
    }

    private func refreshDownloadsIfNeeded(force: Bool) async {
        guard force || downloadsRefreshedAt.map({ Date().timeIntervalSince($0) > downloadsCacheLifetime }) ?? true else { return }
        do {
            let mods = try await fetchCatalogPages(path: "mods", query: [])
            for mod in mods where mod.downloads != nil {
                apply(mod)
            }
            downloadsRefreshedAt = Date()
            catalogItems = uniqueCatalogItems(from: catalogMods)
            persistCatalog()
            if let data = try? JSONEncoder().encode(CatalogCache(items: catalogMods, lastUpdatedAt: latestCatalogUpdate, refreshedAt: downloadsRefreshedAt ?? Date())) {
                UserDefaults.standard.set(data, forKey: downloadsCacheKey)
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
        for mod in mods { index(mod, into: &indexed) }
        return indexed
    }

    private func apply(_ mod: CatalogMod) {
        let current = catalogMods[mod.id.lowercased()]
        index(current?.merged(with: mod) ?? mod, into: &catalogMods)
    }

    private func index(_ mod: CatalogMod, into dictionary: inout [String: CatalogMod]) {
        dictionary[mod.id.lowercased()] = mod
        if let name = mod.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            dictionary[name.lowercased()] = mod
        }
        if let folderName = mod.folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty {
            dictionary[folderName.lowercased()] = mod
        }
    }

    private func applyCachedDetailsToCatalog() {
        let now = Date()
        for entry in detailCache.values where now.timeIntervalSince(entry.refreshedAt) < detailCacheLifetime {
            guard let current = catalogMods[entry.mod.id.lowercased()] else { continue }
            index(current.merged(with: entry.mod), into: &catalogMods)
        }
        catalogItems = uniqueCatalogItems(from: catalogMods)
    }

    private func remove(_ mod: CatalogMod) {
        catalogMods = catalogMods.filter { $0.value.id.caseInsensitiveCompare(mod.id) != .orderedSame }
    }

    private func persistCatalog() {
        guard let catalogRefreshedAt,
              let data = try? JSONEncoder().encode(CatalogCache(items: catalogMods, lastUpdatedAt: latestCatalogUpdate, refreshedAt: catalogRefreshedAt)) else { return }
        UserDefaults.standard.set(data, forKey: catalogCacheKey)
    }

    private func persistDetails() {
        guard let data = try? JSONEncoder().encode(detailCache) else { return }
        UserDefaults.standard.set(data, forKey: detailCacheKey)
    }

    private func beginInstall(_ mod: CatalogMod, replacing: Bool, replacementModURL: URL? = nil) {
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

        guard let graph = resolveDependencyGraph(for: mod) else { return }
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
        guard !isFolderOperationBusy else { return }
        isFolderOperationBusy = true
        installTask = Task { [weak self] in
            await operation()
            self?.isFolderOperationBusy = false
            self?.installTask = nil
        }
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
            directDependencies[key] = Array(Set(direct.map(\.installFolderName))).sorted()
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
        guard mod.requiresTalisman == true else { return nil }
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
            let downloadURL = try await resolveDownloadURL(for: mod.id)
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

    private func resolveDownloadURL(for id: String) async throws -> URL {
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

    private func uniqueCatalogItems(from items: [String: CatalogMod]) -> [CatalogMod] {
        let unique = Dictionary(items.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values
            .filter { $0.installFolderName.caseInsensitiveCompare("lovely") != .orderedSame }
            .sorted {
            ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending
        }
    }

    private func stopAccessingCurrentFolder() {
        activeGameFolderURL?.stopAccessingSecurityScopedResource()
        activeGameFolderURL = nil
        gameFolderURL = nil
        enabledMods = []
        disabledMods = []
        installedFolderNames = []
    }

    private func showError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}
