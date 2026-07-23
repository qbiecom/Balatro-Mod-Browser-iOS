import Foundation

struct FlexibleTimestamp: Codable {
    let value: Int64

    /// Accepts BMI timestamps encoded as either numeric JSON values or decimal strings.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded: Int64
        if let value = try? container.decode(Int64.self) {
            decoded = value
        } else if let string = try? container.decode(String.self),
                  string.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                  let value = Int64(string) {
            decoded = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a positive Unix timestamp integer or decimal string."
            )
        }
        guard decoded > 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Timestamp must be a positive Unix timestamp."
            )
        }
        value = decoded
    }

    /// Writes timestamps in BMI's canonical numeric representation.
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
    let descriptionHTML: String?
    let homepage: String?
    let requiresSteamodded: Bool?
    let requiresTalisman: Bool?
    let downloadURL: String?
    let downloads: ModDownloads?
    let isDeleted: Bool?
    let colors: ModColors?

    enum CodingKeys: String, CodingKey {
        case id, name, author, summary, version, categories, description, homepage, downloads, colors
        case descriptionHTML = "description_html"
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
        let rawValue = descriptionHTML.map(Self.plainText(fromHTML:)) ?? description ?? summary
        let value = Self.removingLeadingTitle(from: rawValue, matching: name ?? id)?
            .replacingOccurrences(of: "![]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var websiteURL: URL? {
        (repository ?? homepage).flatMap(URL.init(string:))
    }

    var thumbnailURL: URL? {
        guard let thumbnailPath, !thumbnailPath.isEmpty else { return nil }
        if let absoluteURL = URL(string: thumbnailPath), absoluteURL.scheme != nil { return absoluteURL }
        let path = thumbnailPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://api-bmi.dasguney.com/")?.appendingPathComponent(path)
    }

    /// Preserves summary-list fields while overlaying any richer values returned by BMI's detail endpoint.
    func merged(with detail: CatalogMod) -> CatalogMod {
        CatalogMod(
            id: id, name: detail.name ?? name, author: detail.author ?? author,
            summary: detail.summary ?? summary, folderName: detail.folderName ?? folderName,
            version: detail.version ?? version, categories: detail.categories ?? categories,
            repository: detail.repository ?? repository, thumbnailPath: detail.thumbnailPath ?? thumbnailPath,
            updatedAt: detail.updatedAt ?? updatedAt, description: detail.description ?? description,
            descriptionHTML: detail.descriptionHTML ?? descriptionHTML,
            homepage: detail.homepage ?? homepage,
            requiresSteamodded: detail.requiresSteamodded ?? requiresSteamodded,
            requiresTalisman: detail.requiresTalisman ?? requiresTalisman,
            downloadURL: detail.downloadURL ?? downloadURL, downloads: detail.downloads ?? downloads,
            isDeleted: detail.isDeleted ?? isDeleted, colors: detail.colors ?? colors
        )
    }

    /// Converts BMI's lightweight HTML descriptions into the text rendered by native SwiftUI detail views.
    nonisolated private static func plainText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(of: "<h1>", with: "\n")
            .replacingOccurrences(of: "</h1>", with: "\n")
            .replacingOccurrences(of: "<h2>", with: "\n\n")
            .replacingOccurrences(of: "</h2>", with: "\n")
            .replacingOccurrences(of: "<p>", with: "")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<ul>", with: "")
            .replacingOccurrences(of: "</ul>", with: "")
            .replacingOccurrences(of: "<li>", with: "• ")
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// Removes a duplicated leading title so list cards do not repeat the mod name as their excerpt.
    nonisolated private static func removingLeadingTitle(from value: String?, matching title: String) -> String? {
        guard let value else { return nil }
        var lines = value.components(separatedBy: .newlines)
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              normalizedTitle(lines[firstIndex]) == normalizedTitle(title) else {
            return value
        }
        lines.remove(at: firstIndex)
        return lines.joined(separator: "\n")
    }

    nonisolated private static func normalizedTitle(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct ModColors: Codable {
    let first: String
    let second: String

    /// Decodes download counters from the compact BMI payload, defaulting omitted values safely.
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

    /// Encodes download counters using BMI's snake-case field names.
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
    let requiresSteamodded: Bool
    let requiresTalisman: Bool
    let downloads: Int?
    let updatedAt: Date?
    let colors: ModColors?
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

/// A dependency identity that remains stable when display names or install folders change.
/// New callers should persist both values when they are known.
nonisolated struct InstalledModDependencyReference: Codable, Equatable, Hashable {
    let catalogID: String?
    let normalizedInstalledPath: String?

    /// Creates a dependency reference that can survive display-name changes and folder migration.
    init(catalogID: String?, normalizedInstalledPath: String?) {
        self.catalogID = catalogID
        self.normalizedInstalledPath = normalizedInstalledPath
    }

    /// Accepts older registry entries that predate stable dependency-path references.
    init(from decoder: Decoder) throws {
        if let legacyValue = try? decoder.singleValueContainer().decode(String.self) {
            catalogID = legacyValue
            normalizedInstalledPath = nil
            return
        }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
        normalizedInstalledPath = try values.decodeIfPresent(String.self, forKey: .normalizedInstalledPath)
    }
}

nonisolated struct InstalledModRecord: Codable, Identifiable, Equatable {
    let gameFolderID: String
    let name: String
    let path: String
    let normalizedModPath: String
    let dependencies: [String]
    let dependencyReferences: [InstalledModDependencyReference]
    let currentVersion: String?
    let orphaned: Bool
    let catalogID: String?

    var id: String { "\(gameFolderID):\(normalizedModPath)" }

    private enum CodingKeys: String, CodingKey {
        case gameFolderID, name, path, normalizedModPath, dependencies, dependencyReferences
        case currentVersion, orphaned, catalogID
    }

    /// Creates a registry record while deriving stable dependency references for legacy callers.
    init(
        gameFolderID: String,
        name: String,
        path: String,
        normalizedModPath: String,
        dependencies: [String],
        currentVersion: String?,
        orphaned: Bool,
        catalogID: String?,
        dependencyReferences: [InstalledModDependencyReference]? = nil
    ) {
        self.gameFolderID = gameFolderID
        self.name = name
        self.path = path
        self.normalizedModPath = normalizedModPath
        self.dependencies = dependencies
        self.dependencyReferences = dependencyReferences
            ?? dependencies.map { InstalledModDependencyReference(catalogID: $0, normalizedInstalledPath: nil) }
        self.currentVersion = currentVersion
        self.orphaned = orphaned
        self.catalogID = catalogID
    }

    /// Decodes current and legacy registry formats, supplying durable defaults for missing fields.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        gameFolderID = try values.decodeIfPresent(String.self, forKey: .gameFolderID) ?? "legacy:\(path.lowercased())"
        normalizedModPath = try values.decodeIfPresent(String.self, forKey: .normalizedModPath) ?? path.lowercased()
        dependencies = try values.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        dependencyReferences = try values.decodeIfPresent(
            [InstalledModDependencyReference].self,
            forKey: .dependencyReferences
        ) ?? dependencies.map { InstalledModDependencyReference(catalogID: $0, normalizedInstalledPath: nil) }
        currentVersion = try values.decodeIfPresent(String.self, forKey: .currentVersion)
        orphaned = try values.decode(Bool.self, forKey: .orphaned)
        catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
    }

    /// Rebinds a record to a newly restored security-scoped folder identity without changing installation data.
    func replacingGameFolderID(with gameFolderID: String) -> InstalledModRecord {
        InstalledModRecord(
            gameFolderID: gameFolderID,
            name: name,
            path: path,
            normalizedModPath: normalizedModPath,
            dependencies: dependencies,
            currentVersion: currentVersion,
            orphaned: orphaned,
            catalogID: catalogID,
            dependencyReferences: dependencyReferences
        )
    }
}

struct DependencyInstallRequest: Identifiable {
    let mod: CatalogMod
    let dependencies: [CatalogMod]
    let directDependencies: [String: [String]]
    let talismanProviderOptions: [CatalogMod]
    let replacing: Bool
    let replacementModURL: URL?

    var id: String { mod.id }
}

enum GameFolderError: LocalizedError {
    case notDirectory
    case invalidLayout

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "Please select the Lovely Mobile Maker game folder, not a file."
        case .invalidLayout:
            "This is not a Lovely Mobile Maker game folder. Select the folder named game."
        }
    }
}

enum ModInstallError: LocalizedError {
    case downloadFailed
    case alreadyInstalled
    case unsafeFolderName
    case invalidUpdateTarget
    case unsupportedArchive
    case unsafeArchive
    case archiveTooLarge
    case tooManyArchiveFiles
    case insufficientStorage
    case untrustedDownloadURL
    case dependencyCycle

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "The mod download could not be completed."
        case .alreadyInstalled: "A mod with this folder name is already installed."
        case .unsafeFolderName: "The catalog supplied an unsafe mod folder name."
        case .invalidUpdateTarget: "The selected mod folder is no longer an immediate child of this game's Mods folder."
        case .unsupportedArchive: "This archive format is not supported. Please use a ZIP release."
        case .unsafeArchive: "This archive contains an unsafe file path."
        case .archiveTooLarge: "This archive expands beyond the 2 GB safety limit."
        case .tooManyArchiveFiles: "This archive contains more than 5,000 files."
        case .insufficientStorage: "There is not enough free storage to safely extract this archive."
        case .untrustedDownloadURL: "The download URL or redirect was not from an approved HTTPS host."
        case .dependencyCycle: "The mod dependency graph contains a cycle."
        }
    }
}
