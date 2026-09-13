// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/io.dart';

/// The isolate-backed session parser (IO platforms, issue #199): record
/// decoding runs off the UI isolate.
SessionParseExecutor? createSessionParseExecutor() =>
    const IsolateSessionParseExecutor();
