import Flutter
import NetworkExtension
import UIKit

public class SwiftOpenVPNFlutterPlugin: NSObject, FlutterPlugin {
    private static var utils: VPNUtils! = VPNUtils()
    private static var EVENT_CHANNEL_VPN_STAGE = "id.laskarmedia.openvpn_flutter/vpnstage"
    private static var METHOD_CHANNEL_VPN_CONTROL = "id.laskarmedia.openvpn_flutter/vpncontrol"

    public static var stage: FlutterEventSink?
    private var initialized: Bool = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftOpenVPNFlutterPlugin()
        instance.onRegister(registrar)
    }

    public func onRegister(_ registrar: FlutterPluginRegistrar) {
        let vpnControlM = FlutterMethodChannel(
            name: SwiftOpenVPNFlutterPlugin.METHOD_CHANNEL_VPN_CONTROL,
            binaryMessenger: registrar.messenger())
        let vpnStageE = FlutterEventChannel(
            name: SwiftOpenVPNFlutterPlugin.EVENT_CHANNEL_VPN_STAGE,
            binaryMessenger: registrar.messenger())

        vpnStageE.setStreamHandler(StageHandler())

        vpnControlM.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "status":
                SwiftOpenVPNFlutterPlugin.utils.getTraffictStats()
                result(
                    UserDefaults.init(suiteName: SwiftOpenVPNFlutterPlugin.utils.groupIdentifier)?
                        .string(forKey: "connectionUpdate"))
                break
            case "stage":
                result(SwiftOpenVPNFlutterPlugin.utils.currentStatus())
                break
            case "initialize":
                let providerBundleIdentifier: String? =
                    (call.arguments as? [String: Any])?["providerBundleIdentifier"] as? String
                let localizedDescription: String? =
                    (call.arguments as? [String: Any])?["localizedDescription"] as? String
                let groupIdentifier: String? =
                    (call.arguments as? [String: Any])?["groupIdentifier"] as? String
                let autoReconnect: Bool =
                    (call.arguments as? [String: Any])?["autoReconnect"] as? Bool ?? false

                if providerBundleIdentifier == nil {
                    result(
                        FlutterError(
                            code: "-2",
                            message: "providerBundleIdentifier content empty or null",
                            details: nil))
                    return
                }
                if localizedDescription == nil {
                    result(
                        FlutterError(
                            code: "-3",
                            message: "localizedDescription content empty or null",
                            details: nil))
                    return
                }
                if groupIdentifier == nil {
                    result(
                        FlutterError(
                            code: "-4",
                            message: "groupIdentifier content empty or null",
                            details: nil))
                    return
                }

                SwiftOpenVPNFlutterPlugin.utils.groupIdentifier = groupIdentifier
                SwiftOpenVPNFlutterPlugin.utils.localizedDescription = localizedDescription
                SwiftOpenVPNFlutterPlugin.utils.providerBundleIdentifier = providerBundleIdentifier
                SwiftOpenVPNFlutterPlugin.utils.autoReconnectEnabled = autoReconnect

                SwiftOpenVPNFlutterPlugin.utils.loadProviderManager { (err: Error?) in
                    if err == nil {
                        result(SwiftOpenVPNFlutterPlugin.utils.currentStatus())
                    } else {
                        result(
                            FlutterError(
                                code: "-4",
                                message: err?.localizedDescription,
                                details: err?.localizedDescription))
                    }
                }
                self.initialized = true
                break
            case "disconnect":
                SwiftOpenVPNFlutterPlugin.utils.stopVPN()
                result(nil)
                break
            case "connect":
                if !self.initialized {
                    result(
                        FlutterError(
                            code: "-1",
                            message: "VPNEngine need to be initialize",
                            details: nil))
                    return
                }
                let config: String? = (call.arguments as? [String: Any])?["config"] as? String
                let username: String? = (call.arguments as? [String: Any])?["username"] as? String
                let password: String? = (call.arguments as? [String: Any])?["password"] as? String

                if config == nil {
                    result(
                        FlutterError(
                            code: "-2",
                            message: "Config is empty or nulled",
                            details: "Config can't be nulled"))
                    return
                }

                SwiftOpenVPNFlutterPlugin.utils.configureVPN(
                    config: config,
                    username: username,
                    password: password,
                    completion: { (success: Error?) -> Void in
                        if success == nil {
                            result(nil)
                        } else {
                            result(
                                FlutterError(
                                    code: "99",
                                    message: "permission denied",
                                    details: success?.localizedDescription))
                        }
                    })
                break
            case "setAutoReconnect":
                let autoReconnect: Bool =
                    (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                SwiftOpenVPNFlutterPlugin.utils.autoReconnectEnabled = autoReconnect
                result(nil)
                break
            case "dispose":
                self.initialized = false
                SwiftOpenVPNFlutterPlugin.utils.dispose()
                result(nil)
                break
            default:
                result(FlutterMethodNotImplemented)
                break
            }
        })
    }

    class StageHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
            -> FlutterError?
        {
            SwiftOpenVPNFlutterPlugin.utils.stage = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            SwiftOpenVPNFlutterPlugin.utils.stage = nil
            return nil
        }
    }
}

@available(iOS 9.0, *)
class VPNUtils {
    var providerManager: NETunnelProviderManager!
    private var vpnStatusTimer: Timer?
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var groupIdentifier: String?
    var stage: FlutterEventSink!
    var vpnStageObserver: NSObjectProtocol?
    var autoReconnectEnabled: Bool = false

    // Track VPN state for auto-reconnect logic
    private var shouldBeConnected: Bool = false
    private var lastConfig: String?
    private var lastUsername: String?
    private var lastPassword: String?
    private var isManualDisconnect: Bool = false
    private var reconnectTimer: Timer?

    // NEW: Track if connection was initiated by app
    private var appInitiatedConnection: Bool = false
    private var connectionMonitorTimer: Timer?

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error == nil {
                self.providerManager = managers?.first ?? NETunnelProviderManager()
                // Check if VPN was previously connected and should auto-reconnect
                self.checkInitialVPNState()
                // Start monitoring for unauthorized connections
                self.startConnectionMonitoring()
                completion(nil)
            } else {
                completion(error)
            }
        }
    }

    private func checkInitialVPNState() {
        // Check UserDefaults to see if VPN was previously in a "should be connected" state
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        self.shouldBeConnected = userDefaults?.bool(forKey: "vpn_should_be_connected") ?? false
        self.appInitiatedConnection =
            userDefaults?.bool(forKey: "app_initiated_connection") ?? false

        if self.shouldBeConnected && self.autoReconnectEnabled {
            // If VPN should be connected but isn't, attempt reconnect
            if let currentStatus = self.providerManager?.connection.status,
                currentStatus == .disconnected || currentStatus == .invalid
            {
                self.attemptReconnect()
            }
        }
    }

    private func saveVPNState() {
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        userDefaults?.set(self.shouldBeConnected, forKey: "vpn_should_be_connected")
        userDefaults?.set(self.appInitiatedConnection, forKey: "app_initiated_connection")
        userDefaults?.synchronize()
    }

    // NEW: Monitor for unauthorized connections every 2 seconds
    private func startConnectionMonitoring() {
        self.connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            self?.checkForUnauthorizedConnection()
        }
    }

    // NEW: Check if VPN is connected without app authorization
    private func checkForUnauthorizedConnection() {
        guard let status = self.providerManager?.connection.status else { return }

        // If VPN is connected/connecting but app didn't initiate it, disconnect immediately
        if (status == .connected || status == .connecting) && !self.appInitiatedConnection {
            print(
                "OpenVPN: Unauthorized connection detected from Settings/Control Center - Disconnecting"
            )
            self.forceDisconnect()
        }
    }

    // NEW: Force disconnect without triggering auto-reconnect
    private func forceDisconnect() {
        self.isManualDisconnect = true
        self.shouldBeConnected = false
        self.appInitiatedConnection = false
        self.saveVPNState()
        self.cancelReconnectTimer()
        self.providerManager?.connection.stopVPNTunnel()
        self.stage?("disconnected")
    }
    private func formatDuration(duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func updateVpnStatus() {
        guard let session = self.providerManager?.connection as? NETunnelProviderSession else {
            return
        }

        do {
            try session.sendProviderMessage("OPENVPN_STATS".data(using: .utf8)!) {
                [weak self] data in
                guard let self = self else { return }
                guard let data = data else { return }

                // Parse stats from data
                if let statsString = String(data: data, encoding: .utf8),
                    let statsData = statsString.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: statsData, options: [])
                        as? [String: Any]
                {

                    let connectedOnString = json["connected_on"] as? String ?? ""
                    let connectedOn = ISO8601DateFormatter().date(from: connectedOnString) ?? Date()
                    let byteIn = json["byte_in"] as? String ?? "0"
                    let byteOut = json["byte_out"] as? String ?? "0"

                    // Calculate duration
                    let duration = Date().timeIntervalSince(connectedOn)
                    let durationStr = self.formatDuration(duration: duration)

                    // Save to UserDefaults for Flutter to read
                    let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
                    let connectionUpdate: [String: Any] = [
                        "connectedOn": connectedOnString,
                        "duration": durationStr,
                        "byteIn": byteIn,
                        "byteOut": byteOut,
                    ]
                    if let encoded = try? JSONSerialization.data(withJSONObject: connectionUpdate) {
                        userDefaults?.set(
                            String(data: encoded, encoding: .utf8), forKey: "connectionUpdate")
                        userDefaults?.synchronize()
                    }
                }
            }
        } catch {
            print("OpenVPN: Failed to request stats: \(error.localizedDescription)")
        }
    }

    private func startVpnStatusTimer() {
        // Cancel if already running
        vpnStatusTimer?.invalidate()

        // Fire every 1 second to update stats
        vpnStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            self?.updateVpnStatus()
        }
    }

    func onVpnStatusChanged(notification: NEVPNStatus) {
        switch notification {
        case NEVPNStatus.connected:
            // Only allow connection if app initiated it
            if !self.appInitiatedConnection {
                print("OpenVPN: Unauthorized connection attempt blocked")
                self.forceDisconnect()
                return
            }

            stage?("connected")
            self.shouldBeConnected = true
            self.saveVPNState()
            self.cancelReconnectTimer()
            self.startVpnStatusTimer()
            break
        case NEVPNStatus.connecting:
            // Only allow connecting if app initiated it
            if !self.appInitiatedConnection {
                print("OpenVPN: Unauthorized connecting attempt blocked")
                self.forceDisconnect()
                return
            }
            stage?("connecting")
            break
        case NEVPNStatus.disconnected:

            stage?("disconnected")
            self.handleDisconnection()
            vpnStatusTimer?.invalidate()
            vpnStatusTimer = nil
            break
        case NEVPNStatus.disconnecting:
            stage?("disconnecting")
            break
        case NEVPNStatus.invalid:
            stage?("invalid")
            self.handleDisconnection()
            vpnStatusTimer?.invalidate()
            vpnStatusTimer = nil
            break
        case NEVPNStatus.reasserting:
            stage?("reasserting")
            break
        default:
            stage?("null")
            break
        }
    }

    private func handleDisconnection() {
        // Check if this was an unauthorized disconnection from Settings/Control Center
        if self.appInitiatedConnection && self.shouldBeConnected && !self.isManualDisconnect {
            // This was unauthorized disconnection - prevent it by reconnecting
            if self.autoReconnectEnabled {
                print("OpenVPN: Unauthorized disconnection detected - Auto-reconnecting")
                self.scheduleReconnect()
                return
            }
        }

        // Only attempt reconnect if:
        // 1. Auto-reconnect is enabled
        // 2. VPN should be connected (was previously connected by user)
        // 3. This wasn't a manual disconnect
        // 4. We have the necessary connection details
        if self.autoReconnectEnabled && self.shouldBeConnected && !self.isManualDisconnect
            && self.lastConfig != nil
        {
            // Schedule reconnection attempt after a short delay
            self.scheduleReconnect()
        } else if self.isManualDisconnect {
            // Reset manual disconnect flag and update state
            self.isManualDisconnect = false
            self.shouldBeConnected = false
            self.appInitiatedConnection = false
            self.saveVPNState()
        }
    }

    private func scheduleReconnect() {
        // Cancel any existing timer
        self.cancelReconnectTimer()

        // Schedule reconnection after 2 seconds
        self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) {
            [weak self] _ in
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard let config = self.lastConfig else { return }
        print("OpenVPN: Attempting auto-reconnect...")

        self.configureVPN(
            config: config,
            username: self.lastUsername,
            password: self.lastPassword
        ) { error in
            if let error = error {
                print("OpenVPN: Auto-reconnect failed: \(error.localizedDescription)")
                // Could implement exponential backoff here if needed
            } else {
                print("OpenVPN: Auto-reconnect initiated successfully")
            }
        }
    }

    private func cancelReconnectTimer() {
        self.reconnectTimer?.invalidate()
        self.reconnectTimer = nil
    }

    func onVpnStatusChangedString(notification: NEVPNStatus?) -> String? {
        if notification == nil {
            return "disconnected"
        }
        switch notification! {
        case NEVPNStatus.connected:
            return "connected"
        case NEVPNStatus.connecting:
            return "connecting"
        case NEVPNStatus.disconnected:
            return "disconnected"
        case NEVPNStatus.disconnecting:
            return "disconnecting"
        case NEVPNStatus.invalid:
            return "invalid"
        case NEVPNStatus.reasserting:
            return "reasserting"
        default:
            return ""
        }
    }

    func currentStatus() -> String? {
        if self.providerManager != nil {
            return onVpnStatusChangedString(notification: self.providerManager.connection.status)
        } else {
            return "disconnected"
        }
    }

    func configureVPN(
        config: String?,
        username: String?,
        password: String?,
        completion: @escaping (_ error: Error?) -> Void = { _ in }
    ) {
        let configData = config

        // Store connection details for potential reconnection
        self.lastConfig = config
        self.lastUsername = username
        self.lastPassword = password

        // IMPORTANT: Mark this as app-initiated connection BEFORE starting
        self.appInitiatedConnection = true
        self.shouldBeConnected = true
        self.saveVPNState()

        self.providerManager?.loadFromPreferences { error in
            if error == nil {
                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.serverAddress = ""
                tunnelProtocol.providerBundleIdentifier = self.providerBundleIdentifier
                let nullData = "".data(using: .utf8)
                tunnelProtocol.providerConfiguration = [
                    "config": configData?.data(using: .utf8) ?? nullData!,
                    "groupIdentifier": self.groupIdentifier?.data(using: .utf8) ?? nullData!,
                    "username": username?.data(using: .utf8) ?? nullData!,
                    "password": password?.data(using: .utf8) ?? nullData!,
                ]
                tunnelProtocol.disconnectOnSleep = false
                self.providerManager.protocolConfiguration = tunnelProtocol
                self.providerManager.localizedDescription = self.localizedDescription
                self.providerManager.isEnabled = true

                self.providerManager.saveToPreferences(completionHandler: { (error) in
                    if error == nil {
                        self.providerManager.loadFromPreferences(completionHandler: { (error) in
                            if error != nil {
                                completion(error)
                                return
                            }
                            do {
                                if self.vpnStageObserver != nil {
                                    NotificationCenter.default.removeObserver(
                                        self.vpnStageObserver!,
                                        name: NSNotification.Name.NEVPNStatusDidChange,
                                        object: nil)
                                }
                                self.vpnStageObserver = NotificationCenter.default.addObserver(
                                    forName: NSNotification.Name.NEVPNStatusDidChange,
                                    object: nil,
                                    queue: nil
                                ) { [weak self] notification in
                                    let nevpnconn = notification.object as! NEVPNConnection
                                    let status = nevpnconn.status
                                    self?.onVpnStatusChanged(notification: status)
                                }

                                if username != nil && password != nil {
                                    let options: [String: NSObject] = [
                                        "username": username! as NSString,
                                        "password": password! as NSString,
                                    ]
                                    try self.providerManager.connection.startVPNTunnel(
                                        options: options)
                                } else {
                                    try self.providerManager.connection.startVPNTunnel()
                                }
                                completion(nil)
                            } catch let error {
                                self.stopVPN()
                                print("Error info: \(error)")
                                completion(error)
                            }
                        })
                    } else {
                        completion(error)
                    }
                })
            } else {
                completion(error)
            }
        }
    }

    func stopVPN() {
        // Mark this as a manual disconnect to prevent auto-reconnect
        self.isManualDisconnect = true
        self.shouldBeConnected = false
        self.appInitiatedConnection = false
        self.saveVPNState()
        self.cancelReconnectTimer()
        // ✅ Stop VPN status timer
        vpnStatusTimer?.invalidate()
        vpnStatusTimer = nil

        self.providerManager.connection.stopVPNTunnel()
    }

    func getTraffictStats() {
        if let session = self.providerManager?.connection as? NETunnelProviderSession {
            do {
                try session.sendProviderMessage("OPENVPN_STATS".data(using: .utf8)!) { (data) in
                    //Do nothing
                }
            } catch {
                // some error
            }
        }
    }

    func dispose() {
        self.cancelReconnectTimer()
        self.connectionMonitorTimer?.invalidate()
        self.connectionMonitorTimer = nil

        if self.vpnStageObserver != nil {
            NotificationCenter.default.removeObserver(
                self.vpnStageObserver!,
                name: NSNotification.Name.NEVPNStatusDidChange,
                object: nil)
            self.vpnStageObserver = nil
        }
        self.shouldBeConnected = false
        self.appInitiatedConnection = false
        self.saveVPNState()
    }
}
