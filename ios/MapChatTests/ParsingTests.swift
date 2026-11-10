import CoreLocation
import XCTest
@testable import MapChat

final class PolylineTests: XCTestCase {
    /// Google's reference example (precision 5).
    func testDecodesReferencePolyline() {
        let pts = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].latitude, 38.5, accuracy: 1e-6)
        XCTAssertEqual(pts[0].longitude, -120.2, accuracy: 1e-6)
        XCTAssertEqual(pts[2].latitude, 43.252, accuracy: 1e-6)
        XCTAssertEqual(pts[2].longitude, -126.453, accuracy: 1e-6)
    }

    /// Same bytes at Valhalla's precision 6 are 10x smaller.
    func testPrecisionSix() {
        let pts = Polyline.decode("_p~iF~ps|U", precision: 6)
        XCTAssertEqual(pts.first!.latitude, 3.85, accuracy: 1e-7)
    }

    func testGarbageDoesNotCrash() {
        XCTAssertTrue(Polyline.decode("").isEmpty)
        _ = Polyline.decode("\u{1}\u{2}")
    }
}

final class ModelParsingTests: XCTestCase {
    func testFriendDecodesBothDateFormats() throws {
        let json = """
        [{"user_id":"11111111-2222-3333-4444-555555555555","display_name":"Ana","lat":35.91,"lng":-79.04,
          "accuracy_m":null,"floor":null,"place_id":null,"place_slug":"davis-library","place_name":"Davis Library",
          "share_precision":"building","recorded_at":"2026-11-10T23:32:25+00:00"},
         {"user_id":"11111111-2222-3333-4444-555555555556","display_name":"Bo","lat":35.9,"lng":-79.0,
          "accuracy_m":4.5,"floor":2,"place_id":null,"place_slug":null,"place_name":null,
          "share_precision":"exact","recorded_at":"2026-11-10T23:32:25.146599+00:00"}]
        """
        let friends = try JSONCoding.decoder.decode([Friend].self, from: Data(json.utf8))
        XCTAssertEqual(friends.count, 2)
        XCTAssertEqual(friends[0].sharePrecision, "building")
        XCTAssertNil(friends[0].floor)
        XCTAssertEqual(friends[1].accuracyM, 4.5)
    }

    func testUploadThrottling() {
        let a = CLLocation(coordinate: .init(latitude: 35.91, longitude: -79.04), altitude: 0,
                           horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: Date())
        let near = CLLocation(coordinate: .init(latitude: 35.9101, longitude: -79.04), altitude: 0,
                              horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: Date())
        let far = CLLocation(coordinate: .init(latitude: 35.92, longitude: -79.04), altitude: 0,
                             horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: Date())
        let bad = CLLocation(coordinate: .init(latitude: 35.92, longitude: -79.04), altitude: 0,
                             horizontalAccuracy: 900, verticalAccuracy: 5, timestamp: Date())
        let now = Date()
        XCTAssertTrue(LocationReporter.shouldUpload(new: a, last: nil, now: now))
        XCTAssertFalse(LocationReporter.shouldUpload(new: near, last: (now, a), now: now.addingTimeInterval(5)))
        XCTAssertTrue(LocationReporter.shouldUpload(new: near, last: (now, a), now: now.addingTimeInterval(31)))
        XCTAssertTrue(LocationReporter.shouldUpload(new: far, last: (now, a), now: now.addingTimeInterval(5)))
        XCTAssertFalse(LocationReporter.shouldUpload(new: bad, last: nil, now: now))
    }
}
