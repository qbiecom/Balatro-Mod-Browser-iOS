import Foundation

struct FlexibleTimestamp: Codable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
        } else if let string = try? container.decode(String.self), let value = Int64(string) {
            self.value = value
        } else {
            self.value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct InstalledMod: Identifiable {
    let id: URL
    let name: String
}

struct CatalogMod: Codable, Identifiable {
    let id: String
    let name: String?
    let author: String?
    let summary: String?
    let folderName: String?
    let version: String?
    let categories: [String]?
    let repository: String?
    let thumbnailPath: String?
    let updatedAt: FlexibleTimestamp?
    let description: String?
    let requiresSteamodded: Bool?
    let requiresTalisman: Bool?
    let downloadURL: String?
    let downloads: ModDownloads?
    let isDeleted: Bool?
    let colors: ModColors?

    enum CodingKeys: String, CodingKey {
        case id, name, author, summary, version, categories, description, downloads, colors
        case folderName = "folder_name"
        case repository = "repo"
        case thumbnailPath = "thumbnail_url"
        case updatedAt = "updated_at"
        case requiresSteamodded = "requires_steamodded"
        case requiresTalisman = "requires_talisman"
        case downloadURL = "download_url"
        case isDeleted = "deleted"
    }

    var installFolderName: String {
        let candidate = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? id : candidate
    }

    var cleanedSummary: String? {
        let value = (description ?? summary)?
            .replacingOccurrences(of: "![]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var thumbnailURL: URL? {
        guard let thumbnailPath, !thumbnailPath.isEmpty else { return nil }
        if let absoluteURL = URL(string: thumbnailPath), absoluteURL.scheme != nil { return absoluteURL }
        let path = thumbnailPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://api-bmi.dasguney.com/")?.appendingPathComponent(path)
    }

    func merged(with detail: CatalogMod) -> CatalogMod {
        CatalogMod(
            id: id, name: detail.name ?? name, author: detail.author ?? author,
            summary: detail.summary ?? summary, folderName: detail.folderName ?? folderName,
            version: detail.version ?? version, categories: detail.categories ?? categories,
            repository: detail.repository ?? repository, thumbnailPath: detail.thumbnailPath ?? thumbnailPath,
            updatedAt: detail.updatedAt ?? updatedAt, description: detail.description ?? description,
            requiresSteamodded: detail.requiresSteamodded ?? requiresSteamodded,
            requiresTalisman: detail.requiresTalisman ?? requiresTalisman,
            downloadURL: detail.downloadURL ?? downloadURL, downloads: detail.downloads ?? downloads,
            isDeleted: detail.isDeleted ?? isDeleted, colors: detail.colors ?? colors
        )
    }
}

struct ModColors: Codable {
    let first: String
    let second: String

    init(from decoder: Decoder) throws {
        if var values = try? decoder.singleValueContainer().decode([String].self), values.count >= 2 {
            first = values.removeFirst()
            second = values.removeFirst()
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        first = try container.decodeIfPresent(String.self, forKey: .color1)
            ?? container.decodeIfPresent(String.self, forKey: .first)
            ?? "#2C2C2E"
        second = try container.decodeIfPresent(String.self, forKey: .color2)
            ?? container.decodeIfPresent(String.self, forKey: .second)
            ?? first
    }

    enum CodingKeys: String, CodingKey {
        case color1, color2, first, second
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(first, forKey: .color1)
        try container.encode(second, forKey: .color2)
    }
}

struct ModDownloads: Codable {
    let total: Int?
    let today: Int?
}

struct ModPresentation {
    let title: String
    let description: String
    let author: String?
    let version: String?
    let categories: [String]
    let repositoryURL: URL?
    let thumbnailURL: URL?
}

struct CatalogPage: Decodable {
    let items: [CatalogMod]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

struct CatalogCache: Codable {
    let items: [String: CatalogMod]
    let lastUpdatedAt: FlexibleTimestamp?
    let refreshedAt: Date
}

struct DetailCacheEntry: Codable {
    let mod: CatalogMod
    let refreshedAt: Date
}

struct InstalledModRecord: Codable, Identifiable {
    let name: String
    let path: String
    let dependencies: [String]
    let currentVersion: String?
    let orphaned: Bool
    let catalogID: String?

    var id: String { name.lowercased() }
}

struct DetectedMod: Identifiable {
    let folder: InstalledMod
    let catalogMod: CatalogMod?

    var id: URL { folder.id }
    var title: String { catalogMod?.name ?? folder.name }
}

enum ModInstallError: LocalizedError {
    case downloadFailed
    case alreadyInstalled
    case unsupportedArchive
    case unsafeArchive
    case archiveTooLarge
    case tooManyArchiveFiles

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "The mod download could not be completed."
        case .alreadyInstalled: "A mod with this folder name is already installed."
        case .unsupportedArchive: "This archive format is not supported. Please use a ZIP release."
        case .unsafeArchive: "This archive contains an unsafe file path."
        case .archiveTooLarge: "This archive expands beyond the 2 GB safety limit."
        case .tooManyArchiveFiles: "This archive contains more than 10,000 files."
        }
    }
}
