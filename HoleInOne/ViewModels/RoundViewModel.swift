import CoreLocation
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class RoundViewModel {
    // Round state
    var round: Round
    var distanceToPin: Int = 0
    var swingCounts: [Int: Int] = [:]   // holeNumber → count
    var userLocation: CLLocation?

    // Settings
    var preferredUnit: DistanceUnit = .yards

    // Learned GPS overrides — loaded on startRound, updated immediately on mark
    var learnedPins: [Int: Coordinate] = [:]   // holeNumber → pin coordinate
    var learnedTees: [Int: Coordinate] = [:]   // holeNumber → tee coordinate

    // Services
    private let locationManager = LocationManager()
    private let watchManager = WatchConnectivityManager.shared
    var historyStore: SwingHistoryStore?
    var learnedGPSStore: LearnedGPSStore?
    private var activeRoundResult: RoundResult?

    init(round: Round) {
        self.round = round
        loadUnitPreference()
    }

    // MARK: - Round lifecycle

    func startRound(store: SwingHistoryStore, gpsStore: LearnedGPSStore) {
        historyStore    = store
        learnedGPSStore = gpsStore
        activeRoundResult = store.startRound(course: round.course, selection: round.selection)

        // Load all previously recorded GPS overrides for this course
        loadLearnedGPS()

        watchManager.onSwingReceived = { [weak self] payload in
            self?.handleSwingFromWatch(payload)
        }
        locationManager.onLocationUpdate = { [weak self] location in
            self?.handleLocationUpdate(location)
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestPermission()
        } else {
            locationManager.start()
        }
    }

    func endRound() {
        locationManager.stop()
        watchManager.onSwingReceived = nil
    }

    // MARK: - Effective hole (learned GPS applied on top of stored coordinates)

    /// Returns the current hole with any player-recorded coordinates substituted in.
    var effectiveCurrentHole: GolfHole {
        effectiveHole(round.currentHole)
    }

    func effectiveHole(_ hole: GolfHole) -> GolfHole {
        GolfHole(
            number:        hole.number,
            par:           hole.par,
            handicap:      hole.handicap,
            teeCoordinate: learnedTees[hole.number] ?? hole.teeCoordinate,
            pinCoordinate: learnedPins[hole.number] ?? hole.pinCoordinate,
            lengthMeters:  hole.lengthMeters
        )
    }

    // MARK: - Marking pin / tee

    func hasLearnedPin(holeNumber: Int) -> Bool { learnedPins[holeNumber] != nil }
    func hasLearnedTee(holeNumber: Int) -> Bool { learnedTees[holeNumber] != nil }

    /// Records the player's current location as the pin for the current hole.
    func markPin() {
        guard let loc = userLocation, let store = learnedGPSStore else { return }
        let holeNumber = round.currentHole.number
        let coord = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        learnedPins[holeNumber] = coord
        store.recordPin(courseId: round.course.id, holeNumber: holeNumber, coordinate: loc.coordinate)
        // Recalculate distance with new pin
        handleLocationUpdate(loc)
    }

    /// Records the player's current location as the tee for the current hole.
    func markTee() {
        guard let loc = userLocation, let store = learnedGPSStore else { return }
        let holeNumber = round.currentHole.number
        let coord = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        learnedTees[holeNumber] = coord
        store.recordTee(courseId: round.course.id, holeNumber: holeNumber, coordinate: loc.coordinate)
    }

    // MARK: - Hole navigation

    func goToNextHole() {
        guard !round.isOnLastHole else { return }
        round.currentHoleIndex += 1
        sendWatchUpdate()
    }

    func goToPreviousHole() {
        guard !round.isOnFirstHole else { return }
        round.currentHoleIndex -= 1
        sendWatchUpdate()
    }

    // MARK: - Swing counting

    func incrementSwing() {
        let hole = round.currentHole.number
        swingCounts[hole, default: 0] += 1
        persistSwing(hole: hole)
    }

    func decrementSwing() {
        let hole = round.currentHole.number
        if swingCounts[hole, default: 0] > 0 {
            swingCounts[hole]! -= 1
            persistSwing(hole: hole)
        }
    }

    var currentSwingCount: Int {
        swingCounts[round.currentHole.number, default: 0]
    }

    // MARK: - Unit preference

    func setUnit(_ unit: DistanceUnit) {
        preferredUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: "preferredDistanceUnit")
        if let location = userLocation { handleLocationUpdate(location) }
    }

    private func loadUnitPreference() {
        if let raw = UserDefaults.standard.string(forKey: "preferredDistanceUnit"),
           let unit = DistanceUnit(rawValue: raw) {
            preferredUnit = unit
        }
    }

    // MARK: - Private

    private func loadLearnedGPS() {
        guard let store = learnedGPSStore else { return }
        let entries = store.fetchAll(courseId: round.course.id)
        for (holeNumber, entry) in entries {
            if let pin = entry.pinCoordinate { learnedPins[holeNumber] = pin }
            if let tee = entry.teeCoordinate { learnedTees[holeNumber] = tee }
        }
    }

    private func handleLocationUpdate(_ location: CLLocation) {
        userLocation = location
        distanceToPin = DistanceCalculator.distance(
            from: location,
            to: effectiveCurrentHole.pinCoordinate,
            unit: preferredUnit
        )
        sendWatchUpdate()
    }

    private func handleSwingFromWatch(_ payload: SwingPayload) {
        guard payload.courseId == round.course.id,
              payload.holeNumber == round.currentHole.number else { return }
        swingCounts[payload.holeNumber] = payload.swingCount
        persistSwing(hole: payload.holeNumber)
    }

    private func sendWatchUpdate() {
        let payload = WatchPayload(
            holeNumber: round.currentHole.number,
            par:        round.currentHole.par,
            distance:   distanceToPin,
            distanceUnit: preferredUnit.rawValue,
            courseName: round.course.name
        )
        watchManager.sendToWatch(payload)
    }

    private func persistSwing(hole: Int) {
        guard let store = historyStore, let result = activeRoundResult else { return }
        let par = round.course.holes.first(where: { $0.number == hole })?.par ?? 4
        store.updateSwingCount(round: result, holeNumber: hole, par: par, swingCount: swingCounts[hole, default: 0])
    }
}
