# Fa — Flutter Agent app

The Flutter macOS/iOS client for the agent harness.

## macOS builds

Two flavors are supported:

- **Sandboxed** (`flutter build macos --release`) — for the App Store.
  Script execution is blocked by the App Sandbox, so embedded interpreters
  are required for agent code execution.
- **Full / no-sandbox** (`scripts/build_macos_nosandbox.sh`) — for GitHub
  Releases. The hardened-runtime build can spawn system interpreters
  (`python3`, `bash`, `node`) and declares HealthKit access. Set
  `MACOS_IDENTITY` to a Developer ID certificate for distribution; the
  default `-` produces an ad-hoc signed local build.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
