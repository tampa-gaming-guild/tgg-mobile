import Flutter
import Foundation

/// Control surface Dart uses to arm/disarm background beacon detection --
/// iOS counterpart of BeaconBackgroundChannel.kt. The Dart callback handle
/// is stored in UserDefaults rather than SharedPreferences, since a region
/// entry can relaunch the process long after the app that registered the
/// callback is gone.
enum BeaconBackgroundChannel {
    // Must match _channel in beacon_background.dart exactly. These are
    // opaque names, so a mismatch compiles and launches cleanly and then
    // simply never delivers a call -- change both sides together.
    static let controlChannelName = "com.tampagamingguild.tggmobile/beacon_control"

    private static let callbackHandleKey = "beacon_background_callback_handle"

    /// 0 means unset, matching Android's SharedPreferences default of 0L.
    static var callbackHandle: Int64 {
        Int64(UserDefaults.standard.integer(forKey: callbackHandleKey))
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: controlChannelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "registerCallback":
                guard let args = call.arguments as? [String: Any],
                      let handle = args["handle"] as? NSNumber else {
                    result(FlutterError(code: "bad_args", message: "registerCallback needs a handle", details: nil))
                    return
                }
                UserDefaults.standard.set(handle.int64Value, forKey: callbackHandleKey)
                result(nil)

            case "startScan":
                guard let args = call.arguments as? [String: Any],
                      let uuid = args["uuid"] as? String, !uuid.isEmpty else {
                    result(FlutterError(code: "bad_args", message: "startScan needs a uuid", details: nil))
                    return
                }
                // nil means started; a string is a human-readable reason it
                // couldn't, which Dart logs rather than surfaces, since this
                // is all opportunistic.
                result(BeaconMonitor.shared.start(uuidString: uuid))

            case "stopScan":
                BeaconMonitor.shared.stop()
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
