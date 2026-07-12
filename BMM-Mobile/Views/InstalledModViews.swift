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
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
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
                HStack(spacing: 8) {
                    StatusChip(title: isEnabled ? "Enabled" : "Disabled", color: isEnabled ? .green : .secondary)
                    if isUpdateAvailable {
                        StatusChip(title: "Update Available", color: .orange)
                    }
                }
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
            .font(.caption2.weight(.medium))
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
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}
