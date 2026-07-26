/// The Tampa Gaming Guild's physical BlueCharm BC011 Pro beacon.
///
/// Read directly off the physical hardware via the KBeaconPro app (General
/// Information > SLOT0 iBeacon > Beacon Detail) on 2026-07-26 -- this is its
/// factory-default UUID (KBeaconPro also shows Major 3838 / Minor 4949, also
/// factory defaults, but those aren't used here since there's only one club
/// beacon and matching on UUID alone is enough to identify it).
class ClubBeacon {
  static const uuid = '426C7565-4368-6172-6D42-6561636F6E73';
}
