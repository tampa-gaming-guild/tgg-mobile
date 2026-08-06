import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Wired unconditionally, even for a plain cold launch with no location
    // key in launchOptions: CLLocationManager needs its delegate set before
    // this method returns to deliver a region event that triggered the
    // launch itself (see BeaconMonitor).
    BeaconMonitor.shared.onBeaconDetected = {
      BeaconBackgroundRunner.dispatch(completion: {})
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Arm/disarm of background beacon detection on the main engine; the
    // detection itself runs in a headless engine, see BeaconBackgroundRunner.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BeaconBackgroundChannel") {
      BeaconBackgroundChannel.register(with: registrar.messenger)
    }
  }
}
