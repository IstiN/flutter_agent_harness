// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web stub (see office_boot.dart): no Office host off the web.
library;

import 'package:fa_office_agent/fa_office_agent.dart';

/// Always null outside the web build — desktop/mobile boots never carry
/// the outlook.* surface.
OfficeApi? bootOfficeApi() => null;
