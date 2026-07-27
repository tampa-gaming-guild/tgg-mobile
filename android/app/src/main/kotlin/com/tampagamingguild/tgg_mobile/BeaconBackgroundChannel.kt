package com.tampagamingguild.tgg_mobile

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The control surface Dart uses to arm and disarm background beacon
 * detection, registered on the main engine (see MainActivity).
 *
 * The Dart entrypoint that should run on a detection is recorded here as a
 * raw callback handle while the app is alive, because a broadcast can arrive
 * long after the process is gone and the runner needs to know what to
 * execute (see BeaconBackgroundRunner).
 */
object BeaconBackgroundChannel {
    const val CONTROL_CHANNEL = "com.tampagamingguild.tgg_mobile/beacon_control"

    private const val PREFS_NAME = "tgg_beacon_background"
    private const val KEY_CALLBACK_HANDLE = "callback_handle"

    fun callbackHandle(context: Context): Long =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getLong(KEY_CALLBACK_HANDLE, 0L)

    private fun setCallbackHandle(context: Context, handle: Long) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_CALLBACK_HANDLE, handle)
            .apply()
    }

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "registerCallback" -> {
                    val handle = call.argument<Any>("handle")
                    val raw = when (handle) {
                        is Long -> handle
                        is Int -> handle.toLong()
                        else -> null
                    }
                    if (raw == null) {
                        result.error("bad_args", "registerCallback needs a handle", null)
                    } else {
                        setCallbackHandle(appContext, raw)
                        result.success(null)
                    }
                }

                "startScan" -> {
                    val uuid = call.argument<String>("uuid")
                    if (uuid.isNullOrBlank()) {
                        result.error("bad_args", "startScan needs a uuid", null)
                    } else {
                        // Null means started; a string is a human-readable
                        // reason it couldn't, which Dart logs rather than
                        // surfaces, since this is all opportunistic.
                        result.success(BeaconScanControl.start(appContext, uuid))
                    }
                }

                "stopScan" -> {
                    BeaconScanControl.stop(appContext)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }
}
