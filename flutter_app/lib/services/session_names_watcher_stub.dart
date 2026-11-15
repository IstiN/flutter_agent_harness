// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Non-IO platforms use hosted/store snapshot broadcasts instead of a file
/// watcher, so there is no desktop file to observe.
Stream<void>? watchSessionNamesFile(ExecutionEnv env) => null;
