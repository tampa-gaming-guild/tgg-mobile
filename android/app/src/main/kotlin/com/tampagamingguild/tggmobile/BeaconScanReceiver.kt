package com.tampagamingguild.tggmobile

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Receives the system's broadcast when the registered background scan (see
 * BeaconScanControl) spots the club beacon. Runs even if the app was killed:
 * Android starts the process just to deliver this.
 *
 * The scan filter already matched the full beacon UUID in the Bluetooth
 * controller, so there's nothing to re-check here; this only has to hand off
 * to Dart, which owns the actual check-in logic.
 */
class BeaconScanReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_BEACON_SCAN_RESULT = "com.tampagamingguild.tggmobile.BEACON_SCAN_RESULT"
        private const val TAG = "BeaconScanReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // Logged before anything can bail out: the failure mode for a
        // registered scan is silence, so "did the system deliver at all" has
        // to be distinguishable from "delivered and we discarded it".
        Log.i(TAG, "Broadcast received: ${intent.action}")

        val errorCode = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, -1)
        if (errorCode != -1) {
            Log.w(TAG, "Background scan reported error $errorCode")
            return
        }

        val results = extractResults(intent)
        if (results.isEmpty()) {
            Log.w(TAG, "Broadcast carried no scan results")
            return
        }
        Log.i(TAG, "Club beacon detected in background (${results.size} result(s))")

        // The check-in involves a token refresh and an HTTP round trip, well
        // past what onReceive may block for, so hold the broadcast open until
        // Dart reports back and let Android keep the process alive meanwhile.
        val pendingResult = goAsync()
        BeaconBackgroundRunner.dispatch(context.applicationContext) {
            pendingResult.finish()
        }
    }

    @Suppress("DEPRECATION") // the typed overload is API 33+, and minSdk here is 24
    private fun extractResults(intent: Intent): List<ScanResult> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT, ScanResult::class.java)
        } else {
            intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT)
        } ?: emptyList()
    }
}
