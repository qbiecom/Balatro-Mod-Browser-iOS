import SwiftUI

struct SettingsView: View {
    let gameFolderURL: URL?
    @Binding var cardDensity: String
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

            Section("Lovely Mobile Maker") {
                Label("Mod files use Lovely's .lovelyignore marker when disabled.", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Grid") {
                Picker("Card Size", selection: $cardDensity) {
                    ForEach(CardDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
