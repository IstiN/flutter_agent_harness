// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Office-host boot seam (issue #182): resolves the [OfficeApi] bridge when
/// this build runs as the Outlook taskpane app. Web-only — every other
/// platform resolves `null` and the agent boots without the outlook.*
/// surface.
library;

export 'office_boot_stub.dart' if (dart.library.html) 'office_boot_web.dart';
