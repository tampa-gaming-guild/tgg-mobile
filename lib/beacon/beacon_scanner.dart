import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ibeacon_reading.dart';

/// Parses standard iBeacon advertisements out of flutter_blue_plus scan
/// results. iBeacon is just a convention layered on top of a BLE
/// manufacturer-data field: Apple's company id (0x004C), followed by a fixed
/// 0x02 0x15 type/length marker, a 16-byte UUID, 2-byte major, 2-byte minor,
/// and a 1-byte measured tx power. There's no dedicated iBeacon plugin here
/// -- this is small enough to parse directly and keeps the app off an
/// unmaintained package.
class BeaconScanner {
  static const appleManufacturerId = 0x004C;

  /// Returns null if this advertisement isn't a standards-shaped iBeacon.
  static IBeaconReading? parse(AdvertisementData data, int rssi) {
    final bytes = data.manufacturerData[appleManufacturerId];
    if (bytes == null || bytes.length < 22 || bytes[0] != 0x02 || bytes[1] != 0x15) return null;

    final uuidBytes = bytes.sublist(2, 18);
    String hex(int start, int end) => uuidBytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid = '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}'.toUpperCase();

    final major = (bytes[18] << 8) | bytes[19];
    final minor = (bytes[20] << 8) | bytes[21];

    return IBeaconReading(uuid: uuid, major: major, minor: minor, rssi: rssi);
  }

  /// One reading per nearby iBeacon-shaped device, updated as new
  /// advertisements arrive. [parse] still re-checks the payload shape, since
  /// the hardware filter below only matches its first two bytes.
  static Stream<List<IBeaconReading>> get readings => FlutterBluePlus.scanResults.map(
        (results) => results.map((r) => parse(r.advertisementData, r.rssi)).whereType<IBeaconReading>().toList(),
      );

  /// Filtering happens in the Bluetooth controller rather than in Dart: the
  /// radio only wakes the app for advertisements already matching Apple's
  /// iBeacon type marker, instead of for every BLE device in the room.
  ///
  /// Balanced rather than lowLatency, which scans continuously and is far too
  /// expensive to leave running for a whole session. Balanced listens in
  /// roughly one-second windows a few seconds apart, and the club beacon
  /// advertises about once a second (measured: 1022.5ms), so a window almost
  /// always overlaps an advertisement; expect detection within a few seconds
  /// of the app coming to the foreground in range. lowPower stretches the gap
  /// between windows enough to make that noticeably slower for a check-in the
  /// member is standing there waiting on.
  ///
  /// Note that scan filters affect which results are delivered, not whether
  /// any are: see the AndroidManifest's note on why BLUETOOTH_SCAN must not
  /// declare neverForLocation.
  static Future<void> startScan() => FlutterBluePlus.startScan(
        withMsd: [MsdFilter(appleManufacturerId, data: const [0x02, 0x15], mask: const [0xFF, 0xFF])],
        androidScanMode: AndroidScanMode.balanced,
      );

  static Future<void> stopScan() => FlutterBluePlus.stopScan();
}
