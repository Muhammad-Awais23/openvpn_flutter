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

            case "checkVpnPermission":
                let providerBundleIdentifier: String? =
                    (call.arguments as? [String: Any])?["providerBundleIdentifier"] as? String

                if providerBundleIdentifier == nil {
                    result(
                        FlutterError(
                            code: "INVALID_ARGUMENTS", message: "Missing providerBundleIdentifier",
                            details: nil))
                    return
                }

                SwiftOpenVPNFlutterPlugin.utils.checkVpnPermission(
                    providerBundleIdentifier: providerBundleIdentifier!,
                    result: result)
                break

            case "requestVpnPermission":
                let providerBundleIdentifier: String? =
                    (call.arguments as? [String: Any])?["providerBundleIdentifier"] as? String
                let localizedDescription: String? =
                    (call.arguments as? [String: Any])?["localizedDescription"] as? String

                if providerBundleIdentifier == nil {
                    result(
                        FlutterError(
                            code: "INVALID_ARGUMENTS", message: "Missing providerBundleIdentifier",
                            details: nil))
                    return
                }

                let description = localizedDescription ?? "VPN"

                SwiftOpenVPNFlutterPlugin.utils.requestVpnPermission(
                    providerBundleIdentifier: providerBundleIdentifier!,
                    localizedDescription: description,
                    result: result)
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
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var groupIdentifier: String?
    var stage: FlutterEventSink!
    var vpnStageObserver: NSObjectProtocol?
    var autoReconnectEnabled: Bool = false

    private var shouldBeConnected: Bool = false
    private var lastConfig: String?
    private var lastUsername: String?
    private var lastPassword: String?
    private var isManualDisconnect: Bool = false
    private var reconnectTimer: Timer?
    private var appInitiatedConnection: Bool = false
    private var connectionMonitorTimer: Timer?

    func checkVpnPermission(providerBundleIdentifier: String, result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                result(
                    FlutterError(
                        code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            let exists =
                managers?.contains(where: { manager in
                    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == providerBundleIdentifier
                }) ?? false

            result(exists)
        }
    }

    func requestVpnPermission(
        providerBundleIdentifier: String,
        localizedDescription: String,
        result: @escaping FlutterResult
    ) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                result(
                    FlutterError(
                        code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            // Check if profile already exists
            if let existingManager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == providerBundleIdentifier
            }) {
                print("VPN Permission: Profile already exists")
                result(true)
                return
            }

            // Create minimal profile ONLY if none exists
            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleIdentifier
            proto.serverAddress = "VPN"  // Use description instead of IP

            manager.protocolConfiguration = proto
            manager.localizedDescription = localizedDescription
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    result(
                        FlutterError(
                            code: "SAVE_ERROR", message: saveError.localizedDescription,
                            details: nil))
                    return
                }

                print("VPN Permission: Profile created successfully")
                result(true)
            }
        }
    }

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error != nil {
                completion(error)
                return
            }

            guard let managers = managers else {
                // No managers exist at all - this shouldn't happen after requestVpnPermission
                print("OpenVPN: No VPN profiles found")
                completion(
                    NSError(
                        domain: "OpenVPN", code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No VPN profile found. Call requestVpnPermission first."
                        ]))
                return
            }

            // Find the manager with matching bundle identifier
            if let existingManager = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == self.providerBundleIdentifier
            }) {
                print("OpenVPN: Found existing VPN profile with matching bundle ID")
                self.providerManager = existingManager
            } else if !managers.isEmpty {
                // Fallback: use the first manager and update it
                print("OpenVPN: Using first available VPN profile")
                self.providerManager = managers[0]
            } else {
                completion(
                    NSError(
                        domain: "OpenVPN", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No VPN profile available"]))
                return
            }

            // DO NOT save here - just use the existing manager
            // The profile was already created by requestVpnPermission
            // We'll update it when configureVPN is called

            self.checkInitialVPNState()
            self.startConnectionMonitoring()
            completion(nil)
        }
    }

    private func checkInitialVPNState() {
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        self.shouldBeConnected = userDefaults?.bool(forKey: "vpn_should_be_connected") ?? false
        self.appInitiatedConnection =
            userDefaults?.bool(forKey: "app_initiated_connection") ?? false

        if self.shouldBeConnected && self.autoReconnectEnabled {
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

    private func startConnectionMonitoring() {
        self.connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            self?.checkForUnauthorizedConnection()
        }
    }

    private func checkForUnauthorizedConnection() {
        guard let status = self.providerManager?.connection.status else { return }

        if (status == .connected || status == .connecting) && !self.appInitiatedConnection {
            print("OpenVPN: Unauthorized connection detected - Disconnecting")
            self.forceDisconnect()
        }
    }

    private func forceDisconnect() {
        self.isManualDisconnect = true
        self.shouldBeConnected = false
        self.appInitiatedConnection = false
        self.saveVPNState()
        self.cancelReconnectTimer()
        self.providerManager?.connection.stopVPNTunnel()
        self.stage?("disconnected")
    }

    func onVpnStatusChanged(notification: NEVPNStatus) {
        switch notification {
        case NEVPNStatus.connected:
            if !self.appInitiatedConnection {
                print("OpenVPN: Unauthorized connection blocked")
                self.forceDisconnect()
                return
            }
            stage?("connected")
            self.shouldBeConnected = true
            self.saveVPNState()
            self.cancelReconnectTimer()
            break
        case NEVPNStatus.connecting:
            if !self.appInitiatedConnection {
                print("OpenVPN: Unauthorized connecting blocked")
                self.forceDisconnect()
                return
            }
            stage?("connecting")
            break
        case NEVPNStatus.disconnected:
            stage?("disconnected")
            self.handleDisconnection()
            break
        case NEVPNStatus.disconnecting:
            stage?("disconnecting")
            break
        case NEVPNStatus.invalid:
            stage?("invalid")
            self.handleDisconnection()
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
        if self.appInitiatedConnection && self.shouldBeConnected && !self.isManualDisconnect {
            if self.autoReconnectEnabled {
                print("OpenVPN: Unauthorized disconnection - Auto-reconnecting")
                self.scheduleReconnect()
                return
            }
        }

        if self.autoReconnectEnabled && self.shouldBeConnected && !self.isManualDisconnect
            && self.lastConfig != nil
        {
            self.scheduleReconnect()
        } else if self.isManualDisconnect {
            self.isManualDisconnect = false
            self.shouldBeConnected = false
            self.appInitiatedConnection = false
            self.saveVPNState()
        }
    }

    private func scheduleReconnect() {
        self.cancelReconnectTimer()
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
            } else {
                print("OpenVPN: Auto-reconnect initiated")
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

        self.lastConfig = config
        self.lastUsername = username
        self.lastPassword = password
        self.appInitiatedConnection = true
        self.shouldBeConnected = true
        self.saveVPNState()

        // CRITICAL FIX: Always reload ALL managers first to get the latest state
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if error != nil {
                completion(error)
                return
            }

            // Find our manager again (it might have been updated)
            if let manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == self.providerBundleIdentifier
            }) {
                self.providerManager = manager
            } else if let manager = managers?.first {
                self.providerManager = manager
            }

            // Update the EXISTING protocol configuration
            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.serverAddress = self.localizedDescription ?? "VPN"
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

            // Save the updated configuration
            self.providerManager.saveToPreferences { saveError in
                if saveError != nil {
                    completion(saveError)
                    return
                }

                print("OpenVPN: Configuration saved, reloading manager...")

                // CRITICAL: Reload ALL managers again to ensure we have the absolute latest
                NETunnelProviderManager.loadAllFromPreferences { reloadedManagers, reloadError in
                    if reloadError != nil {
                        completion(reloadError)
                        return
                    }

                    // Get the fresh manager instance
                    if let freshManager = reloadedManagers?.first(where: {
                        ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                            .providerBundleIdentifier == self.providerBundleIdentifier
                    }) {
                        self.providerManager = freshManager
                        print("OpenVPN: Manager reloaded successfully")
                    } else {
                        completion(
                            NSError(
                                domain: "OpenVPN", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to reload manager"]))
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

                        print("OpenVPN: Starting VPN tunnel...")
                        if username != nil && password != nil {
                            let options: [String: NSObject] = [
                                "username": username! as NSString,
                                "password": password! as NSString,
                            ]
                            try self.providerManager.connection.startVPNTunnel(options: options)
                        } else {
                            try self.providerManager.connection.startVPNTunnel()
                        }
                        print("OpenVPN: VPN tunnel start command sent")
                        completion(nil)
                    } catch let error {
                        print("OpenVPN: Failed to start tunnel: \(error.localizedDescription)")
                        self.stopVPN()
                        completion(error)
                    }
                }
            }
        }
    }

    func stopVPN() {
        self.isManualDisconnect = true
        self.shouldBeConnected = false
        self.appInitiatedConnection = false
        self.saveVPNState()
        self.cancelReconnectTimer()
        self.providerManager.connection.stopVPNTunnel()
    }

    func getTraffictStats() {
        if let session = self.providerManager?.connection as? NETunnelProviderSession {
            do {
                try session.sendProviderMessage("OPENVPN_STATS".data(using: .utf8)!) { (data) in
                }
            } catch {
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
