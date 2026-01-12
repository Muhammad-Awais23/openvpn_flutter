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
  Duration _connectionTimeout = const Duration(seconds: 45);

  ///To indicate the engine already initialize
  bool initialized = false;

  ///Use tempDateTime to countdown, especially on android that has delays
  DateTime? _tempDateTime;

  VPNStage? _lastStage;

  /// Track if auto-reconnect is enabled
  bool _autoReconnectEnabled = false;

  /// Track when connection attempt started (to prevent timeout reset on reconnect)
  DateTime? _connectionAttemptStartTime;

  /// Track if we're in a connection attempt (connecting or reconnecting)
  bool _isConnectionAttempt = false;

  /// Track number of reconnect attempts
  int _reconnectAttempts = 0;

  /// Maximum reconnect attempts before giving up
  int _maxReconnectAttempts = 5;

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

  ///Initialize OpenVPN
  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    bool autoReconnect = false,
    Duration? connectionTimeout,
    int maxReconnectAttempts = 5,
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
    _maxReconnectAttempts = maxReconnectAttempts;
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
  Future connect(
    String config,
    String name, {
    String? username,
    String? password,
    List<String>? bypassPackages,
    required int allowedSeconds,
    required bool isProUser,
    bool certIsRequired = false,
  }) {
    if (!initialized) throw ("OpenVPN need to be initialized");

    if (!certIsRequired) {
      config += "client-cert-not-required";
    }

    _tempDateTime = DateTime.now();
    _reconnectAttempts = 0; // Reset reconnect attempts on new connection
    _startConnectionAttempt(); // Start tracking connection attempt

    return _channelControl.invokeMethod("connect", {
      "config": config,
      "name": name,
      "username": username,
      "password": password,
      "bypass_packages": bypassPackages ?? [],
      "allowed_seconds": allowedSeconds,
      "is_pro_user": isProUser,
    });
  }

  ///Disconnect from VPN
  void disconnect() {
    _tempDateTime = null;
    _endConnectionAttempt(); // Clear connection attempt tracking
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
  @Deprecated('Use checkVpnPermission() and requestVpnPermission() instead')
  Future<bool> requestPermissionAndroid() async {
    return _channelControl
        .invokeMethod("request_permission")
        .then((value) => value ?? false);
  }

  ///Filter config to use single random remote
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
    _endConnectionAttempt();
    if (initialized) {
      _channelControl.invokeMethod("dispose");
    }
    initialized = false;
  }

  ///Convert duration to readable format
  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  ///Convert String to VPNStage
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

  /// Start tracking a connection attempt
  void _startConnectionAttempt() {
    if (!_isConnectionAttempt) {
      _connectionAttemptStartTime = DateTime.now();
      _isConnectionAttempt = true;
      print('🔵 Connection attempt started at ${_connectionAttemptStartTime}');
    }
    _startOrCheckConnectionTimeout();
  }

  /// End connection attempt tracking
  void _endConnectionAttempt() {
    _isConnectionAttempt = false;
    _connectionAttemptStartTime = null;
    _reconnectAttempts = 0;
    _cancelConnectionTimeout();
    print('🔴 Connection attempt ended');
  }

  /// Start or check connection timeout based on total elapsed time
  void _startOrCheckConnectionTimeout() {
    // Cancel any existing timer
    _connectionTimeoutTimer?.cancel();

    if (!_isConnectionAttempt || _connectionAttemptStartTime == null) {
      return;
    }

    // Calculate how much time has elapsed since the first connection attempt
    final elapsedTime = DateTime.now().difference(_connectionAttemptStartTime!);
    final remainingTime = _connectionTimeout - elapsedTime;

    print(
        '⏱️ Timeout check - Elapsed: ${elapsedTime.inSeconds}s, Remaining: ${remainingTime.inSeconds}s, Attempts: $_reconnectAttempts/$_maxReconnectAttempts');

    // FIXED: Check timeout OR attempts, but give servers enough time
    if (remainingTime <= Duration.zero) {
      print('❌ Connection timeout reached after ${elapsedTime.inSeconds}s!');
      _handleConnectionTimeout();
      return;
    }

    // FIXED: Separate check for max attempts (only for reconnects)
    if (_reconnectAttempts >= _maxReconnectAttempts && _reconnectAttempts > 0) {
      print('❌ Max reconnect attempts ($_reconnectAttempts) reached!');
      _handleConnectionTimeout();
      return;
    }

    // Set timer for remaining time
    _connectionTimeoutTimer = Timer(remainingTime, () {
      print(
          '❌ Connection timeout triggered after ${_connectionTimeout.inSeconds}s!');
      _handleConnectionTimeout();
    });
  }

  /// Handle connection timeout
  void _handleConnectionTimeout() {
    print('🚫 Handling connection timeout - disconnecting...');
    _endConnectionAttempt();
    disconnect();
    onConnectionTimeout?.call();
    onAutoReconnectEvent?.call(
        "Connection timeout - giving up after $_reconnectAttempts attempts");
  }

  ///Cancel connection timeout timer
  void _cancelConnectionTimeout() {
    if (_connectionTimeoutTimer?.isActive ?? false) {
      _connectionTimeoutTimer?.cancel();
      _connectionTimeoutTimer = null;
      print('⏹️ Connection timeout cancelled');
    }
  }

  bool _isConnectingStage(VPNStage stage) {
    return stage == VPNStage.connecting ||
        stage == VPNStage.authenticating ||
        stage == VPNStage.prepare ||
        stage == VPNStage.wait_connection ||
        stage == VPNStage.authentication ||
        stage == VPNStage.tcp_connect ||
        stage == VPNStage.udp_connect ||
        stage == VPNStage.assign_ip ||
        stage == VPNStage.resolve ||
        stage == VPNStage.vpn_generate_config ||
        stage == VPNStage.get_config;
  }

  ///Initialize listener
  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      final vpnStage = _strToStage(event);
      final previousStage = _lastStage;

      if (vpnStage != previousStage) {
        _lastStage = vpnStage;
        onVpnStageChanged?.call(vpnStage, event);

        print(
            '📡 Stage changed: $previousStage → $vpnStage (raw: $event, isConnectionAttempt: $_isConnectionAttempt)');

        // Handle stage transitions
        if (_isConnectingStage(vpnStage)) {
          // We're in a connecting stage

          // If we're transitioning FROM disconnected, this is a (re)connect attempt
          if (_isConnectionAttempt && previousStage == VPNStage.disconnected) {
            _reconnectAttempts++;
            print('🔄 Reconnect attempt #$_reconnectAttempts');
            onAutoReconnectEvent?.call(
                "Reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts");
          }

          // Check timeout with accumulated time
          _startOrCheckConnectionTimeout();
        } else if (vpnStage == VPNStage.connected) {
          // Success! End the connection attempt
          if (_connectionAttemptStartTime != null) {
            final totalTime =
                DateTime.now().difference(_connectionAttemptStartTime!);
            print(
                '✅ Connected successfully after ${totalTime.inSeconds}s and $_reconnectAttempts reconnect attempts');
          }
          _endConnectionAttempt();

          if (Platform.isIOS &&
              _autoReconnectEnabled &&
              _reconnectAttempts > 0) {
            onAutoReconnectEvent?.call(
                "Auto-reconnect successful after $_reconnectAttempts attempts");
          }
        } else if (vpnStage == VPNStage.disconnected) {
          if (_isConnectionAttempt) {
            // We're in a connection attempt and got disconnected
            // This could be:
            // 1. Auto-reconnect scenario (iOS) - handled by iOS native code
            // 2. Connection failed - will timeout or retry
            print('⚠️ Disconnected during connection attempt');

            // Don't immediately end connection attempt - let timeout or iOS auto-reconnect handle it
            // Only end if we're not expecting auto-reconnect
            if (!_autoReconnectEnabled || !Platform.isIOS) {
              _endConnectionAttempt();
            }
          } else {
            // Clean disconnection (not during connection attempt)
            _endConnectionAttempt();
          }
        } else if (vpnStage == VPNStage.error || vpnStage == VPNStage.denied) {
          // Error states - end connection attempt immediately
          print('⚠️ Error state reached: $vpnStage');
          _endConnectionAttempt();
        } else if (vpnStage == VPNStage.exiting) {
          // Exiting state
          print('🚪 VPN exiting');
        } else if (vpnStage == VPNStage.unknown) {
          // Unknown state - log but don't kill connection attempt immediately
          print('❓ Unknown VPN stage from event: $event');
        }
      }

      // Manage status timer
      if (vpnStage == VPNStage.connected ||
          (Platform.isAndroid && vpnStage != VPNStage.disconnected)) {
        _createTimer();
      } else {
        _vpnStatusTimer?.cancel();
        _vpnStatusTimer = null;
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
