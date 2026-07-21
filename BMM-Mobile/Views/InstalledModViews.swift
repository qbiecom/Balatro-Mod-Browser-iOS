import SwiftUI

struct ModTile: View {
    let mod: InstalledMod
    let presentation: ModPresentation
    @ObservedObject var folderStore: ModFolderStore
    let isEnabled: Bool
    let isUpdateAvailable: Bool
    let layout: TileLayout
    let update: () -> Void
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ModDetailView(
                    installedModID: mod.id,
                    folderStore: folderStore
                )
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        ModThumbnail(url: presentation.thumbnailURL)
                    }
                    .frame(height: layout.thumbnailHeight)

                    Text(presentation.title)
                        .font(.balatroChrome(20))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.30))
                        .shadow(color: .black.opacity(0.9), radius: 0, x: 1, y: 1)
                        .lineLimit(2)

                    Text(presentation.description)
                        .font(.balatroChrome(15))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.85), radius: 0, x: 1, y: 1)
                        .lineLimit(2)

                    if let author = presentation.author {
                        Text(author)
                        .font(.balatroChrome(12))
                        .foregroundStyle(.white.opacity(0.78))
                        .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                            .lineLimit(1)
                    }

                    FlowLayout(spacing: 6) {
                        ForEach(presentation.categories, id: \.self) { category in
                            StatusChip(
                                title: category,
                                color: .cyan,
                                backgroundColor: .black,
                                backgroundOpacity: 0.24
                            )
                        }
                        if isUpdateAvailable {
                            StatusChip(title: "Update", color: .orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(isEnabled ? .green : .secondary)
                    .accessibilityLabel(isEnabled ? "Enabled" : "Disabled")

                if isUpdateAvailable {
                    Button(action: update) {
                        Label("Update", systemImage: "arrow.down.circle")
                            .font(.balatroChrome(15))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Update \(mod.name)")
                } else {
                    Spacer()
                }

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
        .frame(width: layout.width, alignment: .topLeading)
        .background {
            ModTileBackground(colors: presentation.colors, key: presentation.title, isMuted: !isEnabled)
        }
    }
}

private struct ModDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let installedModID: URL
    @ObservedObject var folderStore: ModFolderStore
    private var mod: InstalledMod? { folderStore.installedMod(id: installedModID) }
    private var isEnabled: Bool { mod.map(folderStore.isEnabled) ?? false }
    private var isUpdateAvailable: Bool { mod.map(folderStore.isUpdateAvailable(for:)) ?? false }

    private var presentation: ModPresentation {
        guard let mod else {
            return ModPresentation(title: installedModID.lastPathComponent, description: "This mod folder is no longer available.", author: nil, version: nil, categories: [], repositoryURL: nil, thumbnailURL: nil, requiresSteamodded: false, requiresTalisman: false, downloads: nil, updatedAt: nil, colors: nil)
        }
        return folderStore.presentation(for: mod)
    }

    var body: some View {
        ScrollView {
            Group {
                if mod == nil {
                    ContentUnavailableView("Mod No Longer Available", systemImage: "folder.badge.questionmark", description: Text("The mod directory was removed or is no longer accessible."))
                } else if horizontalSizeClass == .compact {
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
        .task {
            await folderStore.loadDetail(forInstalledModID: installedModID)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(presentation.title)
                .font(.balatroChrome(22))

            ZStack {
                ModThumbnail(url: presentation.thumbnailURL)
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text("Author")
                    .font(.balatroChrome(12))
                    .foregroundStyle(.secondary)
                Text(presentation.author ?? "Unknown")
                    .font(.balatroChrome(18))
            }

            HStack(spacing: 8) {
                StatusChip(title: isEnabled ? "Enabled" : "Disabled", color: isEnabled ? .green : .secondary)
                if isUpdateAvailable {
                    StatusChip(title: "Update", color: .orange)
                }
            }

            if let mod, isUpdateAvailable {
                Button {
                    folderStore.update(mod)
                } label: {
                    Label("Update Mod", systemImage: "arrow.down.circle")
                        .font(.balatroChrome(16))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!folderStore.isInstallerAvailable)
                .accessibilityHint(folderStore.installerAvailability.message)
            }

            if let downloads = presentation.downloads {
                Label(downloads.formatted(), systemImage: "arrow.down.circle")
                    .font(.balatroChrome(14))
                    .foregroundStyle(.secondary)
            }

            if let repositoryURL = presentation.repositoryURL {
                Link(destination: repositoryURL) {
                    Label("Open Repository", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !presentation.categories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Categories")
                        .font(.balatroChrome(12))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(presentation.categories, id: \.self) { category in
                            StatusChip(title: category, color: .blue)
                        }
                    }
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
                    .font(.balatroChrome(28))
                ForEach(detailSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if section.title != "Overview" {
                            Text(section.title)
                                .font(.balatroChrome(20))
                        }
                        Text(section.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, section.title == "Overview" ? 0 : 8)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: "Folder", value: mod?.name ?? installedModID.lastPathComponent)

                if let version = presentation.version, !version.isEmpty {
                    DetailRow(label: "Version", value: version)
                }
                if !presentation.categories.isEmpty {
                    DetailRow(label: "Categories", value: presentation.categories.joined(separator: ", "))
                }
                if presentation.requiresSteamodded {
                    DetailRow(label: "Requires", value: "Steamodded")
                }
                if presentation.requiresTalisman {
                    DetailRow(label: "Requires", value: "Talisman")
                }
                if let downloads = presentation.downloads {
                    DetailRow(label: "Downloads", value: downloads.formatted())
                }
                if let updatedAt = presentation.updatedAt {
                    DetailRow(label: "Last Updated", value: updatedAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var detailSections: [DetailTextSection] {
        let lines = presentation.description
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != presentation.title }
        var sections: [DetailTextSection] = []
        var title = "Overview"
        var content: [String] = []

        func appendSection() {
            guard !content.isEmpty else { return }
            sections.append(DetailTextSection(title: title, body: content.joined(separator: "\n")))
        }

        for line in lines {
            if ["Usage", "Acknowledgements"].contains(line) {
                appendSection()
                title = line
                content = []
            } else {
                content.append(line)
            }
        }
        appendSection()
        return sections.isEmpty ? [DetailTextSection(title: "Overview", body: presentation.description)] : sections
    }
}

private struct DetailTextSection: Identifiable {
    let title: String
    let body: String
    var id: String { title }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maximumRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                maximumRowWidth = max(maximumRowWidth, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maximumRowWidth = max(maximumRowWidth, max(0, x - spacing))
        return CGSize(width: min(width, maximumRowWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct DetailRow: View {
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

struct StatusChip: View {
    let title: String
    let color: Color
    var backgroundColor: Color? = nil
    var backgroundOpacity = 0.14

    var body: some View {
        Text(title)
            .font(.balatroChrome(12))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((backgroundColor ?? color).opacity(backgroundOpacity), in: Capsule())
    }
}

struct ModThumbnail: View {
    let url: URL?
    @StateObject private var loader: ThumbnailLoader
    @ObservedObject private var cache = ThumbnailCache.shared

    init(url: URL?) {
        self.url = url
        _loader = StateObject(wrappedValue: ThumbnailLoader(url: url))
    }

    var body: some View {
        GeometryReader { proxy in
            let pixelBucket = ThumbnailLoader.pixelBucket(for: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(loader.image == nil ? 0.08 : 0.16))

                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if url != nil && loader.isLoading {
                    ProgressView()
                } else if url != nil {
                    Button {
                        Task { await loader.retry(displaySize: proxy.size) }
                    } label: {
                        placeholder
                    }
                    .accessibilityLabel("Retry thumbnail")
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: LoadID(url: url, cacheGeneration: cache.generation, pixelBucket: pixelBucket)) {
                loader.replace(url: url)
                await loader.load(pixelBucket: pixelBucket)
            }
        }
        .onDisappear { loader.cancel() }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.balatroChrome(22))
            .foregroundStyle(.secondary.opacity(0.48))
    }

    private struct LoadID: Equatable {
        let url: URL?
        let cacheGeneration: UInt
        let pixelBucket: Int

        init(url: URL?, cacheGeneration: UInt, pixelBucket: Int) {
            self.url = url
            self.cacheGeneration = cacheGeneration
            self.pixelBucket = pixelBucket
        }
    }
}
