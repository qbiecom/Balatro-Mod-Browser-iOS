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
                folderStore: folderStore,
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
                            folderStore: folderStore,
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

