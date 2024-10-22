import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'model/vpn_status.dart';

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
  static const String _eventChannelVpnStage =
      "id.laskarmedia.openvpn_flutter/vpnstage";
  static const String _methodChannelVpnControl =
      "id.laskarmedia.openvpn_flutter/vpncontrol";
  static const MethodChannel _channelControl =
      MethodChannel(_methodChannelVpnControl);
  static Stream<String> _vpnStageSnapshot() =>
      const EventChannel(_eventChannelVpnStage).receiveBroadcastStream().cast();

  Timer? _vpnStatusTimer;
  Timer? _autoDisconnectTimer;

  bool initialized = false;
  DateTime? _tempDateTime;
  VPNStage? _lastStage;

  final Function(VpnStatus? data)? onVpnStatusChanged;
  final Function(VPNStage stage, String rawStage)? onVpnStageChanged;

  OpenVPN({this.onVpnStatusChanged, this.onVpnStageChanged});

  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    Function(VpnStatus status)? lastStatus,
    Function(VPNStage stage)? lastStage,
  }) async {
    if (Platform.isIOS) {
      assert(
          groupIdentifier != null &&
              providerBundleIdentifier != null &&
              localizedDescription != null,
          "These values are required for ios.");
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    initialized = true;
    _initializeListener();
    return _channelControl.invokeMethod("initialize", {
      "groupIdentifier": groupIdentifier,
      "providerBundleIdentifier": providerBundleIdentifier,
      "localizedDescription": localizedDescription,
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

  Future connect(String config, String name,
      {String? username,
      String? password,
      List<String>? bypassPackages,
      bool certIsRequired = false,
      int? autoDisconnectMinutes}) {
    if (!initialized) throw ("OpenVPN need to be initialized");
    if (!certIsRequired) config += "client-cert-not-required";
    _tempDateTime = DateTime.now();

    // Set auto-disconnect timer if provided
    if (autoDisconnectMinutes != null && autoDisconnectMinutes > 0) {
      _setAutoDisconnectTimer(autoDisconnectMinutes);
    }

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

  void disconnect() {
    _tempDateTime = null;
    _channelControl.invokeMethod("disconnect");
    _cancelTimers();
  }

  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  Future<VPNStage> stage() async {
    String? stage = await _channelControl.invokeMethod("stage");
    return _strToStage(stage ?? "disconnected");
  }

  Future<VpnStatus> status() {
    return stage().then((value) async {
      var status = VpnStatus.empty();
      if (value == VPNStage.connected) {
        status = await _channelControl.invokeMethod("status").then((value) {
          if (value == null) return VpnStatus.empty();

          if (Platform.isIOS) {
            var splitted = value.split("_");
            var connectedOn = DateTime.tryParse(splitted[0]);
            if (connectedOn == null) return VpnStatus.empty();
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              packetsIn: splitted[1],
              packetsOut: splitted[2],
              byteIn: splitted[3],
              byteOut: splitted[4],
            );
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

  Future<bool> requestPermissionAndroid() async {
    return _channelControl
        .invokeMethod("request_permission")
        .then((value) => value ?? false);
  }

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

  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

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

  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      var vpnStage = _strToStage(event);
      if (vpnStage != _lastStage) {
        onVpnStageChanged?.call(vpnStage, event);
        _lastStage = vpnStage;
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

  void _setAutoDisconnectTimer(int minutes) {
    _autoDisconnectTimer?.cancel(); // Cancel any existing timer
    _autoDisconnectTimer = Timer(Duration(minutes: minutes), () {
      disconnect(); // Auto-disconnect after the specified time
    });
  }

  void _cancelTimers() {
    _vpnStatusTimer?.cancel();
    _vpnStatusTimer = null;
    _autoDisconnectTimer?.cancel();
    _autoDisconnectTimer = null;
  }
}
