import SwiftUI

struct AllModsView: View {
    let mods: [CatalogMod]
    let isLoading: Bool
    let installedFolderNames: Set<String>
    let isInstalling: (CatalogMod) -> Bool
    let installingModName: String?
    @ObservedObject var folderStore: ModFolderStore
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
                                folderStore: folderStore,
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

struct CatalogTile: View {
    let mod: CatalogMod
    let isInstalled: Bool
    let isInstalling: Bool
    @ObservedObject var folderStore: ModFolderStore
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayedMod.author ?? "Unknown")
                    .font(.headline)
            }

            if let repository = displayedMod.repository, let url = URL(string: repository) {
                Link(destination: url) {
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
                Text(displayedMod.name ?? displayedMod.id)
                    .font(.title2.weight(.bold))
                Text(displayedMod.cleanedSummary ?? "No description available")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
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
