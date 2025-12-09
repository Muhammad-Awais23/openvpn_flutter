package id.laskarmedia.openvpn_flutter;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;

import androidx.annotation.NonNull;

import java.util.ArrayList;

import de.blinkt.openvpn.OnVPNStatusChangeListener;
import de.blinkt.openvpn.VPNHelper;
import de.blinkt.openvpn.core.OpenVPNService;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * OpenvpnFlutterPlugin
 */
public class OpenVPNFlutterPlugin implements FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {

    private MethodChannel vpnControlMethod;
    private EventChannel vpnStageEvent;
    private EventChannel.EventSink vpnStageSink;

    private static final String EVENT_CHANNEL_VPN_STAGE = "id.laskarmedia.openvpn_flutter/vpnstage";
    private static final String METHOD_CHANNEL_VPN_CONTROL = "id.laskarmedia.openvpn_flutter/vpncontrol";

    private static final int VPN_PERMISSION_REQUEST_CODE = 24;
    private static final int VPN_CHECK_PERMISSION_REQUEST_CODE = 25;

    private static String config = "", username = "", password = "", name = "";
    private static ArrayList<String> bypassPackages;
    
    @SuppressLint("StaticFieldLeak")
    private static VPNHelper vpnHelper;
    private Activity activity;
    private ActivityPluginBinding activityBinding;
    private Context mContext;

    // Callbacks for permission requests
    private MethodChannel.Result pendingPermissionResult;
    private boolean isCheckingPermission = false;

    public static void connectWhileGranted(boolean granted) {
        if (granted) {
            vpnHelper.startVPN(config, username, password, name, bypassPackages);
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        vpnStageEvent = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL_VPN_STAGE);
        vpnControlMethod = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_VPN_CONTROL);

        vpnStageEvent.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                vpnStageSink = events;
            }

            @Override
            public void onCancel(Object arguments) {
                if (vpnStageSink != null) vpnStageSink.endOfStream();
            }
        });

        vpnControlMethod.setMethodCallHandler((call, result) -> {

            switch (call.method) {
                case "status":
                    if (vpnHelper == null) {
                        result.error("-1", "VPNEngine need to be initialize", "");
                        return;
                    }
                    result.success(vpnHelper.status.toString());
                    break;

                case "initialize":
                    vpnHelper = new VPNHelper(activity);
                    vpnHelper.setOnVPNStatusChangeListener(new OnVPNStatusChangeListener() {
                        @Override
                        public void onVPNStatusChanged(String status) {
                            updateStage(status);
                        }

                        @Override
                        public void onConnectionStatusChanged(String duration, String lastPacketReceive, String byteIn, String byteOut) {
                        }
                    });
                    result.success(updateVPNStages());
                    break;

                case "disconnect":
                    if (vpnHelper == null)
                        result.error("-1", "VPNEngine need to be initialize", "");

                    vpnHelper.stopVPN();
                    updateStage("disconnected");
                    break;

                case "connect":
                    if (vpnHelper == null) {
                        result.error("-1", "VPNEngine need to be initialize", "");
                        return;
                    }

                    config = call.argument("config");
                    name = call.argument("name");
                    username = call.argument("username");
                    password = call.argument("password");
                    bypassPackages = call.argument("bypass_packages");

                    if (config == null) {
                        result.error("-2", "OpenVPN Config is required", "");
                        return;
                    }

                    final Intent permission = VpnService.prepare(activity);
                    if (permission != null) {
                        activity.startActivityForResult(permission, VPN_PERMISSION_REQUEST_CODE);
                        return;
                    }
                    vpnHelper.startVPN(config, username, password, name, bypassPackages);
                    break;

                case "stage":
                    if (vpnHelper == null) {
                        result.error("-1", "VPNEngine need to be initialize", "");
                        return;
                    }
                    result.success(updateVPNStages());
                    break;

                case "request_permission":
                    final Intent request = VpnService.prepare(activity);
                    if (request != null) {
                        activity.startActivityForResult(request, VPN_PERMISSION_REQUEST_CODE);
                        result.success(false);
                        return;
                    }
                    result.success(true);
                    break;

                case "checkVpnPermission":
                    // Android mein VPN permission check karna
                    checkVpnPermission(result);
                    break;

                case "requestVpnPermission":
                    // Android mein VPN permission request karna
                    requestVpnPermission(result);
                    break;

                case "dispose":
                    if (vpnHelper != null) {
                        vpnHelper.stopVPN();
                    }
                    result.success(null);
                    break;

                default:
                    result.notImplemented();
                    break;
            }
        });
        mContext = binding.getApplicationContext();
    }

    /**
     * Check if VPN permission is already granted
     */
    private void checkVpnPermission(MethodChannel.Result result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is not available", null);
            return;
        }

        try {
            Intent intent = VpnService.prepare(activity);
            // Agar intent null hai, matlab permission already granted hai
            boolean isGranted = (intent == null);
            result.success(isGranted);
        } catch (Exception e) {
            result.error("CHECK_ERROR", "Error checking VPN permission: " + e.getMessage(), null);
        }
    }

    /**
     * Request VPN permission from user
     */
    private void requestVpnPermission(MethodChannel.Result result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is not available", null);
            return;
        }

        try {
            Intent intent = VpnService.prepare(activity);
            
            if (intent == null) {
                // Permission already granted
                result.success(true);
                return;
            }

            // Permission chahiye, dialog show karenge
            pendingPermissionResult = result;
            isCheckingPermission = true;
            activity.startActivityForResult(intent, VPN_CHECK_PERMISSION_REQUEST_CODE);
            
        } catch (Exception e) {
            result.error("REQUEST_ERROR", "Error requesting VPN permission: " + e.getMessage(), null);
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == VPN_CHECK_PERMISSION_REQUEST_CODE && isCheckingPermission) {
            isCheckingPermission = false;
            
            if (pendingPermissionResult != null) {
                boolean granted = (resultCode == Activity.RESULT_OK);
                pendingPermissionResult.success(granted);
                pendingPermissionResult = null;
            }
            return true;
        }
        
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                connectWhileGranted(true);
            }
            return true;
        }
        
        return false;
    }

    public void updateStage(String stage) {
        if (stage == null) stage = "idle";
        if (vpnStageSink != null) vpnStageSink.success(stage.toLowerCase());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        vpnStageEvent.setStreamHandler(null);
        vpnControlMethod.setMethodCallHandler(null);
    }

    private String updateVPNStages() {
        if (OpenVPNService.getStatus() == null) {
            OpenVPNService.setDefaultStatus();
        }
        updateStage(OpenVPNService.getStatus());
        return OpenVPNService.getStatus();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
        }
        activity = null;
        activityBinding = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
        }
        activity = null;
        activityBinding = null;
    }
}