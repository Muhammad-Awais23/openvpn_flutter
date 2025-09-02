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

                SwiftOpenVPNFlutterPlugin.utils.configureOnDemandVPN(
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
    var providerManager: NETunnelProviderManager?
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var groupIdentifier: String?
    var stage: FlutterEventSink?
    var vpnStageObserver: NSObjectProtocol?
    var autoReconnectEnabled: Bool = false

    // Track VPN state for auto-reconnect logic
    private var shouldBeConnected: Bool = false
    private var lastConfig: String?
    private var lastUsername: String?
    private var lastPassword: String?
    private var isManualDisconnect: Bool = false
    private var reconnectTimer: Timer?

    // App lifecycle monitoring
    private var appStateObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        // Check if app was previously killed and restore state
        self.checkForKilledAppRecovery()

        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error == nil {
                self.providerManager = managers?.first
                self.startAppLifecycleMonitoring()
                completion(nil)
            } else {
                completion(error)
            }
        }
    }

    private func checkForKilledAppRecovery() {
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        let wasKilled = userDefaults?.bool(forKey: "app_was_killed") ?? false
        let wasConnected = userDefaults?.bool(forKey: "vpn_was_connected_before_kill") ?? false

        if wasKilled {
            print("App was killed and is now restarting")

            // Clear kill flags
            userDefaults?.set(false, forKey: "app_was_killed")

            if wasConnected && self.lastConfig != nil {
                print("Will restore VPN connection after restart")
                // The actual restoration will happen when user calls connect
            }
        }
    }

    private func startAppLifecycleMonitoring() {
        // Remove existing observers
        self.removeLifecycleObservers()

        // Monitor app termination
        appStateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppTermination()
        }

        // Monitor app going to background
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Schedule potential removal in case of force kill
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                self?.handlePotentialAppKill()
            }
        }

        // Monitor app returning to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppReturningToForeground()
        }
    }

    private func removeLifecycleObservers() {
        if let observer = appStateObserver {
            NotificationCenter.default.removeObserver(observer)
            appStateObserver = nil
        }
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    private func handleAppTermination() {
        print("App terminating - saving state and removing VPN configuration")

        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        userDefaults?.set(self.shouldBeConnected, forKey: "vpn_was_connected_before_kill")
        userDefaults?.set(true, forKey: "app_was_killed")
        userDefaults?.synchronize()

        self.removeVPNConfiguration()
    }

    private func handlePotentialAppKill() {
        // This runs if app stays in background for 30 seconds (potential force kill)
        print("App may have been force killed - removing VPN configuration")

        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        userDefaults?.set(self.shouldBeConnected, forKey: "vpn_was_connected_before_kill")
        userDefaults?.set(true, forKey: "app_was_killed")
        userDefaults?.synchronize()

        self.removeVPNConfiguration()
    }

    private func handleAppReturningToForeground() {
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        let wasKilled = userDefaults?.bool(forKey: "app_was_killed") ?? false

        if wasKilled {
            print("App returning from killed state")
            userDefaults?.set(false, forKey: "app_was_killed")
            userDefaults?.synchronize()

            // VPN configuration will be recreated when user tries to connect
        }
    }

    private func removeVPNConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            guard let managers = managers, !managers.isEmpty else { return }

            print("Removing \(managers.count) VPN configuration(s)")

            for manager in managers {
                manager.removeFromPreferences { error in
                    if error == nil {
                        print("VPN configuration removed successfully")
                    } else {
                        print(
                            "Failed to remove VPN configuration: \(error?.localizedDescription ?? "Unknown")"
                        )
                    }
                }
            }
        }
    }

    func onVpnStatusChanged(notification: NEVPNStatus) {
        switch notification {
        case NEVPNStatus.connected:
            stage?("connected")
            self.shouldBeConnected = true
            self.saveVPNState()
            self.cancelReconnectTimer()
            break
        case NEVPNStatus.connecting:
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
        if self.autoReconnectEnabled && self.shouldBeConnected && !self.isManualDisconnect
            && self.lastConfig != nil
        {
            self.scheduleReconnect()
        } else if self.isManualDisconnect {
            self.isManualDisconnect = false
            self.shouldBeConnected = false
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
        print("Attempting auto-reconnect...")

        self.configureOnDemandVPN(
            config: config,
            username: self.lastUsername,
            password: self.lastPassword
        ) { error in
            if let error = error {
                print("Auto-reconnect failed: \(error.localizedDescription)")
            } else {
                print("Auto-reconnect initiated successfully")
            }
        }
    }

    private func cancelReconnectTimer() {
        self.reconnectTimer?.invalidate()
        self.reconnectTimer = nil
    }

    private func saveVPNState() {
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        userDefaults?.set(self.shouldBeConnected, forKey: "vpn_should_be_connected")
        userDefaults?.set(self.autoReconnectEnabled, forKey: "auto_reconnect_enabled")
        userDefaults?.synchronize()
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
            return onVpnStatusChangedString(notification: self.providerManager?.connection.status)
        } else {
            return "disconnected"
        }
    }

    func configureOnDemandVPN(
        config: String?,
        username: String?,
        password: String?,
        completion: @escaping (_ error: Error?) -> Void = { _ in }
    ) {
        // Store connection details
        self.lastConfig = config
        self.lastUsername = username
        self.lastPassword = password
        self.shouldBeConnected = true
        self.isManualDisconnect = false

        // Clear any kill flags since app is active
        let userDefaults = UserDefaults(suiteName: self.groupIdentifier)
        userDefaults?.set(false, forKey: "app_was_killed")
        userDefaults?.removeObject(forKey: "vpn_was_connected_before_kill")
        self.saveVPNState()

        // Create a fresh manager instance
        let manager = NETunnelProviderManager()

        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.serverAddress = ""
        tunnelProtocol.providerBundleIdentifier = self.providerBundleIdentifier

        let nullData = "".data(using: .utf8)
        tunnelProtocol.providerConfiguration = [
            "config": config?.data(using: .utf8) ?? nullData!,
            "groupIdentifier": self.groupIdentifier?.data(using: .utf8) ?? nullData!,
            "username": username?.data(using: .utf8) ?? nullData!,
            "password": password?.data(using: .utf8) ?? nullData!,
        ]

        tunnelProtocol.disconnectOnSleep = false
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = self.localizedDescription
        manager.isEnabled = true

        // Configure On-Demand rules
        let onDemandRule = NEOnDemandRuleConnect()
        onDemandRule.interfaceTypeMatch = .any
        manager.onDemandRules = [onDemandRule]
        manager.isOnDemandEnabled = true

        manager.saveToPreferences { [weak self] error in
            if error == nil {
                self?.providerManager = manager

                manager.loadFromPreferences { error in
                    if error != nil {
                        completion(error)
                        return
                    }

                    do {
                        // Remove existing observer
                        if let observer = self?.vpnStageObserver {
                            NotificationCenter.default.removeObserver(
                                observer,
                                name: NSNotification.Name.NEVPNStatusDidChange,
                                object: nil)
                        }

                        // Add new observer
                        self?.vpnStageObserver = NotificationCenter.default.addObserver(
                            forName: NSNotification.Name.NEVPNStatusDidChange,
                            object: nil,
                            queue: nil
                        ) { [weak self] notification in
                            let nevpnconn = notification.object as! NEVPNConnection
                            let status = nevpnconn.status
                            self?.onVpnStatusChanged(notification: status)
                        }

                        // Start VPN tunnel
                        if username != nil && password != nil {
                            let options: [String: NSObject] = [
                                "username": username! as NSString,
                                "password": password! as NSString,
                            ]
                            try manager.connection.startVPNTunnel(options: options)
                        } else {
                            try manager.connection.startVPNTunnel()
                        }

                        completion(nil)
                    } catch let error {
                        self?.stopVPN()
                        print("Error info: \(error)")
                        completion(error)
                    }
                }
            } else {
                completion(error)
            }
        }
    }

    func stopVPN() {
        self.isManualDisconnect = true
        self.shouldBeConnected = false
        self.saveVPNState()
        self.cancelReconnectTimer()

        // Disable on-demand and remove configuration
        self.providerManager?.isOnDemandEnabled = false
        self.providerManager?.saveToPreferences { [weak self] error in
            if error == nil {
                self?.providerManager?.connection.stopVPNTunnel()
                // After stopping, remove the configuration entirely
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.removeVPNConfiguration()
                }
            } else {
                print("Error disabling on-demand: \(error?.localizedDescription ?? "Unknown")")
                self?.providerManager?.connection.stopVPNTunnel()
            }
        }
    }

    func getTraffictStats() {
        if let session = self.providerManager?.connection as? NETunnelProviderSession {
            do {
                try session.sendProviderMessage("OPENVPN_STATS".data(using: .utf8)!) { (data) in
                    // Do nothing
                }
            } catch {
                // Handle error silently
            }
        }
    }

    func dispose() {
        self.cancelReconnectTimer()
        self.removeLifecycleObservers()

        if let observer = self.vpnStageObserver {
            NotificationCenter.default.removeObserver(
                observer,
                name: NSNotification.Name.NEVPNStatusDidChange,
                object: nil)
            self.vpnStageObserver = nil
        }

        // Mark as manual disconnect and save state
        self.shouldBeConnected = false
        self.saveVPNState()

        // Remove VPN configuration when disposing
        self.removeVPNConfiguration()
    }
}
