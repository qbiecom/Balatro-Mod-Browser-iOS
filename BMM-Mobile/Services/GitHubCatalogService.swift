import Foundation

/// Reads a commit-pinned community index without a catalog server or per-file GitHub API calls.
actor GitHubCatalogService {
    nonisolated static let repository = "kasimeka/balatro-mod-index"
    private let session: TrustedDownloadSession

    struct Snapshot {
        let revision: String
        let records: [String: CatalogMod]
        let fileHashes: [String: String]
        let skippedEntries: [String]
    }

    init(session: TrustedDownloadSession = TrustedDownloadSession()) { self.session = session }

    func fetch(records: [String: CatalogMod], fileHashes: [String: String]) async throws -> Snapshot {
        let endpoint = URL(string: "https://api.github.com/repos/\(Self.repository)/commits/main")!
        let (commitData, _) = try await session.data(from: endpoint, maximumBytes: 2 * 1024 * 1024)
        let commit = try JSONDecoder().decode(IndexCommit.self, from: commitData)
        guard Self.isRevision(commit.sha) else { throw GitHubCatalogError.invalidIndex }
        let treeURL = URL(string: "https://api.github.com/repos/\(Self.repository)/git/trees/\(commit.sha)?recursive=1")!
        let (treeData, _) = try await session.data(from: treeURL, maximumBytes: 8 * 1024 * 1024)
        let files = try Self.catalogFiles(from: treeData)
        let session = self.session
        var updated: [String: CatalogMod] = [:]
        var skipped: [String] = []
        // Eight raw-content requests at a time; unchanged files need no transfer.
        let ids = files.keys.sorted()
        for start in stride(from: 0, to: ids.count, by: 8) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + 8, ids.count)]
            let fetched = try await withThrowingTaskGroup(of: (String, CatalogMod?).self) { group in
                for id in batch {
                    let fingerprint = files[id]!
                    if fileHashes[id.lowercased()] == fingerprint, let cached = records[id.lowercased()] {
                        updated[id.lowercased()] = cached
                        continue
                    }
                    group.addTask {
                        let url = try Self.contentURL(id: id, filename: "meta.json", revision: commit.sha)
                        let (data, _) = try await session.data(from: url, maximumBytes: 128 * 1024)
                        guard let metadata = try? JSONDecoder().decode(GitHubIndexMetadata.self, from: data) else { return (id, nil) }
                        return (id, try? metadata.catalogMod(id: id, revision: commit.sha, hasThumbnail: !fingerprint.hasSuffix(":")))
                    }
                }
                var mods: [(String, CatalogMod?)] = []
                for try await mod in group { mods.append(mod) }
                return mods
            }
            for (id, mod) in fetched {
                if let mod { updated[id.lowercased()] = mod }
                else {
                    skipped.append(id)
                    updated[id.lowercased()] = records[id.lowercased()]
                }
            }
        }
        guard !updated.isEmpty else { throw GitHubCatalogError.invalidIndex }
        var hashes = Dictionary(uniqueKeysWithValues: files.map { ($0.key.lowercased(), $0.value) })
        for id in skipped { hashes[id.lowercased()] = fileHashes[id.lowercased()] }
        return Snapshot(revision: commit.sha, records: updated,
                        fileHashes: hashes, skippedEntries: skipped.sorted())
    }

    func detail(for mod: CatalogMod, revision: String) async throws -> CatalogMod {
        let url = try Self.contentURL(id: mod.id, filename: "description.md", revision: revision)
        let (data, _) = try await session.data(from: url, maximumBytes: 512 * 1024)
        guard let description = String(data: data, encoding: .utf8) else { throw GitHubCatalogError.invalidIndex }
        return mod.replacingDescription(with: description)
    }

    /// Requires a complete tree, real files, unique IDs, and the two required index files.
    nonisolated static func catalogFiles(from data: Data) throws -> [String: String] {
        let tree = try JSONDecoder().decode(IndexTree.self, from: data)
        guard !tree.truncated, tree.tree.count <= 20_000 else { throw GitHubCatalogError.invalidIndex }
        var files: [String: [String: String]] = [:]
        var normalizedIDs: [String: String] = [:]
        for entry in tree.tree {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "mods", ["meta.json", "description.md", "thumbnail.jpg"].contains(String(parts[2])) else { continue }
            let id = String(parts[1])
            guard Self.isID(id), entry.type == "blob", entry.mode == "100644" || entry.mode == "100755",
                  Self.isRevision(entry.sha) else { throw GitHubCatalogError.invalidIndex }
            if let prior = normalizedIDs[id.lowercased()], prior != id { throw GitHubCatalogError.invalidIndex }
            normalizedIDs[id.lowercased()] = id
            guard files[id]?[String(parts[2])] == nil else { throw GitHubCatalogError.invalidIndex }
            files[id, default: [:]][String(parts[2])] = entry.sha
        }
        guard !files.isEmpty, files.count <= 5_000 else { throw GitHubCatalogError.invalidIndex }
        return try files.mapValues { entry in
            guard let meta = entry["meta.json"], let description = entry["description.md"] else { throw GitHubCatalogError.invalidIndex }
            return [meta, description, entry["thumbnail.jpg"] ?? ""].joined(separator: ":")
        }
    }

    nonisolated static func contentURL(id: String, filename: String, revision: String) throws -> URL {
        guard isID(id), isRevision(revision), ["meta.json", "description.md", "thumbnail.jpg"].contains(filename),
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~@"))),
              let url = URL(string: "https://raw.githubusercontent.com/\(repository)/\(revision)/mods/\(encoded)/\(filename)") else { throw GitHubCatalogError.invalidIndex }
        return url
    }

    nonisolated private static func isID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
            && id.rangeOfCharacter(from: .controlCharacters) == nil
    }

    nonisolated private static func isRevision(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct GitHubIndexMetadata: Decodable {
    let title: String
    let author: String
    let repo: String
    let downloadURL: String
    let folderName: String?
    let version: String
    let categories: [String]
    let requiresSteamodded: Bool
    let requiresTalisman: Bool
    let lastUpdated: Int64?

    enum CodingKeys: String, CodingKey {
        case title, author, repo, downloadURL, folderName, version, categories
        case requiresSteamodded = "requires-steamodded"
        case requiresTalisman = "requires-talisman"
        case lastUpdated = "last-updated"
    }

    func catalogMod(id: String, revision: String, hasThumbnail: Bool = true) throws -> CatalogMod {
        let thumbnail = hasThumbnail ? try GitHubCatalogService.contentURL(id: id, filename: "thumbnail.jpg", revision: revision) : nil
        let timestamp = try lastUpdated.flatMap { value -> FlexibleTimestamp? in
            guard value > 0 else { return nil }
            return try JSONDecoder().decode(FlexibleTimestamp.self, from: Data(String(value).utf8))
        }
        guard !title.isEmpty, !version.isEmpty else { throw GitHubCatalogError.invalidIndex }
        return CatalogMod(id: id, name: title, author: author, summary: nil, folderName: folderName,
                          version: version, categories: categories, repository: repo,
                          thumbnailPath: thumbnail?.absoluteString, updatedAt: timestamp,
                          description: nil, descriptionHTML: nil, homepage: nil,
                          requiresSteamodded: requiresSteamodded, requiresTalisman: requiresTalisman,
                          downloadURL: downloadURL, downloads: nil, isDeleted: false, colors: nil)
    }
}

nonisolated private struct IndexCommit: Decodable { let sha: String }
nonisolated private struct IndexTree: Decodable {
    let truncated: Bool
    let tree: [Entry]
    nonisolated struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String }
}

enum GitHubCatalogError: LocalizedError {
    case invalidIndex
    var errorDescription: String? { "The mod index response was incomplete or invalid. Your cached catalog has been kept. Try refreshing again." }
}
