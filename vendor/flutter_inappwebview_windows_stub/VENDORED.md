# Vendored stub: flutter_inappwebview_windows (gh-1265)

Replaces the hosted `flutter_inappwebview_windows` (0.7.0-beta.3) via
`dependency_overrides` in `flutter_app/pubspec.yaml`.

- **What this is**: a same-name, same-version stub with an empty Dart lib
  and **no `flutter: plugin:` section**.
- **Why**: the umbrella `flutter_inappwebview: 6.2.0-beta.3` (direct dep
  since gh-1235) pulls this implementation into every windows build. Its
  CMake compiles C++17 without `/await` while the cppwinrt headers
  (`winrt/Windows.Foundation.h`) include `<experimental/coroutine>`;
  MSVC 14.51 (VS 18, the windows-latest runner image) static-asserts
  `C2338 STL1011` for the legacy coroutine-TS header — nightly windows
  release leg red 5 nights (10-01 → 10-05). No published inappwebview
  version fixes this (0.7.0-beta.3 is the newest windows impl).
- **Why it's safe**: the app never uses flutter_inappwebview on Windows —
  `createFaWebViewHost()` returns null there (renderer placeholder). With
  no plugin registration, `flutter build windows --release` compiles none
  of the plugin's C++ and the app is functionally unchanged; the leg
  returns to the exact native surface it had when last green (2026-09-30).
- **Dropping the stub**: delete the `dependency_overrides` entry in
  flutter_app/pubspec.yaml and this directory, then regenerate
  flutter_app/pubspec.lock — only after upstream ships a windows impl
  whose sources compile on the current MSVC (cppwinrt coroutines or an
  explicit `/await`).

Guarded by `test/nightly_desktop_leg_guard_test.dart` (gh-1265 AC1).
