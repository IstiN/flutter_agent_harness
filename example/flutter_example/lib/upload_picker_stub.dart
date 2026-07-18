// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'upload.dart';

/// Non-web fallback: arbitrary-file picking is only wired up for the
/// browser, so the factory returns `null` and the upload affordance hides
/// itself. Selected unless `dart.library.html` is available.
UploadPicker? createUploadPicker() => null;
