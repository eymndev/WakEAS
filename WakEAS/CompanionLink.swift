@preconcurrency import Network
import Observation
#if os(iOS)
import UIKit
import UserNotifications
#elseif os(macOS)
import AppKit
#endif

struct NearbyPhone: Identifiable, Sendable {
    let id: String
    let name: String
}

nonisolated private struct DiscoveredPhone: @unchecked Sendable {
    let phone: NearbyPhone
    let endpoint: NWEndpoint
}

nonisolated private struct ConnectionReference: @unchecked Sendable {
    let value: NWConnection
}

@MainActor
@Observable
final class CompanionLink {
    static let shared = CompanionLink()
    private static let service = "_wakeas-link._tcp"
    private static let alertData = Data("WAKEAS_ALARM\n".utf8)

    private(set) var enabled = false
    private(set) var nearbyPhones: [NearbyPhone] = []
    private(set) var connectedName: String?
    #if os(iOS)
    var incomingAlert = false
    #endif

    @ObservationIgnored private let networkQueue = DispatchQueue(label: "wakeas.companion", qos: .utility)
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var macConnection: NWConnection?
    @ObservationIgnored private var phoneConnection: NWConnection?
    @ObservationIgnored private var received = Data()

    func restoreIfEnabled() {
        if UserDefaults.standard.bool(forKey: "companionEnabled") { setEnabled(true) }
    }

    func setEnabled(_ active: Bool) {
        guard enabled != active else { return }
        enabled = active
        UserDefaults.standard.set(active, forKey: "companionEnabled")
        if active {
            #if os(iOS)
            startListener()
            Task { await prepareNotifications() }
            #else
            startBrowser()
            #endif
        } else {
            browser?.cancel()
            browser = nil
            listener?.cancel()
            listener = nil
            macConnection?.cancel()
            macConnection = nil
            phoneConnection?.cancel()
            phoneConnection = nil
            connectedName = nil
            endpoints = [:]
            nearbyPhones = []
            received = Data()
        }
    }

    #if os(macOS)
    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let owner = self else { return }
            let found = results.map { result in
                let endpoint = result.endpoint
                let name: String
                if case let .service(serviceName, _, _, _) = endpoint {
                    name = serviceName
                } else {
                    name = String(describing: endpoint)
                }
                return DiscoveredPhone(phone: NearbyPhone(id: String(describing: endpoint), name: name), endpoint: endpoint)
            }
            Task { @MainActor in
                guard owner.enabled else { return }
                owner.endpoints = Dictionary(uniqueKeysWithValues: found.map { ($0.phone.id, $0.endpoint) })
                owner.nearbyPhones = found.map(\.phone).sorted { $0.name < $1.name }
            }
        }
        self.browser = browser
        browser.start(queue: networkQueue)
    }

    func connect(to phone: NearbyPhone) {
        guard enabled, let endpoint = endpoints[phone.id] else { return }
        macConnection?.cancel()
        connectedName = nil
        let connection = NWConnection(to: endpoint, using: .tcp)
        macConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let owner = self, let connection else { return }
            let reference = ConnectionReference(value: connection)
            Task { @MainActor in
                guard owner.macConnection === reference.value else { return }
                switch state {
                case .ready: owner.connectedName = phone.name
                case .cancelled, .failed: owner.connectedName = nil
                default: break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    func sendAlarm() {
        guard enabled, connectedName != nil, let macConnection else { return }
        macConnection.send(content: Self.alertData, completion: .contentProcessed { _ in })
    }
    #endif

    #if os(iOS)
    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: String(UIDevice.current.name.prefix(40)), type: Self.service)
            listener.newConnectionHandler = { [weak self] connection in
                guard let owner = self else { return }
                let reference = ConnectionReference(value: connection)
                Task { @MainActor in owner.accept(reference.value) }
            }
            self.listener = listener
            listener.start(queue: networkQueue)
        } catch {
            enabled = false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard enabled else { connection.cancel(); return }
        phoneConnection?.cancel()
        phoneConnection = connection
        received = Data()
        connectedName = nil
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let owner = self, let connection else { return }
            let reference = ConnectionReference(value: connection)
            Task { @MainActor in
                guard owner.phoneConnection === reference.value else { return }
                switch state {
                case .ready:
                    owner.connectedName = "Mac"
                    owner.receiveNext(on: reference.value)
                case .cancelled, .failed:
                    owner.connectedName = nil
                default: break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveNext(on connection: NWConnection) {
        let reference = ConnectionReference(value: connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let owner = self else { return }
            Task { @MainActor in
                guard owner.phoneConnection === reference.value else { return }
                if let data { owner.received.append(data) }
                while let newline = owner.received.firstIndex(of: 10) {
                    let message = owner.received.prefix(upTo: newline)
                    owner.received.removeSubrange(...newline)
                    if message == Self.alertData.dropLast() { owner.receiveAlarm() }
                }
                if !complete && error == nil {
                    owner.receiveNext(on: reference.value)
                } else {
                    owner.connectedName = nil
                }
            }
        }
    }

    private func prepareNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationPresenter.shared
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func receiveAlarm() {
        guard enabled else { return }
        incomingAlert = true
        let content = UNMutableNotificationContent()
        content.title = "WAKEAS ALERT"
        content.body = "The Mac detected closed eyes. Wake up!"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("AlertNotification.caf"))
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    #endif
}

#if os(iOS)
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
#endif
