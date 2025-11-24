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

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error == nil {
                // CRITICAL FIX: Always use the FIRST EXISTING manager, never create new ones
                if let managers = managers, !managers.isEmpty {
                    // Use the first manager regardless of bundle identifier
                    self.providerManager = managers[0]
                    print("OpenVPN: Reusing existing VPN profile")
                    
                    // Update its configuration to match our requirements
                    if let proto = self.providerManager.protocolConfiguration as? NETunnelProviderProtocol {
                        proto.providerBundleIdentifier = self.providerBundleIdentifier
                        proto.serverAddress = "127.0.0.1"
                    } else {
                        // Create protocol if it doesn't exist
                        let proto = NETunnelProviderProtocol()
                        proto.providerBundleIdentifier = self.providerBundleIdentifier
                        proto.serverAddress = "127.0.0.1"
                        self.providerManager.protocolConfiguration = proto
                    }
                    
                    self.providerManager.localizedDescription = self.localizedDescription
                    self.providerManager.isEnabled = true
                    
                    // Save updated configuration
                    self.providerManager.saveToPreferences { saveError in
                        if let saveError = saveError {
                            print("OpenVPN: Error updating profile: \(saveError.localizedDescription)")
                        } else {
                            print("OpenVPN: Successfully updated existing profile")
                        }
                    }
                } else {
                    // ONLY create new manager if NO managers exist at all
                    print("OpenVPN: No existing profile found, creating new one")
                    let newManager = NETunnelProviderManager()
                    let proto = NETunnelProviderProtocol()
                    proto.providerBundleIdentifier = self.providerBundleIdentifier
                    proto.serverAddress = "127.0.0.1"
                    newManager.protocolConfiguration = proto
                    newManager.localizedDescription = self.localizedDescription
                    newManager.isEnabled = true
                    
                    self.providerManager = newManager
                }
                
                self.checkInitialVPNState()
                self.startConnectionMonitoring()
                completion(nil)
            } else {
                completion(error)
            }
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

        self.providerManager?.loadFromPreferences { error in
            if error == nil {
                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.serverAddress = "127.0.0.1"
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