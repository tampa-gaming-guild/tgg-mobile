package com.tampagamingguild.tggmobile

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// local_auth's Android BiometricPrompt integration requires a
// FragmentActivity-based host to show the biometric dialog -- plain
// FlutterActivity (Flutter's default) doesn't support it.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Arm/disarm of background beacon detection; the detection itself
        // runs in a headless engine, see BeaconBackgroundRunner.
        BeaconBackgroundChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
