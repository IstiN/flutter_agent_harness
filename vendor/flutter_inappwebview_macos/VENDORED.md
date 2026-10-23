# flutter_inappwebview_macos (vendored)

Verbatim copy of the published `flutter_inappwebview_macos` **1.2.0-beta.3**
(pub.dev, MIT — see `LICENSE`), required by the coherent
`flutter_inappwebview` 6.2.0-beta.3 set (gh-1235).

**Changes vs upstream**:

1. macOS deployment-floor declarations raised from 10.14 to 14.0, the app's
   own minimum:

   - `macos/flutter_inappwebview_macos.podspec` — `s.platform = :osx, '10.14'` → `'14.0'`
   - (upstream) `macos/flutter_inappwebview_macos/Package.swift` — `.macOS("10.14")` → `.macOS("14.0")`

2. gh-1798: `macos/flutter_inappwebview_macos/Package.swift` is **deleted**.
   A plugin rides SwiftPM purely because that file exists, and the tool then
   publishes the `flutter-inappwebview-macos` product (14.0 floor) into
   `FlutterGeneratedPluginSwiftPackage` — which Flutter 3.47 generates at
   the macOS **12.0** floor and raises to the app's 14.0 only when a silent
   `xcodebuild -showBuildSettings` read succeeds (failures are swallowed at
   trace level). When that bump skips — it did on the first Xcode 27 run,
   whose SwiftPM resolution pass alone took 56 min — Xcode hard-fails the
   build: `requires minimum platform version 14.0 ... this target supports
   12.0`. Every other SPM-riding macOS plugin declares ≤ 10.15, so this
   vendor was the only way the generated package could ever violate its own
   floor. Without Package.swift the plugin builds via the CocoaPods lane
   (podspec floor 14.0, Podfile `platform :osx, '14.0'`, pod already pinned
   in `flutter_app/macos/Podfile.lock`) with no dependency on the fragile
   bump. `macos/flutter_inappwebview_macos/Package.resolved` is kept only as
   an inert record so the `scripts/check_lockfiles.sh` lockfile inventory
   stays stable. Pinned by `test/inappwebview_macos_pods_lane_test.dart`.

Why the floor raise: upstream declares a 10.14 floor, but
`Sources/flutter_inappwebview_macos/WebAuthenticationSession/WebAuthenticationSession.swift`
marks `presentationAnchor(for:)` `@available(macOS 10.15, *)`, so the
`ASWebAuthenticationPresentationContextProviding` conformance fails to compile
at the 10.14 target (both the SwiftPM and the CocoaPods path). Upstream
master still carries the bug — no fixed release or commit to pin to, hence
the vendor.

**Drop procedure**: once upstream releases a version whose podspec minimum
is ≥ 10.15 AND whose SwiftPM story is settled (no > 12.0 product floor), delete
this directory and the `flutter_inappwebview_macos` entry in
`flutter_app/pubspec.yaml` `dependency_overrides`.
