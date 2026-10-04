// swift-tools-version: 6.2
import PackageDescription

// Exercises the actual filesystem and model code on macOS without an iOS simulator.
let package = Package(
    name: "BMMCore",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(
            name: "BMMCore",
            dependencies: ["ZIPFoundation"],
            path: "BMM-Mobile",
            exclude: ["Assets.xcassets", "Fonts", "Views", "BMMMobileApp.swift", "ContentView.swift",
                      "Services/ModFolderStore.swift", "Services/ThumbnailLoader.swift",
                      "Services/ThumbnailCache.swift", "Services/ModsFolderPresenter.swift"],
            sources: ["Models/ModModels.swift", "Services/ModFileService.swift",
                      "Services/InstalledModRegistry.swift", "Services/TrustedDownloadSession.swift",
                      "Services/GitHubCatalogService.swift", "Services/CatalogFileCache.swift"]
        ),
        .testTarget(name: "BMMCoreTests", dependencies: ["BMMCore", "ZIPFoundation"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
