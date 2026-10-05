# Vendored stub: flutter_inappwebview_linux (gh-1265)

Replaces the hosted `flutter_inappwebview_linux` (0.1.0-beta.1) via
`dependency_overrides` in `flutter_app/pubspec.yaml`.

- **What this is**: a same-name, same-version stub with an empty Dart lib
  and **no `flutter: plugin:` section**.
- **Why**: the umbrella `flutter_inappwebview: 6.2.0-beta.3` (direct dep
  since gh-1235) pulls this implementation into every linux build, and its
  native CMake hard-requires the WPE WebKit system library
  (`CMakeLists.txt:63` — nightly linux release leg red 5 nights,
  10-01 → 10-05). `libwpewebkit-1.0-dev` does not exist on Ubuntu 24.04
  (noble; verified against packages.ubuntu.com — jammy-only), so the
  plugin cannot be built on `ubuntu-latest` at all.
- **Why it's safe**: the app never uses flutter_inappwebview on Linux —
  `createFaWebViewHost()` returns null there (renderer placeholder). With
  no plugin registration, `flutter build linux --release` compiles none of
  the plugin's C++ and the app is functionally unchanged.
- **Dropping the stub**: delete the `dependency_overrides` entry in
  flutter_app/pubspec.yaml and this directory, then regenerate
  flutter_app/pubspec.lock — but only once the linux leg can satisfy the
  WPE WebKit requirement (new runner image, upstream making the dependency
  optional, or upstream shipping a linux impl without it).

Guarded by `test/nightly_desktop_leg_guard_test.dart` (gh-1265 AC1).
