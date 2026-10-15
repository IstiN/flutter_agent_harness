// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/unpacked_loader.dart';
import 'package:fa/services/folder_picker_stub.dart'
    if (dart.library.html) 'package:fa/services/folder_picker_web.dart';

export 'package:fa/apps/unpacked_loader.dart' show UnpackedPickedFile;

/// Platform factory for the unpacked-widget folder picker (gh-1616): the
/// web build gets a real `<input type="file" webkitdirectory>` picker;
/// every other host gets null — the "Load unpacked" affordance hides
/// itself when no picker exists (a host that cannot pick folders never
/// shows a button that errors; the path-in-settings alternative is the
/// ticket's second tier).
FolderPicker? createFolderPicker() => createPlatformFolderPicker();
