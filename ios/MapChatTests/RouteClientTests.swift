import CoreLocation
import XCTest
@testable import MapChat

/// Serves canned responses and records requests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RouteClientTests: XCTestCase {
    private let friendId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func makeClient() -> RouteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RouteClient(baseURL: URL(string: "http://routing.test")!, session: URLSession(configuration: config)) { "tok123" }
    }

    static let sampleJSON = """
    {
      "to": {"user_id": "11111111-2222-3333-4444-555555555555", "display_name": "Ana",
             "lat": 35.91094, "lng": -79.04781, "floor": 3, "place_name": "Davis Library",
             "precision": "exact", "recorded_at": "2026-11-10T23:32:25.146599+00:00"},
      "route": {"profile": "avoid_stairs", "durationS": 1100, "distanceM": 1477,
                "shape": "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
                "steps": ["Walk north.", "Enter Davis Library by the main entrance (floor 1)",
                          "Take elevator A to floor 3", "Arrive on floor 3"],
                "entrance": {"id": "ent-main", "label": "main entrance", "lat": 35.9108025, "lng": -79.0483783},
                "indoor": {"building": "davis-library", "targetFloor": 3, "verified": false}}
    }
    """

    func testBuildsRequestWithAuthAndQuery() {
        let req = makeClient().makeRequest(
            to: friendId, profile: .avoidStairs,
            from: CLLocationCoordinate2D(latitude: 35.9, longitude: -79.04), token: "abc"
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "to" }?.value, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(q.first { $0.name == "profile" }?.value, "avoid_stairs")
        XCTAssertEqual(q.first { $0.name == "fromLat" }?.value, "35.900000")
        XCTAssertEqual(req.url?.path, "/route")
    }

    func testParsesRouteResponse() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(Self.sampleJSON.utf8)) }
        let r = try await makeClient().route(to: friendId)
        XCTAssertEqual(r.to.displayName, "Ana")
        XCTAssertEqual(r.route.indoor?.targetFloor, 3)
        XCTAssertEqual(r.route.entrance?.id, "ent-main")
        XCTAssertTrue(r.route.steps.contains("Take elevator A to floor 3"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
    }

    func testNotVisibleMapsTo404() async {
        StubURLProtocol.handler = { _ in (404, [:], Data(#"{"error":"not_visible"}"#.utf8)) }
        do {
            _ = try await makeClient().route(to: friendId)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? RouteError, .notVisible)
        }
    }

    func testRateLimitReadsRetryAfter() async {
        StubURLProtocol.handler = { _ in (429, ["Retry-After": "42"], Data()) }
        do {
            _ = try await makeClient().route(to: friendId)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? RouteError, .rateLimited(retryAfter: 42))
        }
    }

    func testBadRequestCarriesDetail() async {
        StubURLProtocol.handler = { _ in (400, [:], Data(#"{"error":"invalid_request","detail":"bad to"}"#.utf8)) }
        do {
            _ = try await makeClient().route(to: friendId)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? RouteError, .badRequest("bad to"))
        }
    }
}
