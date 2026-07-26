/// One parsed iBeacon advertisement: the standard Apple payload is UUID +
/// major + minor + measured tx power, carried inside a BLE manufacturer-data
/// field under Apple's company id (0x004C). See BeaconScanner for the parser.
class IBeaconReading {
  final String uuid;
  final int major;
  final int minor;
  final int rssi;

  const IBeaconReading({required this.uuid, required this.major, required this.minor, required this.rssi});

  @override
  String toString() => 'IBeaconReading(uuid: $uuid, major: $major, minor: $minor, rssi: $rssi)';
}
