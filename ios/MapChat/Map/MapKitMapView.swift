import MapKit
import SwiftUI

/// Apple MapKit backend. This is the ONLY file that knows about MapKit.
typealias ActiveMapView = MapKitMapView

/// UNC Chapel Hill main campus.
private let campus = CLLocationCoordinate2D(latitude: 35.9095, longitude: -79.0479)

struct MapKitMapView: MapRendering {
    let people: [MapPerson]
    let route: [CLLocationCoordinate2D]
    let focus: CLLocationCoordinate2D?

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: campus, latitudinalMeters: 1800, longitudinalMeters: 1800)
    )

    init(people: [MapPerson], route: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D?) {
        self.people = people
        self.route = route
        self.focus = focus
    }

    var body: some View {
        Map(position: $position) {
            ForEach(people) { person in
                Annotation(person.name, coordinate: person.coordinate) {
                    ZStack {
                        if person.isApproximate {
                            Circle().fill(Color.orange.opacity(0.2)).frame(width: 56, height: 56)
                        }
                        Circle()
                            .fill(person.isMe ? Color.blue : Color.pink)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel(person.subtitle.map { "\(person.name), \($0)" } ?? person.name)
                }
            }
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onChange(of: route.count) {
            guard route.count > 1 else { return }
            position = .rect(Self.boundingRect(route))
        }
        .onChange(of: focus?.latitude) {
            if let focus {
                position = .region(MKCoordinateRegion(center: focus, latitudinalMeters: 600, longitudinalMeters: 600))
            }
        }
    }

    private static func boundingRect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect {
        let rect = coords.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
            .reduce(MKMapRect.null) { $0.union($1) }
        return rect.insetBy(dx: -rect.width * 0.25 - 200, dy: -rect.height * 0.25 - 200)
    }
}
