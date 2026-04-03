import MapKit
import SwiftUI

struct HoleMapView: View {
    let hole: GolfHole
    let userLocation: CLLocation?

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            // Player position
            UserAnnotation()

            // Pin annotation
            Annotation("Hole \(hole.number)", coordinate: hole.pinCoordinate.clCoordinate) {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.red)
                    .background(Circle().fill(.white).padding(-4))
            }

            // Tee annotation
            Annotation("Tee", coordinate: hole.teeCoordinate.clCoordinate) {
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.green).padding(-4))
            }

            // Tee-to-pin line
            MapPolyline(coordinates: [hole.teeCoordinate.clCoordinate, hole.pinCoordinate.clCoordinate])
                .stroke(.yellow.opacity(0.85), lineWidth: 2)
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: hole) { _, new in
            updateCamera(for: new)
        }
        .onAppear {
            updateCamera(for: hole)
        }
    }

    private func updateCamera(for hole: GolfHole) {
        var coords = [hole.teeCoordinate.clCoordinate, hole.pinCoordinate.clCoordinate]
        if let loc = userLocation {
            coords.append(loc.coordinate)
        }
        let region = MKCoordinateRegion(coords: coords, padding: 80)
        withAnimation(.easeInOut) {
            cameraPosition = .region(region)
        }
    }
}

// Convenience to build a region that fits a set of coordinates with padding
private extension MKCoordinateRegion {
    init(coords: [CLLocationCoordinate2D], padding: CLLocationDistance) {
        guard !coords.isEmpty else {
            self = MKCoordinateRegion()
            return
        }
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        // Add ~30% padding
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.002),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.002)
        )
        self = MKCoordinateRegion(center: center, span: span)
    }
}
