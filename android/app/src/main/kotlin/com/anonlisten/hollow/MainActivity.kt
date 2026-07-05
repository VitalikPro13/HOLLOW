package com.anonlisten.hollow

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity): required by local_auth's
// BiometricPrompt integration.
class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.anonlisten.hollow/platform"
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    "isBatteryOptimized" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(!pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestBatteryExemption" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    "acquireWifiLock" -> {
                        if (wifiLock == null) {
                            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "hollow:ws")
                            wifiLock?.setReferenceCounted(false)
                        }
                        if (wifiLock?.isHeld != true) {
                            wifiLock?.acquire()
                        }
                        result.success(null)
                    }
                    "releaseWifiLock" -> {
                        if (wifiLock?.isHeld == true) {
                            wifiLock?.release()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        super.onDestroy()
    }
}
