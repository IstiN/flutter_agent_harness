// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO build of the app-side Copilot CLI identity install (gh-1606
/// review): `Platform.operatingSystem` fills the OS slot of the PAT-mode
/// user-agent, exactly like the CLI host's boot install.
library;

import 'dart:io';

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
  installCopilotCliIdentity(
    version: faAppVersion,
    os: Platform.operatingSystem,
  );
}
