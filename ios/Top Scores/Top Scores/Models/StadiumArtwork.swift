import Foundation

enum StadiumArtworkRole: String, Codable, Hashable, Sendable {
    case genericBackdrop = "generic_backdrop"
    case genericMatch = "generic_match"
    case team
}

enum StadiumArtworkLightContext: String, Codable, Hashable, Sendable {
    case any
    case day
    case night
}

struct StadiumArtworkTeam: Codable, Hashable, Sendable {
    let name: String
    let aliases: [String]
    let sourceTeamIDs: [String]
    let venueIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name, aliases
        case sourceTeamIDs = "source_team_ids"
        case venueIDs = "venue_ids"
    }
}

struct StadiumArtworkCredit: Codable, Hashable, Sendable {
    let author: String
    let authorURL: String?
    let source: String
    let sourcePage: String?
    let license: String
    let licenseURL: String?
    let attribution: String

    enum CodingKeys: String, CodingKey {
        case author, source, license, attribution
        case authorURL = "author_url"
        case sourcePage = "source_page"
        case licenseURL = "license_url"
    }
}

struct StadiumArtworkAsset: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let role: StadiumArtworkRole
    let lightContext: StadiumArtworkLightContext
    let teamIDs: [String]
    let stadium: String?
    let sha256: String
    let assetPath: String
    let assetURL: String
    let contentType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let credit: StadiumArtworkCredit

    enum CodingKeys: String, CodingKey {
        case id, role, stadium, sha256, width, height, credit
        case lightContext = "light_context"
        case teamIDs = "team_ids"
        case assetPath = "asset_path"
        case assetURL = "asset_url"
        case contentType = "content_type"
        case byteSize = "byte_size"
    }

    nonisolated func remoteURL(apiBaseURL: String) -> URL? {
        guard let baseURL = URL(string: apiBaseURL) else { return nil }
        if let absoluteURL = URL(string: assetURL), absoluteURL.scheme != nil {
            return absoluteURL
        }

        let endpointMarker = "stadium-artwork/assets/"
        let endpointPath: String
        if let markerRange = assetURL.range(of: endpointMarker) {
            endpointPath = String(assetURL[markerRange.lowerBound...])
        } else {
            endpointPath = assetURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !endpointPath.isEmpty else { return nil }
        return endpointPath.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }
}

struct StadiumArtworkCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let catalogVersion: String
    let generatedAt: String
    let teams: [String: StadiumArtworkTeam]
    let assets: [StadiumArtworkAsset]

    enum CodingKeys: String, CodingKey {
        case teams, assets
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case generatedAt = "generated_at"
    }

    var genericBackdropAssets: [StadiumArtworkAsset] {
        assets.filter { $0.role == .genericBackdrop }
    }
}

struct StadiumArtworkFetchResult: Sendable {
    let catalog: StadiumArtworkCatalog?
    let etag: String?
    let isNotModified: Bool
}
