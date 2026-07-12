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
                    mod: mod,
                    folderStore: folderStore,
                    isEnabled: isEnabled,
                    isUpdateAvailable: isUpdateAvailable
                )
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        ModThumbnail(url: presentation.thumbnailURL)
                    }
                    .frame(height: layout.thumbnailHeight)

                    Text(presentation.title)
                        .font(.balatroChrome(18))
                        .lineLimit(2)

                    Text(presentation.description)
                        .font(.balatroChrome(16))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let author = presentation.author {
                        Text(author)
                            .font(.balatroChrome(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        StatusChip(
                            title: isEnabled ? "Enabled" : "Disabled",
                            color: isEnabled ? .green : .secondary
                        )
                        if let category = presentation.categories.first {
                            StatusChip(title: category, color: .blue)
                        }
                        if isUpdateAvailable {
                            StatusChip(title: "Update", color: .orange)
                        }
                    }
                    .lineLimit(1)
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

                if isUpdateAvailable {
                    Button(action: update) {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .accessibilityLabel("Update \(mod.name)")
                    .tint(.blue)
                }

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete \(mod.name)")
            }
        }
        .padding(12)
        .frame(width: layout.width, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ModDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let mod: InstalledMod
    @ObservedObject var folderStore: ModFolderStore
    let isEnabled: Bool
    let isUpdateAvailable: Bool

    private var presentation: ModPresentation {
        folderStore.presentation(for: mod)
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
            await folderStore.loadDetail(for: mod)
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
                Text(.init(presentation.description))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                DetailRow(label: "Folder", value: mod.name)

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
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, max(0, x - spacing)), height: y + rowHeight)
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

    var body: some View {
        Text(title)
            .font(.balatroChrome(12))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct ModThumbnail: View {
    let url: URL?
    @StateObject private var loader: ThumbnailLoader

    init(url: URL?) {
        self.url = url
        _loader = StateObject(wrappedValue: ThumbnailLoader(url: url))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))

                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if url != nil && loader.isLoading {
                    ProgressView()
                } else if url != nil {
                    Button {
                        Task { await loader.retry() }
                    } label: {
                        placeholder
                    }
                    .accessibilityLabel("Retry thumbnail")
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .task { await loader.load() }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.balatroChrome(22))
            .foregroundStyle(.secondary)
    }
}
