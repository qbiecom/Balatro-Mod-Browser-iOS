import SwiftUI

struct SettingsView: View {
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

