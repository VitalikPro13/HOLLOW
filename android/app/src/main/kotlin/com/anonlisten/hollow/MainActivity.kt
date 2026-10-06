package com.anonlisten.hollow

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PersistableBundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity): required by local_auth's
// BiometricPrompt integration.
class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.anonlisten.hollow/platform"
    private val SECRET_CLIP_LABEL = "hollow-secret"
    private var wifiLock: WifiManager.WifiLock? = null
    private var relayNetworkWatch: RelayNetworkWatch? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerPrivacyChannel(flutterEngine)

        val relayTriggers =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hollow/relay_triggers")
        relayNetworkWatch?.stop()
        relayNetworkWatch = RelayNetworkWatch(this) {
            relayTriggers.invokeMethod("network", null)
        }.also { it.start() }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    // Which store (if any) installed this APK. Google Play
                    // reports com.android.vending; a sideload reports null.
                    // The shop UI is hidden entirely on store builds.
                    "getInstallerPackage" -> {
                        val installer = try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                packageManager.getInstallSourceInfo(packageName)
                                    .installingPackageName
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getInstallerPackageName(packageName)
                            }
                        } catch (e: Exception) {
                            null
                        }
                        result.success(installer)
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
                    // Per-app notification settings exist from O; older
                    // releases only have the app details page.
                    "openNotificationSettings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        }
                        val opened = try {
                            startActivity(intent)
                            true
                        } catch (e: Exception) {
                            false
                        }
                        result.success(opened)
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

    // Phrase screens, the App Lock and secrets on the clipboard
    // (privacy_screen.dart, secret_clipboard.dart).
    private fun registerPrivacyChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hollow/privacy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Only while a phrase screen is up: screenshots stay allowed
                    // everywhere else.
                    "setSecureScreen" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    // App Lock on: recents keeps no picture of the last screen.
                    "setSwitcherCover" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            setRecentsScreenshotEnabled(call.arguments != true)
                        }
                        result.success(null)
                    }
                    "copySecret" -> {
                        val clip = ClipData.newPlainText(
                            SECRET_CLIP_LABEL, call.argument<String>("text") ?: "")
                        // Keyboards and the clipboard preview then show dots.
                        val sensitiveKey = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            ClipDescription.EXTRA_IS_SENSITIVE
                        } else {
                            "android.content.extra.IS_SENSITIVE"
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            clip.description.extras = PersistableBundle().apply {
                                putBoolean(sensitiveKey, true)
                            }
                        }
                        clipboard().setPrimaryClip(clip)
                        result.success(true)
                    }
                    // Judged by our clip's label, never its text. A window without
                    // focus cannot see the clipboard, so Dart asks again on resume.
                    "clearSecret" -> {
                        if (!hasWindowFocus()) {
                            result.success("unknown")
                        } else if (clipboard().primaryClipDescription?.label?.toString() == SECRET_CLIP_LABEL) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                clipboard().clearPrimaryClip()
                            } else {
                                clipboard().setPrimaryClip(ClipData.newPlainText("", ""))
                            }
                            result.success("cleared")
                        } else {
                            result.success("other")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun clipboard(): ClipboardManager =
        getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    override fun onDestroy() {
        relayNetworkWatch?.stop()
        relayNetworkWatch = null
        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        super.onDestroy()
    }
}
