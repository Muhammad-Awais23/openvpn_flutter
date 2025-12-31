import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'model/vpn_status.dart';

///Stages of vpn connections
enum VPNStage {
  prepare,
  authenticating,
  connecting,
  authentication,
  connected,
  disconnected,
  disconnecting,
  denied,
  error,
  wait_connection,
  vpn_generate_config,
  get_config,
  tcp_connect,
  udp_connect,
  assign_ip,
  resolve,
  exiting,
  unknown
}

class OpenVPN {
  ///Channel's names of _vpnStageSnapshot
  static const String _eventChannelVpnStage =
      "id.laskarmedia.openvpn_flutter/vpnstage";

  ///Channel's names of _channelControl
  static const String _methodChannelVpnControl =
      "id.laskarmedia.openvpn_flutter/vpncontrol";

  ///Method channel to invoke methods from native side
  static const MethodChannel _channelControl =
      MethodChannel(_methodChannelVpnControl);

  ///Snapshot of stream that produced by native side
  static Stream<String> _vpnStageSnapshot() =>
      const EventChannel(_eventChannelVpnStage).receiveBroadcastStream().cast();

  ///Timer to get vpnstatus as a loop
  Timer? _vpnStatusTimer;

  ///Timer for connection timeout
  Timer? _connectionTimeoutTimer;

  ///Connection timeout duration (default: 20 seconds)
  Duration _connectionTimeout = const Duration(seconds: 20);

  ///To indicate the engine already initialize
  bool initialized = false;

  ///Use tempDateTime to countdown, especially on android that has delays
  DateTime? _tempDateTime;

  VPNStage? _lastStage;

  /// Track if auto-reconnect is enabled
  bool _autoReconnectEnabled = false;

  /// is a listener to see vpn status detail
  final Function(VpnStatus? data)? onVpnStatusChanged;

  /// is a listener to see what stage the connection was
  final Function(VPNStage stage, String rawStage)? onVpnStageChanged;

  /// is a listener for auto-reconnect events
  final Function(String message)? onAutoReconnectEvent;

  /// is a listener for connection timeout events
  final Function()? onConnectionTimeout;

  /// OpenVPN's Constructions, don't forget to implement the listeners
  OpenVPN({
    this.onVpnStatusChanged,
    this.onVpnStageChanged,
    this.onAutoReconnectEvent,
    this.onConnectionTimeout,
  });

  /// Check if VPN permission is granted
  ///
  /// For iOS: Checks if VPN profile exists
  /// For Android: Checks if VpnService.prepare() returns null (meaning permission granted)
  ///
  /// Returns true if VPN permission is granted, false otherwise
  ///
  /// [providerBundleIdentifier] is required for iOS (Network Extension identifier)
  /// For Android, this parameter is ignored
  ///
  /// This should be called BEFORE initialize() to check if permission is already granted
  static Future<bool> checkVpnPermission({
    String? providerBundleIdentifier,
  }) async {
    if (Platform.isIOS) {
      if (providerBundleIdentifier == null) {
        throw ArgumentError('providerBundleIdentifier is required for iOS');
      }

      try {
        final result =
            await _channelControl.invokeMethod('checkVpnPermission', {
          'providerBundleIdentifier': providerBundleIdentifier,
        });
        return result as bool? ?? false;
      } on PlatformException catch (e) {
        print('Error checking VPN permission (iOS): ${e.message}');
        return false;
      }
    } else if (Platform.isAndroid) {
      try {
        final result = await _channelControl.invokeMethod('checkVpnPermission');
        return result as bool? ?? false;
      } on PlatformException catch (e) {
        print('Error checking VPN permission (Android): ${e.message}');
        return false;
      }
    }

    return false;
  }

  /// Request VPN permission
  ///
  /// For iOS: Creates a VPN profile if it doesn't exist and triggers the iOS permission dialog
  /// For Android: Shows the VPN permission dialog using VpnService.prepare()
  ///
  /// Returns true if permission granted/already exists, false otherwise
  ///
  /// [providerBundleIdentifier]: Required for iOS (Your Network Extension identifier)
  /// [localizedDescription]: Description shown in iOS Settings (default: "VPN")
  ///
  /// For Android, only the permission dialog is shown, no additional parameters needed
  ///
  /// This creates a VPN profile (iOS) or requests permission (Android) if not already granted
  /// Should be called BEFORE initialize() if permission is not yet granted
  static Future<bool> requestVpnPermission({
    String? providerBundleIdentifier,
    String localizedDescription = "VPN",
  }) async {
    if (Platform.isIOS) {
      if (providerBundleIdentifier == null) {
        throw ArgumentError('providerBundleIdentifier is required for iOS');
      }

      try {
        final result =
            await _channelControl.invokeMethod('requestVpnPermission', {
          'providerBundleIdentifier': providerBundleIdentifier,
          'localizedDescription': localizedDescription,
        });
        return result as bool? ?? false;
      } on PlatformException catch (e) {
        print('Error requesting VPN permission (iOS): ${e.message}');
        return false;
      }
    } else if (Platform.isAndroid) {
      try {
        final result =
            await _channelControl.invokeMethod('requestVpnPermission');
        return result as bool? ?? false;
      } on PlatformException catch (e) {
        print('Error requesting VPN permission (Android): ${e.message}');
        return false;
      }
    }

    return false;
  }

  ///This function should be called before any usage of OpenVPN
  ///All params required for iOS, make sure you read the plugin's documentation
  ///
  ///[providerBundleIdentifier] is for your Network Extension identifier (iOS only)
  ///
  ///[localizedDescription] is for description to show in user's settings (iOS only)
  ///
  ///[groupIdentifier] is for App Group identifier (iOS only)
  ///
  ///[autoReconnect] enables automatic reconnection when VPN is disconnected (iOS only)
  ///
  ///[connectionTimeout] is the duration to wait before timing out (default: 20 seconds)
  ///
  ///Will return latest VPNStage
  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    bool autoReconnect = false,
    Duration? connectionTimeout,
    Function(VpnStatus status)? lastStatus,
    Function(VPNStage stage)? lastStage,
  }) async {
    if (Platform.isIOS) {
      assert(
          groupIdentifier != null &&
              providerBundleIdentifier != null &&
              localizedDescription != null,
          "These values are required for iOS.");
    }

    _autoReconnectEnabled = autoReconnect;
    if (connectionTimeout != null) {
      _connectionTimeout = connectionTimeout;
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    initialized = true;
    _initializeListener();

    return _channelControl.invokeMethod("initialize", {
      "groupIdentifier": groupIdentifier,
      "providerBundleIdentifier": providerBundleIdentifier,
      "localizedDescription": localizedDescription,
      "autoReconnect": autoReconnect,
    }).then((value) {
      Future.wait([
        status().then((value) => lastStatus?.call(value)),
        stage().then((value) {
          if (value == VPNStage.connected && _vpnStatusTimer == null) {
            _createTimer();
          }
          return lastStage?.call(value);
        }),
      ]);
    });
  }

  /// Set auto-reconnect feature on/off at runtime
  /// Only works on iOS
  Future<void> setAutoReconnect({required bool enabled}) async {
    if (!initialized) throw ("OpenVPN need to be initialized");
    if (!Platform.isIOS) {
      onAutoReconnectEvent?.call("Auto-reconnect is only supported on iOS");
      return;
    }

    _autoReconnectEnabled = enabled;
    await _channelControl.invokeMethod("setAutoReconnect", {
      "enabled": enabled,
    });

    onAutoReconnectEvent
        ?.call(enabled ? "Auto-reconnect enabled" : "Auto-reconnect disabled");
  }

  /// Get current auto-reconnect status
  bool get autoReconnectEnabled => _autoReconnectEnabled;

  /// Set connection timeout duration
  void setConnectionTimeout(Duration timeout) {
    _connectionTimeout = timeout;
  }

  /// Get current connection timeout duration
  Duration get connectionTimeout => _connectionTimeout;

  ///Connect to VPN
  ///
  ///[config]: Your openvpn configuration script, you can find it inside your .ovpn file
  ///
  ///[name]: name that will show in user's notification
  ///
  ///[certIsRequired]: default is false, if your config file has cert, set it to true
  ///
  ///[username] & [password]: set your username and password if your config file has auth-user-pass
  ///
  ///[bypassPackages]: exclude some apps to access/use the VPN Connection (Android Only)
  Future connect(String config, String name,
      {String? username,
      String? password,
      List<String>? bypassPackages,
      bool certIsRequired = false}) {
    if (!initialized) throw ("OpenVPN need to be initialized");
    if (!certIsRequired) config += "client-cert-not-required";
    _tempDateTime = DateTime.now();

    try {
      return _channelControl.invokeMethod("connect", {
        "config": config,
        "name": name,
        "username": username,
        "password": password,
        "bypass_packages": bypassPackages ?? []
      });
    } on PlatformException catch (e) {
      throw ArgumentError(e.message);
    }
  }

  ///Disconnect from VPN
  void disconnect() {
    _tempDateTime = null;
    _cancelConnectionTimeout();
    _channelControl.invokeMethod("disconnect");
    if (_vpnStatusTimer?.isActive ?? false) {
      _vpnStatusTimer?.cancel();
      _vpnStatusTimer = null;
    }
  }

  ///Check if connected to vpn
  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  ///Get latest connection stage
  Future<VPNStage> stage() async {
    String? stage = await _channelControl.invokeMethod("stage");
    return _strToStage(stage ?? "disconnected");
  }

  ///Get latest connection status
  Future<VpnStatus> status() {
    return stage().then((value) async {
      var status = VpnStatus.empty();
      if (value == VPNStage.connected) {
        status = await _channelControl.invokeMethod("status").then((value) {
          if (value == null) return VpnStatus.empty();

          if (Platform.isIOS) {
            try {
              if (value == null || value.trim().isEmpty)
                return VpnStatus.empty();

              var splitted = value.split("_");

              while (splitted.length < 5) splitted.add("0");

              var connectedOn = DateTime.tryParse(splitted[0]) ??
                  _tempDateTime ??
                  DateTime.now();

              String packetsIn =
                  splitted[1].trim().isEmpty ? "0" : splitted[1].trim();
              String packetsOut =
                  splitted[2].trim().isEmpty ? "0" : splitted[2].trim();
              String byteIn =
                  splitted[3].trim().isEmpty ? "0" : splitted[3].trim();
              String byteOut =
                  splitted[4].trim().isEmpty ? "0" : splitted[4].trim();

              return VpnStatus(
                connectedOn: connectedOn,
                duration:
                    _duration(DateTime.now().difference(connectedOn).abs()),
                packetsIn: packetsIn,
                packetsOut: packetsOut,
                byteIn: byteIn,
                byteOut: byteOut,
              );
            } catch (_) {
              return VpnStatus.empty();
            }
          } else if (Platform.isAndroid) {
            var data = jsonDecode(value);
            var connectedOn =
                DateTime.tryParse(data["connected_on"].toString()) ??
                    _tempDateTime ??
                    DateTime.now();
            String byteIn =
                data["byte_in"] != null ? data["byte_in"].toString() : "0";
            String byteOut =
                data["byte_out"] != null ? data["byte_out"].toString() : "0";
            if (byteIn.trim().isEmpty) byteIn = "0";
            if (byteOut.trim().isEmpty) byteOut = "0";
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              byteIn: byteIn,
              byteOut: byteOut,
              packetsIn: byteIn,
              packetsOut: byteOut,
            );
          } else {
            throw Exception("Openvpn not supported on this platform");
          }
        });
      }
      return status;
    });
  }

  ///Request android permission (Return true if already granted)
  ///
  ///DEPRECATED: Use [checkVpnPermission] and [requestVpnPermission] instead
  @Deprecated('Use checkVpnPermission() and requestVpnPermission() instead')
  Future<bool> requestPermissionAndroid() async {
    return _channelControl
        .invokeMethod("request_permission")
        .then((value) => value ?? false);
  }

  ///Sometimes config script has too many Remotes, it cause ANR in several devices
  ///
  ///Use this function if you wanted to force user to use 1 remote by randomize the remotes
  static Future<String?> filteredConfig(String? config) async {
    List<String> remotes = [];
    List<String> output = [];
    if (config == null) return null;
    var raw = config.split("\n");

    for (var item in raw) {
      if (item.trim().toLowerCase().startsWith("remote ")) {
        if (!output.contains("REMOTE_HERE")) {
          output.add("REMOTE_HERE");
        }
        remotes.add(item);
      } else {
        output.add(item);
      }
    }
    String fastestServer = remotes[Random().nextInt(remotes.length - 1)];
    int indexRemote = output.indexWhere((element) => element == "REMOTE_HERE");
    output.removeWhere((element) => element == "REMOTE_HERE");
    output.insert(indexRemote, fastestServer);
    return output.join("\n");
  }

  /// Clean up resources when disposing
  void dispose() {
    _vpnStatusTimer?.cancel();
    _vpnStatusTimer = null;
    _cancelConnectionTimeout();
    if (initialized) {
      _channelControl.invokeMethod("dispose");
    }
    initialized = false;
  }

  Future<bool> startTimer(int durationSeconds, {bool isProUser = false}) async {
    try {
      if (!initialized) {
        throw Exception("OpenVPN needs to be initialized first");
      }

      print('startTimer called - Duration: $durationSeconds, Pro: $isProUser');

      // iOS handled by Network Extension
      if (Platform.isIOS) {
        return true;
      }

      // Android - call platform method
      if (Platform.isAndroid) {
        final bool? result = await _channelControl.invokeMethod('startTimer', {
          'duration_seconds': durationSeconds,
          'is_pro_user': isProUser,
        });

        return result ?? false;
      }

      return false;
    } catch (e) {
      print('Error in startTimer: $e');
      return false;
    }
  }

  ///Convert duration that produced by native side as Connection Time
  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  ///Private function to convert String to VPNStage
  static VPNStage _strToStage(String? stage) {
    if (stage == null ||
        stage.trim().isEmpty ||
        stage.trim() == "idle" ||
        stage.trim() == "invalid") {
      return VPNStage.disconnected;
    }
    var indexStage = VPNStage.values.indexWhere((element) => element
        .toString()
        .trim()
        .toLowerCase()
        .contains(stage.toString().trim().toLowerCase()));
    if (indexStage >= 0) return VPNStage.values[indexStage];
    return VPNStage.unknown;
  }

  ///Start connection timeout timer
  void _startConnectionTimeout() {
    _cancelConnectionTimeout();
    _connectionTimeoutTimer = Timer(_connectionTimeout, () {
      disconnect();
      onConnectionTimeout?.call();
    });
  }

  ///Cancel connection timeout timer
  void _cancelConnectionTimeout() {
    if (_connectionTimeoutTimer?.isActive ?? false) {
      _connectionTimeoutTimer?.cancel();
      _connectionTimeoutTimer = null;
    }
  }

  ///Initialize listener
  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      var vpnStage = _strToStage(event);
      if (vpnStage != _lastStage) {
        onVpnStageChanged?.call(vpnStage, event);
        _lastStage = vpnStage;

        if (vpnStage == VPNStage.connecting ||
            vpnStage == VPNStage.authenticating ||
            vpnStage == VPNStage.prepare ||
            vpnStage == VPNStage.wait_connection) {
          _startConnectionTimeout();
        } else if (vpnStage == VPNStage.connected) {
          _cancelConnectionTimeout();
        } else if (vpnStage == VPNStage.disconnected ||
            vpnStage == VPNStage.error ||
            vpnStage == VPNStage.denied) {
          _cancelConnectionTimeout();
        }

        if (Platform.isIOS && _autoReconnectEnabled) {
          if (vpnStage == VPNStage.connecting) {
            onAutoReconnectEvent?.call("Attempting to reconnect...");
          } else if (vpnStage == VPNStage.connected &&
              _lastStage == VPNStage.connecting) {
            onAutoReconnectEvent?.call("Auto-reconnect successful");
          }
        }
      }

      if (vpnStage != VPNStage.disconnected) {
        if (Platform.isAndroid) {
          _createTimer();
        } else if (Platform.isIOS && vpnStage == VPNStage.connected) {
          _createTimer();
        }
      } else {
        _vpnStatusTimer?.cancel();
      }
    });
  }

  ///Create timer to invoke status
  void _createTimer() {
    if (_vpnStatusTimer != null) {
      _vpnStatusTimer!.cancel();
      _vpnStatusTimer = null;
    }
    _vpnStatusTimer ??=
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      onVpnStatusChanged?.call(await status());
    });
  }
}
