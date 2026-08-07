import Flutter
import UIKit

/// Runs the Dart side of a background beacon detection -- iOS counterpart of
/// BeaconBackgroundRunner.kt.
///
/// The check-in itself lives in Dart, not here: it needs the stored refresh
/// token, the token-rotation logic, the once-per-day stamp and the same
/// api/checkins.php call the foreground path uses. Reimplementing all of
/// that here would mean two copies to keep in step, so instead this spins
/// up a headless FlutterEngine and calls into the app's own code, the same
/// way the Android runner does.
///
/// The Dart entrypoint to run is registered by the app while it's in the
/// foreground (see BeaconBackgroundChannel) and kept in UserDefaults, since
/// by the time a region entry arrives there may be no app process at all.
enum BeaconBackgroundRunner {
    // Must match backgroundChannel in beacon_background.dart exactly.
    static let backgroundChannelName = "com.tampagamingguild.tggmobile/beacon_background"

    /// Ceiling on how long Dart gets before the engine is torn down anyway,
    /// with margin below iOS's own background-task expiration.
    private static let timeoutSeconds: TimeInterval = 20

    private static var engine: FlutterEngine?

    static func dispatch(completion: @escaping () -> Void) {
        // FlutterEngine must be created and driven from the main thread;
        // the CLLocationManagerDelegate callback that leads here may not be.
        DispatchQueue.main.async { start(completion: completion) }
    }

    private static func start(completion: @escaping () -> Void) {
        if engine != nil {
            // A detection is already being handled; ignore the duplicate,
            // mirroring the Android runner's same guard.
            completion()
            return
        }

        let handle = BeaconBackgroundChannel.callbackHandle
        guard handle != 0, let info = FlutterCallbackCache.lookupCallbackInformation(handle) else {
            completion()
            return
        }

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        var finished = false

        func finish(_ reason: String) {
            guard !finished else { return }
            finished = true
            engine?.destroyContext()
            engine = nil
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            completion()
        }

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "BeaconCheckIn") {
            finish("expired")
        }

        let created = FlutterEngine(name: "BeaconBackgroundEngine")
        guard created.run(withEntrypoint: info.callbackName, libraryURI: info.callbackLibraryPath) else {
            NSLog("BeaconBackgroundRunner: failed to start Dart callback")
            finish("failed to start")
            return
        }

        // Unlike Android, where a freshly created FlutterEngine registers
        // plugins for itself, iOS requires this explicitly -- skip it and
        // NotificationService/AutoCheckinPreference's channels
        // (flutter_local_notifications, flutter_secure_storage) have no
        // native handler inside this engine and silently fail inside
        // runCheckIn().
        GeneratedPluginRegistrant.register(with: created)
        engine = created

        // The headless isolate needs its own copy of the control channel
        // too: after a successful check-in it cancels the registered
        // region, and without this that call lands on a channel with no
        // handler and is silently swallowed, leaving the OS waking the app
        // for every further sighting the rest of the day.
        BeaconBackgroundChannel.register(with: created.binaryMessenger)

        let channel = FlutterMethodChannel(name: backgroundChannelName, binaryMessenger: created.binaryMessenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            // Dart has wired up its handler and is ready to be told what
            // happened; anything sent before this would be dropped.
            case "backgroundHandlerReady":
                result(nil)
                channel.invokeMethod("onBeaconDetected", arguments: nil)
            case "backgroundHandlerDone":
                result(nil)
                finish("reported done")
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            finish("timed out")
        }
    }
}
