import SwiftUI
import UniformTypeIdentifiers
import Foundation

private enum AppSection: String, CaseIterable, Identifiable, Hashable {
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

private enum ModCategory: String, CaseIterable, Identifiable, Hashable {
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

private enum SidebarDestination: Hashable {
    case section(AppSection)
    case allCategories
    case category(ModCategory)

    var title: String {
        switch self {
        case .section(let section): section.rawValue
        case .allCategories: "All Mods"
        case .category(let category): category.rawValue
        }
    }

    var category: String? {
        if case .category(let category) = self { return category.rawValue }
        return nil
    }
}

enum CardDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
    var layout: TileLayout {
        switch self {
        case .compact: TileLayout(width: 220, height: 316, thumbnailHeight: 116)
        case .comfortable: TileLayout(width: 250, height: 348, thumbnailHeight: 132)
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct TileLayout {
    let width: CGFloat
    let height: CGFloat
    let thumbnailHeight: CGFloat
}

#Preview {
    ContentView()
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var folderStore = ModFolderStore()
    @AppStorage("cardDensity") private var cardDensityRaw = CardDensity.comfortable.rawValue
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @State private var selectedDestination: SidebarDestination? = .section(.installed)
    @State private var isShowingFolderPicker = false
    @State private var modPendingDeletion: InstalledMod?
    private var cardDensity: CardDensity { CardDensity(rawValue: cardDensityRaw) ?? .comfortable }
    private var appTheme: AppTheme { AppTheme(rawValue: appThemeRaw) ?? .system }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardDensity.layout.width, maximum: cardDensity.layout.width), spacing: 14)]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedDestination) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        HStack {
                            Label(section.rawValue, systemImage: section.icon)
                            Spacer()
                            if section == .installed, !folderStore.updateAvailableNames.isEmpty {
                                Text("\(folderStore.updateAvailableNames.count)")
                                    .font(.balatroChrome(12))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                            }
                        }
                        .font(.balatroChrome(17))
                            .tag(SidebarDestination.section(section))
                    }
                }
                Section("Categories") {
                    Label("All Categories", systemImage: "line.3.horizontal.decrease.circle")
                        .tag(SidebarDestination.allCategories)
                    ForEach(ModCategory.allCases) { category in
                        HStack {
                            Label(category.rawValue, systemImage: category.icon)
                            Spacer()
                            Text("\(categoryCount(category))")
                                .font(.balatroChrome(12))
                                .foregroundStyle(.secondary)
                        }
                        .font(.balatroChrome(15))
                            .tag(SidebarDestination.category(category))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 250)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Balatro Mod Browser")
                        .font(.balatroChrome(24))
                }
            }
        } detail: {
            NavigationStack {
                selectedView
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(selectedDestination?.title ?? "Balatro Mods")
                                .font(.balatroChrome(24))
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                folderStore.forceRefreshCatalog()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(folderStore.isLoadingCatalog || folderStore.isFolderOperationBusy)
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
        .alert("Game Folder Needs Re-linking", isPresented: $folderStore.isShowingGameFolderRelinkNotice) {
            Button("Choose Game Folder") {
                isShowingFolderPicker = true
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Lovely Mobile Maker's game folder is no longer available at its previous location. Select the renewed folder named game so Balatro Mod Browser can reconnect your installed mods.")
        }
        .alert("Couldn't Update Mod", isPresented: $folderStore.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderStore.errorMessage)
        }
        .alert("Catalog Updated", isPresented: $folderStore.isShowingCatalogInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderStore.catalogInfoMessage)
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
        .confirmationDialog(
            "Install Required Mods?",
            isPresented: Binding(
                get: { folderStore.dependencyInstallRequest != nil },
                set: { if !$0 { folderStore.cancelDependencyInstall() } }
            ),
            titleVisibility: .visible
        ) {
            if let request = folderStore.dependencyInstallRequest {
                if request.talismanProviderOptions.isEmpty {
                    Button("Install Required Mods") {
                        folderStore.confirmDependencyInstall()
                    }
                } else {
                    ForEach(request.talismanProviderOptions) { provider in
                        Button("Use \(provider.name ?? provider.id)") {
                            folderStore.confirmDependencyInstall(talismanProvider: provider)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                folderStore.cancelDependencyInstall()
            }
        } message: {
            Text(dependencyInstallMessage)
        }
        .task {
            folderStore.refreshCatalogIfNeeded()
        }
        .preferredColorScheme(appTheme.colorScheme)
        .font(.balatroChrome(16))
        .onChange(of: scenePhase, initial: true) { _, phase in
            folderStore.applicationLifecycleDidChange(isActive: phase == .active)
        }
    }

    private var dependencyInstallMessage: String {
        guard let request = folderStore.dependencyInstallRequest else { return "" }
        let names = request.dependencies.map { $0.name ?? $0.id }
        if !request.talismanProviderOptions.isEmpty {
            let choices = request.talismanProviderOptions.map { $0.name ?? $0.id }.joined(separator: " or ")
            let prefix = names.isEmpty ? "" : "It also needs \(names.joined(separator: ", ")). "
            return "\(prefix)This mod requires a Talisman-compatible provider. Choose \(choices)."
        }
        return "This mod also requires \(names.joined(separator: ", ")). They will be installed first."
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selectedDestination ?? .section(.installed) {
        case .section(.installed):
            installedModsView
        case .section(.allMods), .allCategories, .category:
            AllModsView(
                mods: folderStore.catalogItems,
                isLoading: folderStore.isLoadingCatalog,
                loadError: folderStore.catalogErrorMessage,
                installedFolderNames: folderStore.installedFolderNames,
                isInstalling: folderStore.isInstalling,
                installingModName: folderStore.installingModName,
                folderStore: folderStore,
                category: selectedDestination?.category,
                layout: cardDensity.layout,
                refresh: folderStore.forceRefreshCatalog,
                install: folderStore.install
            )
        case .section(.settings):
            SettingsView(
                gameFolderURL: folderStore.gameFolderURL,
                cardDensity: $cardDensityRaw,
                appTheme: $appThemeRaw,
                clearCache: folderStore.clearCatalogCache,
                totalModCount: folderStore.totalModCount,
                lastCatalogRefresh: folderStore.lastCatalogRefresh
            ) {
                isShowingFolderPicker = true
            }
        }
    }


    private var installedModsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if folderStore.gameFolderURL == nil {
                    firstRunFolderPicker
                } else {
                    if folderStore.isLoadingCatalog {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Updating mod details")
                                .font(.balatroChrome(16))
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

    private var firstRunFolderPicker: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.blue)

            VStack(spacing: 10) {
                Text(folderStore.needsGameFolderRelink ? "Reconnect Your Game Folder" : "Connect Your Game Folder")
                    .font(.balatroChrome(28))

                Text(folderStore.needsGameFolderRelink
                    ? "Lovely Mobile Maker's game folder moved or was renewed. Select its current location to restore Balatro Mod Browser's connection."
                    : "Balatro Mod Browser needs access to the Lovely Mobile Maker game folder before it can manage mods.")
                    .font(.balatroChrome(16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Select the folder named game", systemImage: "checkmark.circle.fill")
                Label("Do not select Mods on its own", systemImage: "xmark.circle.fill")
            }
            .font(.balatroChrome(15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 370, alignment: .leading)

            Button {
                isShowingFolderPicker = true
            } label: {
                Label(folderStore.needsGameFolderRelink ? "Reconnect Game Folder" : "Choose Game Folder", systemImage: "folder")
                    .font(.balatroChrome(18))
                    .frame(minWidth: 210)
            }
            .disabled(folderStore.isFolderOperationBusy)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, minHeight: 470)
        .padding(32)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    /// Renders one enabled or disabled installed-mod section using the selected fixed card density.
    private func modGrid(title: String, mods: [InstalledMod], isEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.balatroChrome(22))

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
                            layout: cardDensity.layout,
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

    /// Sorts by catalog display title while retaining a stable folder-name tie-breaker.
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

    /// Counts catalog entries using normalization that tolerates BMI category punctuation and spacing.
    private func categoryCount(_ category: ModCategory) -> Int {
        folderStore.catalogItems.filter { mod in
            mod.categories?.contains {
                $0.lowercased().filter(\.isLetter) == category.rawValue.lowercased().filter(\.isLetter)
            } == true
        }.count
    }

}
