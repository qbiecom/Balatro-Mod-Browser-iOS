import SwiftUI

struct AllModsView: View {
    let mods: [CatalogMod]
    let isLoading: Bool
    let loadError: String?
    let installedFolderNames: Set<String>
    let isInstalling: (CatalogMod) -> Bool
    let installingModName: String?
    @ObservedObject var folderStore: ModFolderStore
    let category: String?
    let layout: TileLayout
    let refresh: () -> Void
    let install: (CatalogMod) -> Void
    @State private var sort = CatalogSort.name
    @State private var sortAscending = true
    @State private var searchText = ""

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: layout.width, maximum: layout.width), spacing: 14)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Updating mod catalog")
                            .font(.balatroChrome(16))
                            .foregroundStyle(.secondary)
                    }
                }

                if let loadError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(loadError)
                            .font(.balatroChrome(16))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: refresh) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Retry catalog refresh")
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack {
                    Text("\(sortedMods.count)")
                        .font(.balatroChrome(12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    }
                    .accessibilityLabel(sortAscending ? "Sort ascending" : "Sort descending")
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
                            .font(.balatroChrome(16))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if sortedMods.isEmpty {
                    ContentUnavailableView(
                        loadError == nil ? "No Mods Available" : "Catalog Unavailable",
                        systemImage: loadError == nil ? "square.stack.3d.up" : "wifi.exclamationmark",
                        description: Text(loadError == nil ? "The catalog will appear after the Mod Index is loaded." : "Try refreshing when your connection is available.")
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(sortedMods) { mod in
                            CatalogTile(
                                mod: mod,
                                isInstalled: installedFolderNames.contains(mod.installFolderName.lowercased()),
                                isInstalling: isInstalling(mod),
                                folderStore: folderStore,
                                layout: layout,
                                install: { install(mod) }
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .searchable(text: $searchText, prompt: "Search mods")
    }

    private var sortedMods: [CatalogMod] {
        mods.filter { mod in
            guard let category else { return true }
            return mod.categories?.contains {
                normalizedCategory($0) == normalizedCategory(category)
            } == true
        }
        .filter { mod in
            guard !searchText.isEmpty else { return true }
            let query = searchText.localizedLowercase
            return [mod.name, mod.author, mod.summary, mod.categories?.joined(separator: " ")]
                .compactMap { $0?.localizedLowercase }
                .contains { $0.contains(query) }
        }
        .sorted { lhs, rhs in
            switch sort {
            case .name:
                return compareText(lhs.name ?? lhs.id, rhs.name ?? rhs.id)
            case .author:
                return compareText(lhs.author ?? "Unknown", rhs.author ?? "Unknown")
            case .category:
                return compareText(lhs.categories?.first ?? "Miscellaneous", rhs.categories?.first ?? "Miscellaneous")
            case .lastUpdated:
                return compareNumber(lhs.updatedAt?.value ?? 0, rhs.updatedAt?.value ?? 0)
            case .downloads:
                let left = lhs.downloads?.total ?? 0
                let right = rhs.downloads?.total ?? 0
                if left == right {
                    return compareText(lhs.name ?? lhs.id, rhs.name ?? rhs.id)
                }
                return compareNumber(Int64(left), Int64(right))
            }
        }
    }

    private func compareText(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compareNumber(_ lhs: Int64, _ rhs: Int64) -> Bool {
        sortAscending ? lhs < rhs : lhs > rhs
    }

    private func normalizedCategory(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter }
    }
}

struct CatalogTile: View {
    let mod: CatalogMod
    let isInstalled: Bool
    let isInstalling: Bool
    @ObservedObject var folderStore: ModFolderStore
    let layout: TileLayout
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                CatalogModDetailView(mod: mod, folderStore: folderStore)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        ModThumbnail(url: mod.thumbnailURL)
                    }
                    .frame(height: layout.thumbnailHeight)

                    Text(mod.name ?? mod.id)
                        .font(.balatroChrome(20))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.30))
                        .shadow(color: .black.opacity(0.9), radius: 0, x: 1, y: 1)
                        .lineLimit(2)

                    Text(mod.cleanedSummary ?? "No description available")
                        .font(.balatroChrome(15))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.85), radius: 0, x: 1, y: 1)
                        .lineLimit(2)

                    if let author = mod.author {
                        Text(author)
                            .font(.balatroChrome(12))
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                            .lineLimit(1)
                    }

                    if let category = mod.categories?.first {
                        Text(category)
                            .font(.balatroChrome(12))
                            .foregroundStyle(.cyan)
                            .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                            .lineLimit(1)
                    }

                    if let updatedAt = mod.updatedAt, updatedAt.value > 0 {
                        Text("Updated \(Date(timeIntervalSince1970: TimeInterval(updatedAt.value)).formatted(.relative(presentation: .named)))")
                            .font(.balatroChrome(11))
                            .foregroundStyle(.white.opacity(0.72))
                            .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if mod.requiresSteamodded == true {
                            Label("Steamodded", systemImage: "puzzlepiece")
                        }
                        if mod.requiresTalisman == true {
                            Label("Talisman", systemImage: "wand.and.stars")
                        }
                        if let downloads = mod.downloads?.total {
                            Label(downloads.formatted(), systemImage: "arrow.down.circle")
                        }
                    }
                    .font(.balatroChrome(11))
                    .foregroundStyle(.white.opacity(0.78))
                    .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if isInstalled {
                Button {} label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .font(.balatroChrome(16))
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
                            .font(.balatroChrome(16))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
        .padding(12)
        .frame(width: layout.width, alignment: .topLeading)
        .background {
            ModTileBackground(colors: mod.colors, key: mod.name ?? mod.id, isMuted: false)
        }
    }
}

struct CatalogModDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let mod: CatalogMod
    @ObservedObject var folderStore: ModFolderStore

    private var displayedMod: CatalogMod {
        folderStore.catalogMod(id: mod.id) ?? mod
    }

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
                        sidebar.frame(width: 240)
                        details
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Mod Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await folderStore.loadDetail(for: mod) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModThumbnail(url: displayedMod.thumbnailURL)
                .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text("Author")
                    .font(.balatroChrome(12))
                    .foregroundStyle(.secondary)
                Text(displayedMod.author ?? "Unknown")
                    .font(.balatroChrome(18))
            }

            if let url = displayedMod.websiteURL {
                Link(destination: url) {
                    Label("Open Repository", systemImage: "arrow.up.right.square")
                }
            }

            if folderStore.isInstalled(displayedMod) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    folderStore.install(displayedMod)
                } label: {
                    Label("Install Mod", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(folderStore.isInstalling(displayedMod))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(displayedMod.name ?? displayedMod.id)
                    .font(.balatroChrome(28))
                Text(displayedMod.cleanedSummary ?? "No description available")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                if let url = displayedMod.websiteURL {
                    Link(destination: url) {
                        Label("Open Repository", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }
                if let version = displayedMod.version, !version.isEmpty {
                    DetailRow(label: "Version", value: version)
                }
                if let categories = displayedMod.categories, !categories.isEmpty {
                    DetailRow(label: "Categories", value: categories.joined(separator: ", "))
                }
                if displayedMod.requiresSteamodded == true {
                    DetailRow(label: "Requires", value: "Steamodded")
                }
                if displayedMod.requiresTalisman == true {
                    DetailRow(label: "Requires", value: "Talisman")
                }
                if let downloads = displayedMod.downloads?.total {
                    DetailRow(label: "Downloads", value: downloads.formatted())
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum CatalogSort: String, CaseIterable, Identifiable {
    case name
    case author
    case category
    case lastUpdated
    case downloads

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .author: "Author"
        case .category: "Category"
        case .lastUpdated: "Last Updated"
        case .downloads: "Downloads"
        }
    }
}
