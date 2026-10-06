package com.anonlisten.hollow

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Reports a new default network, and the moment it validates, for
 * lib/src/core/services/relay_triggers.dart. The network in use at start is
 * the baseline, never a change.
 */
internal class RelayNetworkWatch(
    context: Context,
    private val onChange: () -> Unit,
) : ConnectivityManager.NetworkCallback() {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())

    // Touched only on the callback thread, after start() set the baseline.
    private var current: Network? = null
    private var validated = false
    private var registered = false

    fun start() {
        if (registered || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        current = connectivity.activeNetwork
        validated = isValidated(connectivity.getNetworkCapabilities(current))
        try {
            connectivity.registerDefaultNetworkCallback(this)
            registered = true
        } catch (e: RuntimeException) {
            Log.w(TAG, "network watch unavailable: $e")
        }
    }

    fun stop() {
        if (!registered) return
        registered = false
        try {
            connectivity.unregisterNetworkCallback(this)
        } catch (_: RuntimeException) {
        }
    }

    override fun onAvailable(network: Network) {
        if (network == current) return
        current = network
        validated = false
        changed("available")
    }

    override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
        val nowValidated = isValidated(caps)
        if (network != current) {
            current = network
            validated = nowValidated
            changed("capabilities")
            return
        }
        if (nowValidated && !validated) changed("validated")
        validated = nowValidated
    }

    override fun onLost(network: Network) {
        if (network != current) return
        current = null
        validated = false
    }

    private fun changed(why: String) {
        Log.i(TAG, "default network $why")
        main.post(onChange)
    }

    private fun isValidated(caps: NetworkCapabilities?): Boolean =
        caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true

    private companion object {
        const val TAG = "HollowRelayTriggers"
    }
}
