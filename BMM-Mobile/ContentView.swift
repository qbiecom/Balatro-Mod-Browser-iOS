import SwiftUI
import Combine
import UniformTypeIdentifiers
import Foundation
import ZIPFoundation

private enum AppSection: String, CaseIterable, Identifiable {
    case installed = "Installed Mods"
    case allMods = "All Mods"
    case settings = "Settings"

    var id: Self { self }

    var icon: String {
        switch self {
        case .installed: "square.grid.2x2"
        case .allMods: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

private enum TileLayout {
    static let width: CGFloat = 250
    static let height: CGFloat = 288
    static let thumbnailHeight: CGFloat = 132
}

struct ContentView: View {
    @StateObject private var folderStore = ModFolderStore()
    @State private var selectedSection: AppSection? = .installed
    @State private var isShowingFolderPicker = false
    @State private var modPendingDeletion: InstalledMod?
    private let columns = [GridItem(.adaptive(minimum: TileLayout.width, maximum: TileLayout.width), spacing: 14)]

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("BMM Mobile")
        } detail: {
            NavigationStack {
                selectedView
                    .navigationTitle(selectedSection?.rawValue ?? "Balatro Mods")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                folderStore.forceRefreshCatalog()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(folderStore.isLoadingCatalog)
                            .accessibilityLabel("Refresh mod details")
                        }
                    }
            }
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            folderStore.handleFolderSelection(result)
        }
        .alert("Couldn't Update Mod", isPresented: $folderStore.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderStore.errorMessage)
        }
        .confirmationDialog(
            "Delete \(modPendingDeletion?.name ?? "this mod")?",
            isPresented: Binding(
                get: { modPendingDeletion != nil },
                set: { if !$0 { modPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Mod", role: .destructive) {
                if let mod = modPendingDeletion {
                    folderStore.delete(mod)
                }
                modPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                modPendingDeletion = nil
            }
        } message: {
            Text("This permanently removes the mod folder and its contents.")
        }
        .task {
            folderStore.refreshCatalogIfNeeded()
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selectedSection ?? .installed {
        case .installed:
            installedModsView
        case .allMods:
            AllModsView(
                mods: folderStore.catalogItems,
                isLoading: folderStore.isLoadingCatalog,
                installedFolderNames: folderStore.installedFolderNames,
                isInstalling: folderStore.isInstalling,
                installingModName: folderStore.installingModName,
                install: folderStore.install
            )
        case .settings:
            SettingsView(gameFolderURL: folderStore.gameFolderURL) {
                isShowingFolderPicker = true
            }
        }
    }

    private var installedModsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if folderStore.gameFolderURL == nil {
                    ContentUnavailableView(
                        "Game Folder Not Connected",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Choose the game folder from your Lovely Mobile Maker app.")
                    )
                } else {
                    if folderStore.isLoadingCatalog {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Updating mod details")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    modGrid(title: "Enabled Mods", mods: folderStore.enabledMods, isEnabled: true)
                    modGrid(title: "Disabled Mods", mods: folderStore.disabledMods, isEnabled: false)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func modGrid(title: String, mods: [InstalledMod], isEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            if mods.isEmpty {
                Text(isEnabled ? "No enabled mods" : "No disabled mods")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(displaySorted(mods)) { mod in
                        ModTile(
                            mod: mod,
                            presentation: folderStore.presentation(for: mod),
                            isEnabled: isEnabled
                        ) {
                            folderStore.setEnabled(!isEnabled, for: mod)
                        } delete: {
                            modPendingDeletion = mod
                        }
                    }
                }
            }
        }
    }

    private func displaySorted(_ mods: [InstalledMod]) -> [InstalledMod] {
        mods.sorted { lhs, rhs in
            let titleOrder = folderStore.presentation(for: lhs).title.localizedStandardCompare(
                folderStore.presentation(for: rhs).title
            )
            if titleOrder == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return titleOrder == .orderedAscending
        }
    }
}

private struct AllModsView: View {
    let mods: [CatalogMod]
    let isLoading: Bool
    let installedFolderNames: Set<String>
    let isInstalling: (CatalogMod) -> Bool
    let installingModName: String?
    let install: (CatalogMod) -> Void
    @State private var sort = CatalogSort.name

    private let columns = [GridItem(.adaptive(minimum: TileLayout.width, maximum: TileLayout.width), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Updating mod catalog")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("All Mods")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(CatalogSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort mods")
                }

                if let installingModName {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Installing \(installingModName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if mods.isEmpty {
                    ContentUnavailableView(
                        "No Mods Available",
                        systemImage: "square.stack.3d.up",
                        description: Text("The catalog will appear after the Mod Index is loaded.")
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(sortedMods) { mod in
                            CatalogTile(
                                mod: mod,
                                isInstalled: installedFolderNames.contains(mod.installFolderName.lowercased()),
                                isInstalling: isInstalling(mod),
                                install: { install(mod) }
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var sortedMods: [CatalogMod] {
        mods.sorted { lhs, rhs in
            switch sort {
            case .name:
                (lhs.name ?? lhs.id).localizedStandardCompare(rhs.name ?? rhs.id) == .orderedAscending
            case .author:
                (lhs.author ?? "Unknown").localizedStandardCompare(rhs.author ?? "Unknown") == .orderedAscending
            case .category:
                (lhs.categories?.first ?? "Miscellaneous").localizedStandardCompare(rhs.categories?.first ?? "Miscellaneous") == .orderedAscending
            case .lastUpdated:
                (lhs.updatedAt?.value ?? 0) > (rhs.updatedAt?.value ?? 0)
            }
        }
    }
}

private struct CatalogTile: View {
    let mod: CatalogMod
    let isInstalled: Bool
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ModThumbnail(url: mod.thumbnailURL)
            }
            .frame(height: TileLayout.thumbnailHeight)

            Text(mod.name ?? mod.id)
                .font(.headline)
                .lineLimit(2)

            Text(mod.cleanedSummary ?? "No description available")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let author = mod.author {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isInstalled {
                Button {} label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(true)
            } else {
                Button(action: install) {
                    if isInstalling {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Installing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
        .padding(12)
        .frame(width: TileLayout.width, height: TileLayout.height, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum CatalogSort: String, CaseIterable, Identifiable {
    case name
    case author
    case category
    case lastUpdated

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .author: "Author"
        case .category: "Category"
        case .lastUpdated: "Last Updated"
        }
    }
}

private struct SettingsView: View {
    let gameFolderURL: URL?
    let chooseFolder: () -> Void

    var body: some View {
        List {
            Section("Game Folder") {
                Button(action: chooseFolder) {
                    Label(gameFolderURL == nil ? "Choose Game Folder" : "Change Game Folder", systemImage: "folder")
                }

                if let gameFolderURL {
                    Label(gameFolderURL.path, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct FlexibleTimestamp: Codable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
        } else if let string = try? container.decode(String.self), let value = Int64(string) {
            self.value = value
        } else {
            self.value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

private struct ModTile: View {
    let mod: InstalledMod
    let presentation: ModPresentation
    let isEnabled: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ModDetailView(mod: mod, presentation: presentation, isEnabled: isEnabled)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        ModThumbnail(url: presentation.thumbnailURL)
                    }
                    .frame(height: TileLayout.thumbnailHeight)

                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(2)

                    Text(presentation.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let author = presentation.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(isEnabled ? .green : .secondary)
                    .accessibilityLabel(isEnabled ? "Enabled" : "Disabled")

                Spacer()

                Toggle(mod.name, isOn: Binding(
                    get: { isEnabled },
                    set: { _ in toggle() }
                ))
                .labelsHidden()

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete \(mod.name)")
            }
        }
        .padding(12)
        .frame(width: TileLayout.width, height: TileLayout.height, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InstalledMod: Identifiable {
    let id: URL
    let name: String
}

private struct CatalogMod: Codable, Identifiable {
    let id: String
    let name: String?
    let author: String?
    let summary: String?
    let folderName: String?
    let version: String?
    let categories: [String]?
    let repository: String?
    let thumbnailPath: String?
    let updatedAt: FlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case author
        case summary
        case folderName = "folder_name"
        case version
        case categories
        case repository = "repo"
        case thumbnailPath = "thumbnail_url"
        case updatedAt = "updated_at"
    }

    var installFolderName: String {
        let candidate = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? id : candidate
    }

    var cleanedSummary: String? {
        let value = summary?
            .replacingOccurrences(of: "![]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var thumbnailURL: URL? {
        guard let thumbnailPath, !thumbnailPath.isEmpty else { return nil }
        if let absoluteURL = URL(string: thumbnailPath), absoluteURL.scheme != nil {
            return absoluteURL
        }
        let path = thumbnailPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://api-bmi.dasguney.com/")?.appendingPathComponent(path)
    }
}

private struct ModPresentation {
    let title: String
    let description: String
    let author: String?
    let version: String?
    let categories: [String]
    let repositoryURL: URL?
    let thumbnailURL: URL?
}

private struct ModDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let mod: InstalledMod
    let presentation: ModPresentation
    let isEnabled: Bool

    var body: some View {
        ScrollView {
            Group {
                if horizontalSizeClass == .compact {
                    VStack(alignment: .leading, spacing: 16) {
                        sidebar
                        details
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        sidebar
                            .frame(width: 240)
                        details
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Mod Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                ModThumbnail(url: presentation.thumbnailURL)
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text("Author")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation.author ?? "Unknown")
                    .font(.headline)
            }

            if let repositoryURL = presentation.repositoryURL {
                Link(destination: repositoryURL) {
                    Label("Open Mod Website", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(presentation.title)
                    .font(.title2.weight(.bold))
                Text(presentation.description)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: "Status", value: isEnabled ? "Enabled" : "Disabled")
                DetailRow(label: "Folder", value: mod.name)

                if let version = presentation.version, !version.isEmpty {
                    DetailRow(label: "Version", value: version)
                }
                if !presentation.categories.isEmpty {
                    DetailRow(label: "Categories", value: presentation.categories.joined(separator: ", "))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ModThumbnail: View {
    let url: URL?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))

                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else if phase.error == nil {
                            ProgressView()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}

private struct CatalogPage: Decodable {
    let items: [CatalogMod]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private enum ModInstallError: LocalizedError {
    case downloadFailed
    case alreadyInstalled

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            "The mod download could not be completed."
        case .alreadyInstalled:
            "A mod with this folder name is already installed."
        }
    }
}

@MainActor
private final class ModFolderStore: ObservableObject {
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
    private let catalogCacheKey = "modIndexMetadataCache"
    private let catalogCacheDateKey = "modIndexMetadataCacheDate"
    private let catalogCacheLifetime: TimeInterval = 60 * 60 * 6
    private var activeGameFolderURL: URL?
    private var catalogMods: [String: CatalogMod] = [:]

    private var modsFolderURL: URL? {
        gameFolderURL?.appendingPathComponent("Mods", isDirectory: true)
    }

    private var disabledModsFolderURL: URL? {
        gameFolderURL?.appendingPathComponent("Disabled Mods", isDirectory: true)
    }

    init() {
        loadCachedCatalog()
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
            await fetchCatalog()
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
        if !catalogItems.isEmpty && catalogItems.allSatisfy({ $0.thumbnailPath == nil }) {
            return true
        }
        guard let cacheDate = UserDefaults.standard.object(forKey: catalogCacheDateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(cacheDate) > catalogCacheLifetime
    }

    private func loadCachedCatalog() {
        guard let data = UserDefaults.standard.data(forKey: catalogCacheKey),
              let cached = try? JSONDecoder().decode([String: CatalogMod].self, from: data) else {
            return
        }
        catalogMods = cached
        catalogItems = uniqueCatalogItems(from: cached)
    }

    private func fetchCatalog() async {
        guard !isLoadingCatalog else { return }

        var cursor: String?
        var fetched: [String: CatalogMod] = [:]

        isLoadingCatalog = true
        defer { isLoadingCatalog = false }

        do {
            repeat {
                var components = URLComponents(string: "https://api-bmi.dasguney.com/mods")
                var queryItems = [
                    URLQueryItem(name: "limit", value: "200"),
                    URLQueryItem(name: "sort", value: "name_asc")
                ]
                if let cursor {
                    queryItems.append(URLQueryItem(name: "cursor", value: cursor))
                }
                components?.queryItems = queryItems

                guard let url = components?.url else { return }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                    return
                }

                let page = try JSONDecoder().decode(CatalogPage.self, from: data)
                for mod in page.items {
                    fetched[mod.id.lowercased()] = mod
                    if let folderName = mod.folderName, !folderName.isEmpty {
                        fetched[folderName.lowercased()] = mod
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil

            catalogMods = fetched
            catalogItems = uniqueCatalogItems(from: fetched)
            if let data = try? JSONEncoder().encode(fetched) {
                UserDefaults.standard.set(data, forKey: catalogCacheKey)
                UserDefaults.standard.set(Date(), forKey: catalogCacheDateKey)
            }
        } catch {
            return
        }
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
            let (archiveData, response) = try await URLSession.shared.data(from: downloadURL)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                throw ModInstallError.downloadFailed
            }

            let archiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")
            try archiveData.write(to: archiveURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: archiveURL) }

            let stagingURL = modsFolderURL.appendingPathComponent(".staging_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingURL) }

            try FileManager.default.unzipItem(at: archiveURL, to: stagingURL)

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

#Preview {
    ContentView()
}
