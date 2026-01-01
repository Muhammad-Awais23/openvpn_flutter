package id.laskarmedia.openvpn_flutter;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.os.Build;
import android.util.Log;

import androidx.annotation.NonNull;

import java.util.ArrayList;

import de.blinkt.openvpn.OnVPNStatusChangeListener;
import de.blinkt.openvpn.VPNHelper;
import de.blinkt.openvpn.core.OpenVPNService;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * OpenvpnFlutterPlugin
 */
public class OpenVPNFlutterPlugin implements FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {

    private static final String TAG = "OpenVPNFlutter";
    
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
    private static MethodChannel.Result pendingPermissionResult;
    private boolean isCheckingPermission = false;

  public static void connectWhileGranted(boolean granted) {
    if (granted) {
        // START TIMER MONITORING IMMEDIATELY after VPN starts
        Log.d(TAG, "connectWhileGranted - Starting VPN and timer monitoring");
        vpnHelper.startVPN(config, username, password, name, bypassPackages);
        
        // Trigger timer monitoring in OpenVPNService
        try {
            SharedPreferences prefs = vpnHelper.activity.getSharedPreferences("vpn_timer_prefs", Context.MODE_PRIVATE);
            int allowedSeconds = prefs.getInt("allowed_seconds", -1);
            boolean isProUser = prefs.getBoolean("is_pro_user", false);
            
            Intent timerIntent = new Intent(vpnHelper.activity, OpenVPNService.class);
            timerIntent.setAction("START_TIMER_MONITORING");
            timerIntent.putExtra("duration_seconds", allowedSeconds);
            timerIntent.putExtra("is_pro_user", isProUser);
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vpnHelper.activity.startForegroundService(timerIntent);
            } else {
                vpnHelper.activity.startService(timerIntent);
            }
            Log.d(TAG, "Timer service started from connectWhileGranted");
        } catch (Exception e) {
            Log.e(TAG, "Error starting timer from connectWhileGranted: " + e.getMessage());
        }
    } 
    // else {
    //     if (pendingPermissionResult != null) {
    //         pendingPermissionResult.error("PERMISSION_DENIED", "VPN permission denied", null);
    //         pendingPermissionResult = null;
    //     }
    // }
}
private void updateVpnTimer(MethodChannel.Result result, MethodCall call) {
    Log.d(TAG, "updateVpnTimer called");
    
    if (activity == null) {
        result.error("NO_ACTIVITY", "Activity is not available", null);
        return;
    }

    try {
        // Get new duration from Flutter
        Integer newDurationSeconds = call.argument("duration_seconds");
        Boolean isProUser = call.argument("is_pro_user");
        
        if (newDurationSeconds == null) {
            newDurationSeconds = -1;
        }
        if (isProUser == null) {
            isProUser = false;
        }

        Log.d(TAG, "Updating timer: duration=" + newDurationSeconds + 
              " seconds, isProUser=" + isProUser);

        // Save to shared preferences
        SharedPreferences prefs = activity.getSharedPreferences("VPNTimerPrefs", Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();
        
        if (isProUser) {
            // Pro user - unlimited time
            editor.putInt("allowed_duration_seconds", -1);
            editor.putBoolean("is_pro_user", true);
            Log.d(TAG, "Updated to Pro user - unlimited time");
        } else {
            // Regular user - update with new duration
            // IMPORTANT: Reset start time to NOW when adding time
            long currentTime = System.currentTimeMillis();
            editor.putInt("allowed_duration_seconds", newDurationSeconds);
            editor.putLong("connection_start_time", currentTime);
            editor.putBoolean("is_pro_user", false);
            Log.d(TAG, "Updated timer: " + newDurationSeconds + " seconds from now");
        }
        
        editor.apply();

        // Send broadcast to OpenVPNService to update its timer
        Intent updateIntent = new Intent(activity, OpenVPNService.class);
        updateIntent.setAction("UPDATE_TIMER");
        updateIntent.putExtra("duration_seconds", newDurationSeconds);
        updateIntent.putExtra("is_pro_user", isProUser);
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(updateIntent);
        } else {
            activity.startService(updateIntent);
        }
        
        Log.d(TAG, "✅ Timer update broadcast sent to OpenVPNService");
        result.success(true);
        
    } catch (Exception e) {
        Log.e(TAG, "❌ Error updating timer: " + e.getMessage(), e);
        result.error("UPDATE_ERROR", "Failed to update timer: " + e.getMessage(), null);
    }
}
// Add this new method
private void startBackgroundTimer(MethodChannel.Result result, MethodCall call) {
    Log.d(TAG, "startBackgroundTimer called");
    
    if (activity == null) {
        result.error("NO_ACTIVITY", "Activity is not available", null);
        return;
    }

    try {
        // Get parameters from Flutter
        Integer durationSeconds = call.argument("duration_seconds");
        Boolean isProUser = call.argument("is_pro_user");
        
        if (durationSeconds == null) {
            durationSeconds = -1;
        }
        if (isProUser == null) {
            isProUser = false;
        }

        Log.d(TAG, "Starting timer with duration: " + durationSeconds + 
              ", isProUser: " + isProUser);

        // Create intent to start timer monitoring in OpenVPNService
        Intent intent = new Intent(activity, OpenVPNService.class);
        intent.setAction("START_TIMER_MONITORING");
        intent.putExtra("duration_seconds", durationSeconds);
        intent.putExtra("is_pro_user", isProUser);
        
        // Start the service
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent);
        } else {
            activity.startService(intent);
        }
        
        Log.d(TAG, "Timer monitoring service started");
        result.success(true);
        
    } catch (Exception e) {
        Log.e(TAG, "Error starting background timer: " + e.getMessage(), e);
        result.error("TIMER_ERROR", "Failed to start timer: " + e.getMessage(), null);
    }
}
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        Log.d(TAG, "onAttachedToEngine");
        
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
            Log.d(TAG, "Method called: " + call.method);

            switch (call.method) {
                case "startTimer":
    Log.d(TAG, "startTimer called");
    startBackgroundTimer(result, call);
    break;
                case "status":
                    if (vpnHelper == null) {
                        result.error("-1", "VPNEngine need to be initialize", "");
                        return;
                    }
                    result.success(vpnHelper.status.toString());
                    break;
case "updateTimer":
    Log.d(TAG, "updateTimer called");
    updateVpnTimer(result, call);
    break;
                case "initialize":
                    Log.d(TAG, "Initializing VPN Helper");
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
    Integer allowedSeconds = call.argument("allowed_seconds");
    Boolean isProUser = call.argument("is_pro_user");

    // CRITICAL: Save timer preferences DURING connection (before permission request)
    if (allowedSeconds != null) {
        SharedPreferences prefs = activity.getSharedPreferences("vpn_timer_prefs", Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();
        if (isProUser != null && isProUser) {
            editor.putInt("allowed_seconds", -1);  // Unlimited for pro
            editor.putBoolean("is_pro_user", true);
        } else {
            editor.putInt("allowed_seconds", allowedSeconds);
            editor.putBoolean("is_pro_user", false);
            editor.putLong("connection_start_time", System.currentTimeMillis());  // Set start time NOW
        }
        editor.apply();
        Log.d(TAG, "Timer prefs saved during connect: seconds=" + allowedSeconds + ", pro=" + isProUser);
    }

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
        pendingPermissionResult = result;  // Store result for connectWhileGranted
        activity.startActivityForResult(permission, VPN_PERMISSION_REQUEST_CODE);
        return;
    }
    connectWhileGranted(true);  // Proceed directly if permission already granted
    result.success(true);
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
                    Log.d(TAG, "checkVpnPermission called");
                    checkVpnPermission(result);
                    break;

                case "requestVpnPermission":
                    Log.d(TAG, "requestVpnPermission called");
                    requestVpnPermission(result);
                    break;

                case "dispose":
                    Log.d(TAG, "dispose called");
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
        Log.d(TAG, "checkVpnPermission: activity=" + (activity != null));
        
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is not available", null);
            return;
        }

        try {
            Intent intent = VpnService.prepare(activity);
            boolean isGranted = (intent == null);
            
            Log.d(TAG, "checkVpnPermission: granted=" + isGranted);
            result.success(isGranted);
        } catch (Exception e) {
            Log.e(TAG, "checkVpnPermission error: " + e.getMessage(), e);
            result.error("CHECK_ERROR", "Error checking VPN permission: " + e.getMessage(), null);
        }
    }

    /**
     * Request VPN permission from user
     */
    private void requestVpnPermission(MethodChannel.Result result) {
        Log.d(TAG, "requestVpnPermission: activity=" + (activity != null));
        
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is not available", null);
            return;
        }

        try {
            Intent intent = VpnService.prepare(activity);
            Log.d(TAG, "requestVpnPermission: intent=" + (intent != null));
            
            if (intent == null) {
                // Permission already granted
                Log.d(TAG, "requestVpnPermission: already granted");
                result.success(true);
                return;
            }

            // Check if there's already a pending request
            if (pendingPermissionResult != null) {
                Log.w(TAG, "requestVpnPermission: Request already in progress");
                result.error("REQUEST_IN_PROGRESS", "Permission request already in progress", null);
                return;
            }

            // Store the result callback and show permission dialog
            Log.d(TAG, "requestVpnPermission: Showing permission dialog");
            pendingPermissionResult = result;
            isCheckingPermission = true;
            
            activity.startActivityForResult(intent, VPN_CHECK_PERMISSION_REQUEST_CODE);
            
        } catch (Exception e) {
            Log.e(TAG, "requestVpnPermission error: " + e.getMessage(), e);
            
            // Clean up on error
            if (pendingPermissionResult != null) {
                pendingPermissionResult.error("REQUEST_ERROR", 
                    "Error requesting VPN permission: " + e.getMessage(), null);
                pendingPermissionResult = null;
            }
            isCheckingPermission = false;
            
            // If result was passed in and we didn't use pendingPermissionResult
            if (result != null && result != pendingPermissionResult) {
                result.error("REQUEST_ERROR", 
                    "Error requesting VPN permission: " + e.getMessage(), null);
            }
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        Log.d(TAG, "onActivityResult: requestCode=" + requestCode + 
              ", resultCode=" + resultCode + ", RESULT_OK=" + Activity.RESULT_OK);
        
        // Handle permission check result
        if (requestCode == VPN_CHECK_PERMISSION_REQUEST_CODE) {
            Log.d(TAG, "onActivityResult: VPN_CHECK_PERMISSION_REQUEST_CODE");
            
            if (!isCheckingPermission) {
                Log.w(TAG, "onActivityResult: Not expecting permission result");
                return false;
            }
            
            isCheckingPermission = false;
            
            if (pendingPermissionResult != null) {
                boolean granted = (resultCode == Activity.RESULT_OK);
                Log.d(TAG, "onActivityResult: Permission granted=" + granted);
                
                pendingPermissionResult.success(granted);
                pendingPermissionResult = null;
            } else {
                Log.w(TAG, "onActivityResult: pendingPermissionResult is null");
            }
            
            return true;
        }
        
        // Handle connection permission result
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            Log.d(TAG, "onActivityResult: VPN_PERMISSION_REQUEST_CODE");
            
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
        Log.d(TAG, "onDetachedFromEngine");
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
        Log.d(TAG, "onAttachedToActivity");
        activity = binding.getActivity();
        activityBinding = binding;
        // CRITICAL: Register activity result listener
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "onDetachedFromActivityForConfigChanges");
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
        }
        activity = null;
        activityBinding = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        Log.d(TAG, "onReattachedToActivityForConfigChanges");
        activity = binding.getActivity();
        activityBinding = binding;
        // CRITICAL: Re-register activity result listener
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivity() {
        Log.d(TAG, "onDetachedFromActivity");
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
        }
        
        // Clean up any pending permission requests
        if (pendingPermissionResult != null) {
            Log.w(TAG, "onDetachedFromActivity: Cleaning up pending permission result");
            pendingPermissionResult.error("ACTIVITY_DETACHED", 
                "Activity detached while waiting for permission", null);
            pendingPermissionResult = null;
        }
        isCheckingPermission = false;
        
        activity = null;
        activityBinding = null;
    }
}