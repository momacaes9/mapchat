import Foundation

/// A person whose location the current user may see (row of visible_friends()).
struct Friend: Codable, Identifiable, Equatable {
    let userId: UUID
    let displayName: String
    let lat: Double
    let lng: Double
    let accuracyM: Double?
    let floor: Int?
    let placeSlug: String?
    let placeName: String?
    let sharePrecision: String
    let recordedAt: Date

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", displayName = "display_name", lat, lng
        case accuracyM = "accuracy_m", floor, placeSlug = "place_slug", placeName = "place_name"
        case sharePrecision = "share_precision", recordedAt = "recorded_at"
    }
}

struct MyLocation: Codable, Equatable {
    let lat: Double
    let lng: Double
    let floor: Int?
    let placeSlug: String?

    enum CodingKeys: String, CodingKey {
        case lat, lng, floor, placeSlug = "place_slug"
    }
}

struct ProfileName: Codable, Equatable {
    let displayName: String
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

/// A row of share_grants with both display names joined in.
struct ShareGrant: Codable, Identifiable, Equatable {
    let id: UUID
    let ownerId: UUID
    let viewerId: UUID
    var status: String
    var precision: String
    var allowFloor: Bool
    let owner: ProfileName?
    let viewer: ProfileName?

    enum CodingKeys: String, CodingKey {
        case id, ownerId = "owner_id", viewerId = "viewer_id", status, precision
        case allowFloor = "allow_floor", owner, viewer
    }
}

/// Response of GET /route.
struct RouteResponse: Codable, Equatable {
    struct Target: Codable, Equatable {
        let userId: UUID
        let displayName: String
        let lat: Double
        let lng: Double
        let floor: Int?
        let placeName: String?
        let precision: String

        enum CodingKeys: String, CodingKey {
            case userId = "user_id", displayName = "display_name", lat, lng, floor
            case placeName = "place_name", precision
        }
    }

    struct Route: Codable, Equatable {
        struct Entrance: Codable, Equatable {
            let id: String
            let label: String
            let lat: Double
            let lng: Double
        }

        struct Indoor: Codable, Equatable {
            let building: String
            let targetFloor: Int
            let verified: Bool
        }

        let profile: String
        let durationS: Int
        let distanceM: Int
        let shape: String
        let steps: [String]
        let entrance: Entrance?
        let indoor: Indoor?
    }

    let to: Target
    let route: Route
}

/// ISO 8601 with or without fractional seconds (Postgres returns both).
enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
}
