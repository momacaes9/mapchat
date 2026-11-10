import CoreLocation
import Foundation

enum RouteProfile: String, CaseIterable, Identifiable {
    case avoidStairs = "avoid_stairs"
    case standard = "default"
    case fastest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .avoidStairs: "No stairs"
        case .standard: "Normal"
        case .fastest: "Fastest"
        }
    }
}

enum RouteError: Error, Equatable, LocalizedError {
    case notSignedIn
    case notVisible
    case noOwnLocation
    case rateLimited(retryAfter: Int)
    case badRequest(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Please sign in again."
        case .notVisible: "This person isn't sharing their location with you right now."
        case .noOwnLocation: "Your own location isn't known yet."
        case let .rateLimited(s): "Too many route requests. Try again in \(s) s."
        case let .badRequest(m): "Invalid request: \(m)"
        case let .server(code): "Routing service error (\(code))."
        }
    }
}

/// Client for the MapChat routing service (GET /route).
struct RouteClient {
    let baseURL: URL
    let session: URLSession
    /// Returns the current Supabase access token.
    let token: () async throws -> String

    init(baseURL: URL, session: URLSession = .shared, token: @escaping () async throws -> String) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    func makeRequest(to userId: UUID, profile: RouteProfile, from: CLLocationCoordinate2D?, token: String) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent("route"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "to", value: userId.uuidString.lowercased()),
            URLQueryItem(name: "profile", value: profile.rawValue),
        ]
        if let from {
            items.append(URLQueryItem(name: "fromLat", value: String(format: "%.6f", from.latitude)))
            items.append(URLQueryItem(name: "fromLng", value: String(format: "%.6f", from.longitude)))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    func route(to userId: UUID, profile: RouteProfile = .avoidStairs, from: CLLocationCoordinate2D? = nil) async throws -> RouteResponse {
        let tok: String
        do { tok = try await token() } catch { throw RouteError.notSignedIn }
        let (data, response) = try await session.data(for: makeRequest(to: userId, profile: profile, from: from, token: tok))
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try JSONCoding.decoder.decode(RouteResponse.self, from: data)
        case 401:
            throw RouteError.notSignedIn
        case 404:
            throw RouteError.notVisible
        case 409:
            throw RouteError.noOwnLocation
        case 429:
            throw RouteError.rateLimited(retryAfter: Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        case 400:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw RouteError.badRequest(detail ?? "unknown")
        case let code:
            throw RouteError.server(code)
        }
    }
}
