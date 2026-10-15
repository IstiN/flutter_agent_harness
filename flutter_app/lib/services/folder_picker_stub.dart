// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/unpacked_loader.dart';

/// Non-web stub: no folder picker exists on this host (gh-1616 — the
/// "Load unpacked" entry hides when this factory returns null).
FolderPicker? createPlatformFolderPicker() => null;
