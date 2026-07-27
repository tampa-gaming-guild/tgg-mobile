package com.tampagamingguild.tgg_mobile

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.UUID

/**
 * Registers a BLE scan with the system that outlives our process.
 *
 * Unlike the foreground scan (BeaconScanner on the Dart side, via
 * flutter_blue_plus), this hands the OS a PendingIntent instead of a
 * callback: the Bluetooth stack keeps scanning after the app is backgrounded
 * or killed and broadcasts to BeaconScanReceiver on a match, which is what
 * makes walk-in detection possible without a foreground service and its
 * permanent notification.
 *
 * The scan filter carries the whole iBeacon payload prefix including the
 * 16-byte UUID, so the Bluetooth controller only wakes us for this club's
 * beacon rather than for every iBeacon in range.
 *
 * Requires API 26 for the PendingIntent overload. Older devices simply keep
 * the foreground-only behaviour; [isSupported] lets Dart tell the difference.
 */
object BeaconScanControl {
    private const val TAG = "BeaconScanControl"
    private const val APPLE_MANUFACTURER_ID = 0x004C
    private const val REQUEST_CODE = 1

    val isSupported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    /**
     * Apple's iBeacon manufacturer payload is 0x02 0x15 followed by the
     * 16-byte proximity UUID (then major/minor/tx power, which we don't
     * constrain). Matching all 18 leading bytes keeps other vendors' beacons
     * from waking the app at all.
     */
    private fun filtersFor(uuid: UUID): List<ScanFilter> {
        val data = ByteArray(18)
        data[0] = 0x02
        data[1] = 0x15
        var msb = uuid.mostSignificantBits
        var lsb = uuid.leastSignificantBits
        for (i in 7 downTo 0) {
            data[2 + i] = (msb and 0xFF).toByte()
            msb = msb shr 8
            data[10 + i] = (lsb and 0xFF).toByte()
            lsb = lsb shr 8
        }
        val mask = ByteArray(18) { 0xFF.toByte() }

        return listOf(
            ScanFilter.Builder()
                .setManufacturerData(APPLE_MANUFACTURER_ID, data, mask)
                .build()
        )
    }

    private fun settings(): ScanSettings {
        // CALLBACK_TYPE_FIRST_MATCH would suit this better in principle, since
        // one wakeup on arrival is all a check-in needs, but it depends on
        // hardware onFound/onLost support and fails by simply never reporting
        // rather than by returning an error, which is exactly what it did on
        // test hardware. ALL_MATCHES is universally supported; the extra
        // wakeups are bounded by cancelling the scan once the day's check-in
        // lands (see BeaconBackground.runCheckIn).
        return ScanSettings.Builder()
            // Low power is right for a scan meant to run for hours in the
            // background; the beacon advertises about once a second, so even
            // a sparse duty cycle picks it up within seconds of walking in.
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, BeaconScanReceiver::class.java).apply {
            action = BeaconScanReceiver.ACTION_BEACON_SCAN_RESULT
        }
        // Mutable because the Bluetooth stack fills in the scan results.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    /** Returns null on success, or a short reason the scan could not start. */
    @SuppressLint("MissingPermission") // Dart only calls this once permissions are granted; see AutoCheckinController.
    fun start(context: Context, uuidString: String): String? {
        if (!isSupported) return "Background scanning needs Android 8.0 or newer."

        val uuid = try {
            UUID.fromString(uuidString)
        } catch (e: IllegalArgumentException) {
            return "Invalid beacon UUID."
        }

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter ?: return "No Bluetooth adapter."
        if (!adapter.isEnabled) return "Bluetooth is off."
        val scanner = adapter.bluetoothLeScanner ?: return "Bluetooth scanner unavailable."

        return try {
            val status = scanner.startScan(filtersFor(uuid), settings(), pendingIntent(context))
            if (status == 0) {
                Log.i(
                    TAG,
                    "Registered background beacon scan for $uuid " +
                        "(offloadedFilter=${adapter.isOffloadedFilteringSupported}, " +
                        "offloadedBatching=${adapter.isOffloadedScanBatchingSupported})"
                )
                null
            } else {
                "Bluetooth rejected the scan (code $status)."
            }
        } catch (e: SecurityException) {
            "Missing Bluetooth permission."
        } catch (e: IllegalStateException) {
            "Bluetooth is not ready."
        }
    }

    @SuppressLint("MissingPermission")
    fun stop(context: Context) {
        if (!isSupported) return
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val scanner = manager?.adapter?.bluetoothLeScanner ?: return
        try {
            scanner.stopScan(pendingIntent(context))
            Log.i(TAG, "Cancelled background beacon scan")
        } catch (e: SecurityException) {
            // Permission revoked while a scan was registered; nothing to undo.
        } catch (e: IllegalStateException) {
            // Adapter already torn down.
        }
    }
}
