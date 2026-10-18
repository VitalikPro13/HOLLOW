package com.anonlisten.hollow

import android.os.Build
import android.security.keystore.KeyInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Log
import androidx.annotation.Keep
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/**
 * The Android Keystore HMAC key that ties the app lock's wrap to this phone
 * (`identity/hw_key.rs`). Rust calls these statics over JNI from its own threads, so
 * every one catches everything: an exception left pending would end the call there.
 *
 * The key needs neither the lock screen nor a biometric (no user authentication), so
 * a new fingerprint or a changed screen lock never invalidates it. A key the phone
 * cannot keep in secure hardware is refused and deleted: a software key would claim a
 * binding that is not there.
 */
@Keep
object HollowHwKey {
    private const val TAG = "HOLLOW-HWKEY"
    private const val STORE = "AndroidKeyStore"

    private const val REFUSED = 0
    private const val TEE = 1
    private const val STRONGBOX = 2

    @JvmStatic
    private external fun nativeRegister()

    /** Hands Rust the four calls below. Before Dart's first unlock. */
    fun register() {
        try {
            // FRB opens the library from Dart; ART needs its own load to bind JNI.
            System.loadLibrary("hollow_core")
            nativeRegister()
        } catch (t: Throwable) {
            Log.w(TAG, "hardware key unavailable: ${t.javaClass.simpleName}")
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    private fun generate(alias: String, strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setKeySize(256)
            .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, STORE)
        generator.init(spec)
        return generator.generateKey()
    }

    private fun levelOf(key: SecretKey): Int {
        val info = SecretKeyFactory.getInstance(key.algorithm, STORE)
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT >= 31) {
            return when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> STRONGBOX
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> TEE
                else -> REFUSED
            }
        }
        @Suppress("DEPRECATION")
        return if (info.isInsideSecureHardware) TEE else REFUSED
    }

    /** A fresh key under [alias]: 2 StrongBox, 1 TEE, 0 refused (nothing kept). */
    @JvmStatic
    fun create(alias: String): Int {
        return try {
            delete(alias)
            val key = try {
                generate(alias, strongBox = true)
            } catch (e: StrongBoxUnavailableException) {
                generate(alias, strongBox = false)
            }
            val level = levelOf(key)
            if (level == REFUSED) delete(alias)
            Log.i(TAG, "key made, level=${when (level) { STRONGBOX -> "strongbox"; TEE -> "tee"; else -> "software (refused)" }}")
            level
        } catch (t: Throwable) {
            Log.w(TAG, "key not made: ${t.javaClass.simpleName}")
            delete(alias)
            REFUSED
        }
    }

    /** 1 the key is there, 0 the keystore says it is not, -1 the keystore failed to say. */
    @JvmStatic
    fun exists(alias: String): Int = try {
        if (keyStore().containsAlias(alias)) 1 else 0
    } catch (t: Throwable) {
        Log.w(TAG, "keystore did not answer: ${t.javaClass.simpleName}")
        -1
    }

    /** HMAC-SHA256 of [input] under the key, null when the operation failed. */
    @JvmStatic
    fun apply(alias: String, input: ByteArray): ByteArray? = try {
        val key = keyStore().getKey(alias, null) as? SecretKey
        if (key == null) {
            null
        } else {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(key)
            mac.doFinal(input)
        }
    } catch (t: Throwable) {
        Log.w(TAG, "key did not answer: ${t.javaClass.simpleName}")
        null
    }

    @JvmStatic
    fun delete(alias: String) {
        try {
            keyStore().deleteEntry(alias)
        } catch (_: Throwable) {
        }
    }
}
