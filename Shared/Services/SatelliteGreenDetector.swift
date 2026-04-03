import CoreLocation
import Foundation
import MapKit
import UIKit
import Vision

// MARK: - SatelliteGreenDetector
//
// Detects golf green locations from satellite imagery when OSM has no data.
//
// Pipeline:
//   1. MKMapSnapshotter captures a 2000×2000px satellite tile (~1m/px) of
//      the course area.
//   2. Pixel scan builds a binary mask: white where HSB matches "golf green"
//      colour (closely-mown grass), black elsewhere.
//   3. Vision VNDetectContoursRequest finds blob outlines in the mask.
//   4. Each contour is scored by real-world area (300–950 m²) and circularity.
//      Greens are oval; fairways and trees are elongated or amorphous.
//   5. Top candidates (up to expectedHoles) are converted from pixel → GPS
//      using MKMapSnapshot.coordinate(at:).
//   6. Results cached for 30 days (same TTL as OSM data).
//
// Limitations / tuning notes:
//   - Colour thresholds assume summer satellite imagery. Dormant/brown greens
//     will be missed. Adjust hue range seasonally if needed.
//   - At very high altitudes (>2500m) grass colour shifts — Sierra Star GC is
//     a known edge case.
//   - The detector cannot assign hole numbers; it returns unordered candidates.
//     Hole numbers are assigned later by proximity to tee markers, or left nil.

actor SatelliteGreenDetector {
    static let shared = SatelliteGreenDetector()

    // Cache
    private let cacheKeyPrefix = "sat_green_"
    private let cacheTTLSeconds: TimeInterval = 30 * 24 * 60 * 60

    // Snapshot parameters
    /// Span in degrees covering ~2 km × 2 km at mid-European latitudes
    private let snapshotLatSpan: CLLocationDegrees = 0.018
    private let snapshotLonSpan: CLLocationDegrees = 0.025
    private let snapshotSize = CGSize(width: 1000, height: 1000)
    private let snapshotScale: CGFloat = 2.0   // → 2000×2000 effective pixels

    // Green size limits in real-world square metres
    private let minGreenAreaM2: Double = 250
    private let maxGreenAreaM2: Double = 1000

    // Minimum circularity score (4π·area/perimeter²); perfect circle = 1.0
    private let minCircularity: Double = 0.35

    private init() {}

    // MARK: - Public entry point

    /// Detects golf green candidates from satellite imagery.
    /// Returns `nil` if snapshot capture fails or no plausible greens are found.
    func detectGreens(
        courseId: String,
        location: Coordinate,
        expectedHoles: Int = 18
    ) async -> OSMHoleData? {
        // Cache check
        if let cached = loadCache(courseId: courseId) { return cached }

        // Capture snapshot on the main thread (MapKit requirement)
        guard let (snapshot, metresPerPixel) = await captureSnapshot(center: location) else {
            return nil
        }

        // Build binary mask, detect contours, filter candidates
        guard let mask = buildGreenMask(from: snapshot.image),
              let contours = try? detectContours(in: mask) else {
            return nil
        }

        let imageSize = CGSize(
            width: snapshot.image.size.width * snapshotScale,
            height: snapshot.image.size.height * snapshotScale
        )

        let candidates = contours
            .compactMap { contour -> (coord: Coordinate, confidence: Double)? in
                score(contour: contour, imageSize: imageSize, metresPerPixel: metresPerPixel,
                      snapshot: snapshot)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(expectedHoles)

        guard !candidates.isEmpty else { return nil }

        let holes: [OSMHoleData.HoleCoords] = candidates.enumerated().map { _, candidate in
            // We cannot assign hole numbers without additional context — leave nil
            // so the caller knows ordering is unresolved.
            OSMHoleData.HoleCoords(
                holeNumber: 0,            // 0 = unassigned
                pinCoordinate: candidate.coord,
                teeCoordinate: nil
            )
        }

        let found = holes.count
        let quality: OSMHoleData.GPSQuality = found >= expectedHoles
            ? .full(holes: found)
            : found > 0 ? .partial(found: found, of: expectedHoles) : .none

        var result = OSMHoleData(holes: holes, sourceCourse: nil, quality: quality)
        result.dataSource = .satellite

        saveCache(courseId: courseId, data: result)
        return result
    }

    // MARK: - Snapshot capture

    @MainActor
    private func captureSnapshot(center: Coordinate) async -> (MKMapSnapshot, Double)? {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            span: MKCoordinateSpan(latitudeDelta: snapshotLatSpan, longitudeDelta: snapshotLonSpan)
        )

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = snapshotSize
        options.scale = snapshotScale
        options.mapType = .satelliteFlyover   // best detail

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            // Calculate real-world metres per effective pixel
            let effectiveWidth = snapshotSize.width * snapshotScale
            let courseLat = center.latitude * .pi / 180
            let metresPerDegLon = 111_320 * cos(courseLat)
            let metresPerPixel = (snapshotLonSpan * metresPerDegLon) / effectiveWidth
            return (snapshot, metresPerPixel)
        } catch {
            print("[SatelliteDetector] Snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Colour mask

    /// Returns a grayscale CGImage: white pixels = golf-green colour, black = other.
    private func buildGreenMask(from image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }

        let width  = cgImage.width
        let height = cgImage.height

        // Read RGBA pixels
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let readCtx = CGContext(
            data: &rgba,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        readCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Write grayscale mask
        var grey = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let r = Double(rgba[base])     / 255.0
                let g = Double(rgba[base + 1]) / 255.0
                let b = Double(rgba[base + 2]) / 255.0
                if isGolfGreen(r: r, g: g, b: b) {
                    grey[y * width + x] = 255
                }
            }
        }

        guard let writeCtx = CGContext(
            data: &grey,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        return writeCtx.makeImage()
    }

    /// Checks whether an RGB triplet (0–1) matches closely-mown golf grass.
    ///
    /// Golf greens in summer satellite imagery appear as a saturated, uniform
    /// green with the G channel clearly dominant over R and B.
    /// Hue 0.22–0.40, saturation 0.18–0.72, brightness 0.18–0.68.
    private func isGolfGreen(r: Double, g: Double, b: Double) -> Bool {
        guard g > r, g > b else { return false }   // green channel must dominate

        // RGB → HSB
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0, maxC > 0 else { return false }

        var h = (g == maxC) ? ((b - r) / delta) + 2.0 : ((r - g) / delta) + 4.0
        h = h / 6.0
        if h < 0 { h += 1 }

        let s = delta / maxC
        let v = maxC

        return h >= 0.22 && h <= 0.40
            && s >= 0.18 && s <= 0.72
            && v >= 0.18 && v <= 0.68
    }

    // MARK: - Contour detection

    private func detectContours(in mask: CGImage) throws -> [VNContour] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.5
        request.detectsDarkOnBright = false   // white blobs on black background

        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first else { return [] }
        // Return only top-level contours (not holes within blobs)
        return (0..<obs.topLevelContourCount).compactMap { try? obs.topLevelContour(at: $0) }
    }

    // MARK: - Scoring

    /// Returns (coordinate, confidence 0–1) if the contour passes area + circularity filters.
    private func score(
        contour: VNContour,
        imageSize: CGSize,
        metresPerPixel: Double,
        snapshot: MKMapSnapshot
    ) -> (coord: Coordinate, confidence: Double)? {
        // Vision normalises coordinates to 0–1; scale to pixel space
        let bb = contour.normalizedBoundingBox
        let pixelBB = CGRect(
            x: bb.minX * imageSize.width,
            y: (1 - bb.maxY) * imageSize.height,   // Vision uses bottom-left origin
            width: bb.width * imageSize.width,
            height: bb.height * imageSize.height
        )

        // Real-world area estimate from bounding-box pixels
        let areaM2 = pixelBB.width * pixelBB.height * metresPerPixel * metresPerPixel
        guard areaM2 >= minGreenAreaM2, areaM2 <= maxGreenAreaM2 else { return nil }

        // Circularity from the normalised path
        let pathAreaPx = pixelBB.width * pixelBB.height   // approximate
        let perimeterPx = contour.normalizedPath.length(inSize: imageSize)
        guard perimeterPx > 0 else { return nil }
        let circularity = (4 * Double.pi * pathAreaPx) / (perimeterPx * perimeterPx)
        guard circularity >= minCircularity else { return nil }

        // Confidence: blend circularity and how well area hits the ideal green size (600 m²)
        let idealAreaM2 = 600.0
        let areaNorm = 1.0 - min(abs(areaM2 - idealAreaM2) / idealAreaM2, 1.0)
        let confidence = (circularity * 0.6 + areaNorm * 0.4)

        // Convert pixel centroid → GPS
        let centrePixel = CGPoint(x: pixelBB.midX / snapshotScale, y: pixelBB.midY / snapshotScale)
        let coord2D = snapshot.coordinate(at: centrePixel)
        let coord = Coordinate(latitude: coord2D.latitude, longitude: coord2D.longitude)

        return (coord, confidence)
    }

    // MARK: - Caching (mirrors OSMGolfService pattern)

    private struct CacheEntry: Codable {
        struct CachedHole: Codable {
            let holeNumber: Int
            let pinLat: Double?; let pinLon: Double?
        }
        let holes: [CachedHole]
        let qualityType: String; let qualityFound: Int; let qualityOf: Int
        let timestamp: Date
    }

    private func cacheKey(_ courseId: String) -> String { cacheKeyPrefix + courseId }

    private func loadCache(courseId: String) -> OSMHoleData? {
        guard let raw = UserDefaults.standard.data(forKey: cacheKey(courseId)),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: raw),
              Date().timeIntervalSince(entry.timestamp) < cacheTTLSeconds else { return nil }

        let holes = entry.holes.map { h -> OSMHoleData.HoleCoords in
            let pin = (h.pinLat != nil && h.pinLon != nil)
                ? Coordinate(latitude: h.pinLat!, longitude: h.pinLon!) : nil
            return OSMHoleData.HoleCoords(holeNumber: h.holeNumber, pinCoordinate: pin, teeCoordinate: nil)
        }
        let quality: OSMHoleData.GPSQuality
        switch entry.qualityType {
        case "full":    quality = .full(holes: entry.qualityFound)
        case "partial": quality = .partial(found: entry.qualityFound, of: entry.qualityOf)
        default:        quality = .none
        }
        var data = OSMHoleData(holes: holes, sourceCourse: nil, quality: quality)
        data.dataSource = .satellite
        return data
    }

    private func saveCache(courseId: String, data: OSMHoleData) {
        let holes = data.holes.map { CacheEntry.CachedHole(
            holeNumber: $0.holeNumber,
            pinLat: $0.pinCoordinate?.latitude,
            pinLon: $0.pinCoordinate?.longitude
        )}
        let (qt, qf, qo): (String, Int, Int)
        switch data.quality {
        case .full(let n):           qt = "full";    qf = n; qo = n
        case .partial(let f, let t): qt = "partial"; qf = f; qo = t
        case .none:                  qt = "none";    qf = 0; qo = 0
        }
        let entry = CacheEntry(holes: holes, qualityType: qt, qualityFound: qf, qualityOf: qo, timestamp: .now)
        if let encoded = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(encoded, forKey: cacheKey(courseId))
        }
    }
}

// MARK: - CGPath length helper

private extension CGPath {
    /// Approximate arc-length by sampling the normalised path at pixel scale.
    func length(inSize size: CGSize) -> Double {
        var totalLength = 0.0
        var lastPoint: CGPoint?
        applyWithBlock { element in
            var pt = element.pointee.points[0]
            pt.x *= size.width
            pt.y *= size.height
            if let prev = lastPoint {
                let dx = pt.x - prev.x
                let dy = pt.y - prev.y
                totalLength += sqrt(dx * dx + dy * dy)
            }
            lastPoint = pt
        }
        return totalLength
    }
}
