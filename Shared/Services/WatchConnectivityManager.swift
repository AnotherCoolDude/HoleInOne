import Foundation
import Observation
import WatchConnectivity

// MARK: - Payloads

struct WatchPayload: Codable {
    let holeNumber: Int
    let par: Int
    let distance: Int
    let distanceUnit: String    // DistanceUnit.rawValue
    let courseName: String
}

struct SwingPayload: Codable {
    let holeNumber: Int
    let courseId: String
    let swingCount: Int
}

// MARK: - Manager

@Observable
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()

    // Set by the view model to receive swing updates from the Watch
    var onSwingReceived: ((SwingPayload) -> Void)?

    // Last payload received on the Watch side
    var latestPayload: WatchPayload?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - iPhone → Watch

    /// Sends distance/hole state. Uses updateApplicationContext so only latest matters.
    func sendToWatch(_ payload: WatchPayload) {
        #if os(iOS)
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        #else
        guard WCSession.default.activationState == .activated else { return }
        #endif
        do {
            let dict = try payload.asDictionary()
            try WCSession.default.updateApplicationContext(dict)
        } catch {
            print("WatchConnectivityManager send error: \(error)")
        }
    }

    // MARK: - Watch → iPhone

    /// Sends swing count back to the iPhone in real-time.
    func sendSwingToPhone(_ payload: SwingPayload) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        do {
            let dict = try payload.asDictionary()
            WCSession.default.sendMessage(dict, replyHandler: nil)
        } catch {
            print("WatchConnectivityManager swing send error: \(error)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    // Receive distance payload on Watch
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let payload = try? WatchPayload(from: applicationContext) else { return }
        DispatchQueue.main.async {
            self.latestPayload = payload
        }
    }

    // Receive swing update on iPhone
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let payload = try? SwingPayload(from: message) else { return }
        DispatchQueue.main.async {
            self.onSwingReceived?(payload)
        }
    }

    // Required on iOS only
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}

// MARK: - Codable ↔ Dictionary helpers

private extension Encodable {
    func asDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Cannot convert to dictionary"))
        }
        return dict
    }
}

private extension WatchPayload {
    init(from dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        self = try JSONDecoder().decode(WatchPayload.self, from: data)
    }
}

private extension SwingPayload {
    init(from dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        self = try JSONDecoder().decode(SwingPayload.self, from: data)
    }
}
