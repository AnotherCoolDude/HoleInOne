import CloudKit
import CoreLocation
import Foundation

// MARK: - CloudGPSService
//
// Crowdsources golf hole GPS data across all app users via CloudKit Public Database.
//
// Two CloudKit record types:
//
//   HoleGPSContribution  — one record per player per hole per session.
//     Individual, unvalidated submissions. Written by every player who marks
//     a pin or tee. Never deleted — they are the source of truth.
//
//   CourseGPSAggregate   — one record per (course, hole, type, teeColor).
//     Pre-computed validated average. Written/updated by any client when the
//     existing aggregate is missing or older than 7 days. Reading is free and
//     fast; writing happens rarely.
//
// SETUP REQUIRED (once per developer account):
//   1. developer.apple.com → Identifiers → com.holeinone.app
//      → Capabilities → iCloud → CloudKit → select container iCloud.com.holeinone.app
//   2. In Xcode → Signing & Capabilities → iCloud → tick CloudKit,
//      add container iCloud.com.holeinone.app
//   3. After testing, deploy schema to production via CloudKit Dashboard
//      (Dashboard → your container → Schema → Deploy to Production)
//
// Privacy:
//   Contributions are tagged with an anonymous random UUID generated on first
//   launch and stored in UserDefaults. No Apple ID or personal data is stored.
//   CloudKit metadata (createdByUserRecordName) is an opaque internal token,
//   not an Apple ID, and cannot be linked to a person.

actor CloudGPSService {
    static let shared = CloudGPSService()

    // MARK: - Configuration

    private let containerID         = "iCloud.com.holeinone.app"
    private let contributionType    = "HoleGPSContribution"
    private let aggregateType       = "CourseGPSAggregate"

    /// How long the local aggregate cache is valid before a fresh CloudKit fetch.
    private let localCacheTTL: TimeInterval = 24 * 60 * 60          // 24 h

    /// How old a CloudKit aggregate record can be before clients re-aggregate.
    private let aggregateStaleTTL: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    // MARK: - Private state

    private var db: CKDatabase { CKContainer(identifier: containerID).publicCloudDatabase }
    private var memoryCache: [String: (data: [CommunityHoleData], at: Date)] = [:]

    private init() {}

    // MARK: - Anonymous contributor ID

    nonisolated func contributorId() -> String {
        let key = "cloud_gps_contributor_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - Public: fetch community GPS

    /// Returns validated community GPS aggregates for all holes of a course.
    ///
    /// Uses memory cache → UserDefaults persistence → CloudKit, in that order.
    /// Low-confidence holes (< 3 validated samples) are returned but marked
    /// as not usable so callers can decide whether to use them.
    ///
    /// Background re-aggregation is triggered automatically when any aggregate
    /// is stale (> 7 days old) without blocking the return.
    func fetchCommunityGPS(courseId: String) async -> [CommunityHoleData] {
        // 1. Memory cache (instant)
        if let hit = memoryCache[courseId],
           Date().timeIntervalSince(hit.at) < localCacheTTL {
            return hit.data
        }

        // 2. UserDefaults persistence (instant, survives relaunches)
        if let persisted = loadPersisted(courseId: courseId) {
            memoryCache[courseId] = (persisted, .now)
            return persisted
        }

        // 3. CloudKit (network, ~500 ms first time)
        do {
            let aggregates = try await fetchAggregates(courseId: courseId)
            let holeData   = buildHoleData(from: aggregates)
            cache(holeData, courseId: courseId)

            // Kick off stale re-aggregation without blocking
            Task { await refreshStale(courseId: courseId, existing: aggregates) }

            return holeData
        } catch {
            #if DEBUG
            print("[CloudGPS] Fetch failed for \(courseId): \(error.localizedDescription)")
            #endif
            return []
        }
    }

    // MARK: - Public: upload pin contribution

    /// Uploads a player-recorded pin location anonymously.
    /// Silently fails when iCloud is unavailable — contributions are best-effort.
    func uploadPin(
        courseId: String,
        holeNumber: Int,
        coordinate: Coordinate,
        accuracy: Double
    ) async {
        await upload(
            courseId: courseId, holeNumber: holeNumber,
            type: .pin, teeColor: nil,
            coordinate: coordinate, accuracy: accuracy
        )
    }

    /// Uploads a player-recorded tee location tagged with the tee colour.
    func uploadTee(
        courseId: String,
        holeNumber: Int,
        teeColor: TeeColor,
        coordinate: Coordinate,
        accuracy: Double
    ) async {
        await upload(
            courseId: courseId, holeNumber: holeNumber,
            type: .tee, teeColor: teeColor,
            coordinate: coordinate, accuracy: accuracy
        )
    }

    /// Drops cached data for a course so the next fetch is fresh.
    func invalidateCache(courseId: String) {
        memoryCache.removeValue(forKey: courseId)
        UserDefaults.standard.removeObject(forKey: persistKey(courseId))
    }

    // MARK: - Upload (private)

    private enum ContribType: String { case pin, tee }

    private func upload(
        courseId: String, holeNumber: Int,
        type: ContribType, teeColor: TeeColor?,
        coordinate: Coordinate, accuracy: Double
    ) async {
        let record = CKRecord(recordType: contributionType)
        record["courseId"]       = courseId
        record["holeNumber"]     = holeNumber
        record["type"]           = type.rawValue
        record["teeColor"]       = teeColor?.rawValue ?? ""
        record["latitude"]       = coordinate.latitude
        record["longitude"]      = coordinate.longitude
        record["accuracyMeters"] = max(1.0, accuracy)
        record["contributorId"]  = contributorId()
        record["recordedAt"]     = Date.now

        do {
            _ = try await db.save(record)
            invalidateCache(courseId: courseId)
            #if DEBUG
            let colorTag = teeColor.map { " (\($0.displayName))" } ?? ""
            print("[CloudGPS] ↑ \(type.rawValue)\(colorTag) hole \(holeNumber) for \(courseId)")
            #endif
        } catch {
            #if DEBUG
            print("[CloudGPS] Upload failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Fetch aggregates from CloudKit

    private struct AggregateRecord {
        let ckID: CKRecord.ID
        let holeNumber: Int
        let type: ContribType
        let teeColor: TeeColor?
        let coordinate: Coordinate
        let sampleCount: Int
        let stdDevMeters: Double
        let confidence: CommunityHoleData.Confidence
        let lastAggregatedAt: Date

        var groupKey: GroupKey { GroupKey(holeNumber: holeNumber, type: type, teeColor: teeColor) }

        init?(record: CKRecord) {
            guard
                let hNum   = record["holeNumber"]      as? Int,
                let tyStr  = record["type"]             as? String,
                let ty     = ContribType(rawValue: tyStr),
                let lat    = record["latitude"]         as? Double,
                let lon    = record["longitude"]        as? Double,
                let cnt    = record["sampleCount"]      as? Int,
                let std    = record["stdDevMeters"]     as? Double,
                let cfStr  = record["confidence"]       as? String,
                let cf     = CommunityHoleData.Confidence(rawValue: cfStr),
                let aggDt  = record["lastAggregatedAt"] as? Date
            else { return nil }

            ckID             = record.recordID
            holeNumber       = hNum
            type             = ty
            coordinate       = Coordinate(latitude: lat, longitude: lon)
            sampleCount      = cnt
            stdDevMeters     = std
            confidence       = cf
            lastAggregatedAt = aggDt
            let cs = record["teeColor"] as? String ?? ""
            teeColor         = cs.isEmpty ? nil : TeeColor(rawValue: cs)
        }
    }

    private func fetchAggregates(courseId: String) async throws -> [AggregateRecord] {
        let predicate = NSPredicate(format: "courseId == %@", courseId)
        let query     = CKQuery(recordType: aggregateType, predicate: predicate)
        var results   = [AggregateRecord]()
        var cursor: CKQueryOperation.Cursor? = nil

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let c = cursor {
                page = try await db.records(continuingMatchFrom: c)
            } else {
                page = try await db.records(matching: query)
            }
            cursor = page.queryCursor
            for (_, result) in page.matchResults {
                if let r = try? result.get(), let agg = AggregateRecord(record: r) {
                    results.append(agg)
                }
            }
        } while cursor != nil

        return results
    }

    // MARK: - Re-aggregate stale holes

    private struct ContribRecord {
        let holeNumber: Int
        let type: ContribType
        let teeColor: TeeColor?
        let coordinate: Coordinate
        let accuracyMeters: Double

        var groupKey: GroupKey { GroupKey(holeNumber: holeNumber, type: type, teeColor: teeColor) }

        init?(record: CKRecord) {
            guard
                let hNum  = record["holeNumber"]     as? Int,
                let tyStr = record["type"]            as? String,
                let ty    = ContribType(rawValue: tyStr),
                let lat   = record["latitude"]        as? Double,
                let lon   = record["longitude"]       as? Double,
                let acc   = record["accuracyMeters"]  as? Double
            else { return nil }

            holeNumber     = hNum
            type           = ty
            coordinate     = Coordinate(latitude: lat, longitude: lon)
            accuracyMeters = acc
            let cs = record["teeColor"] as? String ?? ""
            teeColor       = cs.isEmpty ? nil : TeeColor(rawValue: cs)
        }
    }

    private struct GroupKey: Hashable {
        let holeNumber: Int
        let type: ContribType
        let teeColor: TeeColor?
    }

    private func refreshStale(courseId: String, existing: [AggregateRecord]) async {
        do {
            let contribs = try await fetchContributions(courseId: courseId)
            let byGroup  = Dictionary(grouping: contribs) { $0.groupKey }
            let existing_ = Dictionary(grouping: existing) { $0.groupKey }

            for (key, group) in byGroup where group.count >= 1 {
                let exAgg = existing_[key]?.first
                let isStale = exAgg.map {
                    Date().timeIntervalSince($0.lastAggregatedAt) > aggregateStaleTTL
                } ?? true
                if isStale { await aggregate(courseId: courseId, group: group, key: key, existing: exAgg) }
            }
        } catch {
            #if DEBUG
            print("[CloudGPS] Stale refresh error: \(error.localizedDescription)")
            #endif
        }
    }

    private func fetchContributions(courseId: String) async throws -> [ContribRecord] {
        let predicate = NSPredicate(format: "courseId == %@", courseId)
        let query     = CKQuery(recordType: contributionType, predicate: predicate)
        var results   = [ContribRecord]()
        var cursor: CKQueryOperation.Cursor? = nil

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let c = cursor {
                page = try await db.records(continuingMatchFrom: c)
            } else {
                page = try await db.records(matching: query)
            }
            cursor = page.queryCursor
            for (_, result) in page.matchResults {
                if let r = try? result.get(), let c = ContribRecord(record: r) { results.append(c) }
            }
        } while cursor != nil

        return results
    }

    // MARK: - Aggregation algorithm

    private func aggregate(
        courseId: String,
        group: [ContribRecord],
        key: GroupKey,
        existing: AggregateRecord?
    ) async {
        // Step 1: initial centroid from all raw contributions
        var points = group.map { ($0.coordinate, $0.accuracyMeters) }
        var centre = weightedCentroid(points)

        // Step 2: remove outliers > 75 m (likely wrong-hole marks)
        points = points.filter { distanceM($0.0, centre) <= 75 }
        guard !points.isEmpty else { return }

        // Step 3: tighter second pass — remove > 30 m from refined centroid
        centre = weightedCentroid(points)
        points = points.filter { distanceM($0.0, centre) <= 30 }
        guard !points.isEmpty else { return }

        // Step 4: final weighted average
        let finalCoord = weightedCentroid(points)

        // Step 5: std deviation of surviving points
        let dists = points.map { distanceM($0.0, finalCoord) }
        let mean  = dists.reduce(0, +) / Double(dists.count)
        let variance = dists.map { pow($0 - mean, 2) }.reduce(0, +) / Double(dists.count)
        let stdDev   = sqrt(variance)

        // Step 6: confidence tier
        let confidence: CommunityHoleData.Confidence = points.count >= 8 ? .high
            : points.count >= 3 ? .medium
            : .low

        // Step 7: save / update aggregate record
        let ckRecord: CKRecord
        if let id = existing?.ckID {
            ckRecord = (try? await db.record(for: id)) ?? CKRecord(recordType: aggregateType)
        } else {
            ckRecord = CKRecord(recordType: aggregateType)
        }

        ckRecord["courseId"]          = courseId
        ckRecord["holeNumber"]        = key.holeNumber
        ckRecord["type"]              = key.type.rawValue
        ckRecord["teeColor"]          = key.teeColor?.rawValue ?? ""
        ckRecord["latitude"]          = finalCoord.latitude
        ckRecord["longitude"]         = finalCoord.longitude
        ckRecord["sampleCount"]       = points.count
        ckRecord["stdDevMeters"]      = stdDev
        ckRecord["confidence"]        = confidence.rawValue
        ckRecord["lastAggregatedAt"]  = Date.now

        do {
            _ = try await db.save(ckRecord)
            #if DEBUG
            let colorTag = key.teeColor.map { " \($0.displayName)" } ?? ""
            print("[CloudGPS] ✓ Aggregated hole \(key.holeNumber) \(key.type.rawValue)\(colorTag)" +
                  " → \(points.count) samples, \(confidence.rawValue), σ=\(String(format:"%.1f",stdDev))m")
            #endif
        } catch {
            #if DEBUG
            print("[CloudGPS] Aggregate save failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Build output type

    private func buildHoleData(from records: [AggregateRecord]) -> [CommunityHoleData] {
        var builders: [Int: CommunityHoleData.Builder] = [:]

        for rec in records {
            if builders[rec.holeNumber] == nil {
                builders[rec.holeNumber] = CommunityHoleData.Builder(holeNumber: rec.holeNumber)
            }
            let b = builders[rec.holeNumber]!

            switch rec.type {
            case .pin:
                b.pinCoordinate   = rec.coordinate
                b.pinSampleCount  = rec.sampleCount
                b.pinStdDevMeters = rec.stdDevMeters
                b.pinConfidence   = rec.confidence
            case .tee:
                if let color = rec.teeColor {
                    b.tees[color] = CommunityHoleData.TeeData(
                        coordinate:   rec.coordinate,
                        sampleCount:  rec.sampleCount,
                        stdDevMeters: rec.stdDevMeters,
                        confidence:   rec.confidence
                    )
                }
            }
        }

        return builders.values
            .map { $0.build() }
            .sorted { $0.holeNumber < $1.holeNumber }
    }

    // MARK: - Geometry helpers

    private func weightedCentroid(_ points: [(Coordinate, Double)]) -> Coordinate {
        var wLat = 0.0, wLon = 0.0, totalW = 0.0
        for (coord, acc) in points {
            let w = 1.0 / max(acc, 1.0)
            wLat += coord.latitude * w
            wLon += coord.longitude * w
            totalW += w
        }
        guard totalW > 0 else { return points[0].0 }
        return Coordinate(latitude: wLat / totalW, longitude: wLon / totalW)
    }

    private func distanceM(_ a: Coordinate, _ b: Coordinate) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: - Local persistence (UserDefaults, 24-hour TTL)

    private struct PersistedEntry: Codable {
        let holes: [CommunityHoleData]
        let savedAt: Date
    }

    private func persistKey(_ courseId: String) -> String { "community_gps_v1_\(courseId)" }

    private func cache(_ data: [CommunityHoleData], courseId: String) {
        memoryCache[courseId] = (data, .now)
        let entry = PersistedEntry(holes: data, savedAt: .now)
        if let encoded = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(encoded, forKey: persistKey(courseId))
        }
    }

    private func loadPersisted(courseId: String) -> [CommunityHoleData]? {
        guard
            let raw   = UserDefaults.standard.data(forKey: persistKey(courseId)),
            let entry = try? JSONDecoder().decode(PersistedEntry.self, from: raw),
            Date().timeIntervalSince(entry.savedAt) < localCacheTTL
        else { return nil }
        return entry.holes
    }
}
