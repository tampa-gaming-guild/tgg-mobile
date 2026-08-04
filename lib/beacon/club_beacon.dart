/// The Tampa Gaming Guild's physical BlueCharm BC011 Pro beacon.
///
/// The UUID is "TampaGamingGuild" ASCII-encoded into UUID form, the same way
/// BlueCharm's factory-default UUID ('426C7565-4368-6172-6D42-6561636F6E73')
/// spells out "BlueCharmBeacons". Reprogrammed onto the physical hardware via
/// the KBeaconPro app (General Information > SLOT0 iBeacon > Beacon Detail)
/// and confirmed broadcasting on 2026-08-04; Major/Minor stay at their
/// factory defaults (3838 / 4949) since matching on UUID alone is enough to
/// identify the one club beacon.
class ClubBeacon {
  static const uuid = '54616D70-6147-616D-696E-674775696C64';
}
