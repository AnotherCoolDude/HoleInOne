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

    // Services
    private let locationManager = LocationManager()
    private let watchManager = WatchConnectivityManager.shared
    var historyStore: SwingHistoryStore?
    private var activeRoundResult: RoundResult?

    init(round: Round) {
        self.round = round
        loadUnitPreference()
    }

    // MARK: - Round lifecycle

    func startRound(store: SwingHistoryStore) {
        historyStore = store
        activeRoundResult = store.startRound(course: round.course, selection: round.selection)

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

    // MARK: - Swing counting (local, from iPhone UI)

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
        if let location = userLocation {
            handleLocationUpdate(location)
        }
    }

    private func loadUnitPreference() {
        if let raw = UserDefaults.standard.string(forKey: "preferredDistanceUnit"),
           let unit = DistanceUnit(rawValue: raw) {
            preferredUnit = unit
        }
    }

    // MARK: - Private

    private func handleLocationUpdate(_ location: CLLocation) {
        userLocation = location
        distanceToPin = DistanceCalculator.distance(
            from: location,
            to: round.currentHole.pinCoordinate,
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
            par: round.currentHole.par,
            distance: distanceToPin,
            distanceUnit: preferredUnit.rawValue,
            courseName: round.course.name
        )
        watchManager.sendToWatch(payload)
    }

    private func persistSwing(hole: Int) {
        guard let store = historyStore,
              let result = activeRoundResult else { return }
        let par = round.course.holes.first(where: { $0.number == hole })?.par ?? 4
        store.updateSwingCount(round: result, holeNumber: hole, par: par, swingCount: swingCounts[hole, default: 0])
    }
}
