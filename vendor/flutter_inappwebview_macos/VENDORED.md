# flutter_inappwebview_macos (vendored)

Verbatim copy of the published `flutter_inappwebview_macos` **1.2.0-beta.3**
(pub.dev, MIT — see `LICENSE`), required by the coherent
`flutter_inappwebview` 6.2.0-beta.3 set (gh-1235).

**Single change vs upstream** (both macOS deployment-floor declarations
raised from 10.14 to 14.0, the app's own minimum):

- `macos/flutter_inappwebview_macos/Package.swift` — `.macOS("10.14")` → `.macOS("14.0")`
- `macos/flutter_inappwebview_macos.podspec` — `s.platform = :osx, '10.14'` → `'14.0'`

Why: upstream declares a 10.14 floor, but
`Sources/flutter_inappwebview_macos/WebAuthenticationSession/WebAuthenticationSession.swift`
marks `presentationAnchor(for:)` `@available(macOS 10.15, *)`, so the
`ASWebAuthenticationPresentationContextProviding` conformance fails to compile
at the 10.14 target (both the SwiftPM and the CocoaPods path). Upstream
master still carries the bug — no fixed release or commit to pin to, hence
the vendor.

**Drop procedure**: once upstream releases a version whose Package.swift /
podspec minimum is ≥ 10.15, delete this directory and the
`flutter_inappwebview_macos` entry in
`flutter_app/pubspec.yaml` `dependency_overrides`.
