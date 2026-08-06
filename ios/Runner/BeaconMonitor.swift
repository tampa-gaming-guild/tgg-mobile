import CoreLocation
import Foundation

/// Wraps CoreLocation's CLBeaconRegion monitoring for the club's iBeacon --
/// iOS's counterpart to BeaconScanControl.kt's OS-registered BLE scan.
/// Unlike Android's separate scan-registration/broadcast-receiver pair, iOS
/// delivers both "register" and "detected" through the same
/// CLLocationManagerDelegate, so this single object plays both roles.
///
/// The region is monitored by the OS itself, not by this process, so it
/// keeps reporting entry even after the app is fully terminated -- the same
/// property that makes Android's PendingIntent-based scan work. Matching is
/// UUID-only (major/minor ignored), identical to the Android side.
final class BeaconMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = BeaconMonitor()

    /// Fires on region entry. Set once from AppDelegate; must be set before
    /// application(_:didFinishLaunchingWithOptions:) returns so a cold
    /// launch triggered by region entry itself is not missed.
    var onBeaconDetected: (() -> Void)?

    private let manager = CLLocationManager()
    private let regionIdentifier = "com.tampagamingguild.tggmobile.clubBeacon"

    private override init() {
        super.init()
        manager.delegate = self
    }

    static var isSupported: Bool {
        CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self)
    }

    /// Returns nil on success, or a short reason monitoring could not start
    /// -- mirrors BeaconScanControl.start's contract exactly so Dart's
    /// existing "log, don't surface" handling needs no change.
    func start(uuidString: String) -> String? {
        guard Self.isSupported else { return "Beacon region monitoring unavailable." }
        guard let uuid = UUID(uuidString: uuidString) else { return "Invalid beacon UUID." }

        let region = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
        // One-shot "arrived" signal: exit events would only ever be discarded
        // downstream (see BeaconBackground.runCheckIn's day-stamp logic), so
        // there's no reason to ask for them.
        region.notifyOnEntry = true
        region.notifyOnExit = false

        // Registering an identifier that's already monitored replaces it
        // rather than stacking -- Apple's documented behavior -- so calling
        // this repeatedly (MainShell re-arms on every background transition,
        // same as Android) is safe.
        manager.startMonitoring(for: region)
        return nil
    }

    func stop() {
        for region in manager.monitoredRegions where region.identifier == regionIdentifier {
            manager.stopMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == regionIdentifier else { return }
        onBeaconDetected?()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Nothing to re-check here, same stance as BeaconScanReceiver: the
        // detection logic lives entirely in Dart. Logging only.
        NSLog("BeaconMonitor: monitoring failed for \(region?.identifier ?? "?"): \(error)")
    }
}
