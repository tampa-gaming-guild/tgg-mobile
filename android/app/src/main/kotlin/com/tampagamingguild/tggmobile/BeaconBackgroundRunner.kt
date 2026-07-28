package com.tampagamingguild.tggmobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation

/**
 * Runs the Dart side of a background beacon detection.
 *
 * The check-in itself lives in Dart, not here: it needs the stored refresh
 * token, the token-rotation logic, the once-per-day stamp and the same
 * api/checkins.php call the foreground path uses. Reimplementing all of that
 * in Kotlin would mean two copies to keep in step, so instead this spins up a
 * headless FlutterEngine and calls into the app's own code.
 *
 * The Dart entrypoint to run is registered by the app while it's in the
 * foreground (see BeaconBackgroundChannel) and kept in SharedPreferences,
 * since by the time a broadcast arrives there may be no app process at all.
 */
object BeaconBackgroundRunner {
    private const val TAG = "BeaconBackgroundRunner"
    const val BACKGROUND_CHANNEL = "com.tampagamingguild.tggmobile/beacon_background"

    /** Ceiling on how long Dart gets before we tear the engine down anyway. */
    private const val TIMEOUT_MS = 25_000L

    private var engine: FlutterEngine? = null

    fun dispatch(context: Context, onComplete: () -> Unit) {
        // FlutterEngine must be created and driven from the main thread;
        // onReceive may not be on it.
        Handler(Looper.getMainLooper()).post { start(context, onComplete) }
    }

    private fun start(context: Context, onComplete: () -> Unit) {
        if (engine != null) {
            Log.i(TAG, "Background engine already running; ignoring duplicate detection")
            onComplete()
            return
        }

        val handle = BeaconBackgroundChannel.callbackHandle(context)
        if (handle == 0L) {
            Log.w(TAG, "No Dart callback registered; cannot run background check-in")
            onComplete()
            return
        }

        // Must precede any FlutterJNI call. Resolving a callback handle is a
        // native lookup, so doing it first throws UnsatisfiedLinkError in the
        // case that matters most: a process cold started purely to deliver
        // this broadcast, where nothing has loaded libflutter yet. With the
        // app merely backgrounded the library is already up and the wrong
        // order appears to work.
        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(context)
        }
        loader.ensureInitializationComplete(context, null)

        val callback = FlutterCallbackInformation.lookupCallbackInformation(handle)
        if (callback == null) {
            Log.w(TAG, "Registered Dart callback could not be resolved")
            onComplete()
            return
        }

        val created = FlutterEngine(context)
        engine = created

        // The background isolate needs the control channel too, not just the
        // main engine's copy: after a successful check-in it cancels the
        // registered scan, and without this that call lands on a channel with
        // no handler and is silently swallowed, leaving the OS waking us for
        // every further sighting all visit.
        BeaconBackgroundChannel.register(context, created.dartExecutor.binaryMessenger)

        var finished = false
        val timeout = Handler(Looper.getMainLooper())
        lateinit var finish: (String) -> Unit

        finish = { reason ->
            if (!finished) {
                finished = true
                timeout.removeCallbacksAndMessages(null)
                Log.i(TAG, "Background check-in finished ($reason)")
                created.destroy()
                engine = null
                onComplete()
            }
        }

        val channel = MethodChannel(created.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart has wired up its handler and is ready to be told what
                // happened; anything sent before this would be dropped.
                "backgroundHandlerReady" -> {
                    result.success(null)
                    channel.invokeMethod("onBeaconDetected", null)
                }
                "backgroundHandlerDone" -> {
                    result.success(null)
                    finish("reported done")
                }
                else -> result.notImplemented()
            }
        }

        timeout.postDelayed({ finish("timed out") }, TIMEOUT_MS)

        created.dartExecutor.executeDartCallback(
            DartExecutor.DartCallback(context.assets, loader.findAppBundlePath(), callback)
        )
    }
}
