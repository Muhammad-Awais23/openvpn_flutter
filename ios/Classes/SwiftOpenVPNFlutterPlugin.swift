import NetworkExtension
import OpenVPNAdapter
import UserNotifications
import os.log

extension NEPacketTunnelFlow: @retroactive OpenVPNAdapterPacketFlow {}

class PacketTunnelProvider: NEPacketTunnelProvider {

    lazy var vpnAdapter: OpenVPNAdapter = {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        return adapter
    }()

    let vpnReachability = OpenVPNReachability()

    var startHandler: ((Error?) -> Void)?
    var stopHandler: (() -> Void)?
    var groupIdentifier: String?

    static var timeOutEnabled = true
    var userInitiatedDisconnect = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = protocolConfiguration.providerConfiguration
        else {
            fatalError()
        }

        guard let groupIdentifierData: Data = providerConfiguration["groupIdentifier"] as? Data
        else {
            fatalError()
        }

        self.groupIdentifier = String(decoding: groupIdentifierData, as: UTF8.self)

        // If we reach this point, configuration exists, which means app is running
        // Since we remove configurations when app is killed, this should only run when app is active

        guard let ovpnFileContent: Data = providerConfiguration["config"] as? Data else {
            fatalError()
        }

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = ovpnFileContent
        configuration.tunPersist = false

        let properties: OpenVPNConfigurationEvaluation
        do {
            properties = try vpnAdapter.apply(configuration: configuration)
        } catch {
            completionHandler(error)
            return
        }

        if !properties.autologin {
            guard let username = options?["username"] as? String,
                let password = options?["password"] as? String
            else {
                fatalError()
            }

            let credentials = OpenVPNCredentials()
            credentials.username = username
            credentials.password = password

            do {
                try vpnAdapter.provide(credentials: credentials)
            } catch {
                completionHandler(error)
                return
            }
        }

        vpnReachability.startTracking { [weak self] status in
            guard status == .reachableViaWiFi else { return }
            self?.vpnAdapter.reconnect(afterTimeInterval: 5)
        }

        startHandler = completionHandler
        vpnAdapter.connect(using: packetFlow)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopHandler = completionHandler
        vpnReachability.isTracking ? vpnReachability.stopTracking() : nil
        userInitiatedDisconnect = true
        vpnAdapter.disconnect()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil)
    {
        if String(data: messageData, encoding: .utf8) == "OPENVPN_STATS" {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

            var toSave = ""
            toSave +=
                UserDefaults.init(suiteName: groupIdentifier)?.string(forKey: "connected_on") ?? ""
            toSave += "_\(vpnAdapter.interfaceStatistics.packetsIn)"
            toSave += "_\(vpnAdapter.interfaceStatistics.packetsOut)"
            toSave += "_\(vpnAdapter.interfaceStatistics.bytesIn)"
            toSave += "_\(vpnAdapter.interfaceStatistics.bytesOut)"

            UserDefaults.init(suiteName: groupIdentifier)?.setValue(
                toSave, forKey: "connectionUpdate")
        }
    }

    func scheduleVpnExpiredNotification(after seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "VPN disconnected"
        content.body = "Your free minutes have been consumed"
        content.sound = .default
        content.categoryIdentifier = "vpn_expired"
        content.userInfo = ["fromVPN": true]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "vpn_limit_expired", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                os_log("Failed to schedule notification: %@", error.localizedDescription)
            } else {
                os_log("Notification scheduled after %d seconds", seconds)
            }
        }
    }

    func cancelVpnExpiredNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            "vpn_limit_expired"
        ])
    }
}

extension PacketTunnelProvider: OpenVPNAdapterDelegate {

    func openVPNAdapter(
        _ openVPNAdapter: OpenVPNAdapter,
        configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        networkSettings?.dnsSettings?.matchDomains = [""]
        setTunnelNetworkSettings(networkSettings, completionHandler: completionHandler)
    }

    private func _updateEvent(_ event: OpenVPNAdapterEvent) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var stageValue = "INVALID"
        switch event {
        case .connected:
            stageValue = "CONNECTED"
            UserDefaults.init(suiteName: groupIdentifier)?.setValue(
                formatter.string(from: Date.now), forKey: "connected_on")
        case .disconnected:
            stageValue = "DISCONNECTED"
        case .connecting:
            stageValue = "CONNECTING"
        case .reconnecting:
            stageValue = "RECONNECTING"
        case .info:
            stageValue = "CONNECTED"
        default:
            UserDefaults.init(suiteName: groupIdentifier)?.removeObject(forKey: "connected_on")
        }

        UserDefaults.init(suiteName: groupIdentifier)?.setValue(stageValue, forKey: "vpnStage")
    }

    func openVPNAdapter(
        _ openVPNAdapter: OpenVPNAdapter,
        handleEvent event: OpenVPNAdapterEvent,
        message: String?
    ) {
        PacketTunnelProvider.timeOutEnabled = true
        _updateEvent(event)

        switch event {
        case .connected:
            PacketTunnelProvider.timeOutEnabled = false
            userInitiatedDisconnect = false

            // Handle time-limited connections
            if let group = groupIdentifier,
                let allowed = UserDefaults(suiteName: group)?.integer(
                    forKey: "allowed_duration_seconds"),
                allowed > 0
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(allowed)) { [weak self] in
                    self?.vpnAdapter.disconnect()
                    self?.scheduleVpnExpiredNotification(after: 1)
                }
            }

            startHandler?(nil)
            startHandler = nil

        case .disconnected:
            PacketTunnelProvider.timeOutEnabled = false

            if vpnReachability.isTracking {
                vpnReachability.stopTracking()
            }

            stopHandler?()
            stopHandler = nil

        case .reconnecting:
            break
        default:
            break
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error) {
        guard let fatal = (error as NSError).userInfo[OpenVPNAdapterErrorFatalKey] as? Bool,
            fatal == true
        else { return }

        if vpnReachability.isTracking {
            vpnReachability.stopTracking()
        }

        if let startHandler = startHandler {
            startHandler(error)
            self.startHandler = nil
        } else {
            cancelTunnelWithError(error)
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {}
}
