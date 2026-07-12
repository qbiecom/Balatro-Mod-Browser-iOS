import SwiftUI
import UniformTypeIdentifiers
import Foundation

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

private enum ModCategory: String, CaseIterable, Identifiable {
    case content = "Content"
    case joker = "Joker"
    case qualityOfLife = "Quality of Life"
    case technical = "Technical"
    case miscellaneous = "Miscellaneous"
    case resourcePacks = "Resource Packs"
    case api = "API"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .content: "folder"
        case .joker: "theatermasks"
        case .qualityOfLife: "sparkles"
        case .technical: "wrench.and.screwdriver"
        case .miscellaneous: "square.grid.2x2"
        case .resourcePacks: "shippingbox"
        case .api: "curlybraces"
        }
    }
}

enum TileLayout {
    static let width: CGFloat = 250
    static let height: CGFloat = 288
    static let thumbnailHeight: CGFloat = 132
}

#Preview {
    ContentView()
}

struct ContentView: View {
    @StateObject private var folderStore = ModFolderStore()
    @State private var selectedSection: AppSection? = .installed
    @State private var selectedCategory: ModCategory?
    @State private var isShowingFolderPicker = false
    @State private var modPendingDeletion: InstalledMod?
    private let columns = [GridItem(.adaptive(minimum: TileLayout.width, maximum: TileLayout.width), spacing: 14)]

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                            .onTapGesture {
                                if section == .allMods { selectedCategory = nil }
                            }
                    }
                }
                Section("Categories") {
                    Button {
                        selectedSection = .allMods
                        selectedCategory = nil
                    } label: {
                        Label("All Categories", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    ForEach(ModCategory.allCases) { category in
                        Button {
                            selectedSection = .allMods
                            selectedCategory = category
                        } label: {
                            Label(category.rawValue, systemImage: category.icon)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 250)
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
                folderStore: folderStore,
                category: selectedCategory?.rawValue,
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
                    if !folderStore.detectedManualMods.isEmpty {
                        untrackedModsView
                    }
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
                            folderStore: folderStore,
                            isEnabled: isEnabled,
                            isUpdateAvailable: folderStore.isUpdateAvailable(for: mod),
                            update: { folderStore.update(mod) }
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

    private var untrackedModsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Untracked Local Mods")
                .font(.title3.weight(.semibold))

            ForEach(folderStore.detectedManualMods) { mod in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mod.title)
                        if mod.catalogMod == nil {
                            Text(mod.folder.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Adopt") { folderStore.adopt(mod) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}
