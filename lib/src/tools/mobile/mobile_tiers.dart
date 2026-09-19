/// The on-device automation tiers (issue #622): one `mobile.*` tool
/// contract, three capability tiers, two build flavors.
///
/// | Tier        | Flavor  | Surface                                             |
/// |-------------|---------|-----------------------------------------------------|
/// | store       | store   | own-app automation: deep links, launcher, own logs  |
/// | god         | god     | + AccessibilityService (hierarchy/gestures),        |
/// |             |         |   MediaProjection screenshots, package inventory    |
/// | god+shizuku | god     | + `mobile.shell` over the Shizuku bridge (opt-in)   |
///
/// The tier only changes which tools pass the capability floor
/// (`ToolCapability`); `resolveToolAvailability` (issue #19) does the rest,
/// and gated tools surface the honest sideload reason instead of vanishing
/// silently (the #327 lesson).
///
/// Pure Dart: no `dart:io`. The Android driver and the consent UI live in
/// the app (`flutter_app`); this module is the contract both tiers share.
library;

import '../availability.dart';

/// The build tier of the Android app.
///
/// `god+shizuku` is NOT a build flavor: the same god APK gains the shell
/// bridge when the user opts in (Shizuku running + in-app toggle), so the
/// floor only knows [store] and [god].
enum MobileTier { store, god }

/// The honest gate reason for tools the store flavor cannot provide:
/// names the tier and the sideload link (UT-floor-2 reason golden).
const mobileSideloadGateReason =
    'requires the god tier (sideload build) — get it at https://fa1.dev/android';

/// The capability floor the [tier] flavor implies, for the three mobile
/// availability ids (`mobile`, `mobile_automation`, `mobile_shell`).
///
/// - store: launch/logs present; the accessibility surface and the Shizuku
///   shell are absent with [mobileSideloadGateReason].
/// - god: everything present at the floor. `mobile.shell` still answers
///   the named `Shizuku not running` error at runtime when the bridge is
///   off (UT-tier-3) — the floor says the wiring EXISTS, the bridge says
///   whether it is awake.
Map<String, ToolCapability> mobileCapabilityFloor({required MobileTier tier}) =>
    switch (tier) {
      MobileTier.store => const {
        'mobile': ToolCapability.available(),
        'mobile_automation': ToolCapability.absent(mobileSideloadGateReason),
        'mobile_shell': ToolCapability.absent(mobileSideloadGateReason),
      },
      MobileTier.god => const {
        'mobile': ToolCapability.available(),
        'mobile_automation': ToolCapability.available(),
        'mobile_shell': ToolCapability.available(),
      },
    };
