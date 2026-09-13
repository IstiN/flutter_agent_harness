// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Web (no `dart:isolate`): `null` keeps record parsing inline in
/// pre-chunked batches (issue #199 E1).
SessionParseExecutor? createSessionParseExecutor() => null;
