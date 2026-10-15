// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web build of the app-side Copilot CLI identity install: `dart:io` is
/// unavailable, so the OS slot carries the honest `'web'` value (the
/// browser build still streams provider requests through the harness).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The app's version for the Copilot PAT-mode user-agent: the build name
/// flutter bakes as a dart-define (`--build-name`, or the pubspec version
/// in dev runs); `'fa'` keeps requests working when neither is set.
const faAppVersion = String.fromEnvironment(
  'FLUTTER_BUILD_NAME',
  defaultValue: 'fa',
);

/// Installs the identity at app boot (see the barrel doc).
void installHostCopilotCliIdentity() {
  installCopilotCliIdentity(version: faAppVersion, os: 'web');
}
