import Combine
import Foundation
import ZIPFoundation

@MainActor
final class ModFolderStore: ObservableObject {
    private static let maximumArchiveFileCount = 10_000
    private static let maximumArchiveUncompressedSize: UInt64 = 2 * 1024 * 1024 * 1024
    @Published private(set) var gameFolderURL: URL?
    @Published private(set) var enabledMods: [InstalledMod] = []
    @Published private(set) var disabledMods: [InstalledMod] = []
    @Published private(set) var installedFolderNames: Set<String> = []
    @Published private(set) var catalogItems: [CatalogMod] = []
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var installingModIDs: Set<String> = []
    @Published private(set) var installingModName: String?
    @Published var isShowingError = false
    @Published private(set) var errorMessage = ""

    private let bookmarkKey = "gameFolderBookmark"
    private let catalogCacheKey = "bmiCatalogCacheV2"
    private let detailCacheKey = "bmiDetailCacheV1"
    private let downloadsCacheKey = "bmiDownloadsCacheV1"
    private let catalogCacheLifetime: TimeInterval = 60 * 15
    private let detailCacheLifetime: TimeInterval = 60 * 60 * 48
    private let downloadsCacheLifetime: TimeInterval = 60 * 15
    private var activeGameFolderURL: URL?
    private var catalogMods: [String: CatalogMod] = [:]
    private var latestCatalogUpdate: FlexibleTimestamp?
    private var catalogRefreshedAt: Date?
    private var detailCache: [String: DetailCacheEntry] = [:]
    private var downloadsRefreshedAt: Date?

    private var modsFolderURL: URL? {
        gameFolderURL?.appendingPathComponent("Mods", isDirectory: true)
    }

    private var disabledModsFolderURL: URL? {
        gameFolderURL?.appendingPathComponent("Disabled Mods", isDirectory: true)
    }

    init() {
        loadCachedCatalog()
        loadCachedDetails()
        loadCachedDownloads()
        restoreFolderAccess()
    }

    func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        stopAccessingCurrentFolder()

        guard url.startAccessingSecurityScopedResource() else {
            showError("iOS did not grant access to this folder. Please try selecting it again.")
            return
        }

        do {
            try prepareGameFolder(at: url)
            let bookmark = try url.bookmarkData(options: .minimalBookmark)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            activeGameFolderURL = url
            gameFolderURL = url
            refreshMods()
            refreshCatalogIfNeeded()
        } catch {
            url.stopAccessingSecurityScopedResource()
            showError(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool, for mod: InstalledMod) {
        guard let destinationFolder = enabled ? modsFolderURL : disabledModsFolderURL else { return }

        let destinationURL = destinationFolder.appendingPathComponent(mod.name, isDirectory: true)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            showError("A mod named \(mod.name) already exists in the destination folder.")
            return
        }

        do {
            try FileManager.default.moveItem(at: mod.id, to: destinationURL)
            refreshMods()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func delete(_ mod: InstalledMod) {
        do {
            try FileManager.default.removeItem(at: mod.id)
            refreshMods()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func presentation(for mod: InstalledMod) -> ModPresentation {
        let catalogMod = catalogMods[mod.name.lowercased()]
        let summary = catalogMod?.summary?
            .replacingOccurrences(of: "![]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ModPresentation(
            title: catalogMod?.name ?? mod.name,
            description: summary?.isEmpty == false ? summary! : "Local mod folder",
            author: catalogMod?.author,
            version: catalogMod?.version,
            categories: catalogMod?.categories ?? [],
            repositoryURL: catalogMod?.repository.flatMap(URL.init(string:)),
            thumbnailURL: catalogMod?.thumbnailURL
        )
    }

    func forceRefreshCatalog() {
        guard !isLoadingCatalog else { return }

        Task {
            await fetchCatalog(forceDownloads: true)
        }
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

        Task {
            await downloadAndInstall(mod)
        }
    }

    private func restoreFolderAccess() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

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

            try prepareGameFolder(at: url)

            if isStale {
                let refreshedBookmark = try url.bookmarkData(options: .minimalBookmark)
                UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
            }

            activeGameFolderURL = url
            gameFolderURL = url
            refreshMods()
            refreshCatalogIfNeeded()
        } catch {
            stopAccessingCurrentFolder()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func prepareGameFolder(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.appendingPathComponent("Mods", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: url.appendingPathComponent("Disabled Mods", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func refreshMods() {
        enabledMods = mods(in: modsFolderURL)
        disabledMods = mods(in: disabledModsFolderURL)
        installedFolderNames = Set((enabledMods + disabledMods).map { $0.name.lowercased() })
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

            catalogRefreshedAt = Date()
            catalogItems = uniqueCatalogItems(from: catalogMods)
            persistCatalog()
            await refreshDownloadsIfNeeded(force: forceDownloads)
        } catch {
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
            let (data, response) = try await URLSession.shared.data(from: url)
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
        let (data, response) = try await URLSession.shared.data(from: url)
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
        if let folderName = mod.folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty {
            dictionary[folderName.lowercased()] = mod
        }
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

    private func downloadAndInstall(_ mod: CatalogMod) async {
        guard let modsFolderURL else { return }

        installingModIDs.insert(mod.id)
        installingModName = mod.name ?? mod.id
        defer {
            installingModIDs.remove(mod.id)
            installingModName = nil
        }

        do {
            let downloadURL = try await resolveDownloadURL(for: mod.id)
            let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                throw ModInstallError.downloadFailed
            }

            let archiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
            defer { try? FileManager.default.removeItem(at: archiveURL) }

            guard try isZIPArchive(at: archiveURL) else {
                throw ModInstallError.unsupportedArchive
            }

            let stagingURL = modsFolderURL.appendingPathComponent(".staging_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingURL) }

            try extractZIPArchive(at: archiveURL, to: stagingURL)

            let entries = try FileManager.default.contentsOfDirectory(
                at: stagingURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let folders = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            let hasRootFiles = entries.contains {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            let sourceURL = folders.count == 1 && !hasRootFiles ? folders[0] : stagingURL
            let destinationURL = modsFolderURL.appendingPathComponent(mod.installFolderName, isDirectory: true)

            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw ModInstallError.alreadyInstalled
            }

            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            refreshMods()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func isZIPArchive(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        return magic.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || magic.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || magic.starts(with: [0x50, 0x4B, 0x07, 0x08])
    }

    private func extractZIPArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var fileCount = 0
        var expandedSize: UInt64 = 0
        let destinationPath = destinationURL.standardizedFileURL.path

        for entry in archive {
            fileCount += 1
            guard fileCount <= Self.maximumArchiveFileCount else { throw ModInstallError.tooManyArchiveFiles }
            expandedSize += entry.uncompressedSize
            guard expandedSize <= Self.maximumArchiveUncompressedSize else { throw ModInstallError.archiveTooLarge }

            let outputURL = destinationURL.appendingPathComponent(entry.path).standardizedFileURL
            guard outputURL.path == destinationPath || outputURL.path.hasPrefix(destinationPath + "/") else {
                throw ModInstallError.unsafeArchive
            }

            switch entry.type {
            case .directory:
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            case .file:
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(entry, to: outputURL, bufferSize: 64 * 1024)
            case .symlink:
                throw ModInstallError.unsafeArchive
            @unknown default:
                throw ModInstallError.unsafeArchive
            }
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
            let (detailData, detailResponse) = try await URLSession.shared.data(from: detailURL)
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

    private func mods(in folderURL: URL?) -> [InstalledMod] {
        guard let folderURL else { return [] }

        do {
            return try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .filter { $0.lastPathComponent.caseInsensitiveCompare("lovely") != .orderedSame }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { InstalledMod(id: $0, name: $0.lastPathComponent) }
        } catch {
            return []
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
