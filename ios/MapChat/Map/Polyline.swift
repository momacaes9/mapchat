import CoreLocation

/// Decoder for Google-style encoded polylines. Valhalla uses precision 6.
enum Polyline {
    static func decode(_ encoded: String, precision: Int = 6) -> [CLLocationCoordinate2D] {
        let factor = pow(10.0, Double(precision))
        let bytes = Array(encoded.utf8)
        var coords: [CLLocationCoordinate2D] = []
        var index = 0
        var lat = 0
        var lng = 0

        func next() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                guard b >= 0 else { return nil }
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = next(), let dLng = next() else { break }
            lat += dLat
            lng += dLng
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / factor, longitude: Double(lng) / factor))
        }
        return coords
    }
}
