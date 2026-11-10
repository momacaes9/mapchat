import CoreLocation
import SwiftUI

/// A pin on the map.
struct MapPerson: Identifiable, Equatable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let isMe: Bool
    /// Building-level sharing: the pin is a building centroid, not a position.
    let isApproximate: Bool
    let subtitle: String?

    static func == (a: MapPerson, b: MapPerson) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude && a.subtitle == b.subtitle
    }
}

/// The contract every map backend implements. Screens only use
/// `ActiveMapView`, which is defined by exactly one backend file:
///
///   * MapKitMapView.swift   (current: Apple MapKit, no key needed)
///   * GoogleMapView.swift   (later: Google Maps SDK)
///
/// To switch to Google Maps, replace MapKitMapView.swift with a
/// GoogleMapView.swift that conforms to `MapRendering` and declares
/// `typealias ActiveMapView = GoogleMapView`. Nothing else changes.
protocol MapRendering: View {
    init(people: [MapPerson], route: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D?)
}
